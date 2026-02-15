import CoreGraphics
import Foundation

final class DragInteractionTracker {
    struct ResizeState {
        let windowID: CGWindowID
        let originalFrame: CGRect
    }

    private struct PendingState {
        var orderedWindowIDs: [CGWindowID]
        var entriesByWindowID: [CGWindowID: PendingDrag]
    }

    private enum State {
        case idle
        case pending(PendingState)
        case dragging(DragState)
        case resizing(ResizeState)
    }

    private let moveThreshold: CGFloat
    private let requiredMoveOnlySamples: Int
    private var state: State = .idle

    init(
        moveThreshold: CGFloat = 4,
        requiredMoveOnlySamples: Int = 2
    ) {
        self.moveThreshold = moveThreshold
        self.requiredMoveOnlySamples = max(1, requiredMoveOnlySamples)
    }

    var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    var isResizing: Bool {
        if case .resizing = state { return true }
        return false
    }

    var pendingWindowIDs: [CGWindowID] {
        guard case let .pending(pending) = state else {
            return []
        }
        return pending.orderedWindowIDs
    }

    var draggedWindowID: CGWindowID? {
        guard case let .dragging(dragState) = state else {
            return nil
        }
        return dragState.draggedWindowID
    }

    var resizingWindowID: CGWindowID? {
        guard case let .resizing(resizeState) = state else {
            return nil
        }
        return resizeState.windowID
    }

    var resizeState: ResizeState? {
        guard case let .resizing(resizeState) = state else {
            return nil
        }
        return resizeState
    }

    func beginPendingDrag(windows: [WindowRef]) {
        var orderedWindowIDs: [CGWindowID] = []
        var entriesByWindowID: [CGWindowID: PendingDrag] = [:]
        orderedWindowIDs.reserveCapacity(windows.count)
        entriesByWindowID.reserveCapacity(windows.count)

        for window in windows {
            guard entriesByWindowID[window.windowID] == nil else {
                continue
            }
            orderedWindowIDs.append(window.windowID)
            entriesByWindowID[window.windowID] = PendingDrag(
                windowID: window.windowID,
                originalFrame: window.frame,
                moveOnlySampleCount: 0
            )
        }

        if orderedWindowIDs.isEmpty {
            state = .idle
            return
        }

        state = .pending(
            PendingState(
                orderedWindowIDs: orderedWindowIDs,
                entriesByWindowID: entriesByWindowID
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

    func maybeActivateDrag(
        currentPoint: CGPoint,
        latestWindowsByID: [CGWindowID: WindowRef]
    ) -> DragState? {
        guard case var .pending(pendingState) = state else {
            return nil
        }

        var activeWindowIDs: [CGWindowID] = []
        activeWindowIDs.reserveCapacity(pendingState.orderedWindowIDs.count)

        for windowID in pendingState.orderedWindowIDs {
            guard
                var pendingDrag = pendingState.entriesByWindowID[windowID],
                let latestWindow = latestWindowsByID[windowID]
            else {
                pendingState.entriesByWindowID.removeValue(forKey: windowID)
                continue
            }

            if hasWindowResized(original: pendingDrag.originalFrame, current: latestWindow.frame) {
                // Resize gestures should never enter tiling-drag mode.
                state = .resizing(
                    ResizeState(
                        windowID: latestWindow.windowID,
                        originalFrame: pendingDrag.originalFrame
                    )
                )
                return nil
            }

            guard hasWindowTranslated(original: pendingDrag.originalFrame, current: latestWindow.frame) else {
                pendingDrag.moveOnlySampleCount = 0
                pendingState.entriesByWindowID[windowID] = pendingDrag
                activeWindowIDs.append(windowID)
                continue
            }

            let nextSampleCount = pendingDrag.moveOnlySampleCount + 1
            if nextSampleCount < requiredMoveOnlySamples {
                pendingDrag.moveOnlySampleCount = nextSampleCount
                pendingState.entriesByWindowID[windowID] = pendingDrag
                activeWindowIDs.append(windowID)
                continue
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

        pendingState.orderedWindowIDs = activeWindowIDs
        if pendingState.orderedWindowIDs.isEmpty {
            state = .idle
        } else {
            state = .pending(pendingState)
        }
        return nil
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

    func finishResize() -> ResizeState? {
        guard case let .resizing(resizeState) = state else {
            return nil
        }
        state = .idle
        return resizeState
    }

    private func hasWindowTranslated(original: CGRect, current: CGRect) -> Bool {
        abs(original.origin.x - current.origin.x) >= moveThreshold ||
            abs(original.origin.y - current.origin.y) >= moveThreshold
    }

    private func hasWindowResized(original: CGRect, current: CGRect) -> Bool {
        abs(original.size.width - current.size.width) >= moveThreshold ||
            abs(original.size.height - current.size.height) >= moveThreshold
    }
}
