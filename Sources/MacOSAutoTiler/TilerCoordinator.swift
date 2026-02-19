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
    private let reflowQueue = DispatchQueue(label: "com.dicen.macosautotiler.reflow", qos: .userInitiated)
    private let spaceProbeQueue = DispatchQueue(label: "com.dicen.macosautotiler.spaceprobe", qos: .utility)

    private lazy var rulesPanelController = WindowRulesPanelController(
        registry: typeRegistry,
        ruleStore: ruleStore
    ) { [weak self] in
        self?.reflowAllVisibleWindows(reason: "rules-updated")
    }

    private var activeSpaceObserver: NSObjectProtocol?
    private var activePlan: DisplayLayoutPlan?
    private var lastLoggedHoverIndex: Int?
    private var cachedWindows: [WindowRef]?
    private var cachedTiledWindows: [WindowRef]?
    private var needsDeferredLifecycleReflow = false
    private var isSpaceTransitioning = false
    private var spaceTransitionGeneration: UInt64 = 0
    private var spaceTransitionStartedAt: Date?
    private var lastSpaceSnapshotSignature: UInt64?
    private var stableSpaceSnapshotCount = 0
    private var spaceProbeWorkItem: DispatchWorkItem?

    private var userFloatingWindowIDs = Set<CGWindowID>()
    private var userTiledWindowIDs = Set<CGWindowID>()
    private var lastSpaceSwitchTime: Date = .distantPast

    private let stableSnapshotsRequired = 3
    private let spaceProbeInterval: TimeInterval = 0.12
    private let maxSpaceTransitionWait: TimeInterval = 1.5
    private let windowHitSlop: CGFloat = 24
    private let spaceSwitchCooldown: TimeInterval = 0.5

    private struct FloatingStateSnapshot {
        let userFloatingWindowIDs: Set<CGWindowID>
        let userTiledWindowIDs: Set<CGWindowID>
        let ruleSnapshot: WindowRuleSnapshot
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
        resetSpaceTransitionState()
        resetInteractionState()
        Diagnostics.log("Coordinator stopped", level: .info)
    }

    func showRulesPanel() {
        rulesPanelController.present()
    }

    func reflowAllVisibleWindows(reason: String = "manual") {
        enqueueFullReflow(reason: reason)
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
        defer {
            applyDeferredLifecycleReflowIfNeeded()
        }

        if let resizeState = dragTracker.finishResize() {
            finishResizeSession(resizeState: resizeState, point: point)
            resetInteractionState()
            return
        }

        guard let currentPreviewPlan = activePlan else {
            resetInteractionState()
            return
        }

        guard let dragState = dragTracker.finishDrag(point: point, fallbackHoverSlotIndex: nil) else {
            resetInteractionState()
            return
        }

        clearOverlayState()
        enqueueDropReflow(
            point: point,
            dragState: dragState,
            currentPreviewPlan: currentPreviewPlan
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
            reflowAllVisibleWindows(reason: "floating-toggle")
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
                windowID: old.windowID, pid: old.pid, frame: newFrame,
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
                    windowID: old.windowID, pid: old.pid, frame: newFrame,
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
            needsDeferredLifecycleReflow = false
            return
        }
        guard !isFloatingWindow(resizedWindow) else {
            needsDeferredLifecycleReflow = false
            return
        }

        let tiled = tiledWindows(from: windows)
        layoutPlanner.syncRatiosFromObservedWindows(
            tiled,
            resizingWindowID: resizeState.windowID,
            originalResizingFrame: resizeState.originalFrame
        )
        needsDeferredLifecycleReflow = false

        Diagnostics.log(
            "Resize end windowID=\(resizeState.windowID) app=\(resizedWindow.appName) point=\(point) -> apply once",
            level: .info
        )
        reflowAllVisibleWindows(reason: "resize-end")
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

    private func enqueueFullReflow(reason: String) {
        let floatingState = captureFloatingStateSnapshot()
        reflowQueue.async { [weak self] in
            self?.performFullReflow(reason: reason, floatingState: floatingState)
        }
    }

    private func performFullReflow(reason: String, floatingState: FloatingStateSnapshot) {
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

    private func enqueueDropReflow(point: CGPoint, dragState: DragState, currentPreviewPlan: DisplayLayoutPlan) {
        let floatingState = captureFloatingStateSnapshot()
        reflowQueue.async { [weak self] in
            self?.performDropReflow(
                point: point,
                dragState: dragState,
                currentPreviewPlan: currentPreviewPlan,
                floatingState: floatingState
            )
        }
    }

    private func performDropReflow(
        point: CGPoint,
        dragState: DragState,
        currentPreviewPlan: DisplayLayoutPlan,
        floatingState: FloatingStateSnapshot
    ) {
        let context = buildReflowContext(
            floatingState: floatingState,
            including: [dragState.draggedWindowID]
        )
        let windows = context.windows
        let draggedSpaceID = windows.first(where: { $0.windowID == dragState.draggedWindowID })?.spaceID
        let tiled = context.tiledWindows

        let previewPlan =
            layoutPlanner.buildDragPreviewPlan(
                at: point,
                windows: tiled,
                draggedWindowID: dragState.draggedWindowID,
                preferredSpaceID: draggedSpaceID
            ) ?? currentPreviewPlan

        let destinationIndex =
            layoutPlanner.slotIndex(at: point, in: previewPlan)
            ?? dragState.hoverSlotIndex
        guard let destinationIndex else {
            Diagnostics.log(
                "Drag end windowID=\(dragState.draggedWindowID) with no destination slot",
                level: .debug
            )
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
            return
        }

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

        let failures = geometryApplier.applySync(
            reason: "drop/window=\(dragState.draggedWindowID) display=\(drop.displayID) source=\(sourceSlotText) destination=\(drop.destinationSlotIndex)",
            targetFrames: drop.targetFrames,
            windowsByID: drop.windowsByID
        )
        logApplyResult(failures)
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
            self.beginSpaceTransition()
        }
    }

    private func beginSpaceTransition() {
        spaceTransitionGeneration &+= 1
        let generation = spaceTransitionGeneration
        isSpaceTransitioning = true
        spaceTransitionStartedAt = Date()
        lastSpaceSnapshotSignature = nil
        stableSpaceSnapshotCount = 0
        spaceProbeWorkItem?.cancel()
        spaceProbeWorkItem = nil

        Diagnostics.log(
            "Active space changed, entering transition mode generation=\(generation)",
            level: .info
        )

        probeSpaceSnapshot(generation: generation)
    }

    private func probeSpaceSnapshot(generation: UInt64) {
        spaceProbeQueue.async { [weak self] in
            guard let self else { return }
            let windows = self.discovery.fetchVisibleWindows()
            let signature = self.spaceSnapshotSignature(for: windows)
            let windowCount = windows.count
            DispatchQueue.main.async { [weak self] in
                self?.handleSpaceSnapshotProbe(
                    generation: generation,
                    signature: signature,
                    windowCount: windowCount
                )
            }
        }
    }

    private func handleSpaceSnapshotProbe(generation: UInt64, signature: UInt64, windowCount: Int) {
        guard isSpaceTransitioning, generation == spaceTransitionGeneration else {
            return
        }

        if signature == lastSpaceSnapshotSignature {
            stableSpaceSnapshotCount += 1
        } else {
            lastSpaceSnapshotSignature = signature
            stableSpaceSnapshotCount = 1
        }

        let elapsed = Date().timeIntervalSince(spaceTransitionStartedAt ?? Date())
        let reachedStability = stableSpaceSnapshotCount >= stableSnapshotsRequired
        let reachedTimeout = elapsed >= maxSpaceTransitionWait

        Diagnostics.log(
            "Space transition probe generation=\(generation) stable=\(stableSpaceSnapshotCount)/\(stableSnapshotsRequired) windows=\(windowCount)",
            level: .debug
        )

        if reachedStability || reachedTimeout {
            let settleReason = reachedStability ? "stable" : "timeout"
            isSpaceTransitioning = false
            spaceTransitionStartedAt = nil
            lastSpaceSnapshotSignature = nil
            stableSpaceSnapshotCount = 0
            spaceProbeWorkItem?.cancel()
            spaceProbeWorkItem = nil

            Diagnostics.log(
                "Space transition settled reason=\(settleReason) generation=\(generation)",
                level: .info
            )

            needsDeferredLifecycleReflow = false
            reflowAllVisibleWindows(reason: "space-settled:\(settleReason)")
            return
        }

        scheduleNextSpaceProbe(generation: generation)
    }

    private func scheduleNextSpaceProbe(generation: UInt64) {
        spaceProbeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.probeSpaceSnapshot(generation: generation)
        }
        spaceProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + spaceProbeInterval, execute: workItem)
    }

    private func resetSpaceTransitionState() {
        isSpaceTransitioning = false
        spaceTransitionStartedAt = nil
        lastSpaceSnapshotSignature = nil
        stableSpaceSnapshotCount = 0
        spaceTransitionGeneration &+= 1
        spaceProbeWorkItem?.cancel()
        spaceProbeWorkItem = nil
    }

    private func spaceSnapshotSignature(for windows: [WindowRef]) -> UInt64 {
        var pairs: [(CGWindowID, CGDirectDisplayID, Int)] = []
        pairs.reserveCapacity(windows.count)
        for window in windows {
            let displayID = DisplayService.displayID(for: window.frame) ?? 0
            pairs.append((window.windowID, displayID, window.spaceID))
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

            if isGeometryLifecycleReason(reason) {
                if dragTracker.isResizing {
                    needsDeferredLifecycleReflow = true
                    Diagnostics.log("Lifecycle reflow deferred during resize reason=\(reason)", level: .debug)
                } else {
                    Diagnostics.log(
                        "Lifecycle geometry event ignored to prevent feedback loop reason=\(reason)",
                        level: .debug
                    )
                }
                return
            }

            if isSpaceTransitioning {
                needsDeferredLifecycleReflow = true
                Diagnostics.log(
                    "Lifecycle reflow deferred during space transition reason=\(reason)",
                    level: .debug
                )
                return
            }

            if dragTracker.isDragging {
                needsDeferredLifecycleReflow = true
                Diagnostics.log("Lifecycle reflow deferred during drag reason=\(reason)", level: .debug)
                return
            }

            if dragTracker.isResizing {
                needsDeferredLifecycleReflow = true
                Diagnostics.log("Lifecycle reflow deferred during resize reason=\(reason)", level: .debug)
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
        guard !isSpaceTransitioning else {
            return
        }
        guard !dragTracker.isResizing else {
            return
        }
        needsDeferredLifecycleReflow = false
        reflowAllVisibleWindows(reason: "lifecycle:deferred")
    }

    private func isGeometryLifecycleReason(_ reason: String) -> Bool {
        reason.contains("AXWindowResized") || reason.hasPrefix("cg-geometry")
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
