import CoreGraphics
import Foundation

final class LayoutPlanner {
    private struct LayoutScopeKey: Hashable {
        let displayID: CGDirectDisplayID
        let spaceID: Int
    }

    private let displayInset: CGFloat
    private let slotInset: CGFloat
    private let frameTolerance: CGFloat
    private let defaultMasterRatio: CGFloat
    private let minMasterRatio: CGFloat
    private let maxMasterRatio: CGFloat
    private let minPaneExtent: CGFloat
    private let minStackSlotExtent: CGFloat

    private let stateLock = NSLock()
    private var masterRatioByScope: [LayoutScopeKey: CGFloat] = [:]
    private var stackWeightsByScope: [LayoutScopeKey: [CGFloat]] = [:]

    init(
        displayInset: CGFloat = 12,
        slotInset: CGFloat = 8,
        frameTolerance: CGFloat = 6,
        masterRatio: CGFloat = 0.5
    ) {
        self.displayInset = displayInset
        self.slotInset = slotInset
        self.frameTolerance = frameTolerance
        self.defaultMasterRatio = min(max(masterRatio, 0.2), 0.8)
        minMasterRatio = 0.2
        maxMasterRatio = 0.8
        minPaneExtent = 180
        minStackSlotExtent = 110
    }

    func buildReflowPlans(from windows: [WindowRef]) -> [DisplayLayoutPlan] {
        let grouped = groupByDisplay(windows)
        guard !grouped.isEmpty else {
            return []
        }

        var plans: [DisplayLayoutPlan] = []
        for displayID in grouped.keys.sorted() {
            guard
                let displayWindows = grouped[displayID],
                let plan = buildPlan(
                    for: displayID,
                    windows: displayWindows,
                    slotCount: displayWindows.count
                )
            else {
                continue
            }
            plans.append(plan)
        }
        return plans
    }

    func buildDragPreviewPlan(
        at point: CGPoint,
        windows: [WindowRef],
        draggedWindowID: CGWindowID,
        preferredSpaceID: Int? = nil
    ) -> DisplayLayoutPlan? {
        guard let displayID = DisplayService.displayID(containing: point) else {
            return nil
        }

        let nonDragged = windows.filter { $0.windowID != draggedWindowID }
        let grouped = groupByDisplay(nonDragged)
        let displayWindows = grouped[displayID] ?? []

        // Keep one empty slot for the dragged window on the hovered display.
        return buildPlan(
            for: displayID,
            windows: displayWindows,
            slotCount: displayWindows.count + 1,
            preferredSpaceID: preferredSpaceID
        )
    }

