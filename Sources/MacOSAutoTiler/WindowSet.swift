import CoreGraphics
import Foundation

typealias WindowSetID = UUID

struct WindowSet: Identifiable {
    let id: WindowSetID
    var orderedWindowIDs: [CGWindowID]  // index = スロット番号

    init() { id = UUID(); orderedWindowIDs = [] }

    func slotIndex(of windowID: CGWindowID) -> Int? {
        orderedWindowIDs.firstIndex(of: windowID)
    }

    mutating func add(_ windowID: CGWindowID) {
        guard !orderedWindowIDs.contains(windowID) else { return }
        orderedWindowIDs.append(windowID)
    }

    mutating func remove(_ windowID: CGWindowID) {
        orderedWindowIDs.removeAll { $0 == windowID }
    }

    mutating func moveToSlot(_ windowID: CGWindowID, slot dest: Int) {
        guard let src = orderedWindowIDs.firstIndex(of: windowID) else { return }
        let clamped = max(0, min(dest, orderedWindowIDs.count - 1))
        orderedWindowIDs.remove(at: src)
        orderedWindowIDs.insert(windowID, at: clamped)
    }
}

struct WindowSetStore {
    var sets: [WindowSet]
    var activeSetID: WindowSetID?
}
