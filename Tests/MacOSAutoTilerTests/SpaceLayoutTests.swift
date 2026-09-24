import CoreGraphics
import XCTest
@testable import MacOSAutoTiler

final class SpaceLayoutTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// `area` minus the display inset, i.e. the region slots are carved from.
    private let tiled = CGRect(x: 12, y: 12, width: 976, height: 776)

    func testSingleWindowFillsTheArea() {
        let layout = SpaceLayout(windowIDs: [1])
        XCTAssertEqual(layout.targetFrames(in: area), [1: tiled.insetBy(dx: 8, dy: 8)])
    }

    func testMasterAndStackSplitByRatio() {
        let layout = SpaceLayout(windowIDs: [1, 2, 3], masterRatio: 0.5)
        let rects = layout.slotRects(count: 3, in: area)

        XCTAssertEqual(rects[0], CGRect(x: 12, y: 12, width: 488, height: 776).insetBy(dx: 8, dy: 8))
        XCTAssertEqual(rects[1], CGRect(x: 500, y: 12, width: 488, height: 388).insetBy(dx: 8, dy: 8))
        XCTAssertEqual(rects[2], CGRect(x: 500, y: 400, width: 488, height: 388).insetBy(dx: 8, dy: 8))
    }

    func testAddedStackSlotGetsAnEqualShare() {
        let layout = SpaceLayout(windowIDs: [1, 2, 3], stackWeights: [0.5, 0.5])
        let heights = layout.slotRects(count: 4, in: area).dropFirst().map(\.height)

        XCTAssertEqual(heights[0], heights[1], accuracy: 0.001)
        XCTAssertEqual(heights[1], heights[2], accuracy: 0.001)
    }

    func testResizingMasterRightEdgeMovesTheBoundary() {
        var layout = SpaceLayout(windowIDs: [1, 2])
        let original = layout.slotRects(count: 2, in: area)[0]
        var resized = original
        resized.size.width += 100

        layout.adjust(forResizeOf: 1, from: original, to: resized, in: area)

        XCTAssertEqual(layout.slotRects(count: 2, in: area)[0].maxX, resized.maxX, accuracy: 0.001)
    }

    func testResizingStackLeftEdgeMovesTheBoundary() {
        var layout = SpaceLayout(windowIDs: [1, 2, 3])
        let original = layout.slotRects(count: 3, in: area)[1]
        let resized = CGRect(x: original.minX - 100, y: original.minY, width: original.width + 100, height: original.height)

        layout.adjust(forResizeOf: 2, from: original, to: resized, in: area)

        XCTAssertEqual(layout.slotRects(count: 3, in: area)[1].minX, resized.minX, accuracy: 0.001)
    }

    func testResizingStackBottomEdgeMovesTheRowBoundary() {
        var layout = SpaceLayout(windowIDs: [1, 2, 3])
        let original = layout.slotRects(count: 3, in: area)[1]
        var resized = original
        resized.size.height += 50

        layout.adjust(forResizeOf: 2, from: original, to: resized, in: area)
        let rects = layout.slotRects(count: 3, in: area)

        XCTAssertEqual(rects[1].maxY, resized.maxY, accuracy: 0.001)
        // The row below shrinks; the pane's bottom edge stays put.
        XCTAssertEqual(rects[2].minY, resized.maxY + 2 * SpaceLayout.slotInset, accuracy: 0.001)
        XCTAssertEqual(rects[2].maxY, tiled.maxY - SpaceLayout.slotInset, accuracy: 0.001)
    }

    func testMasterRatioIsClamped() {
        var layout = SpaceLayout(windowIDs: [1, 2])
        let original = layout.slotRects(count: 2, in: area)[0]
        var resized = original
        resized.size.width = 950

        layout.adjust(forResizeOf: 1, from: original, to: resized, in: area)

        XCTAssertEqual(layout.masterRatio, SpaceLayout.masterRatioRange.upperBound)
    }
}
