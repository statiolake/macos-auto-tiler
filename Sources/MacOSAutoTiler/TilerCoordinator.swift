import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let discovery = WindowDiscovery()
    private let layoutPlanner = LayoutPlanner()
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private let geometryApplier = WindowGeometryApplier()
    private let dragTracker = DragInteractionTracker()
    private let lifecycleMonitor = WindowLifecycleMonitor()

    private var activeSpaceObserver: NSObjectProtocol?
    private var activePlan: DisplayLayoutPlan?
    private var lastLoggedHoverIndex: Int?
    private var needsDeferredLifecycleReflow = false

    private var userFloatingWindowIDs = Set<CGWindowID>()
    private var userTiledWindowIDs = Set<CGWindowID>()

    func start() {
        Diagnostics.log("Coordinator start requested", level: .info)

        let accessibilityGranted = Permissions.ensureAccessibilityPermission(prompt: true)
        let inputMonitoringGranted = Permissions.ensureInputMonitoringPermission()

        if !inputMonitoringGranted {
            Diagnostics.log("Input Monitoring permission not granted, prompting user", level: .warn)
            Permissions.presentInputMonitoringAlert()
        }

        let started = eventTap.start { [weak self] eventType, point in
            DispatchQueue.main.async {
                self?.handle(eventType, point: point)
            }
        }

        if !started {
            Diagnostics.log("Event tap failed to start", level: .error)
            presentPermissionAlert(
                title: "Event Tap Failed",
                message: "Failed to start global mouse event tap. Please enable both Input Monitoring and Accessibility permissions in System Settings."
            )
        } else {
            Diagnostics.log("Coordinator started successfully", level: .info)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let canControlWindows = accessibilityGranted || Permissions.ensureAccessibilityPermission(prompt: false)
            if !canControlWindows {
                Diagnostics.log("Startup reflow skipped (Accessibility permission not granted)", level: .warn)
                return
            }
            self.reflowAllVisibleWindows(reason: "startup")
        }

        setupActiveSpaceObserver()
        startLifecycleMonitor()
    }

    func stop() {
        lifecycleMonitor.stop()
        eventTap.stop()
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        resetInteractionState()
        Diagnostics.log("Coordinator stopped", level: .info)
    }

    func reflowAllVisibleWindows(reason: String = "manual") {
        let windows = fetchVisibleWindows()
        let tiled = tiledWindows(from: windows)
        let plans = layoutPlanner.buildReflowPlans(from: tiled)
        guard !plans.isEmpty else {
            Diagnostics.log(
                "Reflow (\(reason)) skipped: no tile candidates (visible=\(windows.count), floating=\(windows.count - tiled.count))",
                level: .debug
            )
            return
        }

        var totalTargets = 0
        var totalFailures: [CGWindowID] = []

        for plan in plans {
            let targets = plan.targetFrames
            totalTargets += targets.count

            Diagnostics.log(
                "Reflow (\(reason)) display=\(plan.displayID) windows=\(plan.windowsByID.count) targets=\(targets.count)",
                level: .info
            )

            let failures = geometryApplier.applySync(
                reason: "reflow(\(reason))/display=\(plan.displayID)",
                targetFrames: targets,
                windowsByID: plan.windowsByID
            )
            totalFailures.append(contentsOf: failures)
        }

        if totalFailures.isEmpty {
            Diagnostics.log("Reflow (\(reason)) finished successfully for \(totalTargets) windows", level: .info)
        } else {
            Diagnostics.log("Reflow (\(reason)) finished with failures: \(totalFailures)", level: .warn)
        }
    }

    private func handle(_ eventType: MouseEventType, point: CGPoint) {
        switch eventType {
        case .down:
            handleMouseDown(at: point)
        case .dragged:
            handleMouseDragged(at: point)
        case .up:
            handleMouseUp(at: point)
        case .secondaryDown:
            handleSecondaryMouseDown(at: point)
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        resetInteractionState()

        let windows = fetchVisibleWindows()
        guard let dragged = windows.first(where: { $0.frame.contains(point) }) else {
            Diagnostics.log("Mouse down at \(point) but no window hit", level: .debug)
            return
        }

        dragTracker.beginPendingDrag(window: dragged)
        Diagnostics.log(
            "Pending drag captured windowID=\(dragged.windowID) app=\(dragged.appName)",
            level: .debug
        )
    }

    private func handleMouseDragged(at point: CGPoint) {
        if dragTracker.isDragging {
            updateActiveDrag(at: point)
            return
        }

        maybeActivateDrag(at: point)
    }

    private func handleMouseUp(at point: CGPoint) {
        defer {
            applyDeferredLifecycleReflowIfNeeded()
        }

        guard let currentPreviewPlan = activePlan else {
            resetInteractionState()
            return
        }

        guard let dragState = dragTracker.finishDrag(point: point, fallbackHoverSlotIndex: nil) else {
            resetInteractionState()
            return
        }

        let windows = fetchVisibleWindows()
        let tiled = tiledWindows(from: windows, including: [dragState.draggedWindowID])

        let previewPlan =
            layoutPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: dragState.draggedWindowID
            ) ?? currentPreviewPlan

        let destinationIndex = layoutPlanner.slotIndex(at: point, in: previewPlan) ?? dragState.hoverSlotIndex
        guard let destinationIndex else {
            Diagnostics.log(
                "Drag end windowID=\(dragState.draggedWindowID) with no destination slot",
                level: .debug
            )
            clearOverlayState()
            return
        }

        guard
            let drop = layoutPlanner.resolveDrop(
                previewPlan: previewPlan,
                dragState: dragState,
                destinationIndex: destinationIndex,
                allWindows: tiled
            )
        else {
            Diagnostics.log("Failed to resolve drop for windowID=\(dragState.draggedWindowID)", level: .warn)
            clearOverlayState()
            return
        }

        clearOverlayState()

        if !drop.shouldApply {
            Diagnostics.log(
                "Drop skipped windowID=\(dragState.draggedWindowID) destination=\(drop.destinationSlotIndex)",
                level: .debug
            )
            return
        }

        let sourceSlotText = drop.sourceSlotIndex.map(String.init) ?? "nil"
        Diagnostics.log(
            "Applying layout from drop windowID=\(dragState.draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex) movedWindows=\(drop.targetFrames.count)",
            level: .info
        )

        geometryApplier.applyAsync(
            reason: "drop/window=\(dragState.draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex)",
            targetFrames: drop.targetFrames,
            windowsByID: drop.windowsByID
        ) { [weak self] failures in
            self?.logApplyResult(failures)
        }
    }

    private func handleSecondaryMouseDown(at point: CGPoint) {
        guard let draggedWindowID = dragTracker.draggedWindowID else {
            return
        }

        let windows = fetchVisibleWindows()
        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            return
        }

        if isFloatingWindow(draggedWindow) {
            userFloatingWindowIDs.remove(draggedWindowID)
            userTiledWindowIDs.insert(draggedWindowID)
            Diagnostics.log("Floating toggle windowID=\(draggedWindowID) -> tiled", level: .info)
            activateDragSession(draggedWindow: draggedWindow, point: point, windows: windows)
        } else {
            userTiledWindowIDs.remove(draggedWindowID)
            userFloatingWindowIDs.insert(draggedWindowID)
            Diagnostics.log("Floating toggle windowID=\(draggedWindowID) -> floating", level: .info)
            clearOverlayState()
            reflowAllVisibleWindows(reason: "floating-toggle")
        }
    }

    private func maybeActivateDrag(at point: CGPoint) {
        guard let pendingWindowID = dragTracker.pendingWindowID else {
            return
        }

        let windows = fetchVisibleWindows()
        guard let latestWindow = windows.first(where: { $0.windowID == pendingWindowID }) else {
            dragTracker.clearPendingDrag()
            return
        }

        guard dragTracker.maybeActivateDrag(currentPoint: point, latestWindow: latestWindow) != nil else {
            return
        }

        if isFloatingWindow(latestWindow) {
            Diagnostics.log("Dragging floating windowID=\(latestWindow.windowID) (tiler preview disabled)", level: .debug)
            clearOverlayState()
            return
        }

        activateDragSession(draggedWindow: latestWindow, point: point, windows: windows)
    }

    private func activateDragSession(draggedWindow: WindowRef, point: CGPoint, windows: [WindowRef]? = nil) {
        let allWindows = windows ?? fetchVisibleWindows()
        let tiled = tiledWindows(from: allWindows, including: [draggedWindow.windowID])

        guard
            let plan = layoutPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: draggedWindow.windowID
            )
        else {
            Diagnostics.log("No windows found for drag session at point=\(point)", level: .warn)
            clearOverlayState()
            return
        }

        let hoverIndex = layoutPlanner.slotIndex(at: point, in: plan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            Diagnostics.log("Failed to update drag state during activation", level: .warn)
            clearOverlayState()
            return
        }

        activePlan = plan
        lastLoggedHoverIndex = hoverIndex

        let hoverText = hoverIndex.map(String.init) ?? "nil"
        Diagnostics.log(
            "Drag begin windowID=\(draggedWindow.windowID) app=\(draggedWindow.appName) title=\"\(draggedWindow.title)\" display=\(plan.displayID) slots=\(plan.slots.count) hover=\(hoverText)",
            level: .info
        )
        renderOverlay(dragState: dragState, plan: plan)
    }

    private func updateActiveDrag(at point: CGPoint) {
        guard let draggedWindowID = dragTracker.draggedWindowID else {
            return
        }

        let windows = fetchVisibleWindows()
        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            resetInteractionState()
            return
        }

        if isFloatingWindow(draggedWindow) {
            clearOverlayState()
            return
        }

        let tiled = tiledWindows(from: windows, including: [draggedWindowID])
        guard
            let previewPlan = layoutPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: draggedWindowID
            )
        else {
            clearOverlayState()
            return
        }

        let hoverIndex = layoutPlanner.slotIndex(at: point, in: previewPlan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            clearOverlayState()
            return
        }

        let previousDisplayID = activePlan?.displayID
        activePlan = previewPlan
        if previousDisplayID != nil, previousDisplayID != previewPlan.displayID {
            Diagnostics.log(
                "Drag display changed windowID=\(dragState.draggedWindowID) display=\(previewPlan.displayID)",
                level: .info
            )
        }

        if dragState.hoverSlotIndex != lastLoggedHoverIndex {
            let hoverText = dragState.hoverSlotIndex.map(String.init) ?? "nil"
            Diagnostics.log(
                "Drag hover changed windowID=\(dragState.draggedWindowID) hover=\(hoverText) point=\(point)",
                level: .debug
            )
            lastLoggedHoverIndex = dragState.hoverSlotIndex
        }

        renderOverlay(dragState: dragState, plan: previewPlan)
    }

    private func renderOverlay(dragState: DragState, plan: DisplayLayoutPlan) {
        let ghostRect = layoutPlanner.ghostRect(for: dragState, in: plan)
        overlay.show(
            displayID: plan.displayID,
            slotRects: plan.slots.map(\.rect),
            hoverIndex: dragState.hoverSlotIndex,
            ghostRect: ghostRect
        )
    }

    private func fetchVisibleWindows() -> [WindowRef] {
        let windows = discovery.fetchVisibleWindows()
        pruneFloatingState(using: windows)
        return windows
    }

    private func tiledWindows(from windows: [WindowRef], including included: Set<CGWindowID> = []) -> [WindowRef] {
        windows.filter { window in
            if included.contains(window.windowID) {
                return true
            }
            return !isFloatingWindow(window)
        }
    }

    private func isFloatingWindow(_ window: WindowRef) -> Bool {
        if userFloatingWindowIDs.contains(window.windowID) {
            return true
        }
        if userTiledWindowIDs.contains(window.windowID) {
            return false
        }
        return isAutomaticallyFloating(window)
    }

    private func isAutomaticallyFloating(_ window: WindowRef) -> Bool {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tiny = window.frame.width <= 260 || window.frame.height <= 140
        let dialogLike = title.isEmpty && window.frame.width <= 520 && window.frame.height <= 360
        return tiny || dialogLike
    }

    private func pruneFloatingState(using windows: [WindowRef]) {
        let liveIDs = Set(windows.map(\.windowID))
        userFloatingWindowIDs.formIntersection(liveIDs)
        userTiledWindowIDs.formIntersection(liveIDs)
    }

    private func setupActiveSpaceObserver() {
        guard activeSpaceObserver == nil else {
            return
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard Permissions.ensureAccessibilityPermission(prompt: false) else {
                return
            }
            Diagnostics.log("Active space changed, triggering reflow", level: .info)
            self.reflowAllVisibleWindows(reason: "space-change")
        }
    }

    private func startLifecycleMonitor() {
        lifecycleMonitor.start { [weak self] reason in
            guard let self else { return }
            guard Permissions.ensureAccessibilityPermission(prompt: false) else { return }

            if dragTracker.isDragging {
                needsDeferredLifecycleReflow = true
                Diagnostics.log("Lifecycle reflow deferred during drag reason=\(reason)", level: .debug)
                return
            }

            Diagnostics.log("Lifecycle change detected reason=\(reason)", level: .debug)
            reflowAllVisibleWindows(reason: "lifecycle:\(reason)")
        }
    }

    private func applyDeferredLifecycleReflowIfNeeded() {
        guard needsDeferredLifecycleReflow else {
            return
        }
        needsDeferredLifecycleReflow = false
        reflowAllVisibleWindows(reason: "lifecycle:deferred")
    }

    private func clearOverlayState() {
        overlay.hide()
        activePlan = nil
        lastLoggedHoverIndex = nil
    }

    private func resetInteractionState() {
        dragTracker.clearAll()
        clearOverlayState()
    }

    private func logApplyResult(_ failures: [CGWindowID]) {
        if failures.isEmpty {
            Diagnostics.log("AX apply completed successfully", level: .info)
            return
        }
        Diagnostics.log("AX apply failures for window IDs: \(failures)", level: .warn)
    }

    private func presentPermissionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
