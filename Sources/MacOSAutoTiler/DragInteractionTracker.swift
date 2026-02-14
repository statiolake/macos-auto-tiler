import CoreGraphics
import Foundation

final class DragInteractionTracker {
    private enum State {
        case idle
        case pending(PendingDrag)
        case dragging(DragState)
    }

    private let moveThreshold: CGFloat
    private var state: State = .idle

    init(moveThreshold: CGFloat = 4) {
        self.moveThreshold = moveThreshold
    }

    var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    var pendingWindowID: CGWindowID? {
        guard case let .pending(pending) = state else {
            return nil
        }
        return pending.windowID
    }

    var draggedWindowID: CGWindowID? {
        guard case let .dragging(dragState) = state else {
            return nil
        }
        return dragState.draggedWindowID
    }

    func beginPendingDrag(window: WindowRef) {
        state = .pending(
            PendingDrag(
                windowID: window.windowID,
                originalFrame: window.frame
            )
        )
    }

    func clearPendingDrag() {
        if case .pending = state {
            state = .idle
        }
    }

    func clearAll() {
        state = .idle
    }

    func maybeActivateDrag(currentPoint: CGPoint, latestWindow: WindowRef?) -> DragState? {
        guard
            case let .pending(pendingDrag) = state,
            let latestWindow,
            latestWindow.windowID == pendingDrag.windowID
        else {
            return nil
        }
        guard hasWindowMoved(original: pendingDrag.originalFrame, current: latestWindow.frame) else {
            return nil
        }

        let newState = DragState(
            draggedWindowID: latestWindow.windowID,
            startPoint: currentPoint,
            currentPoint: currentPoint,
            originalFrame: latestWindow.frame,
            hoverSlotIndex: nil
        )
        state = .dragging(newState)
        return newState
    }

    func updateDrag(point: CGPoint, hoverSlotIndex: Int?) -> DragState? {
        guard case var .dragging(dragState) = state else {
            return nil
        }
        dragState.currentPoint = point
        dragState.hoverSlotIndex = hoverSlotIndex
        state = .dragging(dragState)
        return dragState
    }

    func finishDrag(point: CGPoint, fallbackHoverSlotIndex: Int?) -> DragState? {
        guard case var .dragging(dragState) = state else {
            return nil
        }

        dragState.currentPoint = point
        if dragState.hoverSlotIndex == nil {
            dragState.hoverSlotIndex = fallbackHoverSlotIndex
        }

        state = .idle
        return dragState
    }

    private func hasWindowMoved(original: CGRect, current: CGRect) -> Bool {
        abs(original.origin.x - current.origin.x) >= moveThreshold ||
            abs(original.origin.y - current.origin.y) >= moveThreshold ||
            abs(original.size.width - current.size.width) >= moveThreshold ||
            abs(original.size.height - current.size.height) >= moveThreshold
    }
}
