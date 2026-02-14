import CoreGraphics
import Foundation

final class LayoutEngine {
    func makeSlots(for windowCount: Int, in bounds: CGRect) -> [Slot] {
        guard windowCount > 0 else {
            return []
        }

        switch windowCount {
        case 3:
            // 左右2分割: 左1つ(2倍高さ)、右2つ
            let splitX = bounds.midX
            let leftWidth = splitX - bounds.minX - 8 * 2
            let rightWidth = bounds.maxX - splitX - 8 * 2

            // 左側: 1つの大きなスロット
            let leftSlot = CGRect(
                x: bounds.minX + 8,
                y: bounds.minY + 8,
                width: leftWidth,
                height: bounds.height - 8 * 2
            )

            // 右側: 2つのスロット（半分の高さ）
            let rightSlot1 = CGRect(
                x: splitX + 8,
                y: bounds.minY + 8,
                width: rightWidth,
                height: (bounds.height - 8 * 2) / 2
            )
            let rightSlot2 = CGRect(
                x: splitX + 8,
                y: bounds.minY + 8 + rightSlot1.height + 8,
                width: rightWidth,
                height: (bounds.height - 8 * 2) / 2
            )

            return [
                Slot(rect: leftSlot, windowID: nil),
                Slot(rect: rightSlot1, windowID: nil),
                Slot(rect: rightSlot2, windowID: nil)
            ]

        default:
            // 1, 2, 4つ以上は従来のグリッド
            let columns = max(1, Int(ceil(sqrt(Double(windowCount)))))
            let rows = Int(ceil(Double(windowCount) / Double(columns)))
            let cellWidth = bounds.width / CGFloat(columns)
            let cellHeight = bounds.height / CGFloat(rows)

            var slots: [Slot] = []
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
    }

    func slotIndex(at point: CGPoint, in slots: [Slot]) -> Int? {
        slots.firstIndex { $0.rect.contains(point) }
    }

    func assignWindowsToNearestSlots(
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
            let slotCenter = CGPoint(x: slot.rect.midX, y: slot.rect.midY)
            for window in windows {
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                let distance = hypot(center.x - slotCenter.x, center.y - slotCenter.y)
                pairs.append(Pair(distance: distance, slotIndex: slotIndex, windowID: window.windowID))
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

        for pair in pairs {
            if usedSlots.contains(pair.slotIndex) || usedWindows.contains(pair.windowID) {
                continue
            }
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

    func targets(for slots: [Slot], slotToWindowID: [Int: CGWindowID]) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for (slotIndex, windowID) in slotToWindowID {
            guard slotIndex >= 0, slotIndex < slots.count else {
                continue
            }
            result[windowID] = slots[slotIndex].rect
        }
        return result
    }
}
