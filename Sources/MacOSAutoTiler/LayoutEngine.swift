import CoreGraphics
import Foundation

final class LayoutEngine {
    func makeSlots(for windowCount: Int, in bounds: CGRect) -> [Slot] {
        guard windowCount > 0 else {
            return []
        }

        let columns = max(1, Int(ceil(sqrt(Double(windowCount)))))
        let rows = max(1, Int(ceil(Double(windowCount) / Double(columns))))
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
            ).insetBy(dx: 8, dy: 8)
            slots.append(Slot(rect: rect, windowID: nil))
        }

        return slots
    }

    func slotIndex(at point: CGPoint, in slots: [Slot]) -> Int? {
        slots.firstIndex { $0.rect.contains(point) }
    }

    func reflow(order: [CGWindowID], draggedID: CGWindowID, destinationIndex: Int) -> [CGWindowID] {
        guard let sourceIndex = order.firstIndex(of: draggedID) else {
            return order
        }

        var next = order
        next.remove(at: sourceIndex)
        let clamped = max(0, min(destinationIndex, next.count))
        next.insert(draggedID, at: clamped)
        return next
    }

    func targets(for slots: [Slot], order: [CGWindowID]) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        let count = min(slots.count, order.count)
        for index in 0..<count {
            result[order[index]] = slots[index].rect
        }
        return result
    }
}
