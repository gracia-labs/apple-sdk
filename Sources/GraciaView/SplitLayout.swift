#if os(macOS)

import CoreGraphics
import Metal

/// Column ratios for split view, plus divider hit-testing and drag maths.
@MainActor
final class SplitLayout {
    /// Half-width, in points, of the grab zone around a divider.
    static let dividerHitZone: CGFloat = 8
    private static let minRatio: CGFloat = 0.05

    private(set) var ratios: [CGFloat] = []

    var paneCount: Int { ratios.count }
    var isActive: Bool { ratios.count > 1 }

    func reset(paneCount count: Int) {
        ratios = count > 0 ? Array(repeating: 1 / CGFloat(count), count: count) : []
    }

    /// x of each interior divider, in the same space as `width`.
    func dividerPositions(width: CGFloat) -> [CGFloat] {
        guard isActive else { return [] }
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for ratio in ratios.dropLast() {
            x += ratio * width
            xs.append(x)
        }
        return xs
    }

    func dividerIndex(nearX x: CGFloat, width: CGFloat) -> Int? {
        dividerPositions(width: width).firstIndex { abs(x - $0) < Self.dividerHitZone }
    }

    /// Moves divider `i` by `dx`, keeping both neighbours at least `minRatio` wide.
    func drag(divider i: Int, dx: CGFloat, width: CGFloat) {
        guard width > 0, ratios.indices.contains(i), ratios.indices.contains(i + 1) else { return }
        let total = ratios[i] + ratios[i + 1]
        let moved = (ratios[i] * width + dx) / width
        ratios[i] = Swift.min(Swift.max(Self.minRatio, moved), total - Self.minRatio)
        ratios[i + 1] = total - ratios[i]
    }

    /// One column per pane. The last pane absorbs the rounding so widths sum to exactly `width`,
    /// leaving no unwritten pixel columns between panes.
    func scissorRects(width: Int, height: Int) -> [MTLScissorRect] {
        guard !ratios.isEmpty, width > 0, height > 0 else { return [] }
        var rects: [MTLScissorRect] = []
        var x = 0
        for (i, ratio) in ratios.enumerated() {
            let remaining = width - x
            let w =
                i == ratios.count - 1
                ? remaining : Swift.min(Int((CGFloat(width) * ratio).rounded()), remaining)
            rects.append(
                MTLScissorRect(x: x, y: 0, width: Swift.max(0, w), height: height))
            x += Swift.max(0, w)
        }
        return rects
    }
}

#endif  // os(macOS)
