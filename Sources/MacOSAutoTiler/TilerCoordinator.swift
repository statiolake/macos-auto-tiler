import AppKit
import CoreGraphics

final class TilerCoordinator {
    private let axWindowResolver = AXWindowResolver.shared
    private let ruleStore = WindowRuleStore()
    private lazy var discovery = WindowDiscovery(ruleStore: ruleStore)
    private let layoutPlanner = LayoutPlanner()
    private let overlay = OverlayWindowController()
    private let eventTap = EventTapController()
    private lazy var geometryApplier = WindowGeometryApplier(
        actuator: AXWindowActuator(resolver: axWindowResolver)
    )
    private let dragTracker = DragInteractionTracker()
    private lazy var lifecycleMonitor = WindowLifecycleMonitor(discovery: discovery)
    private lazy var semanticsClassifier = WindowSemanticsClassifier(resolver: axWindowResolver)
    private let typeRegistry = WindowTypeRegistry()
    private let spaceProbeQueue = DispatchQueue(label: "com.statiolake.macosautotiler.spaceprobe", qos: .utility)

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

    private var userFloatingWindowIDs = Set<CGWindowID>()
    private var userTiledWindowIDs = Set<CGWindowID>()
    private var lastSpaceSwitchTime: Date = .distantPast
    private let reflowState = ReflowRequestState()
    private var reflowWorkerTask: Task<Void, Never>?

    private let stableSnapshotsRequired = 3
    private let spaceProbeInterval: TimeInterval = 0.12
    private let maxSpaceTransitionWait: TimeInterval = 1.5
    private let windowHitSlop: CGFloat = 24
    private let spaceSwitchCooldown: TimeInterval = 0.5
    private let interactionWaitNanoseconds: UInt64 = 120_000_000
    private let frameEpsilon: CGFloat = 1.0

    private struct FloatingStateSnapshot {
        let userFloatingWindowIDs: Set<CGWindowID>
        let userTiledWindowIDs: Set<CGWindowID>
        let ruleSnapshot: WindowRuleSnapshot
    }

    private struct QueuedFullReflow {
        let reason: String
    }

    private struct QueuedDropReflow {
        let point: CGPoint
        let draggedWindowID: CGWindowID
        let hoverSlotIndex: Int?
    }

    private enum QueuedReflowRequest {
        case drop(QueuedDropReflow)
        case full(QueuedFullReflow)
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

    private actor ReflowRequestState {
        private struct PriorityQueue {
            private var dropQueue: [QueuedDropReflow] = []
            private var dropHeadIndex = 0
            private var fullReflowRequested = false
            private var latestFullReflowReason = "manual"

            mutating func enqueue(_ request: QueuedReflowRequest) {
                switch request {
                case let .drop(drop):
                    dropQueue.append(drop)
                case let .full(full):
                    fullReflowRequested = true
                    latestFullReflowReason = full.reason
                }
            }

            mutating func dequeue() -> QueuedReflowRequest? {
                if let drop = dequeueDrop() {
                    return .drop(drop)
                }
                guard fullReflowRequested else {
                    return nil
                }
                fullReflowRequested = false
                return .full(QueuedFullReflow(reason: latestFullReflowReason))
            }

            private var hasDropRequests: Bool {
                dropHeadIndex < dropQueue.count
            }

            private mutating func dequeueDrop() -> QueuedDropReflow? {
                guard hasDropRequests else {
                    dropQueue.removeAll(keepingCapacity: true)
                    dropHeadIndex = 0
                    return nil
                }
                let drop = dropQueue[dropHeadIndex]
                dropHeadIndex += 1

                if dropHeadIndex >= 32, dropHeadIndex * 2 >= dropQueue.count {
                    dropQueue.removeFirst(dropHeadIndex)
                    dropHeadIndex = 0
                }
                return drop
            }
        }

        private var queue = PriorityQueue()
        private var waitingContinuation: CheckedContinuation<Void, Never>?

        func enqueue(_ request: QueuedReflowRequest) {
            queue.enqueue(request)
            waitingContinuation?.resume()
            waitingContinuation = nil
        }

        func nextRequest() async -> QueuedReflowRequest? {
            while true {
                if Task.isCancelled {
                    return nil
                }
                if let request = queue.dequeue() {
                    return request
                }
                await withCheckedContinuation { continuation in
                    waitingContinuation = continuation
                }
            }
        }

        func reset() {
            queue = PriorityQueue()
            waitingContinuation?.resume()
            waitingContinuation = nil
        }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.requestFullReflow(reason: "startup")
        }

