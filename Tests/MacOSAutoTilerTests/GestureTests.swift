import CoreGraphics
import XCTest
@testable import MacOSAutoTiler

final class GestureTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testMovedWindowClassifiesAsDrag() {
        let pending = Gesture.Pending(candidates: [window(1, frame: frame)], point: .zero)
        guard case let .drag(window) = pending.classify(currentFrames: [1: frame.offsetBy(dx: 30, dy: 0)]) else {
            return XCTFail("expected a drag")
        }
        XCTAssertEqual(window.windowID, 1)
    }

    func testResizedWindowClassifiesAsResizeEvenIfItAlsoMoved() {
        let pending = Gesture.Pending(candidates: [window(1, frame: frame)], point: .zero)
        let resized = CGRect(x: 80, y: 100, width: 420, height: 300)
        guard case let .resize(window, currentFrame) = pending.classify(currentFrames: [1: resized]) else {
            return XCTFail("expected a resize")
        }
        XCTAssertEqual(window.windowID, 1)
        XCTAssertEqual(currentFrame, resized)
    }

    func testUnchangedWindowsClassifyAsNone() {
        let pending = Gesture.Pending(candidates: [window(1, frame: frame), window(2, frame: frame)], point: .zero)
        guard case .none = pending.classify(currentFrames: [1: frame.offsetBy(dx: 2, dy: 0)]) else {
            return XCTFail("movement below the threshold must not start a gesture")
        }
    }

    func testFirstChangedCandidateWins() {
        let pending = Gesture.Pending(candidates: [window(1, frame: frame), window(2, frame: frame)], point: .zero)
        guard case let .drag(window) = pending.classify(currentFrames: [1: frame, 2: frame.offsetBy(dx: 0, dy: 50)]) else {
            return XCTFail("expected a drag")
        }
        XCTAssertEqual(window.windowID, 2)
    }

    func testResizeProjectsOnlyTheEdgeThatMoved() {
        let current = CGRect(x: 100, y: 100, width: 430, height: 300)
        let resize = Gesture.Resize(windowID: 1, space: SpaceKey(displayID: 1, spaceID: 1), originalFrame: frame, currentFrame: current)

        XCTAssertEqual(resize.projectedFrame(at: CGPoint(x: 700, y: 999)), CGRect(x: 100, y: 100, width: 600, height: 300))
    }

    func testResizeProjectionKeepsAMinimumExtent() {
        let current = CGRect(x: 120, y: 100, width: 380, height: 300)
        let resize = Gesture.Resize(windowID: 1, space: SpaceKey(displayID: 1, spaceID: 1), originalFrame: frame, currentFrame: current)

        let projected = resize.projectedFrame(at: CGPoint(x: 900, y: 0))
        XCTAssertEqual(projected.maxX, frame.maxX)
        XCTAssertEqual(projected.width, Gesture.Resize.minimumExtent)
    }

    private func window(_ id: CGWindowID, frame: CGRect) -> ObservedWindow {
        ObservedWindow(
            windowID: id,
            pid: 100,
            frame: frame,
            title: "window \(id)",
            appName: "Example",
            bundleID: "com.example.app",
            space: SpaceKey(displayID: 1, spaceID: 1),
            isTilable: true
        )
    }
}
