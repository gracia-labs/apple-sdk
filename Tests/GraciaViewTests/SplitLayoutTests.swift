#if os(macOS)

import CoreGraphics
import Testing

@testable import GraciaView

/// The panes are scissored columns of one render pass, so any pixel column that no pane covers is
/// left showing the clear colour — a seam. These pin the arithmetic that prevents it.
@MainActor
@Suite("Split layout")
struct SplitLayoutTests {
    @Test func oneSceneIsNotSplit() {
        let layout = SplitLayout()
        layout.reset(paneCount: 0)
        #expect(!layout.isActive)
        #expect(layout.dividerPositions(width: 100).isEmpty)
        #expect(layout.scissorRects(width: 100, height: 50).isEmpty)
    }

    @Test func panesStartEqual() {
        let layout = SplitLayout()
        layout.reset(paneCount: 3)
        #expect(layout.paneCount == 3)
        #expect(layout.isActive)
        #expect(layout.ratios.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
        #expect(layout.dividerPositions(width: 300) == [100, 200])
    }

    /// 2560 / 3 is not an integer: the last pane absorbs the rounding so the columns tile exactly.
    @Test func scissorRectsTileTheTargetExactly() {
        for (paneCount, width) in [(2, 2560), (3, 2560), (3, 1001), (4, 999), (2, 1)] {
            let layout = SplitLayout()
            layout.reset(paneCount: paneCount)
            let rects = layout.scissorRects(width: width, height: 100)

            #expect(rects.count == paneCount)
            #expect(rects[0].x == 0)
            #expect(rects.reduce(0) { $0 + $1.width } == width)
            for (a, b) in zip(rects, rects.dropFirst()) {
                #expect(a.x + a.width == b.x)  // no gap, no overlap
            }
            #expect(rects.last!.x + rects.last!.width == width)
            #expect(rects.allSatisfy { $0.y == 0 && $0.height == 100 })
        }
    }

    @Test func degenerateSizesProduceNoRects() {
        let layout = SplitLayout()
        layout.reset(paneCount: 2)
        #expect(layout.scissorRects(width: 0, height: 100).isEmpty)
        #expect(layout.scissorRects(width: 100, height: 0).isEmpty)
    }

    @Test func draggingADividerMovesOnlyItsNeighbours() {
        let layout = SplitLayout()
        layout.reset(paneCount: 3)
        layout.drag(divider: 0, dx: 30, width: 300)  // +0.1

        #expect(abs(layout.ratios[0] - (1.0 / 3 + 0.1)) < 1e-6)
        #expect(abs(layout.ratios[1] - (1.0 / 3 - 0.1)) < 1e-6)
        #expect(abs(layout.ratios[2] - 1.0 / 3) < 1e-6)  // untouched
        #expect(abs(layout.ratios.reduce(0, +) - 1) < 1e-6)
    }

    /// A divider can never swallow its neighbour: both keep a 5% minimum.
    @Test func draggingIsClampedToAMinimumPaneWidth() {
        let layout = SplitLayout()
        layout.reset(paneCount: 2)

        layout.drag(divider: 0, dx: 10_000, width: 100)
        #expect(abs(layout.ratios[1] - 0.05) < 1e-6)
        #expect(abs(layout.ratios.reduce(0, +) - 1) < 1e-6)

        layout.drag(divider: 0, dx: -10_000, width: 100)
        #expect(abs(layout.ratios[0] - 0.05) < 1e-6)
        #expect(abs(layout.ratios.reduce(0, +) - 1) < 1e-6)
    }

    @Test func draggingAnOutOfRangeDividerIsIgnored() {
        let layout = SplitLayout()
        layout.reset(paneCount: 2)
        let before = layout.ratios
        layout.drag(divider: 5, dx: 10, width: 100)
        layout.drag(divider: 0, dx: 10, width: 0)  // zero width
        #expect(layout.ratios == before)
    }

    @Test func dividersAreGrabbedWithinTheHitZone() {
        let layout = SplitLayout()
        layout.reset(paneCount: 2)
        let mid: CGFloat = 500  // width 1000

        #expect(layout.dividerIndex(nearX: mid, width: 1000) == 0)
        #expect(layout.dividerIndex(nearX: mid + SplitLayout.dividerHitZone - 1, width: 1000) == 0)
        #expect(layout.dividerIndex(nearX: mid + SplitLayout.dividerHitZone + 1, width: 1000) == nil)
        #expect(layout.dividerIndex(nearX: 0, width: 1000) == nil)
    }
}

#endif  // os(macOS)
