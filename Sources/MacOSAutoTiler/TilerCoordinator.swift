import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let discovery = WindowDiscovery()
    private let layoutPlanner = LayoutPlanner()
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private let geometryApplier = WindowGeometryApplier()
    private let dragTracker = DragInteractionTracker()

    private var activeSpaceObserver: NSObjectProtocol?
    private var activePlan: DisplayLayoutPlan?
    private var lastLoggedHoverIndex: Int?

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
    }

    func stop() {
        eventTap.stop()
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        resetInteractionState()
        Diagnostics.log("Coordinator stopped", level: .info)
    }

    func reflowAllVisibleWindows(reason: String = "manual") {
        let windows = discovery.fetchVisibleWindows()
        let plans = layoutPlanner.buildReflowPlans(from: windows)
        guard !plans.isEmpty else {
            Diagnostics.log("Reflow (\(reason)) skipped: no candidate windows", level: .debug)
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
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        resetInteractionState()

        let windows = discovery.fetchVisibleWindows()
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
        guard let activePlan else {
            dragTracker.clearPendingDrag()
            return
        }

        let fallbackDestination = layoutPlanner.slotIndex(at: point, in: activePlan)
        guard let dragState = dragTracker.finishDrag(point: point, fallbackHoverSlotIndex: fallbackDestination) else {
            resetInteractionState()
            return
        }

        guard let destinationIndex = fallbackDestination ?? dragState.hoverSlotIndex else {
            Diagnostics.log(
                "Drag end windowID=\(dragState.draggedWindowID) with no destination slot",
                level: .debug
            )
            clearOverlayState()
            return
        }

        let latestFrame = discovery.fetchWindow(windowID: dragState.draggedWindowID)?.frame
        guard
            let drop = layoutPlanner.resolveDrop(
                plan: activePlan,
                dragState: dragState,
                destinationIndex: destinationIndex,
                latestDraggedFrame: latestFrame
            )
        else {
            Diagnostics.log("Dragged window is not assigned to any slot, skipping drop", level: .warn)
            clearOverlayState()
            return
        }

        clearOverlayState()

        if !drop.shouldApply {
            Diagnostics.log(
                "Drop skipped windowID=\(dragState.draggedWindowID) source==destination (\(drop.sourceSlotIndex))",
                level: .debug
            )
            return
        }

        Diagnostics.log(
            "Applying layout from drop windowID=\(dragState.draggedWindowID) source=\(drop.sourceSlotIndex) destination=\(drop.destinationSlotIndex) movedWindows=\(drop.targetFrames.count)",
            level: .info
        )

        geometryApplier.applyAsync(
            reason: "drop/window=\(dragState.draggedWindowID) source=\(drop.sourceSlotIndex) destination=\(drop.destinationSlotIndex)",
            targetFrames: drop.targetFrames,
            windowsByID: activePlan.windowsByID
        ) { [weak self] failures in
            self?.logApplyResult(failures)
        }
    }

    private func maybeActivateDrag(at point: CGPoint) {
        guard let pendingWindowID = dragTracker.pendingWindowID else {
            return
        }
        guard let latestWindow = discovery.fetchWindow(windowID: pendingWindowID) else {
            dragTracker.clearPendingDrag()
            return
        }
        guard dragTracker.maybeActivateDrag(currentPoint: point, latestWindow: latestWindow) != nil else {
            return
        }

        activateDragSession(draggedWindow: latestWindow, point: point)
    }

    private func activateDragSession(draggedWindow: WindowRef, point: CGPoint) {
        let windows = discovery.fetchVisibleWindows()
        guard let plan = layoutPlanner.buildDragPlan(at: point, windows: windows) else {
            Diagnostics.log("No windows found for drag session at point=\(point)", level: .warn)
            resetInteractionState()
            return
        }

        guard plan.windowToSlotIndex[draggedWindow.windowID] != nil else {
            Diagnostics.log("Dragged windowID=\(draggedWindow.windowID) was not assigned to a slot", level: .warn)
            resetInteractionState()
            return
        }

        let hoverIndex = layoutPlanner.slotIndex(at: point, in: plan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            Diagnostics.log("Failed to update drag state during activation", level: .warn)
            resetInteractionState()
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
        guard let activePlan else {
            return
        }

        let hoverIndex = layoutPlanner.slotIndex(at: point, in: activePlan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            clearOverlayState()
            return
        }

        if dragState.hoverSlotIndex != lastLoggedHoverIndex {
            let hoverText = dragState.hoverSlotIndex.map(String.init) ?? "nil"
            Diagnostics.log(
                "Drag hover changed windowID=\(dragState.draggedWindowID) hover=\(hoverText) point=\(point)",
                level: .debug
            )
            lastLoggedHoverIndex = dragState.hoverSlotIndex
        }

        renderOverlay(dragState: dragState, plan: activePlan)
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
