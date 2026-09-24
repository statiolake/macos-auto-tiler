import CoreGraphics
import Foundation

/// A left-button gesture on a window, from mouse down to mouse up.
///
/// A mouse down only tells us which windows are under the pointer. Whether the user is moving one of them,
/// resizing it, or doing something else entirely becomes clear only after the window server reports a
/// geometry change, so every gesture starts `pending` and is classified later.
enum Gesture {
    case idle
    case pending(Pending)
    case dragging(windowID: CGWindowID)
    case resizing(Resize)
    /// Not a tiling interaction (e.g. text selection or a floating window resize). Ignored until mouse up.
    case ignored

    /// Pointer travel before window frames are probed; shorter wiggles never become drags.
    static let classificationDistance: CGFloat = 24
    /// Extra wait after `classificationDistance` so the window server has caught up with the pointer.
    static let classificationDelay: TimeInterval = 0.1
    /// Frame change that counts as a move or a resize.
    static let geometryChangeThreshold: CGFloat = 4

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// The window the gesture acts on, if it is known yet.
    var windowID: CGWindowID? {
        switch self {
        case .idle, .ignored:
            return nil
        case let .pending(pending):
            return pending.candidates.first?.windowID
        case let .dragging(windowID):
            return windowID
        case let .resizing(resize):
            return resize.windowID
        }
    }

    struct Pending {
        /// Windows under the pointer at mouse down, front to back, with their frames at that moment.
        let candidates: [ObservedWindow]
        var lastPoint: CGPoint
        var travelled: CGFloat = 0
        var classifiableAt: Date?

        init(candidates: [ObservedWindow], point: CGPoint) {
            precondition(!candidates.isEmpty, "a pending gesture needs at least one candidate window")
            self.candidates = candidates
            lastPoint = point
        }

        enum Classification {
            case drag(ObservedWindow)
            case resize(ObservedWindow, currentFrame: CGRect)
            case none
        }

        func classify(currentFrames: [CGWindowID: CGRect]) -> Classification {
            for candidate in candidates {
                guard let frame = currentFrames[candidate.windowID] else { continue }
                if exceedsThreshold(candidate.frame.size, frame.size) {
                    return .resize(candidate, currentFrame: frame)
                }
                if exceedsThreshold(candidate.frame.origin, frame.origin) {
                    return .drag(candidate)
                }
            }
            return .none
        }

        private func exceedsThreshold(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
            abs(lhs.x - rhs.x) >= Gesture.geometryChangeThreshold || abs(lhs.y - rhs.y) >= Gesture.geometryChangeThreshold
        }

        private func exceedsThreshold(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
            abs(lhs.width - rhs.width) >= Gesture.geometryChangeThreshold || abs(lhs.height - rhs.height) >= Gesture.geometryChangeThreshold
        }
    }

    /// A resize in progress. The window server reports frames with a lag, so while the pointer moves the
    /// edges that started moving are projected onto the pointer instead of being re-read.
    struct Resize {
        static let minimumExtent: CGFloat = 80
        static let edgeDetectionThreshold: CGFloat = 2

        let windowID: CGWindowID
        let space: SpaceKey
        let originalFrame: CGRect
        let frameAtClassification: CGRect
        let movesMinX: Bool
        let movesMaxX: Bool
        let movesMinY: Bool
        let movesMaxY: Bool

        init(windowID: CGWindowID, space: SpaceKey, originalFrame: CGRect, currentFrame: CGRect) {
            self.windowID = windowID
            self.space = space
            self.originalFrame = originalFrame
            frameAtClassification = currentFrame

            // Per axis, only the edge that moved more is the one under the pointer.
            let dMinX = abs(currentFrame.minX - originalFrame.minX)
            let dMaxX = abs(currentFrame.maxX - originalFrame.maxX)
            let dMinY = abs(currentFrame.minY - originalFrame.minY)
            let dMaxY = abs(currentFrame.maxY - originalFrame.maxY)
            movesMinX = dMinX >= Self.edgeDetectionThreshold && dMinX > dMaxX
            movesMaxX = dMaxX >= Self.edgeDetectionThreshold && dMaxX >= dMinX
            movesMinY = dMinY >= Self.edgeDetectionThreshold && dMinY > dMaxY
            movesMaxY = dMaxY >= Self.edgeDetectionThreshold && dMaxY >= dMinY
        }

        var canProject: Bool {
            movesMinX || movesMaxX || movesMinY || movesMaxY
        }

        func projectedFrame(at point: CGPoint) -> CGRect {
            var minX = movesMinX ? point.x : frameAtClassification.minX
            var maxX = movesMaxX ? point.x : frameAtClassification.maxX
            var minY = movesMinY ? point.y : frameAtClassification.minY
            var maxY = movesMaxY ? point.y : frameAtClassification.maxY

            if maxX - minX < Self.minimumExtent {
                if movesMinX { minX = maxX - Self.minimumExtent } else { maxX = minX + Self.minimumExtent }
            }
            if maxY - minY < Self.minimumExtent {
                if movesMinY { minY = maxY - Self.minimumExtent } else { maxY = minY + Self.minimumExtent }
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
