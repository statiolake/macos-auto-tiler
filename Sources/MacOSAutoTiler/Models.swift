import CoreGraphics

struct WindowRef {
    let windowID: CGWindowID
    let pid: pid_t
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let title: String
    let appName: String
    let bundleID: String?
    let spaceID: Int

    func with(frame: CGRect, displayID: CGDirectDisplayID? = nil) -> WindowRef {
        WindowRef(
            windowID: windowID,
            pid: pid,
            displayID: displayID ?? self.displayID,
            frame: frame,
            title: title,
            appName: appName,
            bundleID: bundleID,
            spaceID: spaceID
        )
    }
}

struct Slot {
    let rect: CGRect
}

struct DragState {
    let draggedWindowID: CGWindowID
    let startPoint: CGPoint
    var currentPoint: CGPoint
    let originalFrame: CGRect
    var hoverSlotIndex: Int?
}

struct PendingDrag {
    let windowID: CGWindowID
    let originalFrame: CGRect
}

struct DisplayLayoutPlan {
    let displayID: CGDirectDisplayID
    let spaceID: Int
    let slots: [Slot]
    let orderedWindowIDs: [CGWindowID]   // slots[i].rect が orderedWindowIDs[i] に対応
    let windowsByID: [CGWindowID: WindowRef]

    var targetFrames: [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: zip(orderedWindowIDs, slots).map { ($0, $1.rect) })
    }

    func slotIndex(of windowID: CGWindowID) -> Int? {
        orderedWindowIDs.firstIndex(of: windowID)
    }
}
