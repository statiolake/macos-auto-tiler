import CoreGraphics

struct WindowRef {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let title: String
    let appName: String
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
    let slots: [Slot]
    let slotToWindowID: [Int: CGWindowID]
    let windowToSlotIndex: [CGWindowID: Int]
    let windowsByID: [CGWindowID: WindowRef]

    var targetFrames: [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        result.reserveCapacity(slotToWindowID.count)
        for (slotIndex, windowID) in slotToWindowID {
            guard slotIndex >= 0, slotIndex < slots.count else {
                continue
            }
            result[windowID] = slots[slotIndex].rect
        }
        return result
    }
}

struct DropResolution {
    let displayID: CGDirectDisplayID
    let sourceSlotIndex: Int?
    let destinationSlotIndex: Int
    let shouldApply: Bool
    let targetFrames: [CGWindowID: CGRect]
    let windowsByID: [CGWindowID: WindowRef]
}