    func slotIndex(at point: CGPoint, in plan: DisplayLayoutPlan) -> Int? {
        if let directHit = plan.slots.firstIndex(where: { $0.rect.contains(point) }) {
            return directHit
        }
        guard !plan.slots.isEmpty else {
            return nil
        }

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, slot) in plan.slots.enumerated() {
            let distance = pointDistance(to: slot.rect, from: point)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    func syncRatiosFromObservedWindows(
        _ windows: [WindowRef],
        resizingWindowID: CGWindowID? = nil,
        originalResizingFrame: CGRect? = nil
    ) {
        let grouped = groupByDisplay(windows)
        guard !grouped.isEmpty else {
            return
        }

        var nextMasterRatios: [LayoutScopeKey: CGFloat] = [:]
        var nextStackWeights: [LayoutScopeKey: [CGFloat]] = [:]

        for (displayID, displayWindows) in grouped where displayWindows.count >= 2 {
            let spaceID = dominantSpaceID(in: displayWindows)
            let scope = LayoutScopeKey(displayID: displayID, spaceID: spaceID)
            let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
            guard bounds.width > 1, bounds.height > 1 else {
                continue
            }

            let orderedByPriority = displayWindows.sorted {
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.frame.minY < $1.frame.minY
            }
            guard let masterWindow = orderedByPriority.first else {
                continue
            }
            let stackWindows = orderedByPriority.dropFirst().sorted {
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                return $0.frame.minX < $1.frame.minX
            }

            if let resizingWindowID {
                guard let resizingWindow = displayWindows.first(where: { $0.windowID == resizingWindowID }) else {
                    // During an active resize, keep other displays untouched.
                    continue
                }

                if resizingWindow.windowID == masterWindow.windowID {
                    // Only master boundary should move.
                    let observedMasterEdge = masterWindow.frame.maxX + slotInset
                    let observedMasterRatio = clamp(
                        (observedMasterEdge - bounds.minX) / bounds.width,
                        minMasterRatio,
                        maxMasterRatio
                    )
                    nextMasterRatios[scope] = observedMasterRatio
                    continue
                }

                guard
                    let originalResizingFrame,
                    let resizingIndex = stackWindows.firstIndex(where: { $0.windowID == resizingWindowID })
                else {
                    continue
                }

                var rowHeights = normalizedStackWeights(for: scope, stackCount: stackWindows.count)
                    .map { $0 * bounds.height }
                applyResizingBoundaryPreference(
                    rowHeights: &rowHeights,
                    stackWindows: stackWindows,
                    resizingIndex: resizingIndex,
                    originalFrame: originalResizingFrame,
                    paneMinY: bounds.minY
                )
                let sum = rowHeights.reduce(0, +)
                guard sum > 0 else {
                    continue
                }
                nextStackWeights[scope] = rowHeights.map { $0 / sum }
                continue
            }

            // Non-resize sync path: infer from observed full geometry.
            let observedMasterEdge = masterWindow.frame.maxX + slotInset
            let observedMasterRatio = clamp(
                (observedMasterEdge - bounds.minX) / bounds.width,
                minMasterRatio,
                maxMasterRatio
            )
            nextMasterRatios[scope] = observedMasterRatio

            let rawHeights = stackWindows.map { max($0.frame.height + (slotInset * 2), 1) }
            guard !rawHeights.isEmpty else {
                continue
            }
            let observedSum = rawHeights.reduce(0, +)
            guard observedSum > 0 else {
                continue
            }
            nextStackWeights[scope] = rawHeights.map { $0 / observedSum }
        }

        stateLock.lock()
        for (scope, ratio) in nextMasterRatios {
            masterRatioByScope[scope] = ratio
        }
        for (scope, weights) in nextStackWeights {
            stackWeightsByScope[scope] = weights
        }
        stateLock.unlock()
    }

    private func applyResizingBoundaryPreference(
        rowHeights: inout [CGFloat],
        stackWindows: [WindowRef],
        resizingIndex: Int,
        originalFrame: CGRect,
        paneMinY: CGFloat
    ) {
        guard resizingIndex >= 0, resizingIndex < stackWindows.count else {
            return
        }
        guard rowHeights.count == stackWindows.count, rowHeights.count >= 2 else {
            return
        }

        let current = stackWindows[resizingIndex].frame
        let movedTop = abs(current.minY - originalFrame.minY)
        let movedBottom = abs(current.maxY - originalFrame.maxY)

        let boundaryIndex: Int
        let desiredBoundaryY: CGFloat
        if movedBottom >= movedTop {
            guard resizingIndex < rowHeights.count - 1 else {
                return
            }
            boundaryIndex = resizingIndex
            desiredBoundaryY = current.maxY + slotInset
        } else {
            guard resizingIndex > 0 else {
                return
            }
            boundaryIndex = resizingIndex - 1
            desiredBoundaryY = current.minY - slotInset
        }

        var currentPrefix = CGFloat.zero
        for index in 0...boundaryIndex {
            currentPrefix += rowHeights[index]
        }

        let desiredPrefix = desiredBoundaryY - paneMinY
        var delta = desiredPrefix - currentPrefix

        let maxShrinkUpper = rowHeights[boundaryIndex] - minStackSlotExtent
        let maxGrowUpper = rowHeights[boundaryIndex + 1] - minStackSlotExtent
        delta = clamp(delta, -maxShrinkUpper, maxGrowUpper)

        rowHeights[boundaryIndex] += delta
        rowHeights[boundaryIndex + 1] -= delta
    }

    func resolveDrop(
        previewPlan: DisplayLayoutPlan,
        dragState: DragState,
        destinationIndex: Int,
        allWindows: [WindowRef]
    ) -> DropResolution? {
        guard destinationIndex >= 0, destinationIndex < previewPlan.slots.count else {
            return nil
        }

        guard let draggedWindow = allWindows.first(where: { $0.windowID == dragState.draggedWindowID }) else {
            return nil
        }

        var windowsByID: [CGWindowID: WindowRef] = [:]
        windowsByID.reserveCapacity(allWindows.count)
        for window in allWindows {
            windowsByID[window.windowID] = window
        }

        let nonDragged = allWindows.filter { $0.windowID != dragState.draggedWindowID }
        var combinedTargets: [CGWindowID: CGRect] = [:]

        let otherDisplayPlans = buildReflowPlans(from: nonDragged)
            .filter { $0.displayID != previewPlan.displayID }
        for plan in otherDisplayPlans {
            combinedTargets.merge(plan.targetFrames, uniquingKeysWith: { _, new in new })
        }

        var nextSlotToWindowID = previewPlan.slotToWindowID
        let sourceSlotIndex = previewPlan.slots.indices.first { nextSlotToWindowID[$0] == nil }

        let displacedWindowID = nextSlotToWindowID[destinationIndex]
        nextSlotToWindowID[destinationIndex] = dragState.draggedWindowID

        if let displacedWindowID, displacedWindowID != dragState.draggedWindowID {
            if let sourceSlotIndex, sourceSlotIndex != destinationIndex {
                nextSlotToWindowID[sourceSlotIndex] = displacedWindowID
            } else if let fallbackEmpty = previewPlan.slots.indices.first(where: { nextSlotToWindowID[$0] == nil }) {
                nextSlotToWindowID[fallbackEmpty] = displacedWindowID
            }
        }

        let previewTargets = targetFrames(for: previewPlan.slots, slotToWindowID: nextSlotToWindowID)
        combinedTargets.merge(previewTargets, uniquingKeysWith: { _, new in new })

        let shouldApply = !GeometryUtils.isApproximatelyEqual(
            draggedWindow.frame,
            previewPlan.slots[destinationIndex].rect,
            tolerance: frameTolerance
        )

        return DropResolution(
            displayID: previewPlan.displayID,
            sourceSlotIndex: sourceSlotIndex,
            destinationSlotIndex: destinationIndex,
            shouldApply: shouldApply,
            targetFrames: combinedTargets,
            windowsByID: windowsByID
        )
    }

    private func buildPlan(
        for displayID: CGDirectDisplayID,
        windows: [WindowRef],
        slotCount: Int,
        preferredSpaceID: Int? = nil
    ) -> DisplayLayoutPlan? {
        guard slotCount > 0 else {
            return nil
        }

        let scope = layoutScope(for: displayID, windows: windows, preferredSpaceID: preferredSpaceID)
        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        let slots = makeSlots(for: slotCount, in: bounds, scope: scope)
        let assignment = assignWindowsToNearestSlots(windows: windows, slots: slots)

        var windowsByID: [CGWindowID: WindowRef] = [:]
        windowsByID.reserveCapacity(windows.count)
        for window in windows {
            windowsByID[window.windowID] = window
        }

        return DisplayLayoutPlan(
            displayID: displayID,
            spaceID: scope.spaceID,
            slots: slots,
            slotToWindowID: assignment.slotToWindowID,
            windowToSlotIndex: assignment.windowToSlotIndex,
            windowsByID: windowsByID
        )
    }

    private func groupByDisplay(_ windows: [WindowRef]) -> [CGDirectDisplayID: [WindowRef]] {
        guard !windows.isEmpty else {
            return [:]
        }

        var groupedByDisplay: [CGDirectDisplayID: [WindowRef]] = [:]
        for window in windows {
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let displayID = DisplayService.displayID(containing: midpoint) else {
                continue
            }
            groupedByDisplay[displayID, default: []].append(window)
        }
        return groupedByDisplay
    }

    private func layoutScope(
        for displayID: CGDirectDisplayID,
        windows: [WindowRef],
        preferredSpaceID: Int? = nil
    ) -> LayoutScopeKey {
        let preferredSpaceID = preferredSpaceID ?? dominantSpaceID(in: windows)
        return LayoutScopeKey(displayID: displayID, spaceID: preferredSpaceID)
    }

    private func dominantSpaceID(in windows: [WindowRef]) -> Int {
        guard !windows.isEmpty else {
            return 0
        }
        var counts: [Int: Int] = [:]
        for window in windows {
            counts[window.spaceID, default: 0] += 1
        }
        let dominant = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        })?.key ?? 0
        return dominant
    }

    private func makeSlots(
        for windowCount: Int,
        in bounds: CGRect,
        scope: LayoutScopeKey
    ) -> [Slot] {
        guard windowCount > 0 else {
            return []
        }

        if windowCount == 1 {
            return [Slot(rect: bounds.insetBy(dx: slotInset, dy: slotInset))]
        }

        let master = masterRatio(for: scope)
        let paneWidths = prioritizedExtents(
            total: bounds.width,
            weights: [master, 1 - master],
            minimumExtent: minPaneExtent
        )
        guard paneWidths.count == 2 else {
            return [Slot(rect: bounds.insetBy(dx: slotInset, dy: slotInset))]
        }

        let masterWidth = paneWidths[0]
        let stackWidth = paneWidths[1]
        let masterPane = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: masterWidth,
            height: bounds.height
        )
        let stackPane = CGRect(
            x: masterPane.maxX,
            y: bounds.minY,
            width: stackWidth,
            height: bounds.height
        )

        var slots: [Slot] = []
        slots.reserveCapacity(windowCount)
        slots.append(Slot(rect: masterPane.insetBy(dx: slotInset, dy: slotInset)))

        let stackCount = windowCount - 1
        let stackWeights = normalizedStackWeights(for: scope, stackCount: stackCount)
        let rowHeights = prioritizedExtents(
            total: stackPane.height,
            weights: stackWeights,
            minimumExtent: minStackSlotExtent
        )
        var rowY = stackPane.minY
        for row in 0..<stackCount {
            let rowHeight = rowHeights[row]
            let rowRect = CGRect(
                x: stackPane.minX,
                y: rowY,
                width: stackPane.width,
                height: rowHeight
            )
            slots.append(Slot(rect: rowRect.insetBy(dx: slotInset, dy: slotInset)))
            rowY += rowHeight
        }
        return slots
    }

    private func assignWindowsToNearestSlots(
        windows: [WindowRef],
        slots: [Slot]
    ) -> (slotToWindowID: [Int: CGWindowID], windowToSlotIndex: [CGWindowID: Int]) {
        guard !windows.isEmpty, !slots.isEmpty else {
            return ([:], [:])
        }

        struct Pair {
            let distance: CGFloat
            let slotIndex: Int
            let windowID: CGWindowID
        }

        var pairs: [Pair] = []
        pairs.reserveCapacity(windows.count * slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            for window in windows {
                pairs.append(
                    Pair(
                        distance: GeometryUtils.centerDistance(slot.rect, window.frame),
                        slotIndex: slotIndex,
                        windowID: window.windowID
                    )
                )
            }
        }

        pairs.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.slotIndex != $1.slotIndex { return $0.slotIndex < $1.slotIndex }
            return $0.windowID < $1.windowID
        }

        var usedSlots = Set<Int>()
        var usedWindows = Set<CGWindowID>()
        var slotToWindowID: [Int: CGWindowID] = [:]
        var windowToSlotIndex: [CGWindowID: Int] = [:]

        for pair in pairs where !usedSlots.contains(pair.slotIndex) && !usedWindows.contains(pair.windowID) {
            usedSlots.insert(pair.slotIndex)
            usedWindows.insert(pair.windowID)
            slotToWindowID[pair.slotIndex] = pair.windowID
            windowToSlotIndex[pair.windowID] = pair.slotIndex

            if usedWindows.count == windows.count || usedSlots.count == slots.count {
                break
            }
        }

        return (slotToWindowID, windowToSlotIndex)
    }

    private func targetFrames(for slots: [Slot], slotToWindowID: [Int: CGWindowID]) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        result.reserveCapacity(slotToWindowID.count)
        for (slotIndex, windowID) in slotToWindowID {
            guard slotIndex >= 0, slotIndex < slots.count else {
                continue
            }
            result[windowID] = slots[slotIndex].rect
        }
        return result
    }

    private func masterRatio(for scope: LayoutScopeKey) -> CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        let ratio = masterRatioByScope[scope] ?? defaultMasterRatio
        return clamp(ratio, minMasterRatio, maxMasterRatio)
    }

    private func normalizedStackWeights(for scope: LayoutScopeKey, stackCount: Int) -> [CGFloat] {
        guard stackCount > 0 else {
            return []
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        let existing = stackWeightsByScope[scope] ?? []
        let normalized = normalizeWeights(existing, count: stackCount)
        return normalized
    }

    private func normalizeWeights(_ input: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else {
            return []
        }

        var values = Array(input.prefix(count)).map { max($0, 0.0001) }
        if values.count < count {
            values.append(contentsOf: Array(repeating: 1, count: count - values.count))
        }

        let sum = values.reduce(0, +)
        guard sum > 0 else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        return values.map { $0 / sum }
    }

    // Lower slot indices have higher priority: when minimum extents conflict,
    // earlier slots keep their minimum before later slots.
    private func prioritizedExtents(
        total: CGFloat,
        weights: [CGFloat],
        minimumExtent: CGFloat
    ) -> [CGFloat] {
        let count = weights.count
        guard count > 0 else {
            return []
        }
        guard count > 1 else {
            return [max(total, 0)]
        }

        let normalized = normalizeWeights(weights, count: count)
        var result = Array(repeating: CGFloat.zero, count: count)
        var remainingTotal = max(total, 0)
        var remainingWeight = CGFloat(1)

        for index in 0..<(count - 1) {
            let ratio = remainingWeight > 0 ? normalized[index] / remainingWeight : 0
            let desired = remainingTotal * ratio
            let remainingSlots = count - index - 1
            let reserveForRest = minimumExtent * CGFloat(remainingSlots)

            let allocated: CGFloat
            if remainingTotal >= minimumExtent + reserveForRest {
                let maxAllowed = remainingTotal - reserveForRest
                allocated = clamp(desired, minimumExtent, maxAllowed)
            } else {
                allocated = min(remainingTotal, minimumExtent)
            }

            result[index] = max(allocated, 0)
            remainingTotal = max(0, remainingTotal - result[index])
            remainingWeight = max(0, remainingWeight - normalized[index])
        }

        result[count - 1] = max(remainingTotal, 0)
        return result
    }

    private func pointDistance(to rect: CGRect, from point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
