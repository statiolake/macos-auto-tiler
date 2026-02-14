import Foundation

struct WindowTypeDescriptor: Hashable {
    let role: String
    let subrole: String

    var typeKey: String {
        "\(role)::\(subrole)"
    }
}

struct DiscoveredWindowType: Identifiable {
    let appName: String
    let descriptor: WindowTypeDescriptor
    var seenCount: Int
    var lastSeenAt: Date

    var id: String {
        "\(appName)||\(descriptor.typeKey)"
    }
}

struct WindowRuleSnapshot {
    let floatingApps: Set<String>
    let floatingTypeKeys: Set<String>

    func isAppForcedFloating(_ appName: String) -> Bool {
        floatingApps.contains(appName)
    }

    func isTypeForcedFloating(_ descriptor: WindowTypeDescriptor) -> Bool {
        floatingTypeKeys.contains(descriptor.typeKey)
    }
}

final class WindowRuleStore {
    private enum Keys {
        static let floatingApps = "rules.floatingApps"
        static let floatingTypeKeys = "rules.floatingTypeKeys"
    }

    private let defaults: UserDefaults
    private var floatingApps: Set<String>
    private var floatingTypeKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.floatingApps = Set(defaults.stringArray(forKey: Keys.floatingApps) ?? [])
        self.floatingTypeKeys = Set(defaults.stringArray(forKey: Keys.floatingTypeKeys) ?? [])
    }

    func isAppForcedFloating(_ appName: String) -> Bool {
        floatingApps.contains(appName)
    }

    func isTypeForcedFloating(_ descriptor: WindowTypeDescriptor) -> Bool {
        floatingTypeKeys.contains(descriptor.typeKey)
    }

    func setAppForcedFloating(_ appName: String, enabled: Bool) {
        if enabled {
            floatingApps.insert(appName)
        } else {
            floatingApps.remove(appName)
        }
        defaults.set(Array(floatingApps).sorted(), forKey: Keys.floatingApps)
    }

    func setTypeForcedFloating(_ descriptor: WindowTypeDescriptor, enabled: Bool) {
        if enabled {
            floatingTypeKeys.insert(descriptor.typeKey)
        } else {
            floatingTypeKeys.remove(descriptor.typeKey)
        }
        defaults.set(Array(floatingTypeKeys).sorted(), forKey: Keys.floatingTypeKeys)
    }

    func snapshot() -> WindowRuleSnapshot {
        WindowRuleSnapshot(
            floatingApps: floatingApps,
            floatingTypeKeys: floatingTypeKeys
        )
    }
}

final class WindowTypeRegistry {
    private var recordsByID: [String: DiscoveredWindowType] = [:]
    private let maxRecords = 1000

    func record(appName: String, descriptor: WindowTypeDescriptor) {
        let key = "\(appName)||\(descriptor.typeKey)"
        let now = Date()
        if var existing = recordsByID[key] {
            existing.seenCount += 1
            existing.lastSeenAt = now
            recordsByID[key] = existing
            return
        }

        recordsByID[key] = DiscoveredWindowType(
            appName: appName,
            descriptor: descriptor,
            seenCount: 1,
            lastSeenAt: now
        )

        if recordsByID.count > maxRecords {
            trimOldRecords()
        }
    }

    func snapshot(limit: Int = 200) -> [DiscoveredWindowType] {
        recordsByID.values
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    private func trimOldRecords() {
        let sortedKeysToKeep = Set(recordsByID.values
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.id < rhs.id
            }
            .prefix(maxRecords)
            .map(\.id))
        recordsByID = recordsByID.filter { sortedKeysToKeep.contains($0.key) }
    }
}
