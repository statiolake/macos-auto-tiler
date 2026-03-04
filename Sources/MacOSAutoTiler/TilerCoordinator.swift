import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let axWindowResolver = AXWindowResolver.shared
    private let ruleStore = WindowRuleStore()
    private lazy var discovery = WindowDiscovery(ruleStore: ruleStore)
    private let defaultLayoutPlanner = LayoutPlanner()
    private let overlay = OverlayWindowController()
    private let groupManager = WindowGroupManager()
    private let tabBar = TabBarWindowController()
    private var layoutPlannerByGroupID: [WindowGroupID: LayoutPlanner] = [:]
    private let eventTap = EventTapController()
    private lazy var geometryApplier = WindowGeometryApplier(
        actuator: AXWindowActuator(resolver: axWindowResolver)
    )
    private let dragTracker = DragInteractionTracker()
    private lazy var lifecycleMonitor = WindowLifecycleMonitor(discovery: discovery)
    private lazy var semanticsClassifier = WindowSemanticsClassifier(resolver: axWindowResolver)
    private let typeRegistry = WindowTypeRegistry()
    private let displaySpaceStateLock = NSLock()
    private var displayGenerationByID: [CGDirectDisplayID: UInt64] = [:]
    private var lastKnownSpaceByDisplayID: [CGDirectDisplayID: Int] = [:]

    private lazy var rulesPanelController = WindowRulesPanelController(
        registry: typeRegistry,
        ruleStore: ruleStore
    ) { [weak self] in
        self?.requestFullReflow(reason: "rules-updated")
    }

    private var activeSpaceObserver: NSObjectProtocol?
    private var activePlan: DisplayLayoutPlan?
    private var lastLoggedHoverIndex: Int?
    private var cachedWindows: [WindowRef]?
    private var cachedTiledWindows: [WindowRef]?
    private var pendingDragCheckpoint: PendingDragCheckpoint?
    private var pendingDragDeferredProbeWorkItem: DispatchWorkItem?
    private var resizePreviewProjection: ResizePreviewProjection?

    private var userFloatingWindowIDs = Set<CGWindowID>()
    private var userTiledWindowIDs = Set<CGWindowID>()
    private var lastSpaceSwitchTime: Date = .distantPast
    private let reflowState = ReflowRequestState()
    private var reflowWorkerTask: Task<Void, Never>?

    private let stableSnapshotsRequired = 3
    private let spaceProbeInterval: TimeInterval = 0.06
    private let maxSpaceTransitionWait: TimeInterval = 1.5
    private let windowHitSlop: CGFloat = 24
    private let pendingDragCheckpointDistance: CGFloat = 24
    private let pendingDragPostThresholdDelay: TimeInterval = TimingConstants.shortSettleDelay
    private let resizeProjectionEdgeDetectionThreshold: CGFloat = 2
    private let minimumProjectedWindowExtent: CGFloat = 80
    private let spaceSwitchCooldown: TimeInterval = 0.3
    private let frameEpsilon: CGFloat = 1.0

    private struct FloatingStateSnapshot {
        let userFloatingWindowIDs: Set<CGWindowID>
        let userTiledWindowIDs: Set<CGWindowID>
        let ruleSnapshot: WindowRuleSnapshot
    }

    private struct PendingDragCheckpoint {
        var lastPoint: CGPoint
        var cumulativeDistance: CGFloat
        var readyAt: Date?
        let startedAt: Date
    }

    private struct ResizeProjectionEdges {
        var moveMinX: Bool
        var moveMaxX: Bool
        var moveMinY: Bool
        var moveMaxY: Bool

        var isEmpty: Bool {
            !moveMinX && !moveMaxX && !moveMinY && !moveMaxY
        }
    }

    private struct ResizePreviewProjection {
        let windowID: CGWindowID
        let activationPoint: CGPoint
        let activationFrame: CGRect
        let edges: ResizeProjectionEdges
    }

    private struct FloatingEvaluationContext {
        let userFloatingWindowIDs: Set<CGWindowID>
        let userTiledWindowIDs: Set<CGWindowID>
        let ruleSnapshot: WindowRuleSnapshot
        let semanticsClassifier: WindowSemanticsClassifier
    }

    private struct ReflowContext {
        let windows: [WindowRef]
        let tiledWindows: [WindowRef]
    }

    func start() {
        Diagnostics.log("Coordinator start requested", level: .info)
        startReflowWorkerIfNeeded()

        let started = eventTap.start { [weak self] eventType, point -> Bool in
            if case let .scrollWheel(deltaY) = eventType {
                return self?.handleScrollWheel(deltaY: deltaY, at: point) ?? false
            }
            DispatchQueue.main.async {
                self?.handle(eventType, point: point)
            }
            return false
        }

        if !started {
            Diagnostics.log("Event tap failed to start (permissions are expected to be pre-granted)", level: .error)
            return
        } else {
            Diagnostics.log("Coordinator started successfully", level: .info)
        }

        setupActiveSpaceObserver()
        refreshDisplaySpaceState(reason: "startup")
        startLifecycleMonitor()

        let activeDisplayIDs = DisplayService.activeDisplayIDs()
        for displayID in activeDisplayIDs {
            DisplayService.additionalBottomInsetByDisplay[displayID] = TabBarWindowController.barHeight
        }
        tabBar.delegate = self
        tabBar.setupWindows(for: activeDisplayIDs)
        refreshTabBars()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.requestFullReflow(reason: "startup")
        }
    }

    func stop() {
        lifecycleMonitor.stop()
        eventTap.stop()
        reflowWorkerTask?.cancel()
        reflowWorkerTask = nil
        Task { [reflowState] in
            await reflowState.reset()
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        displaySpaceStateLock.lock()
        displayGenerationByID.removeAll()
        lastKnownSpaceByDisplayID.removeAll()
        displaySpaceStateLock.unlock()
        resetInteractionState()
        Diagnostics.log("Coordinator stopped", level: .info)
    }

    func showRulesPanel() {
        rulesPanelController.present()
    }

    func requestFullReflow(reason: String = "manual") {
        enqueueReflowRequest(
            .full(
                QueuedFullReflow(
                    reason: reason
                )
            )
        )
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
        case .optionPressed:
            handleOptionKeyPress(at: point)
        case .scrollWheel:
            break // handled synchronously in start() closure
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        resetInteractionState()

        let windows = fetchVisibleWindows()
        let candidates = windowsAtInteractionPoint(point, windows: windows)
        guard !candidates.isEmpty else {
            Diagnostics.log(
                "Mouse down at \(point) but no window hit (windows=\(windows.count) slop=\(windowHitSlop))",
                level: .debug
            )
            return
        }

        cachedWindows = windows
        dragTracker.beginPendingDrag(windows: candidates)
        pendingDragCheckpoint = PendingDragCheckpoint(
            lastPoint: point,
            cumulativeDistance: 0,
            readyAt: nil,
            startedAt: Date()
        )
        let candidateIDs = candidates.map { String($0.windowID) }.joined(separator: ",")
        Diagnostics.log(
            "Pending drag captured candidates=[\(candidateIDs)] count=\(candidates.count)",
            level: .debug
        )
    }

    private func handleMouseDragged(at point: CGPoint) {
        if dragTracker.isResizing {
            updateActiveResizePreview(at: point)
            return
        }

        if dragTracker.isDragging {
            updateActiveDrag(at: point)
            return
        }

        maybeActivateDrag(at: point)
    }

    private func handleMouseUp(at point: CGPoint) {
        if let resizeState = dragTracker.finishResize() {
            finishResizeSession(resizeState: resizeState, point: point)
            resetInteractionState()
            return
        }

        guard activePlan != nil else {
            resetInteractionState()
            return
        }

        guard let dragState = dragTracker.finishDrag(point: point, fallbackHoverSlotIndex: nil) else {
            resetInteractionState()
            return
        }

        // タブバーへのドロップ検出
        if let hit = tabBar.groupID(at: point) {
            clearOverlayState()
            groupManager.moveWindow(dragState.draggedWindowID, toGroup: hit.groupID, on: hit.displayID)
            refreshTabBars()
            requestFullReflow(reason: "group-drop")
            resetInteractionState()
            return
        }

        clearOverlayState()
        enqueueReflowRequest(
            .drop(
                QueuedDropReflow(
                    point: point,
                    draggedWindowID: dragState.draggedWindowID,
                    hoverSlotIndex: dragState.hoverSlotIndex
                )
            )
        )
    }

    private func handleSecondaryMouseDown(at point: CGPoint) {
        toggleFloatingForActiveDrag(at: point)
    }

    private func handleOptionKeyPress(at point: CGPoint) {
        toggleFloatingForActiveDrag(at: point)
    }

    private func toggleFloatingForActiveDrag(at point: CGPoint) {
        guard let draggedWindowID = dragTracker.draggedWindowID else {
            return
        }

        let windows = fetchVisibleWindows()
        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            return
        }

        let floatingContext = liveFloatingContext()
        if isFloatingWindow(draggedWindow, context: floatingContext) {
            userFloatingWindowIDs.remove(draggedWindowID)
            userTiledWindowIDs.insert(draggedWindowID)
            Diagnostics.log("Floating toggle windowID=\(draggedWindowID) -> tiled", level: .info)
            activateDragSession(draggedWindow: draggedWindow, point: point, windows: windows)
        } else {
            userTiledWindowIDs.remove(draggedWindowID)
            userFloatingWindowIDs.insert(draggedWindowID)
            Diagnostics.log("Floating toggle windowID=\(draggedWindowID) -> floating", level: .info)
            clearOverlayState()
            requestFullReflow(reason: "floating-toggle")
        }
    }

    private func maybeActivateDrag(at point: CGPoint) {
        let pendingWindowIDs = dragTracker.pendingWindowIDs
        guard !pendingWindowIDs.isEmpty else {
            pendingDragCheckpoint = nil
            cancelDeferredPendingDragProbe()
            return
        }

        guard hasPassedPendingDragCheckpoint(at: point) else {
            return
        }

        guard var windows = cachedWindows else {
            return
        }
        let beforeFramesByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.frame) })
        let checkpointSnapshot = pendingDragCheckpoint

        // Update only pending windows' frames (skip space/app lookups)
        let updatedFrames = discovery.fetchWindowFrames(for: Set(pendingWindowIDs))
        for (windowID, newFrame) in updatedFrames {
            guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else {
                continue
            }
            let old = windows[index]
            windows[index] = old.with(
                frame: newFrame,
                displayID: DisplayService.displayID(for: newFrame)
            )
        }
        cachedWindows = windows

        let latestByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        if pendingWindowIDs.allSatisfy({ latestByID[$0] == nil }) {
            dragTracker.clearPendingDrag()
            pendingDragCheckpoint = nil
            return
        }

        let checkpointResult = dragTracker.evaluatePendingDragCheckpoint(
            currentPoint: point,
            latestWindowsByID: latestByID
        )
        let resultDescription: String = {
            switch checkpointResult {
            case .resizeActivated:
                return "resizeActivated"
            case .dragActivated:
                return "dragActivated"
            case .noWindowGeometryChange:
                return "noWindowGeometryChange"
            case .pendingCleared:
                return "pendingCleared"
            }
        }()
        let cumulativeDistance = checkpointSnapshot?.cumulativeDistance ?? 0
        let elapsedMS: Int = {
            guard let startedAt = checkpointSnapshot?.startedAt else {
                return 0
            }
            return Int(Date().timeIntervalSince(startedAt) * 1000)
        }()
        let details = pendingWindowIDs.map { windowID -> String in
            let fetched = updatedFrames[windowID] != nil
            guard
                let oldFrame = beforeFramesByID[windowID],
                let newFrame = latestByID[windowID]?.frame
            else {
                return "id=\(windowID) fetched=\(fetched) old=\(String(describing: beforeFramesByID[windowID])) new=\(String(describing: latestByID[windowID]?.frame))"
            }
            let dx = abs(newFrame.origin.x - oldFrame.origin.x)
            let dy = abs(newFrame.origin.y - oldFrame.origin.y)
            let dw = abs(newFrame.size.width - oldFrame.size.width)
            let dh = abs(newFrame.size.height - oldFrame.size.height)
            return "id=\(windowID) fetched=\(fetched) dx=\(dx) dy=\(dy) dw=\(dw) dh=\(dh)"
        }.joined(separator: " | ")
        Diagnostics.log(
            "Pending drag probe distance=\(cumulativeDistance) elapsedMs=\(elapsedMS) result=\(resultDescription) details=[\(details)]",
            level: .debug
        )

        switch checkpointResult {
        case .resizeActivated:
            pendingDragCheckpoint = nil
            cancelDeferredPendingDragProbe()
            configureResizePreviewProjection(at: point, latestWindowsByID: latestByID)
            updateActiveResizePreview(at: point)
            return
        case .dragActivated:
            pendingDragCheckpoint = nil
            cancelDeferredPendingDragProbe()
            resizePreviewProjection = nil
            break
        case .noWindowGeometryChange:
            dragTracker.clearPendingDrag()
            pendingDragCheckpoint = nil
            cancelDeferredPendingDragProbe()
            resizePreviewProjection = nil
            Diagnostics.log(
                "Pending drag checkpoint reached but no window geometry change; suppressing this drag sequence",
                level: .debug
            )
            return
        case .pendingCleared:
            pendingDragCheckpoint = nil
            cancelDeferredPendingDragProbe()
            resizePreviewProjection = nil
            return
        }

        guard
            let draggedWindowID = dragTracker.draggedWindowID,
            let latestWindow = latestByID[draggedWindowID]
        else {
            return
        }

        let floatingContext = liveFloatingContext()
        if isFloatingWindow(latestWindow, context: floatingContext) {
            Diagnostics.log("Dragging floating windowID=\(latestWindow.windowID) (tiler preview disabled)", level: .debug)
            clearOverlayState()
            return
        }

        activateDragSession(draggedWindow: latestWindow, point: point, windows: windows)
    }

    private func updateActiveResizePreview(at point: CGPoint) {
        guard let resizingWindowID = dragTracker.resizingWindowID else {
            resizePreviewProjection = nil
            return
        }

        let windows: [WindowRef]
        if var cached = cachedWindows,
            let index = cached.firstIndex(where: { $0.windowID == resizingWindowID })
        {
            let old = cached[index]
            let projected = projectedResizeFrame(windowID: resizingWindowID, at: point)
            let resolvedFrame: CGRect?
            if let projected {
                resolvedFrame = projected
            } else {
                let updatedFrames = discovery.fetchWindowFrames(for: [resizingWindowID])
                resolvedFrame = updatedFrames[resizingWindowID]
            }

            if let newFrame = resolvedFrame {
                cached[index] = old.with(frame: newFrame)
            } else {
                cached[index] = old
            }
            cachedWindows = cached
            windows = cached
        } else {
            let fetched = fetchVisibleWindows()
            cachedWindows = fetched
            windows = fetched
        }

        guard let resizingWindow = windows.first(where: { $0.windowID == resizingWindowID }) else {
            clearOverlayState()
            return
        }

        let floatingContext = liveFloatingContext()
        if isFloatingWindow(resizingWindow, context: floatingContext) {
            clearOverlayState()
            return
        }

        let tiled = tiledWindows(from: windows, floatingContext: floatingContext)
        guard let displayID = DisplayService.displayID(containing: point) else {
            clearOverlayState()
            return
        }
        let resizePlanner = activeLayoutPlanner(for: displayID)
        resizePlanner.syncRatiosFromObservedWindows(
            tiled,
            resizingWindowID: resizingWindowID,
            originalResizingFrame: dragTracker.resizeState?.originalFrame
        )

        let plans = resizePlanner.buildReflowPlans(from: tiled)
        guard
            let plan = plans.first(where: { $0.displayID == displayID && $0.spaceID == resizingWindow.spaceID })
                ?? plans.first(where: { $0.displayID == displayID })
        else {
            clearOverlayState()
            return
        }

        activePlan = plan
        lastLoggedHoverIndex = nil
        overlay.show(
            displayID: plan.displayID,
            slotRects: plan.slots.map(\.rect),
            hoverIndex: nil
        )
    }

    private func finishResizeSession(resizeState: DragInteractionTracker.ResizeState, point: CGPoint) {
        clearOverlayState()

        let windows = fetchVisibleWindows()
        guard let resizedWindow = windows.first(where: { $0.windowID == resizeState.windowID }) else {
            return
        }
        let floatingContext = liveFloatingContext()
        guard !isFloatingWindow(resizedWindow, context: floatingContext) else {
            return
        }

        let tiled = tiledWindows(from: windows, floatingContext: floatingContext)
        let resizePlanner = activeLayoutPlanner(for: resizedWindow.displayID)
        resizePlanner.syncRatiosFromObservedWindows(
            tiled,
            resizingWindowID: resizeState.windowID,
            originalResizingFrame: resizeState.originalFrame
        )

        Diagnostics.log(
            "Resize end windowID=\(resizeState.windowID) app=\(resizedWindow.appName) point=\(point) -> apply once",
            level: .info
        )
        requestFullReflow(reason: "resize-end")
    }

    private func activateDragSession(draggedWindow: WindowRef, point: CGPoint, windows: [WindowRef]? = nil) {
        let allWindows = windows ?? fetchVisibleWindows()
        let floatingContext = liveFloatingContext()
        let tiled = tiledWindows(
            from: allWindows,
            including: [draggedWindow.windowID],
            floatingContext: floatingContext
        )

        cachedWindows = allWindows
        cachedTiledWindows = tiled

        let dragDisplayID = DisplayService.displayID(containing: point) ?? draggedWindow.displayID
        let dragPlanner = activeLayoutPlanner(for: dragDisplayID)
        guard
            let plan = dragPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: draggedWindow.windowID,
                preferredSpaceID: draggedWindow.spaceID
            )
        else {
            Diagnostics.log("No windows found for drag session at point=\(point)", level: .warn)
            clearOverlayState()
            return
        }

        let hoverIndex = dragPlanner.slotIndex(at: point, in: plan)
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

        guard let windows = cachedWindows else {
            resetInteractionState()
            return
        }
        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            resetInteractionState()
            return
        }

        let floatingContext = liveFloatingContext()
        if isFloatingWindow(draggedWindow, context: floatingContext) {
            clearOverlayState()
            return
        }

        let previousDisplayID = activePlan?.displayID
        let currentDisplayID = DisplayService.displayID(containing: point)

        let previewPlan: DisplayLayoutPlan
        if let existing = activePlan, currentDisplayID == existing.displayID {
            previewPlan = existing
        } else {
            let tiled = cachedTiledWindows
                ?? tiledWindows(
                    from: windows,
                    including: [draggedWindowID],
                    floatingContext: floatingContext
                )
            let updateDisplayID = currentDisplayID ?? draggedWindow.displayID
            let updatePlanner = activeLayoutPlanner(for: updateDisplayID)
            guard
                let newPlan = updatePlanner.buildDragPreviewPlan(
                    at: point,
                    windows: tiled,
                    draggedWindowID: draggedWindowID,
                    preferredSpaceID: draggedWindow.spaceID
                )
            else {
                clearOverlayState()
                return
            }
            previewPlan = newPlan
        }

        let activeDragPlanner = activeLayoutPlanner(for: previewPlan.displayID)
        let hoverIndex = activeDragPlanner.slotIndex(at: point, in: previewPlan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            clearOverlayState()
            return
        }

        activePlan = previewPlan

        let displayChanged = previousDisplayID != nil && previousDisplayID != previewPlan.displayID
        let hoverChanged = dragState.hoverSlotIndex != lastLoggedHoverIndex

        if displayChanged {
            Diagnostics.log(
                "Drag display changed windowID=\(dragState.draggedWindowID) display=\(previewPlan.displayID)",
                level: .info
            )
        }

        if hoverChanged {
            let hoverText = dragState.hoverSlotIndex.map(String.init) ?? "nil"
            Diagnostics.log(
                "Drag hover changed windowID=\(dragState.draggedWindowID) hover=\(hoverText) point=\(point)",
                level: .debug
            )
            lastLoggedHoverIndex = dragState.hoverSlotIndex
        }

        if hoverChanged || displayChanged {
            renderOverlay(dragState: dragState, plan: previewPlan)
        }
    }

    private func renderOverlay(dragState: DragState, plan: DisplayLayoutPlan) {
        overlay.show(
            displayID: plan.displayID,
            slotRects: plan.slots.map(\.rect),
            hoverIndex: dragState.hoverSlotIndex
        )
    }

    private func startReflowWorkerIfNeeded() {
        guard reflowWorkerTask == nil else {
            return
        }

        reflowWorkerTask = Task { [weak self] in
            guard let self else { return }
            await runReflowWorker()
        }
    }

    private func enqueueReflowRequest(_ request: QueuedReflowRequest) {
        Task { [weak self] in
            guard let self else { return }
            await reflowState.enqueue(request)
        }
    }

    private func runReflowWorker() async {
        while true {
            if Task.isCancelled {
                return
            }

            guard let request = await reflowState.nextRequest() else {
                continue
            }

            // Check if reflow conditions are met atomically.
            let isIdle = await MainActor.run { [weak self] in
                guard let self else { return false }
                return !self.dragTracker.isDragging
                    && !self.dragTracker.isResizing
                    && self.dragTracker.pendingWindowIDs.isEmpty
            }

            let isStable = await isReflowStable()

            if !isIdle || !isStable {
                // Conditions not met - re-enqueue and retry.
                await reflowState.enqueue(request)
                continue
            }

            // Conditions met - perform reflow.
            switch request {
            case let .drop(drop):
                _ = performDropReflow(
                    point: drop.point,
                    draggedWindowID: drop.draggedWindowID,
                    hoverSlotIndex: drop.hoverSlotIndex
                )
            case let .full(full):
                _ = performFullReflow(reason: full.reason)
            }
        }
    }

    private func isReflowStable() async -> Bool {
        let deadline = Date().addingTimeInterval(maxSpaceTransitionWait)
        var stableCount = 0
        var lastSignature: UInt64?

        while stableCount < stableSnapshotsRequired {
            if Task.isCancelled || Date() > deadline {
                Diagnostics.log("Reflow stability timeout", level: .warn)
                return false
            }

            let windows = discovery.fetchVisibleWindows()
            let signature = spaceSnapshotSignature(for: windows)

            if let last = lastSignature, last == signature {
                stableCount += 1
            } else {
                stableCount = 1
                lastSignature = signature
            }

            try? await Task.sleep(nanoseconds: UInt64(spaceProbeInterval * 1_000_000_000))
        }

        return true
    }

    private func reflowTriggerDescription(for request: QueuedReflowRequest) -> String {
        switch request {
        case let .drop(drop):
            return "drop:\(drop.draggedWindowID)"
        case let .full(full):
            return "full:\(full.reason)"
        }
    }

    private func performFullReflow(reason: String) -> Bool {
        let expectedDisplayGenerationByID = captureDisplayGenerationSnapshot(for: Set(DisplayService.activeDisplayIDs()))
        let floatingState = captureFloatingStateSnapshot()
        Diagnostics.log("Reflow job started (\(reason))", level: .debug)
        guard
            let context = buildReflowContext(
                floatingState: floatingState,
                reason: reason
            )
        else {
            Diagnostics.log("Reflow (\(reason)) canceled: unresolved window-space mapping", level: .warn)
            return false
        }
        let windows = context.windows
        let tiled = context.tiledWindows
        let plansByDisplay = Dictionary(grouping: tiled, by: \.displayID)
        var plans: [DisplayLayoutPlan] = []
        for (displayID, displayWindows) in plansByDisplay {
            plans += activeLayoutPlanner(for: displayID).buildReflowPlans(from: displayWindows)
        }
        guard !plans.isEmpty else {
            Diagnostics.log(
                "Reflow (\(reason)) skipped: no tile candidates (visible=\(windows.count), floating=\(windows.count - tiled.count))",
                level: .debug
            )
            return false
        }

        var totalTargets = 0
        var totalFailures: [CGWindowID] = []
        for plan in plans {
            guard displayGenerationsUnchanged(
                for: Set([plan.displayID]),
                expectedByDisplay: expectedDisplayGenerationByID,
                reason: "\(reason)/display=\(plan.displayID)"
            ) else {
                continue
            }

            let targets = targetFramesNeedingApply(
                targetFrames: plan.targetFrames,
                windowsByID: plan.windowsByID
            )
            guard !targets.isEmpty else {
                Diagnostics.log(
                    "Reflow (\(reason)) display=\(plan.displayID) skipped: all targets already satisfied",
                    level: .debug
                )
                continue
            }
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
            if totalTargets == 0 {
                Diagnostics.log("Reflow (\(reason)) no-op: target frames already applied", level: .debug)
            } else {
                Diagnostics.log("Reflow (\(reason)) finished successfully for \(totalTargets) windows", level: .info)
            }
        } else {
            Diagnostics.log("Reflow (\(reason)) finished with failures: \(totalFailures)", level: .warn)
        }
        return totalTargets > 0
    }

    private func performDropReflow(
        point: CGPoint,
        draggedWindowID: CGWindowID,
        hoverSlotIndex: Int?
    ) -> Bool {
        let expectedDisplayGenerationByID = captureDisplayGenerationSnapshot(for: Set(DisplayService.activeDisplayIDs()))
        let floatingState = captureFloatingStateSnapshot()
        guard
            let context = buildReflowContext(
                floatingState: floatingState,
                including: [draggedWindowID],
                reason: "drop/window=\(draggedWindowID)"
            )
        else {
            Diagnostics.log(
                "Drop reflow canceled windowID=\(draggedWindowID): unresolved window-space mapping",
                level: .warn
            )
            return false
        }
        let windows = context.windows
        let tiled = context.tiledWindows

        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            Diagnostics.log("Drop fallback: dragged window missing windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:missing-window")
        }

        let dropDisplayID = DisplayService.displayID(containing: point) ?? draggedWindow.displayID
        let dropPlanner = activeLayoutPlanner(for: dropDisplayID)
        guard
            let previewPlan = dropPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: draggedWindowID,
                preferredSpaceID: draggedWindow.spaceID
            )
        else {
            Diagnostics.log("Drop fallback: failed to build preview plan windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:preview-plan")
        }

        let destinationIndex = dropPlanner.slotIndex(at: point, in: previewPlan) ?? hoverSlotIndex
        guard let destinationIndex else {
            Diagnostics.log("Drop fallback: no destination slot windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:destination")
        }

        let dragState = DragState(
            draggedWindowID: draggedWindowID,
            startPoint: point,
            currentPoint: point,
            originalFrame: draggedWindow.frame,
            hoverSlotIndex: hoverSlotIndex
        )

        guard
            let drop = dropPlanner.resolveDrop(
                previewPlan: previewPlan,
                dragState: dragState,
                destinationIndex: destinationIndex,
                allWindows: tiled
            )
        else {
            Diagnostics.log("Drop fallback: resolve failed windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:resolve")
        }

        if !drop.shouldApply {
            Diagnostics.log(
                "Drop requested with unchanged destination windowID=\(draggedWindowID) destination=\(drop.destinationSlotIndex); applying full layout anyway",
                level: .debug
            )
        }

        let sourceSlotText = drop.sourceSlotIndex.map(String.init) ?? "nil"
        let targetFrames = targetFramesNeedingApply(
            targetFrames: drop.targetFrames,
            windowsByID: drop.windowsByID
        )
        guard !targetFrames.isEmpty else {
            Diagnostics.log(
                "Drop no-op windowID=\(draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex)",
                level: .debug
            )
            return false
        }

        let involvedDisplayIDs = displayIDsForTargetFrames(
            targetFrames,
            windowsByID: drop.windowsByID
        )
        guard displayGenerationsUnchanged(
            for: involvedDisplayIDs,
            expectedByDisplay: expectedDisplayGenerationByID,
            reason: "drop/window=\(draggedWindowID)"
        ) else {
            return false
        }

        Diagnostics.log(
            "Applying layout from drop windowID=\(draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex) movedWindows=\(targetFrames.count)",
            level: .info
        )

        let failures = geometryApplier.applySync(
            reason: "drop/window=\(draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex)",
            targetFrames: targetFrames,
            windowsByID: drop.windowsByID
        )
        logApplyResult(failures)
        return !targetFrames.isEmpty
    }

    private func buildReflowContext(
        floatingState: FloatingStateSnapshot,
        including includedWindowIDs: Set<CGWindowID> = [],
        reason: String
    ) -> ReflowContext? {
        guard let windows = discovery.fetchVisibleWindowsReflowSafe() else {
            Diagnostics.log(
                "Reflow context rejected reason=\(reason): incomplete space mapping",
                level: .warn
            )
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allIDs = self.discovery.fetchAllWindowIDs()
            self.pruneFloatingState(to: allIDs)
        }

        // グループ管理の同期
        let allLiveIDs = Set(windows.map(\.windowID))
        groupManager.pruneWindows(to: allLiveIDs)
        for displayID in Set(windows.map(\.displayID)) {
            let ids = windows.filter { $0.displayID == displayID }.map(\.windowID)
            groupManager.registerNewWindows(ids, on: displayID)
        }
        DispatchQueue.main.async { [weak self] in self?.refreshTabBars() }

        let floatingContext = makeFloatingContext(
            from: floatingState,
            semanticsClassifier: semanticsClassifier
        )
        let allTiled = tiledWindows(
            from: windows,
            including: includedWindowIDs,
            floatingContext: floatingContext
        )

        // アクティブグループ以外のウィンドウを除外
        let groupFiltered = allTiled.filter { w in
            if includedWindowIDs.contains(w.windowID) { return true }
            return !groupManager.inactiveWindowIDs(for: w.displayID).contains(w.windowID)
        }
        return ReflowContext(windows: windows, tiledWindows: groupFiltered)
    }

    private func fetchVisibleWindows() -> [WindowRef] {
        let windows = discovery.fetchVisibleWindows()
        pruneFloatingState(using: windows)
        for window in windows {
            let semantics = semanticsClassifier.semantics(for: window)
            typeRegistry.record(
                appName: window.appName,
                bundleID: window.bundleID,
                descriptor: semantics.descriptor
            )
        }
        return windows
    }

    private func captureFloatingStateSnapshot() -> FloatingStateSnapshot {
        FloatingStateSnapshot(
            userFloatingWindowIDs: userFloatingWindowIDs,
            userTiledWindowIDs: userTiledWindowIDs,
            ruleSnapshot: ruleStore.snapshot()
        )
    }

    private func makeFloatingContext(
        from snapshot: FloatingStateSnapshot,
        semanticsClassifier: WindowSemanticsClassifier
    ) -> FloatingEvaluationContext {
        FloatingEvaluationContext(
            userFloatingWindowIDs: snapshot.userFloatingWindowIDs,
            userTiledWindowIDs: snapshot.userTiledWindowIDs,
            ruleSnapshot: snapshot.ruleSnapshot,
            semanticsClassifier: semanticsClassifier
        )
    }

    private func tiledWindows(
        from windows: [WindowRef],
        including included: Set<CGWindowID> = [],
        floatingContext: FloatingEvaluationContext? = nil
    ) -> [WindowRef] {
        let context = floatingContext ?? liveFloatingContext()
        return windows.filter { window in
            if included.contains(window.windowID) {
                return true
            }
            return !isFloatingWindow(window, context: context)
        }
    }

    private func liveFloatingContext() -> FloatingEvaluationContext {
        FloatingEvaluationContext(
            userFloatingWindowIDs: userFloatingWindowIDs,
            userTiledWindowIDs: userTiledWindowIDs,
            ruleSnapshot: ruleStore.snapshot(),
            semanticsClassifier: semanticsClassifier
        )
    }

    private func isFloatingWindow(_ window: WindowRef, context: FloatingEvaluationContext) -> Bool {
        if context.userFloatingWindowIDs.contains(window.windowID) {
            return true
        }
        if context.userTiledWindowIDs.contains(window.windowID) {
            return false
        }
        if context.ruleSnapshot.isBundleExcluded(window.bundleID) {
            return true
        }
        if context.ruleSnapshot.isAppForcedFloating(window.appName) {
            return true
        }
        let semantics = context.semanticsClassifier.semantics(for: window)
        if context.ruleSnapshot.isTypeForcedFloating(semantics.descriptor) {
            return true
        }
        return semantics.isSpecialFloating
    }

    private func pruneFloatingState(using windows: [WindowRef]) {
        // floating state の prune は全 space のウィンドウを基準にする。
        // visible windows (on-screen only) だと他 space や最小化ウィンドウが除外され、
        // floating state が誤って削除される。
        let allIDs = discovery.fetchAllWindowIDs()
        pruneFloatingState(to: allIDs)
        // semantics cache は visible windows のみで prune する（メモリ効率のため）
        let visibleIDs = Set(windows.map(\.windowID))
        semanticsClassifier.prune(to: visibleIDs)
    }

    private func pruneFloatingState(to liveIDs: Set<CGWindowID>) {
        userFloatingWindowIDs.formIntersection(liveIDs)
        userTiledWindowIDs.formIntersection(liveIDs)
    }

    private func refreshDisplaySpaceState(reason: String) {
        let activeDisplayIDs = Set(DisplayService.activeDisplayIDs())
        guard !activeDisplayIDs.isEmpty else {
            return
        }
        let currentSpaceByDisplayID = CGSSpaceService.shared.currentSpaceByDisplayID(displayIDs: activeDisplayIDs)

        displaySpaceStateLock.lock()
        defer { displaySpaceStateLock.unlock() }

        let staleDisplayIDs = Set(displayGenerationByID.keys).subtracting(activeDisplayIDs)
        for displayID in staleDisplayIDs {
            displayGenerationByID.removeValue(forKey: displayID)
            lastKnownSpaceByDisplayID.removeValue(forKey: displayID)
        }

        var changed: [String] = []
        for displayID in activeDisplayIDs.sorted() {
            if displayGenerationByID[displayID] == nil {
                displayGenerationByID[displayID] = 0
            }

            guard let nextSpaceID = currentSpaceByDisplayID[displayID] else {
                continue
            }

            let previousSpaceID = lastKnownSpaceByDisplayID[displayID]
            lastKnownSpaceByDisplayID[displayID] = nextSpaceID
            guard let previousSpaceID, previousSpaceID != nextSpaceID else {
                continue
            }

            let nextGeneration = (displayGenerationByID[displayID] ?? 0) &+ 1
            displayGenerationByID[displayID] = nextGeneration
            changed.append("display=\(displayID) \(previousSpaceID)->\(nextSpaceID) gen=\(nextGeneration)")
        }

        if !changed.isEmpty {
            Diagnostics.log(
                "Display space generation advanced reason=\(reason) \(changed.joined(separator: ", "))",
                level: .debug
            )
            return
        }

        if currentSpaceByDisplayID.count < activeDisplayIDs.count {
            Diagnostics.log(
                "Display space generation refresh partial reason=\(reason) resolved=\(currentSpaceByDisplayID.count)/\(activeDisplayIDs.count)",
                level: .debug
            )
        }
    }

    private func captureDisplayGenerationSnapshot(for displayIDs: Set<CGDirectDisplayID>) -> [CGDirectDisplayID: UInt64] {
        guard !displayIDs.isEmpty else {
            return [:]
        }

        displaySpaceStateLock.lock()
        defer { displaySpaceStateLock.unlock() }

        var snapshot: [CGDirectDisplayID: UInt64] = [:]
        snapshot.reserveCapacity(displayIDs.count)
        for displayID in displayIDs {
            snapshot[displayID] = displayGenerationByID[displayID] ?? 0
        }
        return snapshot
    }

    private func displayGenerationsUnchanged(
        for displayIDs: Set<CGDirectDisplayID>,
        expectedByDisplay: [CGDirectDisplayID: UInt64],
        reason: String
    ) -> Bool {
        guard !displayIDs.isEmpty else {
            return true
        }

        displaySpaceStateLock.lock()
        var mismatches: [String] = []
        mismatches.reserveCapacity(displayIDs.count)
        for displayID in displayIDs.sorted() {
            let expected = expectedByDisplay[displayID] ?? 0
            let current = displayGenerationByID[displayID] ?? 0
            if expected != current {
                mismatches.append("display=\(displayID) expected=\(expected) current=\(current)")
            }
        }
        displaySpaceStateLock.unlock()

        guard mismatches.isEmpty else {
            Diagnostics.log(
                "Reflow canceled reason=\(reason) due to display space generation mismatch [\(mismatches.joined(separator: ", "))]",
                level: .warn
            )
            return false
        }
        return true
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
            Diagnostics.log("Active space changed", level: .debug)
            self.refreshDisplaySpaceState(reason: "active-space-notification")
            self.requestFullReflow(reason: "space-change")
        }
    }

    private func spaceSnapshotSignature(for windows: [WindowRef]) -> UInt64 {
        var pairs: [(CGWindowID, CGDirectDisplayID, Int)] = []
        pairs.reserveCapacity(windows.count)
        for window in windows {
            pairs.append((window.windowID, window.displayID, window.spaceID))
        }
        pairs.sort {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }

        var hash = UInt64(pairs.count)
        for (windowID, displayID, spaceID) in pairs {
            FNV1a64.combine(&hash, UInt64(windowID))
            FNV1a64.combine(&hash, UInt64(displayID))
            FNV1a64.combine(&hash, signed: spaceID)
        }
        return hash
    }

    private func startLifecycleMonitor() {
        lifecycleMonitor.start { [weak self] reason in
            guard let self else { return }
            Diagnostics.log("Lifecycle change detected reason=\(reason)", level: .debug)
            requestFullReflow(reason: "lifecycle:\(reason)")
        }
    }

    private func displayIDsForTargetFrames(
        _ targetFrames: [CGWindowID: CGRect],
        windowsByID: [CGWindowID: WindowRef]
    ) -> Set<CGDirectDisplayID> {
        var displayIDs = Set<CGDirectDisplayID>()
        displayIDs.reserveCapacity(targetFrames.count)
        for windowID in targetFrames.keys {
            guard let displayID = windowsByID[windowID]?.displayID else {
                continue
            }
            displayIDs.insert(displayID)
        }
        return displayIDs
    }

    private func targetFramesNeedingApply(
        targetFrames: [CGWindowID: CGRect],
        windowsByID: [CGWindowID: WindowRef]
    ) -> [CGWindowID: CGRect] {
        targetFrames.filter { windowID, targetFrame in
            guard let window = windowsByID[windowID] else {
                return true
            }
            return !GeometryUtils.isApproximatelyEqual(window.frame, targetFrame, tolerance: frameEpsilon)
        }
    }

    private func clearOverlayState() {
        overlay.hide()
        activePlan = nil
        lastLoggedHoverIndex = nil
    }

    private func resetInteractionState() {
        dragTracker.clearAll()
        cancelDeferredPendingDragProbe()
        clearOverlayState()
        cachedWindows = nil
        cachedTiledWindows = nil
        pendingDragCheckpoint = nil
        resizePreviewProjection = nil
    }

    private func logApplyResult(_ failures: [CGWindowID]) {
        if failures.isEmpty {
            Diagnostics.log("AX apply completed successfully", level: .info)
            return
        }
        Diagnostics.log("AX apply failures for window IDs: \(failures)", level: .warn)
    }

    private func handleScrollWheel(deltaY: Int64, at point: CGPoint) -> Bool {
        guard !discovery.hasVisibleWindow(at: point) else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastSpaceSwitchTime) >= spaceSwitchCooldown else {
            return true
        }

        let goLeft = deltaY > 0
        let switched = simulateSpaceSwitch(goLeft: goLeft, at: point, deltaY: deltaY)
        if switched {
            lastSpaceSwitchTime = now
        }
        return switched
    }

    private func simulateSpaceSwitch(goLeft: Bool, at point: CGPoint, deltaY: Int64) -> Bool {
        guard let displayID = DisplayService.displayID(containing: point) else {
            Diagnostics.log("Space switch failed: no display at point", level: .warn)
            return false
        }

        Diagnostics.log(
            "Empty-area scroll -> switch Space \(goLeft ? "left" : "right") (deltaY=\(deltaY))",
            level: .info
        )

        let switched = CGSSpaceService.shared.switchToAdjacentSpace(displayID: displayID, goLeft: goLeft)
        if !switched {
            Diagnostics.log("Space switch failed: no adjacent target or shortcut post failed", level: .warn)
            return false
        }
        return true
    }

    private func hasPassedPendingDragCheckpoint(at point: CGPoint) -> Bool {
        guard var checkpoint = pendingDragCheckpoint else {
            return true
        }

        let deltaX = point.x - checkpoint.lastPoint.x
        let deltaY = point.y - checkpoint.lastPoint.y
        checkpoint.cumulativeDistance += hypot(deltaX, deltaY)
        checkpoint.lastPoint = point
        if checkpoint.cumulativeDistance < pendingDragCheckpointDistance {
            pendingDragCheckpoint = checkpoint
            return false
        }

        if let readyAt = checkpoint.readyAt {
            pendingDragCheckpoint = checkpoint
            return Date() >= readyAt
        }

        checkpoint.readyAt = Date().addingTimeInterval(pendingDragPostThresholdDelay)
        pendingDragCheckpoint = checkpoint
        scheduleDeferredPendingDragProbe()
        return false
    }

    private func scheduleDeferredPendingDragProbe() {
        guard pendingDragDeferredProbeWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDragDeferredProbeWorkItem = nil
            guard let checkpoint = self.pendingDragCheckpoint else {
                return
            }
            self.maybeActivateDrag(at: checkpoint.lastPoint)
        }
        pendingDragDeferredProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingDragPostThresholdDelay, execute: workItem)
    }

    private func cancelDeferredPendingDragProbe() {
        pendingDragDeferredProbeWorkItem?.cancel()
        pendingDragDeferredProbeWorkItem = nil
    }

    private func configureResizePreviewProjection(at point: CGPoint, latestWindowsByID: [CGWindowID: WindowRef]) {
        guard
            let resizeState = dragTracker.resizeState,
            let latestWindow = latestWindowsByID[resizeState.windowID]
        else {
            resizePreviewProjection = nil
            return
        }

        let edges = detectResizeProjectionEdges(
            originalFrame: resizeState.originalFrame,
            currentFrame: latestWindow.frame
        )

        guard !edges.isEmpty else {
            resizePreviewProjection = nil
            return
        }

        resizePreviewProjection = ResizePreviewProjection(
            windowID: latestWindow.windowID,
            activationPoint: point,
            activationFrame: latestWindow.frame,
            edges: edges
        )
    }

    private func detectResizeProjectionEdges(originalFrame: CGRect, currentFrame: CGRect) -> ResizeProjectionEdges {
        let minXDelta = abs(currentFrame.minX - originalFrame.minX)
        let maxXDelta = abs(currentFrame.maxX - originalFrame.maxX)
        let minYDelta = abs(currentFrame.minY - originalFrame.minY)
        let maxYDelta = abs(currentFrame.maxY - originalFrame.maxY)

        var edges = ResizeProjectionEdges(
            moveMinX: minXDelta >= resizeProjectionEdgeDetectionThreshold,
            moveMaxX: maxXDelta >= resizeProjectionEdgeDetectionThreshold,
            moveMinY: minYDelta >= resizeProjectionEdgeDetectionThreshold,
            moveMaxY: maxYDelta >= resizeProjectionEdgeDetectionThreshold
        )

        if edges.moveMinX && edges.moveMaxX {
            if minXDelta > maxXDelta {
                edges.moveMaxX = false
            } else {
                edges.moveMinX = false
            }
        }

        if edges.moveMinY && edges.moveMaxY {
            if minYDelta > maxYDelta {
                edges.moveMaxY = false
            } else {
                edges.moveMinY = false
            }
        }

        return edges
    }

    private func projectedResizeFrame(windowID: CGWindowID, at point: CGPoint) -> CGRect? {
        guard let projection = resizePreviewProjection, projection.windowID == windowID else {
            return nil
        }

        var minX = projection.activationFrame.minX
        var maxX = projection.activationFrame.maxX
        var minY = projection.activationFrame.minY
        var maxY = projection.activationFrame.maxY

        if projection.edges.moveMinX {
            minX = point.x
        }
        if projection.edges.moveMaxX {
            maxX = point.x
        }
        if projection.edges.moveMinY {
            minY = point.y
        }
        if projection.edges.moveMaxY {
            maxY = point.y
        }

        if maxX - minX < minimumProjectedWindowExtent {
            if projection.edges.moveMinX && !projection.edges.moveMaxX {
                minX = maxX - minimumProjectedWindowExtent
            } else {
                maxX = minX + minimumProjectedWindowExtent
            }
        }

        if maxY - minY < minimumProjectedWindowExtent {
            if projection.edges.moveMinY && !projection.edges.moveMaxY {
                minY = maxY - minimumProjectedWindowExtent
            } else {
                maxY = minY + minimumProjectedWindowExtent
            }
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func windowsAtInteractionPoint(_ point: CGPoint, windows: [WindowRef]) -> [WindowRef] {
        return windows.filter {
            $0.frame.insetBy(dx: -windowHitSlop, dy: -windowHitSlop).contains(point)
        }
    }

    // MARK: - Group / Tab Bar helpers

    private func activeLayoutPlanner(for displayID: CGDirectDisplayID) -> LayoutPlanner {
        guard let groupID = groupManager.activeGroup(for: displayID)?.id else {
            return defaultLayoutPlanner
        }
        if let planner = layoutPlannerByGroupID[groupID] { return planner }
        let planner = LayoutPlanner()
        layoutPlannerByGroupID[groupID] = planner
        return planner
    }

    private func refreshTabBars() {
        for displayID in DisplayService.activeDisplayIDs() {
            tabBar.updateTabs(
                groups: groupManager.groups(for: displayID),
                activeGroupID: groupManager.activeGroup(for: displayID)?.id,
                for: displayID
            )
        }
    }

    private func raiseGroupWindows(_ windowIDs: Set<CGWindowID>, from allWindows: [WindowRef]) {
        for window in allWindows where windowIDs.contains(window.windowID) {
            if let resolved = axWindowResolver.window(pid: window.pid, windowID: window.windowID) {
                AXUIElementPerformAction(resolved.element, "AXRaise" as CFString)
            }
        }
    }
}

// MARK: - TabBarWindowControllerDelegate

extension TilerCoordinator: TabBarWindowControllerDelegate {
    func tabBar(_ controller: TabBarWindowController, didSelectGroupID id: WindowGroupID, on displayID: CGDirectDisplayID) {
        groupManager.activateGroup(id: id, for: displayID)
        let activeWindowIDs = groupManager.activeGroup(for: displayID)?.windowIDs ?? []
        raiseGroupWindows(activeWindowIDs, from: discovery.fetchVisibleWindows())
        refreshTabBars()
        requestFullReflow(reason: "group-switch")
    }

    func tabBar(_ controller: TabBarWindowController, didRequestNewGroupOn displayID: CGDirectDisplayID) {
        let name = "Group \(groupManager.groups(for: displayID).count + 1)"
        groupManager.createGroup(for: displayID, name: name)
        refreshTabBars()
    }

    func tabBar(_ controller: TabBarWindowController, didDropWindowID windowID: CGWindowID, ontoGroupID groupID: WindowGroupID, on displayID: CGDirectDisplayID) {
        groupManager.moveWindow(windowID, toGroup: groupID, on: displayID)
        refreshTabBars()
        requestFullReflow(reason: "group-drop")
    }
}
