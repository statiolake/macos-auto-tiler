import CoreGraphics
import Foundation

final class LayoutPlanner {
    private let displayInset: CGFloat
    private let slotInset: CGFloat
    private let frameTolerance: CGFloat

    init(
        displayInset: CGFloat = 12,
        slotInset: CGFloat = 8,
        frameTolerance: CGFloat = 6
    ) {
        self.displayInset = displayInset
        self.slotInset = slotInset
        self.frameTolerance = frameTolerance
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
                let plan = buildPlan(for: displayID, windows: displayWindows)
            else {
                continue
            }
            plans.append(plan)
        }
        return plans
    }

    func buildDragPlan(at point: CGPoint, windows: [WindowRef]) -> DisplayLayoutPlan? {
        guard let displayID = DisplayService.displayID(containing: point) else {
            return nil
        }

        let displayWindows = windows.filter { window in
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return DisplayService.displayID(containing: midpoint) == displayID
        }

        return buildPlan(for: displayID, windows: displayWindows)
    }

    func slotIndex(at point: CGPoint, in plan: DisplayLayoutPlan) -> Int? {
        plan.slots.firstIndex { $0.rect.contains(point) }
    }

    func resolveDrop(
        plan: DisplayLayoutPlan,
        dragState: DragState,
        destinationIndex: Int,
        latestDraggedFrame: CGRect?
    ) -> DropResolution? {
        guard let sourceIndex = plan.windowToSlotIndex[dragState.draggedWindowID] else {
            return nil
        }

        var nextSlotToWindowID = plan.slotToWindowID
        var shouldApply = true

        if sourceIndex == destinationIndex {
            if let latestDraggedFrame {
                shouldApply = !GeometryUtils.isApproximatelyEqual(
                    latestDraggedFrame,
                    plan.slots[sourceIndex].rect,
                    tolerance: frameTolerance
                )
            }
        } else {
            let destinationWindowID = nextSlotToWindowID[destinationIndex]
            nextSlotToWindowID[destinationIndex] = dragState.draggedWindowID

            if let destinationWindowID, destinationWindowID != dragState.draggedWindowID {
                nextSlotToWindowID[sourceIndex] = destinationWindowID
            } else {
                nextSlotToWindowID.removeValue(forKey: sourceIndex)
            }
        }

        return DropResolution(
            sourceSlotIndex: sourceIndex,
            destinationSlotIndex: destinationIndex,
            shouldApply: shouldApply,
            targetFrames: targetFrames(for: plan.slots, slotToWindowID: nextSlotToWindowID)
        )
    }

    func ghostRect(for dragState: DragState, in plan: DisplayLayoutPlan) -> CGRect {
        if let hover = dragState.hoverSlotIndex, hover >= 0, hover < plan.slots.count {
            return plan.slots[hover].rect
        }

        let dx = dragState.currentPoint.x - dragState.startPoint.x
        let dy = dragState.currentPoint.y - dragState.startPoint.y
        return dragState.originalFrame.offsetBy(dx: dx, dy: dy)
    }

    private func buildPlan(for displayID: CGDirectDisplayID, windows: [WindowRef]) -> DisplayLayoutPlan? {
        guard !windows.isEmpty else {
            return nil
        }

        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        let slots = makeSlots(for: windows.count, in: bounds)
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

        switch windowCount {
        case 3:
            let splitX = bounds.midX
            let leftWidth = splitX - bounds.minX - slotInset * 2
            let rightWidth = bounds.maxX - splitX - slotInset * 2

            let leftSlot = CGRect(
                x: bounds.minX + slotInset,
                y: bounds.minY + slotInset,
                width: leftWidth,
                height: bounds.height - slotInset * 2
            )
            let rightSlot1 = CGRect(
                x: splitX + slotInset,
                y: bounds.minY + slotInset,
                width: rightWidth,
                height: (bounds.height - slotInset * 2) / 2
            )
            let rightSlot2 = CGRect(
                x: splitX + slotInset,
                y: bounds.minY + slotInset + rightSlot1.height + slotInset,
                width: rightWidth,
                height: (bounds.height - slotInset * 2) / 2
            )
            return [
                Slot(rect: leftSlot),
                Slot(rect: rightSlot1),
                Slot(rect: rightSlot2),
            ]

        default:
            let columns = max(1, Int(ceil(sqrt(Double(windowCount)))))
            let rows = Int(ceil(Double(windowCount) / Double(columns)))
            let cellWidth = bounds.width / CGFloat(columns)
            let cellHeight = bounds.height / CGFloat(rows)

            var slots: [Slot] = []
            slots.reserveCapacity(windowCount)
            for index in 0..<windowCount {
                let row = index / columns
                let column = index % columns
                let rect = CGRect(
                    x: bounds.minX + CGFloat(column) * cellWidth,
                    y: bounds.minY + CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ).insetBy(dx: slotInset, dy: slotInset)
                slots.append(Slot(rect: rect))
            }
            return slots
        }
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
}
