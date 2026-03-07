import CoreGraphics
import Foundation

final class WindowSetManager {
    private let lock = NSLock()
    /// キー = "\(displayID):\(spaceID)"
    private var storeByKey: [String: WindowSetStore] = [:]

    // MARK: - Queries

    func activeSet(for displayID: CGDirectDisplayID, spaceID: Int) -> WindowSet? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeSetID
        else { return nil }
        return store.sets.first { $0.id == activeID }
    }

    func sets(for displayID: CGDirectDisplayID, spaceID: Int) -> [WindowSet] {
        lock.lock()
        defer { lock.unlock() }
        return storeByKey[key(displayID, spaceID)]?.sets ?? []
    }

    func orderedWindowIDs(on displayID: CGDirectDisplayID, spaceID: Int) -> [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeSetID,
            let activeSet = store.sets.first(where: { $0.id == activeID })
        else { return [] }
        return activeSet.orderedWindowIDs
    }

    func slotIndex(of windowID: CGWindowID, on displayID: CGDirectDisplayID, spaceID: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeSetID,
            let activeSet = store.sets.first(where: { $0.id == activeID })
        else { return nil }
        return activeSet.orderedWindowIDs.firstIndex(of: windowID)
    }

    func inactiveWindowIDs(for displayID: CGDirectDisplayID, spaceID: Int) -> Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeSetID
        else { return [] }
        var result = Set<CGWindowID>()
        for set in store.sets where set.id != activeID {
            result.formUnion(set.orderedWindowIDs)
        }
        return result
    }

    // MARK: - Mutations

    @discardableResult
    func createSet(for displayID: CGDirectDisplayID, spaceID: Int) -> WindowSet {
        let newSet = WindowSet()
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowSetStore(sets: [], activeSetID: nil)
        store.sets.append(newSet)
        store.activeSetID = newSet.id
        storeByKey[k] = store
        lock.unlock()
        return newSet
    }

    func activateSet(id: WindowSetID, for displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowSetStore(sets: [], activeSetID: nil)
        store.activeSetID = id
        storeByKey[k] = store
        lock.unlock()
    }

    func registerNewWindows(_ windowIDs: [CGWindowID], on displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowSetStore(sets: [], activeSetID: nil)
        if store.sets.isEmpty {
            let defaultSet = WindowSet()
            store.sets.append(defaultSet)
            store.activeSetID = defaultSet.id
        }
        guard
            let activeID = store.activeSetID,
            let idx = store.sets.firstIndex(where: { $0.id == activeID })
        else {
            lock.unlock()
            return
        }
        let allRegistered = store.sets.reduce(into: Set<CGWindowID>()) { $0.formUnion($1.orderedWindowIDs) }
        for windowID in windowIDs where !allRegistered.contains(windowID) {
            store.sets[idx].orderedWindowIDs.append(windowID)
        }
        storeByKey[k] = store
        lock.unlock()
    }

    func moveWindowToSet(
        _ windowID: CGWindowID,
        toSetID setID: WindowSetID,
        on displayID: CGDirectDisplayID,
        spaceID: Int
    ) {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowSetStore(sets: [], activeSetID: nil)
        for i in store.sets.indices {
            store.sets[i].remove(windowID)
        }
        if let idx = store.sets.firstIndex(where: { $0.id == setID }) {
            store.sets[idx].add(windowID)
        }
        cleanupEmptySets(in: &store)
        storeByKey[k] = store
        lock.unlock()
    }

    func moveWindowToSlot(_ windowID: CGWindowID, slot: Int, on displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        guard
            var store = storeByKey[k],
            let activeID = store.activeSetID,
            let idx = store.sets.firstIndex(where: { $0.id == activeID })
        else {
            lock.unlock()
            return
        }
        store.sets[idx].moveToSlot(windowID, slot: slot)
        storeByKey[k] = store
        lock.unlock()
    }

    func removeWindowFromAllSets(_ windowID: CGWindowID) {
        lock.lock()
        for k in storeByKey.keys {
            for i in storeByKey[k]!.sets.indices {
                storeByKey[k]!.sets[i].remove(windowID)
            }
            cleanupEmptySets(in: &storeByKey[k]!)
        }
        lock.unlock()
    }

    func pruneWindows(to liveIDs: Set<CGWindowID>, on displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        if var store = storeByKey[k] {
            for i in store.sets.indices {
                store.sets[i].orderedWindowIDs.removeAll { !liveIDs.contains($0) }
            }
            cleanupEmptySets(in: &store)
            storeByKey[k] = store
        }
        lock.unlock()
    }

    // MARK: - Helpers

    /// 空になったセットを削除。アクティブセットが消えた場合は先頭へ切り替える。
    private func cleanupEmptySets(in store: inout WindowSetStore) {
        let before = store.sets.count
        store.sets.removeAll { $0.orderedWindowIDs.isEmpty }
        guard store.sets.count < before else { return }
        if let activeID = store.activeSetID,
           !store.sets.contains(where: { $0.id == activeID }) {
            store.activeSetID = store.sets.first?.id
        }
    }

    private func key(_ displayID: CGDirectDisplayID, _ spaceID: Int) -> String {
        "\(displayID):\(spaceID)"
    }
}
