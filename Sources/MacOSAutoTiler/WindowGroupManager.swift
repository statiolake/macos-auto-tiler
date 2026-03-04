import CoreGraphics
import Foundation

final class WindowGroupManager {
    private let lock = NSLock()
    private var storeByDisplayID: [String: WindowGroupStore] = [:]
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
        storeByDisplayID = decoded
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let snapshot = storeByDisplayID
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: persistURL)
    }

    private func saveAsync() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.save() }
    }

    // MARK: - Queries

    func activeGroup(for displayID: CGDirectDisplayID) -> WindowGroup? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByDisplayID[key(displayID)],
            let activeID = store.activeGroupID
        else { return nil }
        return store.groups.first { $0.id == activeID }
    }

    func groups(for displayID: CGDirectDisplayID) -> [WindowGroup] {
        lock.lock()
        defer { lock.unlock() }
        return storeByDisplayID[key(displayID)]?.groups ?? []
    }

    func inactiveWindowIDs(for displayID: CGDirectDisplayID) -> Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        guard
            let store = storeByDisplayID[key(displayID)],
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
    func createGroup(for displayID: CGDirectDisplayID, name: String) -> WindowGroup {
        let group = WindowGroup(name: name)
        lock.lock()
        var store = storeByDisplayID[key(displayID)] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        store.groups.append(group)
        store.activeGroupID = group.id
        storeByDisplayID[key(displayID)] = store
        lock.unlock()
        saveAsync()
        return group
    }

    func activateGroup(id: WindowGroupID, for displayID: CGDirectDisplayID) {
        lock.lock()
        var store = storeByDisplayID[key(displayID)] ?? WindowGroupStore(groups: [], activeGroupID: nil)
        store.activeGroupID = id
        storeByDisplayID[key(displayID)] = store
        lock.unlock()
        saveAsync()
    }

    @discardableResult
    func moveWindow(
        _ windowID: CGWindowID,
        toGroup groupID: WindowGroupID,
        on displayID: CGDirectDisplayID
    ) -> (from: WindowGroupID?, to: WindowGroupID)? {
        lock.lock()
        var store = storeByDisplayID[key(displayID)] ?? WindowGroupStore(groups: [], activeGroupID: nil)
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
        storeByDisplayID[key(displayID)] = store
        lock.unlock()
        saveAsync()
        return (fromGroupID, groupID)
    }

    func registerNewWindows(_ windowIDs: [CGWindowID], on displayID: CGDirectDisplayID) {
        lock.lock()
        var store = storeByDisplayID[key(displayID)] ?? WindowGroupStore(groups: [], activeGroupID: nil)
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
        storeByDisplayID[key(displayID)] = store
        lock.unlock()
        saveAsync()
    }

    func pruneWindows(to liveIDs: Set<CGWindowID>) {
        lock.lock()
        for key in storeByDisplayID.keys {
            for i in storeByDisplayID[key]!.groups.indices {
                storeByDisplayID[key]!.groups[i].windowIDs.formIntersection(liveIDs)
            }
        }
        lock.unlock()
        saveAsync()
    }

    // MARK: - Helpers

    private func key(_ displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}
