import AppKit
import CoreGraphics

/// Turns input events, window lifecycle changes and space switches into layouts.
///
/// Everything here runs on the main thread. The only work handed elsewhere is writing frames through AX
/// (`AXWindowActuator`) and registering AX observers (`WindowLifecycleMonitor`), both of which can block on
/// unresponsive apps.
final class TilerCoordinator {
    private static let windowHitSlop: CGFloat = 24
    private static let frameTolerance: CGFloat = 1
    private static let settleProbeInterval: TimeInterval = 0.06
    private static let spaceSwitchCooldown: TimeInterval = 0.3

    private let ruleStore = WindowRuleStore()
    private let typeRegistry = WindowTypeRegistry()
    private let resolver = AXWindowResolver()
    private lazy var discovery = WindowDiscovery(ruleStore: ruleStore, typeRegistry: typeRegistry, resolver: resolver)
    private lazy var actuator = AXWindowActuator(resolver: resolver)
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private let lifecycleMonitor = WindowLifecycleMonitor()
    private lazy var rulesPanel = WindowRulesPanelController(registry: typeRegistry, ruleStore: ruleStore) { [weak self] in
        self?.requestReflow("rules-updated")
    }
    private var spaceObserver: NSObjectProtocol?

    private var state = TilingState()
    private var gesture = Gesture.idle
    /// Taken at mouse down. A gesture works on this view of the windows until mouse up.
    private var gestureSnapshot: WindowSnapshot?
    /// Unlike the windows, the shown spaces can change mid-gesture: pushing a held window against the screen
    /// edge, or pressing the space shortcut while holding it, switches spaces and carries the window along.
    private var gestureVisibleSpaces: [CGDirectDisplayID: SpaceKey] = [:]
    private var pointer = CGPoint.zero
    private var pendingReflow: PendingReflow?
    private var isReflowScheduled = false
    private var lastSpaceSwitch = Date.distantPast

