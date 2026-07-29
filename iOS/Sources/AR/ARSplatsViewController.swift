//
//  AR mode: runs an `ARSession`, drives `ARSplatsRenderer` from a display link, and lets the user
//  tap to place the scene, pinch to resize it, and drag to spin it.
//
//  Presented full-screen from the viewer. It owns its own renderer (and therefore its own
//  `GraciaContext` and `Scene` built from the same URL) — scenes are bound to the context that made
//  them, so AR cannot borrow the viewer's.
//

import ARKit
import Metal
import UIKit
import simd

/// A bare UIView whose backing layer is a `CAMetalLayer`, so the renderer can present into it.
final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class ARSplatsViewController: UIViewController {
    private let sceneURL: URL
    private let session = ARSession()
    private var renderer: ARSplatsRenderer?
    private var displayLink: CADisplayLink?

    private let metalView = MetalLayerView()
    private let instruction = UILabel()
    private let closeButton = UIButton(type: .system)
    private let presetBar = UIScrollView()
    private var lastPanTranslationX: CGFloat = 0
    private var lastPinchScale: CGFloat = 1
    /// Identity of the last environment-probe texture we projected, so we re-project only on change.
    private var lastProbeTextureID: ObjectIdentifier?

    init(sceneURL: URL) {
        self.sceneURL = sceneURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalView.frame = view.bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(metalView)

        do {
            let renderer = try ARSplatsRenderer(layer: metalView.metalLayer)
            try renderer.load(url: sceneURL)
            renderer.onStatus = { [weak self] in self?.updateStatus($0) }
            self.renderer = renderer
        } catch {
            presentErrorAndDismiss(error)
            return
        }

        buildOverlay()
        addGestures()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        // Have ARKit build environment cube maps we can project to SH for the splats' lighting.
        config.environmentTexturing = .automatic
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let layer = metalView.metalLayer
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Frame loop

    @objc private func tick() {
        guard let renderer, let frame = session.currentFrame else { return }
        feedEnvironmentProbe(frame, to: renderer)
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        renderer.render(frame: frame, orientation: orientation, viewportSize: view.bounds.size)
    }

    /// Hands the renderer the environment cube map from the probe nearest the placed scene, whenever
    /// ARKit updates it. Picking the nearest probe (rather than `anchors.first`, whose order isn't
    /// stable) keeps the choice steady and re-projects only when that probe's texture actually
    /// changes — which ARKit does as you move around, so the lighting tracks the room.
    private func feedEnvironmentProbe(_ frame: ARFrame, to renderer: ARSplatsRenderer) {
        guard renderer.usingProbe else { return }
        let probes = frame.anchors
            .compactMap { $0 as? AREnvironmentProbeAnchor }
            .filter { $0.environmentTexture != nil }
        guard !probes.isEmpty else { return }

        let chosen: AREnvironmentProbeAnchor
        if let scene = renderer.scenePosition {
            chosen = probes.min { probeDistanceSq($0, scene) < probeDistanceSq($1, scene) }!
        } else {
            chosen = probes[0]
        }

        guard let cube = chosen.environmentTexture else { return }
        let id = ObjectIdentifier(cube)
        guard id != lastProbeTextureID else { return }
        lastProbeTextureID = id
        renderer.updateEnvironmentProbe(cube)
    }

    private func probeDistanceSq(_ probe: AREnvironmentProbeAnchor, _ p: SIMD3<Float>) -> Float {
        let t = probe.transform.columns.3
        let d = SIMD3(t.x, t.y, t.z) - p
        return simd_dot(d, d)
    }

    // MARK: - Placement & manipulation

    private func addGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        view.addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let renderer, let frame = session.currentFrame else { return }
        let loc = g.location(in: view)

        // ARFrame.raycastQuery takes the point in normalised UI coordinates (0…1, top-left) —
        // Apple's documented space; ARKit maps it to the captured image internally. So this is a
        // plain view-normalised point: NOT pixels, and NOT the image space displayTransform uses.
        let normalized = CGPoint(x: loc.x / view.bounds.width, y: loc.y / view.bounds.height)
        let query = frame.raycastQuery(from: normalized, allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            let t = hit.worldTransform
            renderer.place(at: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z))
        } else {
            // No surface found — drop it a metre ahead so a tap always does something.
            renderer.place(using: frame)
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let x = g.translation(in: view).x
        switch g.state {
        case .began:
            lastPanTranslationX = x
        case .changed:
            let dx = x - lastPanTranslationX
            lastPanTranslationX = x
            // A full view-width drag spins the scene roughly one full turn.
            renderer?.addYaw(Float(dx / view.bounds.width) * (2 * .pi))
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            lastPinchScale = 1
        case .changed:
            renderer?.multiplyScale(Float(g.scale / lastPinchScale))
            lastPinchScale = g.scale
        default: break
        }
    }

    // MARK: - Overlay

    private func buildOverlay() {
        instruction.translatesAutoresizingMaskIntoConstraints = false
        instruction.numberOfLines = 0
        instruction.textAlignment = .center
        instruction.textColor = .white
        instruction.font = .systemFont(ofSize: 15, weight: .medium)
        instruction.text = "Point at a surface and tap to place the scene."
        instruction.layer.shadowColor = UIColor.black.cgColor
        instruction.layer.shadowRadius = 4
        instruction.layer.shadowOpacity = 0.9
        instruction.layer.shadowOffset = .zero
        view.addSubview(instruction)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)

        buildPresetBar()

        NSLayoutConstraint.activate([
            instruction.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instruction.bottomAnchor.constraint(equalTo: presetBar.topAnchor, constant: -12),
            instruction.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// A scrollable row: Off · Probe · then every SDK preset. Tapping applies it right away.
    private func buildPresetBar() {
        presetBar.translatesAutoresizingMaskIntoConstraints = false
        presetBar.showsHorizontalScrollIndicator = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)

        stack.addArrangedSubview(chip("Off") { [weak self] in
            self?.renderer?.disableEnvironment(); self?.setEnvLabel("off")
        })
        stack.addArrangedSubview(chip("Probe") { [weak self] in
            self?.lastProbeTextureID = nil
            self?.renderer?.useProbe(); self?.setEnvLabel("probe")
        })
        for preset in ARSplatsRenderer.presets {
            stack.addArrangedSubview(chip(preset.name) { [weak self] in
                self?.renderer?.applyPreset(preset.sh); self?.setEnvLabel(preset.name)
            })
        }

        presetBar.addSubview(stack)
        view.addSubview(presetBar)
        NSLayoutConstraint.activate([
            presetBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            presetBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            presetBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            presetBar.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: presetBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: presetBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: presetBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: presetBar.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: presetBar.heightAnchor),
        ])
    }

    private func chip(_ title: String, _ handler: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .white
        config.background.backgroundColor = UIColor(white: 0, alpha: 0.5)
        config.background.cornerRadius = 16
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        return UIButton(configuration: config, primaryAction: UIAction { _ in handler() })
    }

    private func setEnvLabel(_ name: String) {
        instruction.text = "env: \(name)"
    }

    private func updateStatus(_ s: ARStatus) {
        instruction.text = s.isPlaced
            ? "\(decimal(s.visibleSplats)) splats · pinch to resize · drag to spin · tap to move"
            : "Point at a surface and tap to place the scene."
    }

    private func decimal(_ n: UInt32) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func presentErrorAndDismiss(_ error: any Error) {
        let alert = UIAlertController(
            title: "Could not start AR", message: "\(error)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
}
