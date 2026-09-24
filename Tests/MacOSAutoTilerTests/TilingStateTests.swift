import CoreGraphics
import XCTest
@testable import MacOSAutoTiler

final class TilingStateTests: XCTestCase {
    private let spaceA = SpaceKey(displayID: 1, spaceID: 10)
    private let spaceB = SpaceKey(displayID: 1, spaceID: 11)
    private let spaceOnOtherDisplay = SpaceKey(displayID: 2, spaceID: 20)

    func testReconcileAppendsNewWindowsFrontToBack() {
        var state = TilingState()
        state.reconcile(with: snapshot([window(3, in: spaceA), window(1, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 3])
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [3, 1])

        state.reconcile(with: snapshot([window(2, in: spaceA), window(3, in: spaceA), window(1, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2, 3])
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [3, 1, 2], "existing order is kept; new windows go last")
    }

    func testReconcileDropsWindowsThatLeftAVisibleSpace() {
        var state = TilingState()
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2])
        // Window 2 was minimized: still alive, but no longer on screen.
        state.reconcile(with: snapshot([window(1, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2])

        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [1])
    }

    func testReconcileKeepsHiddenSpacesUntilTheirWindowsDie() {
        var state = TilingState()
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2])

        state.reconcile(with: snapshot([window(3, in: spaceB)], showing: [spaceB]), liveWindowIDs: [1, 2, 3])
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [1, 2])

        state.reconcile(with: snapshot([window(3, in: spaceB)], showing: [spaceB]), liveWindowIDs: [2, 3])
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])
    }

    func testReconcileMovesAWindowThatShowsUpOnAnotherSpace() {
        var state = TilingState()
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2])

        // The user moved window 1 to space B in Mission Control and switched there.
        state.reconcile(with: snapshot([window(1, in: spaceB)], showing: [spaceB]), liveWindowIDs: [1, 2])

        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])
        XCTAssertEqual(state.layout(for: spaceB).windowIDs, [1])
        XCTAssertEqual(state.space(of: 1), spaceB)
    }

    func testReconcileKeepsADroppedWindowInItsTargetSpace() {
        var state = TilingState()
        let showing = [spaceA, spaceOnOtherDisplay]
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: showing), liveWindowIDs: [1, 2])

        // Dropped into the other display, but the window has not been moved there yet.
        state.insert(1, into: spaceOnOtherDisplay, at: 0)
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: showing), liveWindowIDs: [1, 2])

        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])
        XCTAssertEqual(state.layout(for: spaceOnOtherDisplay).windowIDs, [1])
    }

    func testReconcileSkipsFloatingAndUntilableWindows() {
        var state = TilingState()
        state.setFloating(2, true)
        state.reconcile(
            with: snapshot([window(1, in: spaceA), window(2, in: spaceA), window(3, in: spaceA, tilable: false)], showing: [spaceA]),
            liveWindowIDs: [1, 2, 3]
        )
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [1])
    }

    func testFloatingIsForgottenOnceTheWindowIsGone() {
        var state = TilingState()
        state.setFloating(2, true)
        state.reconcile(with: snapshot([], showing: [spaceA]), liveWindowIDs: [])
        XCTAssertEqual(state.floatingWindowIDs, [])
    }

    func testSettingFloatingRemovesFromLayoutAndUnsettingLetsReconcileAppendIt() {
        var state = TilingState()
        let windows = [window(1, in: spaceA), window(2, in: spaceA)]
        state.reconcile(with: snapshot(windows, showing: [spaceA]), liveWindowIDs: [1, 2])

        state.setFloating(1, true)
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])

        state.setFloating(1, false)
        state.reconcile(with: snapshot(windows, showing: [spaceA]), liveWindowIDs: [1, 2])
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2, 1])
    }

    func testInsertMovesAcrossSpacesAndClampsTheSlot() {
        var state = TilingState()
        state.reconcile(
            with: snapshot([window(1, in: spaceA), window(2, in: spaceA), window(3, in: spaceOnOtherDisplay)], showing: [spaceA, spaceOnOtherDisplay]),
            liveWindowIDs: [1, 2, 3]
        )

        state.insert(1, into: spaceOnOtherDisplay, at: 0)
        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])
        XCTAssertEqual(state.layout(for: spaceOnOtherDisplay).windowIDs, [1, 3])

        state.insert(2, into: spaceOnOtherDisplay, at: 99)
        XCTAssertEqual(state.layout(for: spaceOnOtherDisplay).windowIDs, [1, 3, 2])
    }

    func testRemoveKeepsTheRatiosOfTheSpace() {
        var state = TilingState()
        state.reconcile(with: snapshot([window(1, in: spaceA), window(2, in: spaceA)], showing: [spaceA]), liveWindowIDs: [1, 2])
        state.updateLayout(for: spaceA) { $0.masterRatio = 0.7 }

        state.remove(1)

        XCTAssertEqual(state.layout(for: spaceA).windowIDs, [2])
        XCTAssertEqual(state.layout(for: spaceA).masterRatio, 0.7)
    }

    private func window(_ id: CGWindowID, in space: SpaceKey, tilable: Bool = true) -> ObservedWindow {
        ObservedWindow(
            windowID: id,
            pid: 100,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            title: "window \(id)",
            appName: "Example",
            bundleID: "com.example.app",
            space: space,
            isTilable: tilable
        )
    }

    private func snapshot(_ windows: [ObservedWindow], showing spaces: [SpaceKey]) -> WindowSnapshot {
        WindowSnapshot(
            windows: windows,
            visibleSpaces: Dictionary(uniqueKeysWithValues: spaces.map { ($0.displayID, $0) }),
            isComplete: true
        )
    }
}
