import CoreGraphics
import Foundation

final class WindowGroupManager {
    private let lock = NSLock()
    /// キー = "\(displayID):\(spaceID)"
    private var storeByKey: [String: WindowGroupStore] = [:]
    private let persistURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("MacOSAutoTiler")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        persistURL = dir.appendingPathComponent("window-groups.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard
            let data = try? Data(contentsOf: persistURL),
            let decoded = try? JSONDecoder().decode([String: WindowGroupStore].self, from: data)
        else { return }
        lock.lock()
        storeByKey = decoded
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let snapshot = storeByKey
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: persistURL)
    }

    private func saveAsync() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.save() }
    }

    // MARK: - Queries

    func activeGroup(for displayID: CGDirectDisplayID, spaceID: Int) -> WindowGroup? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeGroupID
        else { return nil }
        return store.groups.first { $0.id == activeID }
    }

    func groups(for displayID: CGDirectDisplayID, spaceID: Int) -> [WindowGroup] {
        lock.lock()
        defer { lock.unlock() }
        return storeByKey[key(displayID, spaceID)]?.groups ?? []
    }

    func inactiveWindowIDs(for displayID: CGDirectDisplayID, spaceID: Int) -> Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByKey[key(displayID, spaceID)],
            let activeID = store.activeGroupID
        else { return [] }
        var result = Set<CGWindowID>()
        for group in store.groups where group.id != activeID {
            result.formUnion(group.windowIDs)
        }
        return result
    }

    // MARK: - Mutations

    @discardableResult
    func createGroup(for displayID: CGDirectDisplayID, spaceID: Int, name: String) -> WindowGroup {
        let group = WindowGroup(name: name)
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        store.groups.append(group)
        store.activeGroupID = group.id
        storeByKey[k] = store
        lock.unlock()
        saveAsync()
        return group
    }

    func activateGroup(id: WindowGroupID, for displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        store.activeGroupID = id
        storeByKey[k] = store
        lock.unlock()
        saveAsync()
    }

    @discardableResult
    func moveWindow(
        _ windowID: CGWindowID,
        toGroup groupID: WindowGroupID,
        on displayID: CGDirectDisplayID,
        spaceID: Int
    ) -> (from: WindowGroupID?, to: WindowGroupID)? {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        var fromGroupID: WindowGroupID?
        for i in store.groups.indices {
            if store.groups[i].windowIDs.contains(windowID) {
                store.groups[i].windowIDs.remove(windowID)
                fromGroupID = store.groups[i].id
            }
        }
        if let idx = store.groups.firstIndex(where: { $0.id == groupID }) {
            store.groups[idx].windowIDs.insert(windowID)
        }
        cleanupEmptyGroups(in: &store)
        storeByKey[k] = store
        lock.unlock()
        saveAsync()
        return (fromGroupID, groupID)
    }

    func registerNewWindows(_ windowIDs: [CGWindowID], on displayID: CGDirectDisplayID, spaceID: Int) {
        lock.lock()
        let k = key(displayID, spaceID)
        var store = storeByKey[k] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        if store.groups.isEmpty {
            let defaultGroup = WindowGroup(name: "Default")
            store.groups.append(defaultGroup)
            store.activeGroupID = defaultGroup.id
        }
        guard
            let activeID = store.activeGroupID,
            let idx = store.groups.firstIndex(where: { $0.id == activeID })
        else {
            lock.unlock()
            return
        }
        let allRegistered = store.groups.reduce(into: Set<CGWindowID>()) { $0.formUnion($1.windowIDs) }
        for windowID in windowIDs where !allRegistered.contains(windowID) {
            store.groups[idx].windowIDs.insert(windowID)
        }
        storeByKey[k] = store
        lock.unlock()
        saveAsync()
    }

    func pruneWindows(to liveIDs: Set<CGWindowID>) {
        lock.lock()
        for k in storeByKey.keys {
            for i in storeByKey[k]!.groups.indices {
                storeByKey[k]!.groups[i].windowIDs.formIntersection(liveIDs)
            }
            cleanupEmptyGroups(in: &storeByKey[k]!)
        }
        lock.unlock()
        saveAsync()
    }

    // MARK: - Helpers

    /// 空になったグループを削除。アクティブグループが消えた場合は先頭へ切り替える。
    private func cleanupEmptyGroups(in store: inout WindowGroupStore) {
        let before = store.groups.count
        store.groups.removeAll { $0.windowIDs.isEmpty }
        guard store.groups.count < before else { return }
        if let activeID = store.activeGroupID,
           !store.groups.contains(where: { $0.id == activeID }) {
            store.activeGroupID = store.groups.first?.id
        }
    }

    private func key(_ displayID: CGDirectDisplayID, _ spaceID: Int) -> String {
        "\(displayID):\(spaceID)"
    }
}
