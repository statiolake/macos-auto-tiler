import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let axWindowResolver = AXWindowResolver.shared
    private let ruleStore = WindowRuleStore()
    private lazy var discovery = WindowDiscovery(ruleStore: ruleStore)
    private let defaultLayoutPlanner = LayoutPlanner()
    private let overlay = OverlayWindowController()
    private let windowSetManager = WindowSetManager()
    private let windowFocusController = PrivateWindowFocusController()
    private let tabBar = TabBarWindowController()
    private var layoutPlannerBySetID: [WindowSetID: LayoutPlanner] = [:]
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
    private var pendingDragCheckpoint: PendingDragCheckpoint?
    private var pendingDragDeferredProbeWorkItem: DispatchWorkItem?
    private var resizePreviewProjection: ResizePreviewProjection?

    private var explicitFloatingWindowIDs = Set<CGWindowID>()
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
    private let windowRaiseDelay: TimeInterval = 0.01
    private let setSwitchReasonPrefix = "set-switch/display="
    private let spaceChangeReason = "space-change"

    private struct FloatingStateSnapshot {
        let explicitFloatingWindowIDs: Set<CGWindowID>
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
        let explicitFloatingWindowIDs: Set<CGWindowID>
    }

    private enum FloatingDisposition {
        case tiled
        case explicitFloating
        case automaticFloating
    }

    func start() {
        Diagnostics.log("Coordinator start requested", level: .info)
        startReflowWorkerIfNeeded()

        let started = eventTap.start { [weak self] eventType, point -> Bool in
            if case let .scrollWheel(deltaY) = eventType {
                return self?.handleScrollWheel(deltaY: deltaY, at: point) ?? false
            }
            if case .optionTabPressed = eventType {
                return self?.handle(eventType, point: point) ?? false
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
        // inset は refreshTabBars でセット数に応じて動的に設定されるため初期値は 0
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

    @discardableResult
    private func handle(_ eventType: MouseEventType, point: CGPoint) -> Bool {
        switch eventType {
        case .down:
            handleMouseDown(at: point)
            return false
        case .dragged:
            handleMouseDragged(at: point)
            return false
        case .up:
            handleMouseUp(at: point)
            return false
        case .secondaryDown:
            handleSecondaryMouseDown(at: point)
            return false
        case .optionPressed:
            handleOptionKeyPress(at: point)
            return false
        case let .optionTabPressed(reverse):
            return handleOptionTabPress(at: point, reverse: reverse)
        case .scrollWheel:
            return false // handled synchronously in start() closure
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
            resetInteractionState()
            finishResizeSession(resizeState: resizeState, point: point)
            return
        }

        // タブバーへのドロップ検出（activePlan の有無に関わらず最優先でチェック）
        if dragTracker.isDragging, let draggedWindowID = dragTracker.draggedWindowID {
            if let hit = tabBar.setID(at: point) {
                let spaceID = currentSpaceID(for: hit.displayID)
                windowSetManager.moveWindowToSet(draggedWindowID, toSetID: hit.setID, on: hit.displayID, spaceID: spaceID)
                resetInteractionState()
                refreshTabBars()
                requestFullReflow(reason: "set-drop")
                return
            }
            if let displayID = tabBar.isPlusZone(at: point) {
                let spaceID = currentSpaceID(for: displayID)
                let newSet = windowSetManager.createSet(for: displayID, spaceID: spaceID)
                windowSetManager.moveWindowToSet(draggedWindowID, toSetID: newSet.id, on: displayID, spaceID: spaceID)
                resetInteractionState()
                refreshTabBars()
                requestFullReflow(reason: "set-drop-new")
                return
            }
        }

        guard activePlan != nil else {
            resetInteractionState()
            return
        }

        guard let dragState = dragTracker.finishDrag(point: point, fallbackHoverSlotIndex: nil) else {
            resetInteractionState()
            return
        }

        resetInteractionState()
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
        guard dragTracker.isDragging || dragTracker.isResizing || !dragTracker.pendingWindowIDs.isEmpty else {
            return
        }
        toggleFloatingForActiveDrag(at: point)
    }

    private func handleOptionTabPress(at point: CGPoint, reverse: Bool) -> Bool {
        guard !dragTracker.isDragging, !dragTracker.isResizing else {
            return false
        }

        let activeDisplayIDs = DisplayService.activeDisplayIDs()
        guard !activeDisplayIDs.isEmpty else {
            return false
        }

        let displayID = DisplayService.displayID(containing: point) ?? activeDisplayIDs[0]
        let spaceID = currentSpaceID(for: displayID)
        let sets = windowSetManager.sets(for: displayID, spaceID: spaceID)
        guard sets.count > 1 else {
            return false
        }

        let activeSetID = windowSetManager.activeSet(for: displayID, spaceID: spaceID)?.id
        let activeIndex = sets.firstIndex { $0.id == activeSetID } ?? 0
        let nextIndex: Int
        if reverse {
            nextIndex = (activeIndex - 1 + sets.count) % sets.count
        } else {
            nextIndex = (activeIndex + 1) % sets.count
        }

        activateWindowSet(sets[nextIndex].id, on: displayID)
        return true
    }

    private func toggleFloatingForActiveDrag(at point: CGPoint) {
        let windows = fetchVisibleWindows()
        guard let targetWindow = floatingToggleTargetWindow(at: point, windows: windows) else {
            return
        }

        let floatingContext = liveFloatingContext()
        switch floatingDisposition(of: targetWindow, context: floatingContext) {
        case .explicitFloating:
            explicitFloatingWindowIDs.remove(targetWindow.windowID)
            Diagnostics.log("Floating toggle windowID=\(targetWindow.windowID) -> tiled", level: .info)
            if continueDragAfterSinking(window: targetWindow, point: point, windows: windows) {
                return
            }
            resetInteractionState()
            requestFullReflow(reason: "floating-toggle")
        case .automaticFloating:
            Diagnostics.log(
                "Floating toggle ignored for automatic floating windowID=\(targetWindow.windowID)",
                level: .debug
            )
        case .tiled:
            explicitFloatingWindowIDs.insert(targetWindow.windowID)
            Diagnostics.log("Floating toggle windowID=\(targetWindow.windowID) -> floating", level: .info)
            resetInteractionState()
            requestFullReflow(reason: "floating-toggle")
        }
    }

    private func floatingToggleTargetWindow(at point: CGPoint, windows: [WindowRef]) -> WindowRef? {
        if let draggedWindowID = dragTracker.draggedWindowID,
           let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) {
            return draggedWindow
        }

        if let resizingWindowID = dragTracker.resizingWindowID,
           let resizingWindow = windows.first(where: { $0.windowID == resizingWindowID }) {
            return resizingWindow
        }

        for pendingWindowID in dragTracker.pendingWindowIDs {
            if let pendingWindow = windows.first(where: { $0.windowID == pendingWindowID }) {
                return pendingWindow
            }
        }

        return windowsAtInteractionPoint(point, windows: windows).first
    }

    private func continueDragAfterSinking(window: WindowRef, point: CGPoint, windows: [WindowRef]) -> Bool {
        let isInteractionInFlight =
            dragTracker.draggedWindowID == window.windowID ||
            dragTracker.resizingWindowID == window.windowID ||
            dragTracker.pendingWindowIDs.contains(window.windowID)

        guard isInteractionInFlight else {
            return false
        }

        cancelDeferredPendingDragProbe()
        pendingDragCheckpoint = nil
        resizePreviewProjection = nil
        dragTracker.beginDrag(windowID: window.windowID, point: point, originalFrame: window.frame)
        activateDragSession(draggedWindowID: window.windowID, point: point, windows: windows)
        return activePlan != nil
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
            beginFloatingDragSession(window: latestWindow, windows: windows)
            return
        }

        activateDragSession(draggedWindowID: draggedWindowID, point: point, windows: windows)
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
            resetInteractionState()
            return
        }

        let floatingContext = liveFloatingContext()
        if isFloatingWindow(resizingWindow, context: floatingContext) {
            resetInteractionState()
            return
        }

        guard let displayID = DisplayService.displayID(containing: point) else {
            resetInteractionState()
            return
        }

        let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { f, _ in f })
        let spaceID = currentSpaceID(for: displayID)
        let orderedIDs = tiledOrderedWindowIDs(
            on: displayID,
            spaceID: spaceID,
            windowsByID: windowsByID,
            floatingContext: floatingContext
        )
        guard !orderedIDs.isEmpty else {
            resetInteractionState()
            return
        }

        let resizePlanner = activeLayoutPlanner(for: displayID)
        resizePlanner.syncRatiosFromObservedWindows(
            orderedWindowIDs: orderedIDs,
            windowsByID: windowsByID,
            resizingWindowID: resizingWindowID,
            originalResizingFrame: dragTracker.resizeState?.originalFrame,
            displayID: displayID,
            spaceID: spaceID
        )

        guard let plan = resizePlanner.buildPlan(
            orderedWindowIDs: orderedIDs,
            windowsByID: windowsByID,
            displayID: displayID,
            spaceID: spaceID
        ) else {
            resetInteractionState()
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
        let windows = fetchVisibleWindows()
        guard let resizedWindow = windows.first(where: { $0.windowID == resizeState.windowID }) else {
            return
        }
        let floatingContext = liveFloatingContext()
        guard !isFloatingWindow(resizedWindow, context: floatingContext) else {
            return
        }

        let displayID = resizedWindow.displayID
        let spaceID = currentSpaceID(for: displayID)
        let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { f, _ in f })
        let orderedIDs = tiledOrderedWindowIDs(
            on: displayID,
            spaceID: spaceID,
            windowsByID: windowsByID,
            floatingContext: floatingContext
        )

        let resizePlanner = activeLayoutPlanner(for: displayID)
        resizePlanner.syncRatiosFromObservedWindows(
            orderedWindowIDs: orderedIDs,
            windowsByID: windowsByID,
            resizingWindowID: resizeState.windowID,
            originalResizingFrame: resizeState.originalFrame,
            displayID: displayID,
            spaceID: spaceID
        )

        Diagnostics.log(
            "Resize end windowID=\(resizeState.windowID) app=\(resizedWindow.appName) point=\(point) -> apply once",
            level: .info
        )
        requestFullReflow(reason: "resize-end")
    }

    private func tiledOrderedWindowIDs(
        on displayID: CGDirectDisplayID,
        spaceID: Int,
        windowsByID: [CGWindowID: WindowRef],
        floatingContext: FloatingEvaluationContext,
        excluding excludedWindowIDs: Set<CGWindowID> = [],
        appending appendedWindowID: CGWindowID? = nil
    ) -> [CGWindowID] {
        var orderedIDs = windowSetManager.orderedWindowIDs(on: displayID, spaceID: spaceID)
            .filter { id in
                guard let window = windowsByID[id] else { return false }
                guard !excludedWindowIDs.contains(id) else { return false }
                return !isFloatingWindow(window, context: floatingContext)
            }
        if let appendedWindowID,
           !excludedWindowIDs.contains(appendedWindowID),
           windowsByID[appendedWindowID] != nil,
           !orderedIDs.contains(appendedWindowID) {
            orderedIDs.append(appendedWindowID)
        }
        return orderedIDs
    }

    private func buildDisplayPlan(
        on displayID: CGDirectDisplayID,
        spaceID: Int,
        windowsByID: [CGWindowID: WindowRef],
        floatingContext: FloatingEvaluationContext,
        excluding excludedWindowIDs: Set<CGWindowID> = [],
        appending appendedWindowID: CGWindowID? = nil
    ) -> DisplayLayoutPlan? {
        let orderedIDs = tiledOrderedWindowIDs(
            on: displayID,
            spaceID: spaceID,
            windowsByID: windowsByID,
            floatingContext: floatingContext,
            excluding: excludedWindowIDs,
            appending: appendedWindowID
        )
        guard !orderedIDs.isEmpty else { return nil }
        return activeLayoutPlanner(for: displayID).buildPlan(
            orderedWindowIDs: orderedIDs,
            windowsByID: windowsByID,
            displayID: displayID,
            spaceID: spaceID
        )
    }

    @discardableResult
    private func applyDisplayPlan(_ plan: DisplayLayoutPlan, reason: String) -> Bool {
        let targets = targetFramesNeedingApply(
            targetFrames: plan.targetFrames,
            windowsByID: plan.windowsByID
        )
        guard !targets.isEmpty else { return false }

        let failures = geometryApplier.applySync(
            reason: reason,
            targetFrames: targets,
            windowsByID: plan.windowsByID
        )
        logApplyResult(failures)
        return true
    }

    /// ドラッグセッション開始: フレーム取得なし、O(N) リスト検索のみ
    private func activateDragSession(draggedWindowID: CGWindowID, point: CGPoint, windows: [WindowRef]) {
        let displayID = DisplayService.displayID(containing: point)
            ?? windows.first(where: { $0.windowID == draggedWindowID })?.displayID
        guard let displayID else { return }
        let spaceID = currentSpaceID(for: displayID)

        let floatingContext = liveFloatingContext()
        let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { f, _ in f })
        let orderedIDs = tiledOrderedWindowIDs(
            on: displayID,
            spaceID: spaceID,
            windowsByID: windowsByID,
            floatingContext: floatingContext
        )

        guard orderedIDs.contains(draggedWindowID) else {
            Diagnostics.log("Drag windowID=\(draggedWindowID) not in active set; skipping overlay", level: .debug)
            return
        }

        DisplayService.additionalTopInsetByDisplay[displayID] = TabBarWindowController.reservedTopInset
        tabBar.setDragging(true)
        if let remainingPlan = buildDisplayPlan(
            on: displayID,
            spaceID: spaceID,
            windowsByID: windowsByID,
            floatingContext: floatingContext,
            excluding: [draggedWindowID]
        ) {
            applyDisplayPlan(
                remainingPlan,
                reason: "drag-begin/display=\(displayID)"
            )
        }

        let planner = activeLayoutPlanner(for: displayID)
        let slots = planner.buildSlots(count: orderedIDs.count, displayID: displayID, spaceID: spaceID)
        guard !slots.isEmpty else { return }

        let plan = DisplayLayoutPlan(
            displayID: displayID,
            spaceID: spaceID,
            slots: slots,
            orderedWindowIDs: orderedIDs,
            windowsByID: windowsByID
        )

        let hoverIndex = planner.slotIndex(at: point, in: plan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            Diagnostics.log("Failed to update drag state during activation", level: .warn)
            resetInteractionState()
            return
        }

        cachedWindows = windows
        activePlan = plan
        lastLoggedHoverIndex = hoverIndex

        let hoverText = hoverIndex.map(String.init) ?? "nil"
        let draggedAppName = windowsByID[draggedWindowID]?.appName ?? "?"
        Diagnostics.log(
            "Drag begin windowID=\(draggedWindowID) app=\(draggedAppName) display=\(plan.displayID) slots=\(plan.slots.count) hover=\(hoverText)",
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
            // ディスプレイ変更: 新ディスプレイのセットで plan を再構築
            let updateDisplayID = currentDisplayID ?? draggedWindow.displayID
            let spaceID = currentSpaceID(for: updateDisplayID)
            let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { f, _ in f })
            guard let newPlan = buildDisplayPlan(
                on: updateDisplayID,
                spaceID: spaceID,
                windowsByID: windowsByID,
                floatingContext: floatingContext,
                appending: draggedWindowID
            ) else {
                resetInteractionState()
                return
            }
            previewPlan = newPlan
        }

        let activeDragPlanner = activeLayoutPlanner(for: previewPlan.displayID)
        let hoverIndex = activeDragPlanner.slotIndex(at: point, in: previewPlan)
        guard let dragState = dragTracker.updateDrag(point: point, hoverSlotIndex: hoverIndex) else {
            resetInteractionState()
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

    private func beginFloatingDragSession(window: WindowRef, windows: [WindowRef]) {
        cachedWindows = windows
        clearOverlayState()
        refreshTabBars(using: windows)
        Diagnostics.log("Dragging floating windowID=\(window.windowID) (tiler preview disabled)", level: .debug)
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

            let requiresStableSpaceSnapshot: Bool = {
                switch request {
                case let .full(full):
                    return full.reason == spaceChangeReason
                case .drop:
                    return false
                }
            }()

            let isStable = requiresStableSpaceSnapshot ? await isReflowStable() : true

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

            let windows = fetchVisibleWindows()
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
        Diagnostics.log("Reflow job started (\(reason))", level: .debug)

        guard let discoveredWindows = discovery.fetchVisibleWindowsReflowSafe() else {
            Diagnostics.log("Reflow (\(reason)) canceled: unresolved window-space mapping", level: .warn)
            return false
        }
        let windows = prepareWindowsForInteraction(discoveredWindows)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allIDs = self.discovery.fetchAllWindowIDs()
            self.pruneFloatingState(to: allIDs)
        }

        syncWindowSets(with: windows)

        let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { f, _ in f })
        let floatingState = captureFloatingStateSnapshot()
        let floatingContext = makeFloatingContext(from: floatingState)

        var plans: [DisplayLayoutPlan] = []
        for displayID in DisplayService.activeDisplayIDs() {
            let spaceID = currentSpaceID(for: displayID)
            if let plan = buildDisplayPlan(
                on: displayID,
                spaceID: spaceID,
                windowsByID: windowsByID,
                floatingContext: floatingContext
            ) {
                plans.append(plan)
            }
        }

        guard !plans.isEmpty else {
            if let displayID = setSwitchDisplayID(for: reason) {
                raiseActiveSetWindows(on: displayID, from: windows)
            }
            Diagnostics.log(
                "Reflow (\(reason)) skipped: no tile candidates (visible=\(windows.count))",
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

        if let displayID = setSwitchDisplayID(for: reason) {
            raiseActiveSetWindows(on: displayID, from: windows)
        }
        return totalTargets > 0
    }

    private func performDropReflow(
        point: CGPoint,
        draggedWindowID: CGWindowID,
        hoverSlotIndex: Int?
    ) -> Bool {
        let windows = fetchVisibleWindows()
        let draggedWindow = windows.first { $0.windowID == draggedWindowID }
        let dropDisplayID = DisplayService.displayID(containing: point) ?? draggedWindow?.displayID
        guard let dropDisplayID else {
            return performFullReflow(reason: "drop-fallback:no-display")
        }
        let dropSpaceID = currentSpaceID(for: dropDisplayID)

        // cross-display drop: 旧ディスプレイのセットから削除し、新ディスプレイの active set に追加
        if let draggedWindow, draggedWindow.displayID != dropDisplayID {
            windowSetManager.removeWindowFromAllSets(draggedWindowID)
            windowSetManager.registerNewWindows([draggedWindowID], on: dropDisplayID, spaceID: dropSpaceID)
        }
        if let slot = hoverSlotIndex {
            windowSetManager.moveWindowToSlot(draggedWindowID, slot: slot, on: dropDisplayID, spaceID: dropSpaceID)
        }

        return performFullReflow(reason: "drop")
    }

    /// ウィンドウセットをライブウィンドウと同期（prune + 新規登録 + タブバー更新）
    private func syncWindowSets(with windows: [WindowRef]) {
        let byDisplaySpace = Dictionary(grouping: windows) { "\($0.displayID):\($0.spaceID)" }
        for group in byDisplaySpace.values {
            guard let first = group.first else { continue }
            let liveIDs = Set(group.map(\.windowID))
            windowSetManager.pruneWindows(to: liveIDs, on: first.displayID, spaceID: first.spaceID)
            windowSetManager.registerNewWindows(Array(liveIDs), on: first.displayID, spaceID: first.spaceID)
        }
        DispatchQueue.main.async { [weak self, windows] in self?.refreshTabBars(using: windows) }
    }

    private func fetchVisibleWindows() -> [WindowRef] {
        let windows = prepareWindowsForInteraction(discovery.fetchVisibleWindows())
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

    private func prepareWindowsForInteraction(_ windows: [WindowRef]) -> [WindowRef] {
        let ruleSnapshot = ruleStore.snapshot()
        return windows.map { window in
            let semantics = semanticsClassifier.semantics(for: window)
            let isAutomaticallyFloating =
                !window.isTilable ||
                ruleSnapshot.isBundleExcluded(window.bundleID) ||
                ruleSnapshot.isAppForcedFloating(window.appName) ||
                ruleSnapshot.isTypeForcedFloating(semantics.descriptor) ||
                semantics.isSpecialFloating
            return window.with(isTilable: !isAutomaticallyFloating)
        }
    }

    private func captureFloatingStateSnapshot() -> FloatingStateSnapshot {
        FloatingStateSnapshot(
            explicitFloatingWindowIDs: explicitFloatingWindowIDs
        )
    }

    private func makeFloatingContext(from snapshot: FloatingStateSnapshot) -> FloatingEvaluationContext {
        FloatingEvaluationContext(
            explicitFloatingWindowIDs: snapshot.explicitFloatingWindowIDs
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
            explicitFloatingWindowIDs: explicitFloatingWindowIDs
        )
    }

    private func isFloatingWindow(_ window: WindowRef, context: FloatingEvaluationContext) -> Bool {
        context.explicitFloatingWindowIDs.contains(window.windowID) || !window.isTilable
    }

    private func floatingDisposition(of window: WindowRef, context: FloatingEvaluationContext) -> FloatingDisposition {
        if context.explicitFloatingWindowIDs.contains(window.windowID) {
            return .explicitFloating
        }
        if !window.isTilable {
            return .automaticFloating
        }
        return .tiled
    }

    private func pruneFloatingState(using windows: [WindowRef]) {
        // floating state の prune は全 space のウィンドウを基準にする。
        let allIDs = discovery.fetchAllWindowIDs()
        pruneFloatingState(to: allIDs)
        let visibleIDs = Set(windows.map(\.windowID))
        semanticsClassifier.prune(to: visibleIDs)
    }

    private func pruneFloatingState(to liveIDs: Set<CGWindowID>) {
        explicitFloatingWindowIDs.formIntersection(liveIDs)
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
            self.refreshTabBars()
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
        pendingDragCheckpoint = nil
        resizePreviewProjection = nil
        tabBar.setDragging(false)
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

    // MARK: - Set / Tab Bar helpers

    private func activeLayoutPlanner(for displayID: CGDirectDisplayID) -> LayoutPlanner {
        let spaceID = currentSpaceID(for: displayID)
        guard let setID = windowSetManager.activeSet(for: displayID, spaceID: spaceID)?.id else {
            return defaultLayoutPlanner
        }
        if let planner = layoutPlannerBySetID[setID] { return planner }
        let planner = LayoutPlanner()
        layoutPlannerBySetID[setID] = planner
        return planner
    }

    private func currentSpaceID(for displayID: CGDirectDisplayID) -> Int {
        displaySpaceStateLock.lock()
        defer { displaySpaceStateLock.unlock() }
        return lastKnownSpaceByDisplayID[displayID] ?? 0
    }

    private func refreshTabBars(using windows: [WindowRef]? = nil) {
        let sourceWindows = windows ?? fetchVisibleWindows()
        let titlesByID = Dictionary(
            sourceWindows.map { ($0.windowID, $0.appName) },
            uniquingKeysWith: { first, _ in first }
        )
        for displayID in DisplayService.activeDisplayIDs() {
            let spaceID = currentSpaceID(for: displayID)
            let sets = windowSetManager.sets(for: displayID, spaceID: spaceID)
            DisplayService.additionalTopInsetByDisplay[displayID] =
                shouldReserveTabBarSpace(forSetCount: sets.count) ? TabBarWindowController.reservedTopInset : 0
            tabBar.updateTabs(
                sets: sets,
                activeSetID: windowSetManager.activeSet(for: displayID, spaceID: spaceID)?.id,
                windowTitles: titlesByID,
                for: displayID
            )
        }
    }

    private func shouldReserveTabBarSpace(forSetCount setCount: Int) -> Bool {
        setCount > 1 || dragTracker.isDragging
    }

    private func activateWindowSet(_ id: WindowSetID, on displayID: CGDirectDisplayID) {
        let spaceID = currentSpaceID(for: displayID)
        windowSetManager.activateSet(id: id, for: displayID, spaceID: spaceID)
        let allWindows = fetchVisibleWindows()
        refreshTabBars(using: allWindows)
        requestFullReflow(reason: setSwitchReason(for: displayID))
    }

    private func setSwitchReason(for displayID: CGDirectDisplayID) -> String {
        "\(setSwitchReasonPrefix)\(displayID)"
    }

    private func setSwitchDisplayID(for reason: String) -> CGDirectDisplayID? {
        guard reason.hasPrefix(setSwitchReasonPrefix) else {
            return nil
        }
        let rawValue = reason.dropFirst(setSwitchReasonPrefix.count)
        guard let parsed = UInt32(rawValue) else {
            return nil
        }
        return CGDirectDisplayID(parsed)
    }

    private func raiseActiveSetWindows(on displayID: CGDirectDisplayID, from allWindows: [WindowRef]) {
        let spaceID = currentSpaceID(for: displayID)
        let activeWindowIDs = windowSetManager.activeSet(for: displayID, spaceID: spaceID)?.orderedWindowIDs ?? []
        raiseGroupWindows(activeWindowIDs, from: allWindows)
    }

    private func raiseGroupWindows(_ windowIDs: [CGWindowID], from allWindows: [WindowRef]) {
        let windowsByID = Dictionary(uniqueKeysWithValues: allWindows.map { ($0.windowID, $0) })
        let floatingContext = liveFloatingContext()
        let orderedTargets = windowIDs.compactMap { windowsByID[$0] }
        let tiledTargets = orderedTargets.filter { !isFloatingWindow($0, context: floatingContext) }
        let floatingTargets = orderedTargets.filter { isFloatingWindow($0, context: floatingContext) }
        let targets = tiledTargets + floatingTargets

        guard !targets.isEmpty else {
            Diagnostics.log("Raise skipped: no matching windows in active set", level: .debug)
            return
        }

        let orderedDescription = orderedTargets.map { window in
            "id=\(window.windowID) app=\(window.appName) tilable=\(window.isTilable)"
        }.joined(separator: " | ")
        let raiseDescription = targets.map { window in
            let kind = isFloatingWindow(window, context: floatingContext) ? "floating" : "tiled"
            return "id=\(window.windowID) app=\(window.appName) kind=\(kind)"
        }.joined(separator: " | ")
        Diagnostics.log("Raise active set ordered=[\(orderedDescription)]", level: .debug)
        Diagnostics.log("Raise execution order=[\(raiseDescription)]", level: .debug)

        // AXRaise で各ウィンドウを前面順に並べる
        for (index, window) in targets.enumerated() {
            if let resolved = axWindowResolver.window(pid: window.pid, windowID: window.windowID) {
                let isFloating = isFloatingWindow(window, context: floatingContext)
                _ = windowFocusController.focus(
                    windowID: window.windowID,
                    pid: window.pid,
                    axElement: resolved.element,
                    isFloating: isFloating
                )
            } else {
                Diagnostics.log(
                    "AXRaise skipped unresolved windowID=\(window.windowID) app=\(window.appName) pid=\(window.pid)",
                    level: .warn
                )
            }
            if index < targets.count - 1 {
                Thread.sleep(forTimeInterval: windowRaiseDelay)
            }
        }
    }
}

// MARK: - TabBarWindowControllerDelegate

extension TilerCoordinator: TabBarWindowControllerDelegate {
    func tabBar(_ controller: TabBarWindowController, didSelectSetID id: WindowSetID, on displayID: CGDirectDisplayID) {
        activateWindowSet(id, on: displayID)
    }

    func tabBar(_ controller: TabBarWindowController, didRequestNewSetOn displayID: CGDirectDisplayID) {
        let spaceID = currentSpaceID(for: displayID)
        windowSetManager.createSet(for: displayID, spaceID: spaceID)
        refreshTabBars()
    }

    func tabBar(_ controller: TabBarWindowController, didDropWindowID windowID: CGWindowID, ontoSetID setID: WindowSetID, on displayID: CGDirectDisplayID) {
        let spaceID = currentSpaceID(for: displayID)
        windowSetManager.moveWindowToSet(windowID, toSetID: setID, on: displayID, spaceID: spaceID)
        refreshTabBars()
        requestFullReflow(reason: "set-drop")
    }
}
