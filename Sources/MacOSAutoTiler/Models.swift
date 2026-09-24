import CoreGraphics

/// A native Mission Control space as seen on one display. Every key owns an independent tiling layout.
struct SpaceKey: Hashable, CustomStringConvertible {
    let displayID: CGDirectDisplayID
    let spaceID: Int

    var description: String {
        "display=\(displayID)/space=\(spaceID)"
    }
}

struct ObservedWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let title: String
    let appName: String
    let bundleID: String?
    let space: SpaceKey
    /// False for windows that must never be tiled: non-regular apps, dialogs, and rule-forced floating windows.
    let isTilable: Bool
}

/// On-screen windows at one instant, together with the space currently shown on every active display.
struct WindowSnapshot {
    /// Front-to-back order as reported by the window server.
    let windows: [ObservedWindow]
    let visibleSpaces: [CGDirectDisplayID: SpaceKey]
    /// False while the window server is mid-transition and some window or display has no resolvable space.
    let isComplete: Bool

    private let windowsByID: [CGWindowID: ObservedWindow]

    init(windows: [ObservedWindow], visibleSpaces: [CGDirectDisplayID: SpaceKey], isComplete: Bool) {
        self.windows = windows
        self.visibleSpaces = visibleSpaces
        self.isComplete = isComplete
        windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func window(_ windowID: CGWindowID) -> ObservedWindow? {
        windowsByID[windowID]
    }

    /// Identity of every window's placement; two snapshots with equal placements describe the same arrangement.
    var placements: Set<Placement> {
        Set(windows.map { Placement(windowID: $0.windowID, space: $0.space) })
    }

    struct Placement: Hashable {
        let windowID: CGWindowID
        let space: SpaceKey
    }
}