    func start() throws {
        // Bounds how long a single AX call may block when an app is unresponsive (the default is 6 seconds).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        try eventTap.start { [weak self] event in
            self?.handleTapEvent(event) ?? false
        }
        lifecycleMonitor.start { [weak self] reason in
            self?.requestReflow(reason)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSpaceChange()
        }
        requestReflow("startup")
    }

    func stop() {
        eventTap.stop()
        lifecycleMonitor.stop()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        overlay.hide()
    }

    func showRulesPanel() {
        rulesPanel.present()
    }

    // MARK: - Reflow

    /// Reflow requests coalesce into one. It runs once no gesture is in progress and the window server
    /// reports a complete arrangement; after a space switch, also only once that arrangement stopped changing.
    private struct PendingReflow {
        static let stableProbesRequired = 3
        static let maxSettleWait: TimeInterval = 1.5

        enum Settlement {
            case ready
            case wait
            case giveUp
        }

        private(set) var reasons: [String] = []
        private var waitsForStableSpaces = false
        private let deadline = Date().addingTimeInterval(maxSettleWait)
        private var lastPlacements: Set<WindowSnapshot.Placement>?
        private var stableProbes = 0

        mutating func add(_ reason: String, waitForStableSpaces: Bool) {
            if !reasons.contains(reason) {
                reasons.append(reason)
            }
            waitsForStableSpaces = waitsForStableSpaces || waitForStableSpaces
        }

        mutating func settle(with snapshot: WindowSnapshot) -> Settlement {
            let placements = snapshot.placements
            stableProbes = placements == lastPlacements ? stableProbes + 1 : 1
            lastPlacements = placements

            if snapshot.isComplete && (!waitsForStableSpaces || stableProbes >= Self.stableProbesRequired) {
                return .ready
            }
            if Date() < deadline {
                return .wait
            }
            return snapshot.isComplete ? .ready : .giveUp
        }
    }

    func requestReflow(_ reason: String, waitForStableSpaces: Bool = false) {
        var request = pendingReflow ?? PendingReflow()
        request.add(reason, waitForStableSpaces: waitForStableSpaces)
        pendingReflow = request
        scheduleReflowIfPossible()
    }

    private func scheduleReflowIfPossible(after delay: TimeInterval = 0) {
        guard pendingReflow != nil, gesture.isIdle, !isReflowScheduled else { return }
        isReflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runPendingReflow()
        }
    }

    private func runPendingReflow() {
        isReflowScheduled = false
        // A gesture started meanwhile; mouse up schedules the request again.
        guard gesture.isIdle, var request = pendingReflow else { return }

        let snapshot = discovery.snapshot()
        switch request.settle(with: snapshot) {
        case .wait:
            pendingReflow = request
            scheduleReflowIfPossible(after: Self.settleProbeInterval)
            return
        case .giveUp:
            pendingReflow = nil
            Diagnostics.log(
                "Reflow (\(request.reasons.joined(separator: ","))) dropped: window spaces stayed unresolved",
                level: .warn
            )
            return
        case .ready:
            pendingReflow = nil
        }

        state.reconcile(with: snapshot, liveWindowIDs: discovery.allWindowIDs())
        applyLayouts(of: snapshot, reason: request.reasons.joined(separator: ","))
    }

    /// Moves every tiled window on a visible space into its slot. Does not change the tiling state.
    private func applyLayouts(of snapshot: WindowSnapshot, reason: String) {
        var jobs: [(window: ObservedWindow, target: CGRect)] = []
        for space in snapshot.visibleSpaces.values {
            guard let area = DisplayService.visibleBounds(for: space.displayID) else { continue }
            for (windowID, target) in state.layout(for: space).targetFrames(in: area) {
                // Absent when the window closed after the snapshot the gesture started with.
                guard let window = snapshot.window(windowID) else { continue }
                if !window.frame.isApproximatelyEqual(to: target, tolerance: Self.frameTolerance) {
                    jobs.append((window, target))
                }
            }
        }
        guard !jobs.isEmpty else { return }
        Diagnostics.log("Reflow (\(reason)) moving \(jobs.count) windows", level: .info)
        actuator.apply(jobs, reason: reason)
    }

    private func handleSpaceChange() {
        if !gesture.isIdle {
            gestureVisibleSpaces = discovery.visibleSpaces()
            if case .dragging = gesture {
                updateDragPreview(at: pointer)
            }
        }
        requestReflow("space-change", waitForStableSpaces: true)
    }

    // MARK: - Input

    private func handleTapEvent(_ event: TapEvent) -> Bool {
        if case let .scrollWheel(point, deltaY) = event {
            // Must answer synchronously: the return value decides whether the scroll is swallowed.
            return handleScroll(at: point, deltaY: deltaY)
        }
        // Keep the tap callback short; the system disables taps that respond slowly.
        DispatchQueue.main.async { [weak self] in
            self?.handle(event)
        }
        return false
    }

    private func handle(_ event: TapEvent) {
        switch event {
        case let .mouseDown(point):
            beginGesture(at: point)
        case let .mouseDragged(point):
            continueGesture(at: point)
        case let .mouseUp(point):
            endGesture(at: point)
        case let .rightMouseDown(point), let .optionPressed(point):
            toggleFloating(at: point)
        case .scrollWheel:
            preconditionFailure("scroll events are handled synchronously in the tap callback")
        }
    }

    /// Scrolling the wheel over the desktop switches to the adjacent space. At the first or last space the
    /// scroll reaches the desktop as usual.
    private func handleScroll(at point: CGPoint, deltaY: Int64) -> Bool {
        let goLeft = deltaY > 0
        guard
            !discovery.hasVisibleWindow(at: point),
            let displayID = DisplayService.displayID(containing: point),
            CGSSpaceService.shared.hasSpace(on: displayID, atOffset: goLeft ? -1 : 1)
        else {
            return false
        }
        // One wheel notch produces several events; swallow the rest instead of switching again.
        guard Date().timeIntervalSince(lastSpaceSwitch) >= Self.spaceSwitchCooldown else { return true }
        do {
            try CGSSpaceService.shared.postAdjacentSpaceShortcut(goLeft: goLeft)
        } catch {
            Diagnostics.log("Space switch by scroll failed: \(error.localizedDescription)", level: .warn)
            NSSound.beep()
            return false
        }
        lastSpaceSwitch = Date()
        return true
    }

    // MARK: - Gestures

    private var snapshotForGesture: WindowSnapshot {
        guard let gestureSnapshot else {
            preconditionFailure("gesture \(gesture) without a mouse-down snapshot")
        }
        return gestureSnapshot
    }

    private func beginGesture(at point: CGPoint) {
        overlay.hide()
        let snapshot = discovery.snapshot()
        let candidates = snapshot.windows.filter {
            $0.frame.insetBy(dx: -Self.windowHitSlop, dy: -Self.windowHitSlop).contains(point)
        }
        gestureSnapshot = snapshot
        gestureVisibleSpaces = snapshot.visibleSpaces
        pointer = point
        gesture = candidates.isEmpty ? .ignored : .pending(Gesture.Pending(candidates: candidates, point: point))
    }

    private func continueGesture(at point: CGPoint) {
        pointer = point
        switch gesture {
        case var .pending(pending):
            pending.travelled += hypot(point.x - pending.lastPoint.x, point.y - pending.lastPoint.y)
            pending.lastPoint = point
            if pending.travelled >= Gesture.classificationDistance, pending.classifiableAt == nil {
                pending.classifiableAt = Date().addingTimeInterval(Gesture.classificationDelay)
                // The pointer may stop right here; classify once the delay passes even without further events.
                DispatchQueue.main.asyncAfter(deadline: .now() + Gesture.classificationDelay) { [weak self] in
                    self?.classifyPendingGesture()
                }
            }
            gesture = .pending(pending)
            classifyPendingGesture()
        case .dragging:
            updateDragPreview(at: point)
        case let .resizing(resize):
            updateResizePreview(resize, at: point)
        case .idle, .ignored:
            break
        }
    }

    private func classifyPendingGesture() {
        guard case let .pending(pending) = gesture, let classifiableAt = pending.classifiableAt, Date() >= classifiableAt else {
            return
        }
        let frames = discovery.frames(of: Set(pending.candidates.map(\.windowID)))
        switch pending.classify(currentFrames: frames) {
        case let .drag(window):
            beginDrag(of: window, at: pending.lastPoint)
        case let .resize(window, currentFrame):
            beginResize(of: window, currentFrame: currentFrame, at: pending.lastPoint)
        case .none:
            gesture = .ignored
        }
    }

    private func endGesture(at point: CGPoint) {
        let ended = gesture
        gesture = .idle
        overlay.hide()
        switch ended {
        case let .dragging(windowID):
            drop(windowID, at: point)
        case let .resizing(resize):
            finishResize(resize)
        case .idle, .pending, .ignored:
            break
        }
        gestureSnapshot = nil
        scheduleReflowIfPossible()
    }

    /// Option or right click while holding a window flips it between tiled and floating.
    private func toggleFloating(at point: CGPoint) {
        guard let windowID = gesture.windowID, let window = snapshotForGesture.window(windowID) else { return }
        guard window.isTilable else {
            Diagnostics.log("Floating toggle ignored: \(window.appName) windows always float", level: .info)
            return
        }

        if state.floatingWindowIDs.contains(windowID) {
            state.setFloating(windowID, false)
            Diagnostics.log("Window \(windowID) (\(window.appName)) is now tiled", level: .info)
            // Keep holding it: from now on it drags like a tiled window, with the slot preview.
            gesture = .dragging(windowID: windowID)
            updateDragPreview(at: point)
        } else {
            let wasInLayout = state.space(of: windowID) != nil
            state.setFloating(windowID, true)
            Diagnostics.log("Window \(windowID) (\(window.appName)) is now floating", level: .info)
            if case .dragging = gesture {} else {
                gesture = .ignored
            }
            overlay.hide()
            if wasInLayout {
                applyLayouts(of: snapshotForGesture, reason: "floating-toggle")
            }
        }
    }

    // MARK: Drag

    private struct DropTarget {
        let space: SpaceKey
        let slotRects: [CGRect]
        let slot: Int
    }

    private func beginDrag(of window: ObservedWindow, at point: CGPoint) {
        gesture = .dragging(windowID: window.windowID)
        guard !state.isFloating(window) else { return }

        Diagnostics.log("Drag begin windowID=\(window.windowID) app=\(window.appName)", level: .info)
        if state.space(of: window.windowID) != nil {
            // Close the gap right away so the preview shows the layout the drop will produce.
            state.remove(window.windowID)
            applyLayouts(of: snapshotForGesture, reason: "drag-begin")
        }
        updateDragPreview(at: point)
    }

    private func updateDragPreview(at point: CGPoint) {
        guard
            case let .dragging(windowID) = gesture,
            let window = snapshotForGesture.window(windowID),
            !state.isFloating(window),
            let target = dropTarget(at: point)
        else {
            overlay.hide()
            return
        }
        overlay.show(displayID: target.space.displayID, slotRects: target.slotRects, hoverIndex: target.slot)
    }

    private func drop(_ windowID: CGWindowID, at point: CGPoint) {
        guard let window = snapshotForGesture.window(windowID), !state.isFloating(window) else { return }
        // The space-change notification may still be on its way when the button is released right after a switch.
        gestureVisibleSpaces = discovery.visibleSpaces()
        guard let target = dropTarget(at: point) else {
            Diagnostics.log("Drop of window \(windowID) at \(point) has no resolvable space; it rejoins on the next reflow", level: .warn)
            requestReflow("drop")
            return
        }
        Diagnostics.log("Drop windowID=\(windowID) into \(target.space) slot=\(target.slot)", level: .info)
        state.insert(windowID, into: target.space, at: target.slot)
        requestReflow("drop")
    }

    /// The slots the space under `point` would have with one more window, and the one nearest to `point`.
    private func dropTarget(at point: CGPoint) -> DropTarget? {
        guard
            let displayID = DisplayService.displayID(containing: point),
            let space = gestureVisibleSpaces[displayID],
            let area = DisplayService.visibleBounds(for: displayID)
        else {
            return nil
        }
        let layout = state.layout(for: space)
        let rects = layout.slotRects(count: layout.windowIDs.count + 1, in: area)
        guard let slot = rects.indices.min(by: { rects[$0].distance(to: point) < rects[$1].distance(to: point) }) else {
            preconditionFailure("a layout with at least one window has no slots")
        }
        return DropTarget(space: space, slotRects: rects, slot: slot)
    }

    // MARK: Resize

    private func beginResize(of window: ObservedWindow, currentFrame: CGRect, at point: CGPoint) {
        guard !state.isFloating(window), let space = state.space(of: window.windowID) else {
            gesture = .ignored
            return
        }
        let resize = Gesture.Resize(windowID: window.windowID, space: space, originalFrame: window.frame, currentFrame: currentFrame)
        gesture = .resizing(resize)
        updateResizePreview(resize, at: point)
    }

    private func updateResizePreview(_ resize: Gesture.Resize, at point: CGPoint) {
        guard let area = DisplayService.visibleBounds(for: resize.space.displayID) else {
            overlay.hide()
            return
        }
        let frame = resize.canProject
            ? resize.projectedFrame(at: point)
            : discovery.frames(of: [resize.windowID])[resize.windowID] ?? resize.frameAtClassification
        var layout = state.layout(for: resize.space)
        layout.adjust(forResizeOf: resize.windowID, from: resize.originalFrame, to: frame, in: area)
        overlay.show(
            displayID: resize.space.displayID,
            slotRects: layout.slotRects(count: layout.windowIDs.count, in: area),
            hoverIndex: layout.windowIDs.firstIndex(of: resize.windowID)
        )
    }

    private func finishResize(_ resize: Gesture.Resize) {
        if
            let area = DisplayService.visibleBounds(for: resize.space.displayID),
            let frame = discovery.frames(of: [resize.windowID])[resize.windowID]
        {
            state.updateLayout(for: resize.space) {
                $0.adjust(forResizeOf: resize.windowID, from: resize.originalFrame, to: frame, in: area)
            }
        }
        requestReflow("resize-end")
    }
}
