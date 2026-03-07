import CoreGraphics
import Foundation

final class LayoutPlanner {
    private struct LayoutScopeKey: Hashable {
        let displayID: CGDirectDisplayID
        let spaceID: Int
    }

    private let displayInset: CGFloat
    private let slotInset: CGFloat
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
        masterRatio: CGFloat = 0.5
    ) {
        self.displayInset = displayInset
        self.slotInset = slotInset
        self.defaultMasterRatio = min(max(masterRatio, 0.2), 0.8)
        minMasterRatio = 0.2
        maxMasterRatio = 0.8
        minPaneExtent = 180
        minStackSlotExtent = 110
    }

    // MARK: - Public API

    /// orderedWindowIDs → DisplayLayoutPlan（index=スロット、座標マッチングなし）
    func buildPlan(
        orderedWindowIDs: [CGWindowID],
        windowsByID: [CGWindowID: WindowRef],
        displayID: CGDirectDisplayID,
        spaceID: Int
    ) -> DisplayLayoutPlan? {
        guard !orderedWindowIDs.isEmpty else { return nil }
        let scope = LayoutScopeKey(displayID: displayID, spaceID: spaceID)
        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        let slots = makeSlots(for: orderedWindowIDs.count, in: bounds, scope: scope)
        guard !slots.isEmpty else { return nil }
        return DisplayLayoutPlan(
            displayID: displayID,
            spaceID: spaceID,
            slots: slots,
            orderedWindowIDs: orderedWindowIDs,
            windowsByID: windowsByID
        )
    }

    /// ドラッグプレビュー用: スロット矩形のみ返す（window 情報不要）
    func buildSlots(count: Int, displayID: CGDirectDisplayID, spaceID: Int) -> [Slot] {
        guard count > 0 else { return [] }
        let scope = LayoutScopeKey(displayID: displayID, spaceID: spaceID)
        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        return makeSlots(for: count, in: bounds, scope: scope)
    }

    /// drag hover 判定
    func slotIndex(at point: CGPoint, in plan: DisplayLayoutPlan) -> Int? {
        if let directHit = plan.slots.firstIndex(where: { $0.rect.contains(point) }) {
            return directHit
        }
        guard !plan.slots.isEmpty else { return nil }
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

    /// リサイズ ratio 同期: orderedWindowIDs[0]=master、[1...]=stack（sort不要）
    func syncRatiosFromObservedWindows(
        orderedWindowIDs: [CGWindowID],
        windowsByID: [CGWindowID: WindowRef],
        resizingWindowID: CGWindowID?,
        originalResizingFrame: CGRect?,
        displayID: CGDirectDisplayID,
        spaceID: Int
    ) {
        guard orderedWindowIDs.count >= 2 else { return }
        guard let masterWindow = windowsByID[orderedWindowIDs[0]] else { return }
        let scope = LayoutScopeKey(displayID: displayID, spaceID: spaceID)
        let bounds = DisplayService.visibleBounds(for: displayID).insetBy(dx: displayInset, dy: displayInset)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let stackIDs = Array(orderedWindowIDs.dropFirst())
        let stackWindows = stackIDs.compactMap { windowsByID[$0] }

        if let resizingWindowID {
            guard windowsByID[resizingWindowID] != nil else { return }

            if resizingWindowID == orderedWindowIDs[0] {
                // master のリサイズ
                let observedMasterEdge = masterWindow.frame.maxX + slotInset
                let observedMasterRatio = ((observedMasterEdge - bounds.minX) / bounds.width)
                    .clamped(to: minMasterRatio...maxMasterRatio)
                stateLock.lock()
                masterRatioByScope[scope] = observedMasterRatio
                stateLock.unlock()
                return
            }

            guard
                let originalResizingFrame,
                let resizingIndex = stackWindows.firstIndex(where: { $0.windowID == resizingWindowID })
            else { return }

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
            guard sum > 0 else { return }
            stateLock.lock()
            stackWeightsByScope[scope] = rowHeights.map { $0 / sum }
            stateLock.unlock()
            return
        }

        // Non-resize: 観測フレームから ratio を推定
        let observedMasterEdge = masterWindow.frame.maxX + slotInset
        let observedMasterRatio = ((observedMasterEdge - bounds.minX) / bounds.width)
            .clamped(to: minMasterRatio...maxMasterRatio)

        var nextStackWeights: [CGFloat]?
        if !stackWindows.isEmpty {
            let rawHeights = stackWindows.map { max($0.frame.height + (slotInset * 2), 1) }
            let observedSum = rawHeights.reduce(0, +)
            if observedSum > 0 {
                nextStackWeights = rawHeights.map { $0 / observedSum }
            }
        }

        stateLock.lock()
        masterRatioByScope[scope] = observedMasterRatio
        if let weights = nextStackWeights { stackWeightsByScope[scope] = weights }
        stateLock.unlock()
    }

    // MARK: - Private

    private func applyResizingBoundaryPreference(
        rowHeights: inout [CGFloat],
        stackWindows: [WindowRef],
        resizingIndex: Int,
        originalFrame: CGRect,
        paneMinY: CGFloat
    ) {
        guard resizingIndex >= 0, resizingIndex < stackWindows.count else { return }
        guard rowHeights.count == stackWindows.count, rowHeights.count >= 2 else { return }

        let current = stackWindows[resizingIndex].frame
        let movedTop = abs(current.minY - originalFrame.minY)
        let movedBottom = abs(current.maxY - originalFrame.maxY)

        let boundaryIndex: Int
        let desiredBoundaryY: CGFloat
        if movedBottom >= movedTop {
            guard resizingIndex < rowHeights.count - 1 else { return }
            boundaryIndex = resizingIndex
            desiredBoundaryY = current.maxY + slotInset
        } else {
            guard resizingIndex > 0 else { return }
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
        delta = delta.clamped(to: -maxShrinkUpper...maxGrowUpper)

        rowHeights[boundaryIndex] += delta
        rowHeights[boundaryIndex + 1] -= delta
    }

    private func makeSlots(
        for windowCount: Int,
        in bounds: CGRect,
        scope: LayoutScopeKey
    ) -> [Slot] {
        guard windowCount > 0 else { return [] }

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

    private func masterRatio(for scope: LayoutScopeKey) -> CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        let ratio = masterRatioByScope[scope] ?? defaultMasterRatio
        return ratio.clamped(to: minMasterRatio...maxMasterRatio)
    }

    private func normalizedStackWeights(for scope: LayoutScopeKey, stackCount: Int) -> [CGFloat] {
        guard stackCount > 0 else { return [] }
        stateLock.lock()
        defer { stateLock.unlock() }
        let existing = stackWeightsByScope[scope] ?? []
        return normalizeWeights(existing, count: stackCount)
    }

    private func normalizeWeights(_ input: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
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
        guard count > 0 else { return [] }
        guard count > 1 else { return [max(total, 0)] }

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
                allocated = desired.clamped(to: minimumExtent...maxAllowed)
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
}
