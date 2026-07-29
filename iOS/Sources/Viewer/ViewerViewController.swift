//
//  The 2D viewer screen: a full-screen `SplatsMetalView`, a HUD, a transport bar, and two buttons
//  in the nav bar — Open (pick a scene) and AR (drop the loaded scene into the world).
//
//  Kept deliberately plain, like the mac demo: no settings, no appearance panel, just playback.
//

import ARKit
import GraciaSDK
import Metal
import UIKit
import UniformTypeIdentifiers

final class ViewerViewController: UIViewController {
    private var metalView: SplatsMetalView!
    private var currentURL: URL?

    private let hud = UILabel()
    private let transport = UIStackView()
    private let playButton = UIButton(type: .system)
    private let timeSlider = UISlider()
    private let clock = UILabel()
    private var arButton: UIBarButtonItem!
    private var isScrubbing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Gracia"
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            presentFatal("This device has no Metal GPU.")
            return
        }
        do {
            // A cache directory lets HTTP(S) MINT streams cache chunks on disk; harmless for files.
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            metalView = try SplatsMetalView(device: device, cacheDirectory: cache)
        } catch {
            presentFatal("Could not start the renderer.\n\(error)")
            return
        }

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.onStatus = { [weak self] in self?.updateStatus($0) }
        metalView.onSceneLoaded = { [weak self] in self?.sceneLoaded($0) }
        metalView.onError = { [weak self] in self?.report($0) }
        view.addSubview(metalView)

        buildChrome()
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Auto-load a scene bundled into the app, if a developer dropped one into Resources.
        if let bundled = bundledScene() {
            open(bundled)
        }
    }

    // The AR screen is presented full-screen, so this view disappears while it is up: stop the 2D
    // renderer then, and resume it on return, so the two Metal surfaces never draw at once.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        metalView?.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        metalView?.suspend()
    }

    // MARK: - Chrome

    private func buildChrome() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Open", style: .plain, target: self, action: #selector(openTapped))
        arButton = UIBarButtonItem(
            title: "AR", style: .plain, target: self, action: #selector(arTapped))
        arButton.isEnabled = false
        navigationItem.rightBarButtonItem = arButton

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.numberOfLines = 0
        hud.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hud.textColor = .white
        hud.text = "Tap Open to load a .ply, .sog or .mint scene."
        hud.layer.shadowColor = UIColor.black.cgColor
        hud.layer.shadowRadius = 3
        hud.layer.shadowOpacity = 0.9
        hud.layer.shadowOffset = .zero
        view.addSubview(hud)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.textColor = .white
        clock.textAlignment = .right
        clock.setContentHuggingPriority(.required, for: .horizontal)

        timeSlider.minimumValue = 0
        timeSlider.maximumValue = 1
        timeSlider.addTarget(self, action: #selector(scrub), for: .valueChanged)
        timeSlider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        timeSlider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        transport.axis = .horizontal
        transport.spacing = 12
        transport.alignment = .center
        transport.isLayoutMarginsRelativeArrangement = true
        transport.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        transport.translatesAutoresizingMaskIntoConstraints = false
        transport.addArrangedSubview(playButton)
        transport.addArrangedSubview(timeSlider)
        transport.addArrangedSubview(clock)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(transport)
        blur.isHidden = true
        transportBackdrop = blur
        view.addSubview(blur)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),

            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            transport.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            transport.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            transport.bottomAnchor.constraint(equalTo: blur.contentView.safeAreaLayoutGuide.bottomAnchor),
            clock.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
    }

    private var transportBackdrop: UIVisualEffectView!

    // MARK: - Loading

    @objc private func openTapped() {
        // .ply / .sog / .mint aren't system types, so accept any file and validate by extension.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func open(_ url: URL) {
        do {
            try metalView.load(url: url)
        } catch {
            report(error)
        }
    }

    private func sceneLoaded(_ url: URL) {
        currentURL = url
        arButton.isEnabled = true
    }

    private func bundledScene() -> URL? {
        for ext in Scene.supportedExtensions {
            if let url = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil)?.first {
                return url
            }
        }
        return nil
    }

    // MARK: - Transport

    @objc private func togglePlayback() {
        metalView.isPlaying.toggle()
    }

    @objc private func scrubBegan() { isScrubbing = true }
    @objc private func scrubEnded() { isScrubbing = false }

    @objc private func scrub(_ sender: UISlider) {
        metalView.seek(to: Double(sender.value))
    }

    private func updateStatus(_ s: ViewerStatus) {
        transportBackdrop.isHidden = !s.hasVideo
        if s.hasVideo {
            let name = s.isPlaying ? "pause.fill" : "play.fill"
            playButton.setImage(UIImage(systemName: name), for: .normal)
            if s.duration > 0 {
                timeSlider.maximumValue = Float(s.duration)
                if !isScrubbing { timeSlider.value = Float(s.playhead) }
                clock.text = s.isBuffering
                    ? "buffering…"
                    : String(format: "%.1f / %.1f", s.playhead, s.duration)
            }
        }

        hud.text = String(
            format: "%@\n%@ / %@ splats · %.0f fps · GPU %.0f MB",
            s.name, decimal(s.visibleSplats), decimal(s.splatsBudget),
            s.fps, Double(s.gpuBytes) / 1e6)
    }

    private func decimal(_ n: UInt32) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - AR

    @objc private func arTapped() {
        guard let currentURL else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            presentAlert("AR unavailable", "This device does not support world-tracking AR.")
            return
        }
        let ar = ARSplatsViewController(sceneURL: currentURL)
        ar.modalPresentationStyle = .fullScreen
        present(ar, animated: true)
    }

    // MARK: - Errors

    private func report(_ error: any Error) {
        presentAlert("Could not open the scene", "\(error)")
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentFatal(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }
}

extension ViewerViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        open(url)
    }
}
