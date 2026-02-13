import ApplicationServices
import CoreGraphics

struct WindowRef {
    let windowID: CGWindowID
    let pid: pid_t
    var axWindow: AXUIElement?
    let frame: CGRect
    let title: String
    let appName: String
}

struct Slot {
    let rect: CGRect
    var windowID: CGWindowID?
}

struct LayoutState {
    var slots: [Slot]
}

struct DragState {
    var active: Bool
    let draggedWindowID: CGWindowID
    let startPoint: CGPoint
    var currentPoint: CGPoint
    let originalFrame: CGRect
    var hoverSlotIndex: Int?
}

struct ActiveLayoutContext {
    let displayID: CGDirectDisplayID
    var slots: [Slot]
    var order: [CGWindowID]
    var windowsByID: [CGWindowID: WindowRef]
}
