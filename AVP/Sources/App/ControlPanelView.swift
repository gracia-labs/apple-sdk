//
//  The 2D control window: pick a scene, open/close the immersive space, and while it's open, adjust
//  where the scene sits and (for volumetric video) drive playback. A small HUD mirrors the renderer.
//

import GraciaSDK
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @Bindable var model: AppModel
    @Binding var immersion: ImmersionMode

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                sceneSection
                if model.isImmersed {
                    Divider()
                    gestureSection
                    if model.status.isVideo {
                        Divider()
                        playbackSection
                    }
                    Divider()
                    hud
                }
            }
            .padding(28)
        }
        .frame(minWidth: 380, minHeight: 420)
        .fileImporter(
            isPresented: $showImporter, allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        // Keep the renderer's clear-alpha (passthrough vs opaque black) in sync with the style,
        // including the initial value.
        .onChange(of: immersion, initial: true) { _, newValue in
            model.link.setImmersion(newValue)
        }
        // (No scenePhase reset: `isImmersed` is resynced by the renderer's onExit when the space
        // actually closes — see GraciaVisionApp — which the control window's scenePhase can't tell.)
        // Poll the render thread for the HUD while immersed.
        .task(id: model.isImmersed) {
            guard model.isImmersed else { return }
            while !Task.isCancelled {
                model.refreshStatus()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gracia — Vision Pro").font(.largeTitle.bold())
            Text("A stereo, head-tracked player for Gaussian-splat scenes.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Scene

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.sceneName ?? "No scene loaded", systemImage: "cube.transparent")
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Label("Open .ply / .sog / .mint / .grv", systemImage: "folder")
                }

                Button(model.isImmersed ? "Exit Immersive Space" : "Enter Immersive Space") {
                    toggleImmersiveSpace()
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = model.loadError {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(3)
            }

            if !model.isImmersed {
                Text("Load a scene, then enter the immersive space to step inside it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Placement

    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move it with your hands").font(.headline)
            Text("Pinch and drag with one hand to move the scene; pinch with both hands to scale and rotate it.")
                .font(.footnote).foregroundStyle(.secondary)

            Button {
                model.recenter()
            } label: {
                Label("Recenter in front of me", systemImage: "scope")
            }
        }
    }

    // MARK: Playback (volumetric video)

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback").font(.headline)
            HStack(spacing: 16) {
                Button {
                    model.isPlaying.toggle()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                if model.status.duration > 0 {
                    Slider(
                        value: Binding(
                            get: { model.status.playhead },
                            set: { model.seek(to: $0) }),
                        in: 0...model.status.duration)
                    Text(clock).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clock: String {
        model.status.buffering
            ? "buffering…"
            : String(format: "%.1f / %.1f", model.status.playhead, model.status.duration)
    }

    // MARK: Immersion + HUD

    private var hud: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Immersion", selection: $immersion) {
                ForEach(ImmersionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            let s = model.status
            Text(
                String(
                    format: "%@ / %@ splats · %.0f fps · GPU %.0f MB",
                    decimal(s.visibleSplats), decimal(s.splatsBudget), s.fps,
                    Double(s.gpuBytes) / 1e6)
            )
            .font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func decimal(_ n: UInt32) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func toggleImmersiveSpace() {
        Task {
            if model.isImmersed {
                await dismissImmersiveSpace()
                model.isImmersed = false
            } else {
                switch await openImmersiveSpace(id: GraciaVisionApp.immersiveSpaceID) {
                case .opened: model.isImmersed = true
                case .userCancelled, .error: model.isImmersed = false
                @unknown default: model.isImmersed = false
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            do {
                let copy = try Self.copyIntoContainer(source)
                model.selectScene(url: copy)
            } catch {
                model.loadError = "Couldn't import the file: \(error)"
            }
        case .failure(let error):
            model.loadError = "\(error)"
        }
    }

    /// Copies a picked (security-scoped) file into Application Support so the render thread can read
    /// it later on its own context — the same "as a copy" import the iOS demo does.
    private static func copyIntoContainer(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destination = dir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