        setupActiveSpaceObserver()
        startLifecycleMonitor()
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
            requestFullReflow(reason: "floating-toggle")
        }
    }

    private func maybeActivateDrag(at point: CGPoint) {
        let pendingWindowIDs = dragTracker.pendingWindowIDs
        guard !pendingWindowIDs.isEmpty else {
            return
        }

        guard var windows = cachedWindows else {
            return
        }

        // Update only pending windows' frames (skip space/app lookups)
        let updatedFrames = discovery.fetchWindowFrames(for: Set(pendingWindowIDs))
        for (windowID, newFrame) in updatedFrames {
            guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else {
                continue
            }
            let old = windows[index]
            windows[index] = WindowRef(
                windowID: old.windowID, pid: old.pid,
                displayID: DisplayService.displayID(for: newFrame) ?? old.displayID,
                frame: newFrame,
                title: old.title, appName: old.appName, bundleID: old.bundleID,
                spaceID: old.spaceID
            )
        }
        cachedWindows = windows

        let latestByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        if pendingWindowIDs.allSatisfy({ latestByID[$0] == nil }) {
            dragTracker.clearPendingDrag()
            return
        }

        let activatedDrag = dragTracker.maybeActivateDrag(
            currentPoint: point,
            latestWindowsByID: latestByID
        )
        if dragTracker.isResizing {
            updateActiveResizePreview(at: point)
            return
        }

        guard
            let activatedDrag,
            let latestWindow = latestByID[activatedDrag.draggedWindowID]
        else {
            return
        }

        if isFloatingWindow(latestWindow) {
            Diagnostics.log("Dragging floating windowID=\(latestWindow.windowID) (tiler preview disabled)", level: .debug)
            clearOverlayState()
            return
        }

        activateDragSession(draggedWindow: latestWindow, point: point, windows: windows)
    }

    private func updateActiveResizePreview(at point: CGPoint) {
        guard let resizingWindowID = dragTracker.resizingWindowID else {
            return
        }

        let windows: [WindowRef]
        if var cached = cachedWindows,
            let index = cached.firstIndex(where: { $0.windowID == resizingWindowID })
        {
            let updatedFrames = discovery.fetchWindowFrames(for: [resizingWindowID])
            if let newFrame = updatedFrames[resizingWindowID] {
                let old = cached[index]
                cached[index] = WindowRef(
                    windowID: old.windowID, pid: old.pid,
                    displayID: DisplayService.displayID(for: newFrame) ?? old.displayID,
                    frame: newFrame,
                    title: old.title, appName: old.appName, bundleID: old.bundleID,
                    spaceID: old.spaceID
                )
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

        if isFloatingWindow(resizingWindow) {
            clearOverlayState()
            return
        }

        let tiled = tiledWindows(from: windows)
        layoutPlanner.syncRatiosFromObservedWindows(
            tiled,
            resizingWindowID: resizingWindowID,
            originalResizingFrame: dragTracker.resizeState?.originalFrame
        )

        let plans = layoutPlanner.buildReflowPlans(from: tiled)
        guard
            let displayID = DisplayService.displayID(containing: point),
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
        guard !isFloatingWindow(resizedWindow) else {
            return
        }

        let tiled = tiledWindows(from: windows)
        layoutPlanner.syncRatiosFromObservedWindows(
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
        let tiled = tiledWindows(from: allWindows, including: [draggedWindow.windowID])

        cachedWindows = allWindows
        cachedTiledWindows = tiled

        guard
            let plan = layoutPlanner.buildDragPreviewPlan(
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

        guard let windows = cachedWindows else {
            resetInteractionState()
            return
        }
        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            resetInteractionState()
            return
        }

        if isFloatingWindow(draggedWindow) {
            clearOverlayState()
            return
        }

        let previousDisplayID = activePlan?.displayID
        let currentDisplayID = DisplayService.displayID(containing: point)

        let previewPlan: DisplayLayoutPlan
        if let existing = activePlan, currentDisplayID == existing.displayID {
            previewPlan = existing
        } else {
            let tiled = cachedTiledWindows ?? tiledWindows(from: windows, including: [draggedWindowID])
            guard
                let newPlan = layoutPlanner.buildDragPreviewPlan(
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

        let hoverIndex = layoutPlanner.slotIndex(at: point, in: previewPlan)
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

            await waitForInteractionIdle()
            await waitForReflowStabilization(trigger: reflowTriggerDescription(for: request))
            await waitForInteractionIdle()

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

    private func waitForInteractionIdle() async {
        while true {
            if Task.isCancelled {
                return
            }
            let isInteractionActive = await MainActor.run { [weak self] in
                guard let self else { return false }
                return self.dragTracker.isDragging || self.dragTracker.isResizing
            }
            if !isInteractionActive {
                return
            }
            try? await Task.sleep(nanoseconds: interactionWaitNanoseconds)
        }
    }

    private func waitForReflowStabilization(trigger: String) async {
        let stabilizer = WindowSnapshotStabilizer(
            stableSnapshotsRequired: stableSnapshotsRequired,
            probeInterval: spaceProbeInterval,
            timeout: maxSpaceTransitionWait,
            probeQueue: spaceProbeQueue,
            snapshotProvider: { [weak self] in
                guard let self else {
                    return .init(signature: 0, windowCount: 0)
                }
                let windows = self.discovery.fetchVisibleWindows()
                return .init(
                    signature: self.spaceSnapshotSignature(for: windows),
                    windowCount: windows.count
                )
            },
            probeHandler: { generation, stableCount, required, windowCount in
                Diagnostics.log(
                    "Reflow probe generation=\(generation) trigger=\(trigger) stable=\(stableCount)/\(required) windows=\(windowCount)",
                    level: .debug
                )
            }
        )

        let result = await stabilizer.waitForStabilize()
        Diagnostics.log(
            "Reflow stabilization settled generation=\(result.generation) trigger=\(trigger) reason=\(result.reason.rawValue)",
            level: .debug
        )
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
        let floatingState = captureFloatingStateSnapshot()
        Diagnostics.log("Reflow job started (\(reason))", level: .debug)
        let context = buildReflowContext(floatingState: floatingState)
        let windows = context.windows
        let tiled = context.tiledWindows
        let plans = layoutPlanner.buildReflowPlans(from: tiled)
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
        let floatingState = captureFloatingStateSnapshot()
        let context = buildReflowContext(
            floatingState: floatingState,
            including: [draggedWindowID]
        )
        let windows = context.windows
        let tiled = context.tiledWindows

        guard let draggedWindow = windows.first(where: { $0.windowID == draggedWindowID }) else {
            Diagnostics.log("Drop fallback: dragged window missing windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:missing-window")
        }

        guard
            let previewPlan = layoutPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: draggedWindowID,
                preferredSpaceID: draggedWindow.spaceID
            )
        else {
            Diagnostics.log("Drop fallback: failed to build preview plan windowID=\(draggedWindowID)", level: .warn)
            return performFullReflow(reason: "drop-fallback:preview-plan")
        }

        let destinationIndex = layoutPlanner.slotIndex(at: point, in: previewPlan) ?? hoverSlotIndex
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
            let drop = layoutPlanner.resolveDrop(
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
        including includedWindowIDs: Set<CGWindowID> = []
    ) -> ReflowContext {
        let windows = discovery.fetchVisibleWindows()
        let liveWindowIDs = Set(windows.map(\.windowID))
        DispatchQueue.main.async { [weak self] in
            self?.pruneFloatingState(to: liveWindowIDs)
        }

        let semantics = WindowSemanticsClassifier(resolver: axWindowResolver)
        let floatingContext = makeFloatingContext(
            from: floatingState,
            semanticsClassifier: semantics
        )
        let tiled = tiledWindows(
            from: windows,
            including: includedWindowIDs,
            floatingContext: floatingContext
        )
        return ReflowContext(windows: windows, tiledWindows: tiled)
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

    private func isFloatingWindow(_ window: WindowRef) -> Bool {
        isFloatingWindow(window, context: liveFloatingContext())
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
        let liveIDs = Set(windows.map(\.windowID))
        pruneFloatingState(to: liveIDs)
    }

    private func pruneFloatingState(to liveIDs: Set<CGWindowID>) {
        userFloatingWindowIDs.formIntersection(liveIDs)
        userTiledWindowIDs.formIntersection(liveIDs)
        semanticsClassifier.prune(to: liveIDs)
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
            hash ^= UInt64(windowID)
            hash = hash &* 1_099_511_628_211
            hash ^= UInt64(displayID)
            hash = hash &* 1_099_511_628_211
            hash ^= UInt64(bitPattern: Int64(spaceID))
            hash = hash &* 1_099_511_628_211
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
            return !framesApproximatelyEqual(window.frame, targetFrame)
        }
    }

    private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameEpsilon
            && abs(lhs.origin.y - rhs.origin.y) <= frameEpsilon
            && abs(lhs.size.width - rhs.size.width) <= frameEpsilon
            && abs(lhs.size.height - rhs.size.height) <= frameEpsilon
    }

    private func clearOverlayState() {
        overlay.hide()
        activePlan = nil
        lastLoggedHoverIndex = nil
    }

    private func resetInteractionState() {
        dragTracker.clearAll()
        clearOverlayState()
        cachedWindows = nil
        cachedTiledWindows = nil
    }

    private func logApplyResult(_ failures: [CGWindowID]) {
        if failures.isEmpty {
            Diagnostics.log("AX apply completed successfully", level: .info)
            return
        }
        Diagnostics.log("AX apply failures for window IDs: \(failures)", level: .warn)
    }

    private func handleScrollWheel(deltaY: Int64, at point: CGPoint) -> Bool {
        guard DisplayService.isPointInDockRegion(point) else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastSpaceSwitchTime) >= spaceSwitchCooldown else {
            return true
        }

        let goLeft = deltaY > 0
        lastSpaceSwitchTime = now

        Diagnostics.log(
            "Dock scroll -> switch Space \(goLeft ? "left" : "right") (deltaY=\(deltaY))",
            level: .info
        )
        simulateSpaceSwitch(goLeft: goLeft, at: point)
        return true
    }

    private func simulateSpaceSwitch(goLeft: Bool, at point: CGPoint) {
        guard let displayID = DisplayService.displayID(containing: point) else {
            Diagnostics.log("Space switch failed: no display at point", level: .warn)
            return
        }
        let ok = CGSSpaceService.shared.switchToAdjacentSpace(displayID: displayID, goLeft: goLeft)
        if !ok {
            Diagnostics.log("Space switch failed: CGS API returned false", level: .warn)
        }
    }

    private func windowsAtInteractionPoint(_ point: CGPoint, windows: [WindowRef]) -> [WindowRef] {
        return windows.filter {
            $0.frame.contains(point) ||
                $0.frame.insetBy(dx: -windowHitSlop, dy: -windowHitSlop).contains(point)
        }
    }
}
