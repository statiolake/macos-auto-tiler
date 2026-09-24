import CoreGraphics

/// Master/stack layout of one space: slot 0 is the master pane, the remaining slots stack vertically on the right.
struct SpaceLayout {
    static let displayInset: CGFloat = 12
    static let slotInset: CGFloat = 8
    static let masterRatioRange: ClosedRange<CGFloat> = 0.2...0.8
    static let minPaneExtent: CGFloat = 180
    static let minStackSlotExtent: CGFloat = 110

    /// Index is the slot number.
    var windowIDs: [CGWindowID] = []
    var masterRatio: CGFloat = 0.5
    /// Relative heights of stack slots. Missing entries default to an equal share.
    var stackWeights: [CGFloat] = []

    func targetFrames(in visibleArea: CGRect) -> [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: zip(windowIDs, slotRects(count: windowIDs.count, in: visibleArea)))
    }

    func slotRects(count: Int, in visibleArea: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let area = visibleArea.insetBy(dx: Self.displayInset, dy: Self.displayInset)
        guard count > 1 else {
            return [area.insetBy(dx: Self.slotInset, dy: Self.slotInset)]
        }

        let paneWidths = Self.prioritizedExtents(
            total: area.width,
            weights: [masterRatio, 1 - masterRatio],
            minimumExtent: Self.minPaneExtent
        )
        let masterPane = CGRect(x: area.minX, y: area.minY, width: paneWidths[0], height: area.height)
        let stackPane = CGRect(x: masterPane.maxX, y: area.minY, width: paneWidths[1], height: area.height)

        let rowHeights = Self.prioritizedExtents(
            total: stackPane.height,
            weights: normalizedStackWeights(count: count - 1),
            minimumExtent: Self.minStackSlotExtent
        )
        var rects = [masterPane.insetBy(dx: Self.slotInset, dy: Self.slotInset)]
        var rowY = stackPane.minY
        for rowHeight in rowHeights {
            let row = CGRect(x: stackPane.minX, y: rowY, width: stackPane.width, height: rowHeight)
            rects.append(row.insetBy(dx: Self.slotInset, dy: Self.slotInset))
            rowY += rowHeight
        }
        return rects
    }

    /// Updates the ratios so that the edge the user dragged stays where they released it.
    mutating func adjust(
        forResizeOf windowID: CGWindowID,
        from originalFrame: CGRect,
        to currentFrame: CGRect,
        in visibleArea: CGRect
    ) {
        guard windowIDs.count >= 2, let slot = windowIDs.firstIndex(of: windowID) else { return }
        let area = visibleArea.insetBy(dx: Self.displayInset, dy: Self.displayInset)
        guard area.width > 1, area.height > 1 else { return }

        let horizontalMove = slot == 0
            ? abs(currentFrame.maxX - originalFrame.maxX)
            : abs(currentFrame.minX - originalFrame.minX)
        let verticalMove = max(
            abs(currentFrame.minY - originalFrame.minY),
            abs(currentFrame.maxY - originalFrame.maxY)
        )

        if slot == 0 || horizontalMove > verticalMove {
            // The master/stack boundary sits on the master's right edge and the stack's left edge.
            let boundaryX = slot == 0
                ? currentFrame.maxX + Self.slotInset
                : currentFrame.minX - Self.slotInset
            masterRatio = ((boundaryX - area.minX) / area.width).clamped(to: Self.masterRatioRange)
        } else {
            adjustStackBoundary(stackIndex: slot - 1, from: originalFrame, to: currentFrame, paneMinY: area.minY, paneHeight: area.height)
        }
    }

    private mutating func adjustStackBoundary(
        stackIndex: Int,
        from originalFrame: CGRect,
        to currentFrame: CGRect,
        paneMinY: CGFloat,
        paneHeight: CGFloat
    ) {
        var rowHeights = normalizedStackWeights(count: windowIDs.count - 1).map { $0 * paneHeight }
        guard rowHeights.count >= 2 else { return }

        let movedTop = abs(currentFrame.minY - originalFrame.minY)
        let movedBottom = abs(currentFrame.maxY - originalFrame.maxY)
        let boundaryIndex: Int
        let desiredBoundaryY: CGFloat
        if movedBottom >= movedTop {
            guard stackIndex < rowHeights.count - 1 else { return }
            boundaryIndex = stackIndex
            desiredBoundaryY = currentFrame.maxY + Self.slotInset
        } else {
            guard stackIndex > 0 else { return }
            boundaryIndex = stackIndex - 1
            desiredBoundaryY = currentFrame.minY - Self.slotInset
        }

        let currentPrefix = rowHeights[0...boundaryIndex].reduce(0, +)
        let maxShrink = rowHeights[boundaryIndex] - Self.minStackSlotExtent
        let maxGrow = rowHeights[boundaryIndex + 1] - Self.minStackSlotExtent
        let delta = (desiredBoundaryY - paneMinY - currentPrefix).clamped(to: -maxShrink...maxGrow)
        rowHeights[boundaryIndex] += delta
        rowHeights[boundaryIndex + 1] -= delta

        let sum = rowHeights.reduce(0, +)
        stackWeights = rowHeights.map { $0 / sum }
    }

    private func normalizedStackWeights(count: Int) -> [CGFloat] {
        Self.normalize(stackWeights, count: count)
    }

    private static func normalize(_ input: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        var values = input.prefix(count).map { max($0, 0.0001) }
        values.append(contentsOf: repeatElement(values.isEmpty ? 1 : values.reduce(0, +) / CGFloat(values.count), count: count - values.count))
        let sum = values.reduce(0, +)
        return values.map { $0 / sum }
    }

    /// Splits `total` by `weights`. When minimum extents conflict, earlier entries keep their minimum first.
    private static func prioritizedExtents(total: CGFloat, weights: [CGFloat], minimumExtent: CGFloat) -> [CGFloat] {
        let count = weights.count
        guard count > 1 else { return [max(total, 0)] }

        let normalized = normalize(weights, count: count)
        var result: [CGFloat] = []
        var remainingTotal = max(total, 0)
        var remainingWeight: CGFloat = 1

        for index in 0..<(count - 1) {
            let desired = remainingWeight > 0 ? remainingTotal * normalized[index] / remainingWeight : 0
            let reserveForRest = minimumExtent * CGFloat(count - index - 1)
            let allocated = remainingTotal >= minimumExtent + reserveForRest
                ? desired.clamped(to: minimumExtent...(remainingTotal - reserveForRest))
                : min(remainingTotal, minimumExtent)
            result.append(allocated)
            remainingTotal -= allocated
            remainingWeight -= normalized[index]
        }
        result.append(remainingTotal)
        return result
    }
}
