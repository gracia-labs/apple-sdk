#if os(macOS)

import AppKit
import GraciaCamera
import GraciaSDK
import GraciaView
import Metal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: ViewerOptions
    private var window: NSWindow!
    private var view: SplatsSceneView!
    private var hud: NSTextField!
    private var transport: NSStackView!
    private var timeSlider: NSSlider!
    private var playPause: NSButton!
    private var clock: NSTextField!
    private var speedSlider: NSSlider!
    private var speedReadout: NSTextField!
    private var isScrubbing = false

    // Per-scene visibility + HSV sliders, rebuilt on scene change, so open files tune independently.
    private var appearanceContainer: NSView!
    private var appearanceStack: NSStackView!
    private var appearanceRows: [SceneAppearanceRow] = []

    // Remembered across "Set Flag…" dialogs so you needn't retype.
    private var lastFlagKey = ""
    private var lastFlagOn = true

    init(options: ViewerOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fail("No Metal device available.") }

        do {
            view = try SplatsSceneView(device: device)
        } catch {
            // Also NULL when a GPU frame debugger is attached.
            fail("\(error)")
        }

        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        view.onCommandKey = { [weak self] code in self?.handleKey(code) ?? false }
        view.onStatus = { [weak self] status in self?.updateHUD(status) }
        view.onSceneLoaded = { [weak self] urls in
            guard let self else { return }
            self.updateTitle(urls)
            self.rebuildAppearanceControls()
            self.appearanceContainer.isHidden = false
            self.applyAppearance()
        }
        view.onError = { [weak self] error in self?.report(error) }

        buildMenu()
        buildWindow()

        if !options.sceneURLs.isEmpty {
            open(options.sceneURLs, layout: options.layout)
            if options.zoom != 1 { view.camera.zoom(options.zoom) }
            if let t = options.seek {
                view.isPlaying = false
                view.seek(to: t)
            }
        } else if let stream = options.streamURL {
            openStream(url: stream, token: options.streamToken)
        }

        if let second = options.reloadURL {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated { self.open([second]) }
            }
        }

        if let path = options.screenshotPath {
            guard view.hasScenes else { fail("--screenshot needs a scene that loaded successfully") }
            // A screenshot run isn't key, so pause-when-inactive would stop it before it drew.
            view.ignoresWindowActivation = true
            view.snapshot(to: path, afterFrames: options.screenshotFrames) {
                [weak self] result in
                if case .failure(let error) = result { self?.fail("\(error)") }
                NSApp.terminate(nil)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Scene

    private func open(_ urls: [URL], layout: SceneLayout = .mix) {
        do {
            try view.load(urls: urls, layout: layout)
        } catch {
            report(error, opening: urls)
        }
    }

    private func updateTitle(_ urls: [URL]) {
        window?.title =
            urls.count == 1
            ? "Gracia — \(urls[0].lastPathComponent)"
            : "Gracia — \(urls.count) scenes"
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more .ply, .sog, .mint or .grv scenes"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(panel.urls)
    }

    /// Prompts for a stream URL + optional token, then opens it.
    @objc private func openStreamDialog(_ sender: Any?) {
        let urlField = NSTextField(frame: NSRect(x: 52, y: 30, width: 308, height: 22))
        urlField.placeholderString = "https://…/stream.mint"
        let tokenField = NSTextField(frame: NSRect(x: 52, y: 0, width: 308, height: 22))
        tokenField.placeholderString = "optional"
        urlField.nextKeyView = tokenField

        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 48, height: 22)
            l.alignment = .right
            return l
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        accessory.subviews = [label("URL", y: 30), urlField, label("Token", y: 0), tokenField]

        let alert = NSAlert()
        alert.messageText = "Open Stream"
        alert.informativeText = "Enter the URL of a MINT stream. A token is optional."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        // Caret starts in the URL field, not a button.
        alert.window.initialFirstResponder = urlField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        openStream(url: url, token: token.isEmpty ? nil : token)
    }

    private func openStream(url: String, token: String?) {
        do {
            try view.load(streamURL: url, token: token)
        } catch {
            report(error)
        }
    }

    /// Prompts for a flag key and an on/off value, then applies it to the loaded scene(s).
    @objc private func setFlagDialog(_ sender: Any?) {
        let keyField = NSTextField(frame: NSRect(x: 0, y: 26, width: 320, height: 22))
        keyField.placeholderString = "flag key"
        keyField.stringValue = lastFlagKey

        let checkbox = NSButton(checkboxWithTitle: "On (true)", target: nil, action: nil)
        checkbox.frame = NSRect(x: 0, y: 0, width: 320, height: 18)
        checkbox.state = lastFlagOn ? .on : .off

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
        accessory.subviews = [keyField, checkbox]

        let alert = NSAlert()
        alert.messageText = "Set Scene Flag"
        alert.informativeText = "Applies to the loaded scene(s)."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = keyField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lastFlagKey = key
        lastFlagOn = checkbox.state == .on
        view.setSceneFlag(key, lastFlagOn)
    }

    /// Matched by physical key code, so the shortcuts land on the same keys on every layout.
    private func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case KeyCode.space: view.isPlaying.toggle()
        case KeyCode.zero: view.camera.reset()
        case KeyCode.m: try? view.toggleLayout()
        default: return false
        }
        return true
    }

    // MARK: - Chrome

    private func buildWindow() {
        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Gracia Viewer"
        window.center()

        let content = NSView(frame: view.frame)
        content.addSubview(view)
        view.autoresizingMask = [.width, .height]

        hud = NSTextField(
            labelWithString: "Drop a .ply / .sog / .mint / .grv file, press ⌘O, or ⌘L to open a stream")
        hud.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hud.textColor = .white
        hud.drawsBackground = false
        hud.isBezeled = false
        hud.maximumNumberOfLines = 0
        hud.shadow = {
            let s = NSShadow()
            s.shadowColor = .black
            s.shadowBlurRadius = 3
            return s
        }()
        hud.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hud.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
        ])

        buildTransport(in: content)
        buildAppearancePanel(in: content)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    /// Hidden for a static scene.
    private func buildTransport(in content: NSView) {
        playPause = NSButton(title: "", target: self, action: #selector(togglePlayback))
        playPause.bezelStyle = .rounded
        playPause.setButtonType(.momentaryPushIn)

        timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(scrub))
        // Fires during the drag so the picture tracks the thumb.
        timeSlider.isContinuous = true
        // Or the scene view loses key events the moment you touch the transport.
        timeSlider.refusesFirstResponder = true
        playPause.refusesFirstResponder = true

        clock = NSTextField(labelWithString: "")
        clock.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        clock.textColor = .secondaryLabelColor
        clock.alignment = .right

        speedSlider = NSSlider(
            value: 1, minValue: 0.1, maxValue: 2, target: self, action: #selector(speedChanged))
        speedSlider.isContinuous = true
        speedSlider.refusesFirstResponder = true
        speedSlider.controlSize = .small
        speedSlider.toolTip = "Playback speed"

        speedReadout = NSTextField(labelWithString: "1.0×")
        speedReadout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedReadout.textColor = .secondaryLabelColor
        speedReadout.alignment = .right

        transport = NSStackView(views: [playPause, timeSlider, clock, speedSlider, speedReadout])
        transport.orientation = .horizontal
        transport.spacing = 10
        transport.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        transport.translatesAutoresizingMaskIntoConstraints = false
        transport.wantsLayer = true
        transport.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        transport.isHidden = true

        content.addSubview(transport)
        NSLayoutConstraint.activate([
            transport.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            clock.widthAnchor.constraint(equalToConstant: 88),
            speedSlider.widthAnchor.constraint(equalToConstant: 90),
            speedReadout.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        view.playbackSpeed = sender.doubleValue
        speedReadout.stringValue = String(format: "%.1f×", sender.doubleValue)
    }

    @objc private func togglePlayback() {
        view.isPlaying.toggle()
    }

    /// While the thumb is down the slider wins, so `updateTransport` must not write the playhead back.
    @objc private func scrub(_ sender: NSSlider) {
        view.seek(to: sender.doubleValue)
        isScrubbing = NSApp.currentEvent?.type != .leftMouseUp
    }

    // MARK: - Appearance panel

    /// Empty scrollable shell; ``rebuildAppearanceControls()`` fills it once scenes load.
    private func buildAppearancePanel(in content: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        appearanceStack = stack

        // Overlay scroller so a tall stack scrolls without stealing layout width.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 8
        container.isHidden = true
        container.addSubview(scroll)
        appearanceContainer = container

        content.addSubview(container)

        // Hug the stack's height until it hits the window bottom, where the cap wins and it scrolls.
        let hug = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        hug.priority = .defaultHigh

        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            container.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hug,
        ])
    }

    /// Rebuilds one section per loaded scene. Called on every scene load.
    private func rebuildAppearanceControls() {
        for view in appearanceStack.arrangedSubviews { view.removeFromSuperview() }
        appearanceRows = []
        guard let scenes = view.group?.scenes else { return }

        for (i, scene) in scenes.enumerated() {
            if i > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(
                    equalToConstant: SceneAppearanceRow.width).isActive = true
                appearanceStack.addArrangedSubview(separator)
            }
            let row = SceneAppearanceRow(
                name: scene.name, index: i, target: self,
                sliderAction: #selector(appearanceChanged),
                resetAction: #selector(resetScene(_:)))
            appearanceStack.addArrangedSubview(row.container)
            appearanceRows.append(row)
        }
    }

    @objc private func appearanceChanged(_ sender: Any?) {
        for row in appearanceRows { row.refreshReadouts() }
        applyAppearance()
    }

    @objc private func resetScene(_ sender: NSButton) {
        guard appearanceRows.indices.contains(sender.tag) else { return }
        appearanceRows[sender.tag].reset()
        applyAppearance()
    }

    /// Applies each section to its scene. `weight` stays 1, so the grade is identity until tuned.
    private func applyAppearance() {
        guard let scenes = view.group?.scenes else { return }
        for (scene, row) in zip(scenes, appearanceRows) { row.apply(to: scene) }
        view.requestFrame()
    }

    /// One scene's appearance controls: header + reset over visibility and HSV sliders.
    @MainActor
    final class SceneAppearanceRow {
        /// Label + slider + readout, matched to the widths below.
        static let width: CGFloat = 66 + 8 + 130 + 8 + 42

        let container: NSStackView
        private let visibility: NSSlider
        private let hue: NSSlider
        private let saturation: NSSlider
        private let value: NSSlider
        private let visibilityOut: NSTextField
        private let hueOut: NSTextField
        private let saturationOut: NSTextField
        private let valueOut: NSTextField

        init(name: String, index: Int, target: AnyObject, sliderAction: Selector, resetAction: Selector) {
            func slider(min: Double, max: Double, value: Double) -> NSSlider {
                let s = NSSlider(
                    value: value, minValue: min, maxValue: max, target: target, action: sliderAction)
                s.isContinuous = true
                s.refusesFirstResponder = true
                s.controlSize = .small
                return s
            }
            func readout() -> NSTextField {
                let r = NSTextField(labelWithString: "")
                r.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                r.textColor = .secondaryLabelColor
                r.alignment = .right
                return r
            }
            func row(_ name: String, _ slider: NSSlider, _ out: NSTextField) -> NSStackView {
                let label = NSTextField(labelWithString: name)
                label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                label.textColor = .white
                label.alignment = .right
                let row = NSStackView(views: [label, slider, out])
                row.orientation = .horizontal
                row.spacing = 8
                NSLayoutConstraint.activate([
                    label.widthAnchor.constraint(equalToConstant: 66),
                    slider.widthAnchor.constraint(equalToConstant: 130),
                    out.widthAnchor.constraint(equalToConstant: 42),
                ])
                return row
            }

            visibility = slider(min: 0, max: 1, value: 1)
            hue = slider(min: -180, max: 180, value: 0)
            saturation = slider(min: 0, max: 2, value: 1)
            value = slider(min: 0, max: 2, value: 1)
            visibilityOut = readout()
            hueOut = readout()
            saturationOut = readout()
            valueOut = readout()

            let title = NSTextField(labelWithString: name)
            title.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            title.textColor = .white
            title.lineBreakMode = .byTruncatingMiddle
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let reset = NSButton(title: "Reset", target: target, action: resetAction)
            reset.bezelStyle = .rounded
            reset.controlSize = .mini
            reset.refusesFirstResponder = true
            // Lets ``resetScene(_:)`` find this button's section.
            reset.tag = index

            let header = NSStackView(views: [title, reset])
            header.orientation = .horizontal
            header.spacing = 8
            header.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

            container = NSStackView(views: [
                header,
                row("Visibility", visibility, visibilityOut),
                row("Hue", hue, hueOut),
                row("Saturation", saturation, saturationOut),
                row("Value", value, valueOut),
            ])
            container.orientation = .vertical
            container.alignment = .trailing
            container.spacing = 5
            refreshReadouts()
        }

        func refreshReadouts() {
            visibilityOut.stringValue = String(format: "%.2f", visibility.doubleValue)
            hueOut.stringValue = String(format: "%.0f°", hue.doubleValue)
            saturationOut.stringValue = String(format: "%.2f", saturation.doubleValue)
            valueOut.stringValue = String(format: "%.2f", value.doubleValue)
        }

        /// The SDK takes hue in turns; the slider is degrees.
        func apply(to scene: Scene) {
            scene.setVisibility(Float(visibility.doubleValue))
            scene.setColorGrade(
                hue: Float(hue.doubleValue / 360),
                saturation: Float(saturation.doubleValue),
                value: Float(value.doubleValue),
                weight: 1)
        }

        func reset() {
            visibility.doubleValue = 1
            hue.doubleValue = 0
            saturation.doubleValue = 1
            value.doubleValue = 1
            refreshReadouts()
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(
            title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        let streamItem = NSMenuItem(
            title: "Open Stream…", action: #selector(openStreamDialog(_:)), keyEquivalent: "l")
        streamItem.target = self
        fileMenu.addItem(streamItem)

        let flagItem = NSMenuItem(
            title: "Set Flag…", action: #selector(setFlagDialog(_:)), keyEquivalent: "k")
        flagItem.target = self
        fileMenu.addItem(flagItem)

        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        NSApp.mainMenu = mainMenu
    }

    private func updateTransport(_ s: SceneStatus) {
        transport.isHidden = !s.hasVideo
        guard s.hasVideo, s.duration > 0 else { return }

        playPause.title = s.isPlaying ? "Pause" : "Play"
        if timeSlider.maxValue != s.duration { timeSlider.maxValue = s.duration }
        if !isScrubbing { timeSlider.doubleValue = s.playhead }

        clock.stringValue =
            s.isBuffering
            ? "buffering…" : String(format: "%.1f / %.1f s", s.playhead, s.duration)
    }

    private func updateHUD(_ s: SceneStatus) {
        updateTransport(s)
        guard !s.sceneNames.isEmpty else { return }
        let title =
            s.sceneNames.count == 1
            ? s.sceneNames[0]
            : "\(s.sceneNames.count) scenes (\(s.layout.rawValue)): "
                + s.sceneNames.joined(separator: ", ")

        let lines = [
            "\(title)  —  \(fmt(s.visibleSplats)) / \(fmt(s.splatsBudget)) splats",
            String(
                format: "%.0f fps · GPU %.0f MB",
                s.fps, Double(s.gpuBytes) / 1e6),
        ]
        hud.stringValue = lines.joined(separator: "\n")
    }

    private func fmt(_ n: UInt32) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func report(_ error: any Error, opening urls: [URL] = []) {
        guard options.screenshotPath == nil else { fail("\(error)") }
        let alert = NSAlert()
        alert.messageText =
            urls.isEmpty
            ? "Could not open the scene"
            : "Could not open \(urls.map(\.lastPathComponent).joined(separator: ", "))"
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

#endif  // os(macOS)
