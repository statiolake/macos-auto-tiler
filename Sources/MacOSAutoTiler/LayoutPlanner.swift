import CoreGraphics
import Foundation

final class LayoutPlanner {
    private let displayInset: CGFloat
    private let slotInset: CGFloat
    private let frameTolerance: CGFloat
    private let masterRatio: CGFloat

    init(
        displayInset: CGFloat = 12,
        slotInset: CGFloat = 8,
        frameTolerance: CGFloat = 6,
        masterRatio: CGFloat = 0.5
    ) {
        self.displayInset = displayInset
        self.slotInset = slotInset
        self.frameTolerance = frameTolerance
        self.masterRatio = min(max(masterRatio, 0.2), 0.8)
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
        draggedWindowID: CGWindowID
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
            slotCount: displayWindows.count + 1
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
        slotCount: Int
    ) -> DisplayLayoutPlan? {
        guard slotCount > 0 else {
            return nil
        }

        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        let slots = makeSlots(for: slotCount, in: bounds)
        let assignment = assignWindowsToNearestSlots(windows: windows, slots: slots)

        var windowsByID: [CGWindowID: WindowRef] = [:]
        windowsByID.reserveCapacity(windows.count)
        for window in windows {
            windowsByID[window.windowID] = window
        }

        return DisplayLayoutPlan(
            displayID: displayID,
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

    private func makeSlots(for windowCount: Int, in bounds: CGRect) -> [Slot] {
        guard windowCount > 0 else {
            return []
        }

        if windowCount == 1 {
            return [Slot(rect: bounds.insetBy(dx: slotInset, dy: slotInset))]
        }

        let masterWidth = bounds.width * masterRatio
        let stackWidth = bounds.width - masterWidth
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
        let rowHeight = stackPane.height / CGFloat(stackCount)
        for row in 0..<stackCount {
            let rowRect = CGRect(
                x: stackPane.minX,
                y: stackPane.minY + CGFloat(row) * rowHeight,
                width: stackPane.width,
                height: rowHeight
            )
            slots.append(Slot(rect: rowRect.insetBy(dx: slotInset, dy: slotInset)))
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

    private func pointDistance(to rect: CGRect, from point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
