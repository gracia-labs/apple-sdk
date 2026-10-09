#if os(macOS)

import Foundation
import GraciaCamera
import GraciaView

struct ViewerOptions {
    var sceneURLs: [URL] = []
    var layout: SceneLayout = .mix
    var screenshotPath: URL?
    var screenshotFrames = 20
    var zoom: Float = 1
    var seek: Double?
    var reloadURL: URL?
    var streamURL: String?
    var streamToken: String?

    /// Parses CLI arguments; see ``printUsage()``.
    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--screenshot":
                if let p = it.next() { screenshotPath = URL(fileURLWithPath: p) }
            case "--frames":
                if let n = it.next(), let v = Int(n) { screenshotFrames = max(1, v) }
            case "--reload":
                if let p = it.next() { reloadURL = URL(fileURLWithPath: p) }
            case "--stream":
                if let u = it.next() { streamURL = u }
            case "--token":
                if let t = it.next() { streamToken = t }
            case "--split":
                layout = .split
            case "--zoom":
                if let z = it.next(), let v = Float(z), v > 0 { zoom = v }
            case "--seek":
                if let t = it.next(), let v = Double(t) { seek = max(0, v) }
            case "--help", "-h":
                Self.printUsage()
                exit(0)
            default:
                if !arg.hasPrefix("-") {
                    sceneURLs.append(
                        URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
                }
            }
        }
    }

    static func printUsage() {
        print(
            """
            mac-viewer [scene] [options]

              scene...               one or more .ply, .sog (static), .mint or .grv (video) files

            Options:
              --stream <url>         open an HTTP(S) MINT stream instead of a file
              --token <token>        bearer token for --stream (optional)
              --screenshot <path>    render, write a PNG, and exit
              --frames <n>           frames to render before the screenshot (default 20)
              --reload <path>        load a second scene after 0.5s (exercises scene swapping)
              --split                side-by-side panes instead of compositing the scenes
              --zoom <factor>        zoom in after framing; >1 moves closer
              --seek <seconds>       pause a video at this time (renders that frame)

            Controls:
              drag            orbit / look
              right-drag      pan (also ⌥-drag)
              scroll, pinch   zoom
              wasd rf qe      fly: move, up/down, roll (⇧ sprints; scroll sets speed)
              space           play/pause video (speed slider in the transport bar)
              0               reset framing
              m               toggle mix / split (with more than one scene)
              b (hold)        show the split dividers
              ⌘O              open one or more files (mix)
              ⌘L              open a stream (URL + optional token)
              ⌘K              set a scene flag (key + on/off)
              drop            drop files on the window (two or more open split)
              top-right panel per-scene sliders to tune visibility and HSV grade
            """)
    }
}

#endif  // os(macOS)
