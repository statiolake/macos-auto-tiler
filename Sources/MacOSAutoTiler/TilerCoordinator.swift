import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let discovery = WindowDiscovery()
    private let layoutEngine = LayoutEngine()
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private let actuator = AXWindowActuator()

    private var dragState: DragState?
    private var activeLayout: ActiveLayoutContext?
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
    }

    func stop() {
        eventTap.stop()
        overlay.hide()
        Diagnostics.log("Coordinator stopped", level: .info)
    }

    func reflowAllVisibleWindows(reason: String = "manual") {
        let windows = discovery.fetchVisibleWindows()
        guard !windows.isEmpty else {
            Diagnostics.log("Reflow (\(reason)) skipped: no candidate windows", level: .debug)
            return
        }

        var groupedByDisplay: [CGDirectDisplayID: [WindowRef]] = [:]
        for window in windows {
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let displayID = DisplayService.displayID(containing: midpoint) else {
                continue
            }
            groupedByDisplay[displayID, default: []].append(window)
        }

        var totalTargets = 0
        var totalFailures: [CGWindowID] = []

        let sortedDisplays = groupedByDisplay.keys.sorted()
        for displayID in sortedDisplays {
            guard let displayWindows = groupedByDisplay[displayID], !displayWindows.isEmpty else {
                continue
            }
            var windowsByID: [CGWindowID: WindowRef] = [:]
            for window in displayWindows {
                windowsByID[window.windowID] = window
            }

            let bounds = DisplayService.bounds(for: displayID).insetBy(dx: 12, dy: 12)
            let slots = layoutEngine.makeSlots(for: displayWindows.count, in: bounds)
            let order = displayWindows.map(\.windowID)
            let targets = layoutEngine.targets(for: slots, order: order)
            totalTargets += targets.count

            Diagnostics.log(
                "Reflow (\(reason)) display=\(displayID) windows=\(displayWindows.count) targets=\(targets.count)",
                level: .info
            )
            let failures = actuator.apply(targetFrames: targets, windows: windowsByID)
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
            beginDrag(at: point)
        case .dragged:
            updateDrag(at: point)
        case .up:
            endDrag(at: point)
        }
    }

    private func beginDrag(at point: CGPoint) {
        let windows = discovery.fetchVisibleWindows()
        guard let dragged = windows.first(where: { $0.frame.contains(point) }) else {
            Diagnostics.log("Mouse down at \(point) but no window hit", level: .debug)
            return
        }

        guard let displayID = DisplayService.displayID(containing: point) else {
            Diagnostics.log("Failed to resolve display for drag start at \(point)", level: .warn)
            return
        }

        let displayBounds = DisplayService.bounds(for: displayID).insetBy(dx: 12, dy: 12)
        let displayWindows = windows.filter { window in
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return DisplayService.displayID(containing: midpoint) == displayID
        }
        guard !displayWindows.isEmpty else {
            Diagnostics.log("No windows found on display \(displayID) for drag session", level: .warn)
            return
        }

        var slots = layoutEngine.makeSlots(for: displayWindows.count, in: displayBounds)
        let order = displayWindows.map(\.windowID)
        for index in slots.indices {
            if index < order.count {
                slots[index].windowID = order[index]
            }
        }

        var windowsByID: [CGWindowID: WindowRef] = [:]
        for window in displayWindows {
            windowsByID[window.windowID] = window
        }

        let hoverIndex = layoutEngine.slotIndex(at: point, in: slots)
        dragState = DragState(
            active: true,
            draggedWindowID: dragged.windowID,
            startPoint: point,
            currentPoint: point,
            originalFrame: dragged.frame,
            hoverSlotIndex: hoverIndex
        )
        activeLayout = ActiveLayoutContext(
            displayID: displayID,
            slots: slots,
            order: order,
            windowsByID: windowsByID
        )
        lastLoggedHoverIndex = hoverIndex
        Diagnostics.log(
            "Drag begin windowID=\(dragged.windowID) app=\(dragged.appName) title=\"\(dragged.title)\" display=\(displayID) slots=\(slots.count) hover=\(hoverIndex?.description ?? "nil")",
            level: .info
        )
        renderOverlay()
    }

    private func updateDrag(at point: CGPoint) {
        guard var dragState, let activeLayout else {
            return
        }
        dragState.currentPoint = point
        dragState.hoverSlotIndex = layoutEngine.slotIndex(at: point, in: activeLayout.slots)
        self.dragState = dragState
        self.activeLayout = activeLayout
        if dragState.hoverSlotIndex != lastLoggedHoverIndex {
            Diagnostics.log(
                "Drag hover changed windowID=\(dragState.draggedWindowID) hover=\(dragState.hoverSlotIndex?.description ?? "nil") point=\(point)",
                level: .debug
            )
            lastLoggedHoverIndex = dragState.hoverSlotIndex
        }
        renderOverlay()
    }

    private func endDrag(at point: CGPoint) {
        guard var dragState, let activeLayout else {
            overlay.hide()
            self.dragState = nil
            self.activeLayout = nil
            return
        }

        dragState.currentPoint = point
        let destinationIndex = layoutEngine.slotIndex(at: point, in: activeLayout.slots) ?? dragState.hoverSlotIndex
        defer {
            overlay.hide()
            self.dragState = nil
            self.activeLayout = nil
            self.lastLoggedHoverIndex = nil
        }

        guard let destinationIndex else {
            Diagnostics.log(
                "Drag end windowID=\(dragState.draggedWindowID) with no destination slot",
                level: .debug
            )
            return
        }

        let nextOrder = layoutEngine.reflow(
            order: activeLayout.order,
            draggedID: dragState.draggedWindowID,
            destinationIndex: destinationIndex
        )
        let targets = layoutEngine.targets(for: activeLayout.slots, order: nextOrder)
        Diagnostics.log(
            "Applying reflow windowID=\(dragState.draggedWindowID) destination=\(destinationIndex) movedWindows=\(targets.count)",
            level: .info
        )
        let failures = actuator.apply(targetFrames: targets, windows: activeLayout.windowsByID)
        if !failures.isEmpty {
            Diagnostics.log("AX apply failures for window IDs: \(failures)", level: .warn)
        } else {
            Diagnostics.log("AX apply completed successfully", level: .info)
        }
    }

    private func renderOverlay() {
        guard let dragState, let activeLayout else {
            overlay.hide()
            return
        }

        let ghostRect: CGRect
        if let hover = dragState.hoverSlotIndex, hover < activeLayout.slots.count {
            ghostRect = activeLayout.slots[hover].rect
        } else {
            let dx = dragState.currentPoint.x - dragState.startPoint.x
            let dy = dragState.currentPoint.y - dragState.startPoint.y
            ghostRect = dragState.originalFrame.offsetBy(dx: dx, dy: dy)
        }

        overlay.show(
            displayID: activeLayout.displayID,
            slotRects: activeLayout.slots.map(\.rect),
            hoverIndex: dragState.hoverSlotIndex,
            ghostRect: ghostRect
        )
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
