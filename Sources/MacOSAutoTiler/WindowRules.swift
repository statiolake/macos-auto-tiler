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
    let bundleID: String?
    let descriptor: WindowTypeDescriptor
    var seenCount: Int
    var lastSeenAt: Date

    var id: String {
        "\(bundleID ?? "-")||\(appName)||\(descriptor.typeKey)"
    }
}

struct WindowRuleSnapshot {
    let floatingApps: Set<String>
    let floatingTypeKeys: Set<String>
    let excludedBundleIDs: Set<String>

    func isAppForcedFloating(_ appName: String) -> Bool {
        floatingApps.contains(appName)
    }

    func isTypeForcedFloating(_ descriptor: WindowTypeDescriptor) -> Bool {
        floatingTypeKeys.contains(descriptor.typeKey)
    }

    func isBundleExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }
}

final class WindowRuleStore {
    private enum Keys {
        static let floatingApps = "rules.floatingApps"
        static let floatingTypeKeys = "rules.floatingTypeKeys"
        static let excludedBundleIDs = "rules.excludedBundleIDs"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var floatingApps: Set<String>
    private var floatingTypeKeys: Set<String>
    private var excludedBundleIDs: Set<String>

    private static let defaultFloatingApps: Set<String> = [
        "Dock",
        "WindowManager",
        "Notification Center",
        "Control Center",
        "SystemUIServer",
        "Spotlight",
        "loginwindow",
    ]

    private static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.accessibility.AXVisualSupportAgent",
        "com.apple.wallpaper.agent",
        "com.apple.talagent",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.floatingApps = Set(defaults.stringArray(forKey: Keys.floatingApps) ?? [])
        self.floatingTypeKeys = Set(defaults.stringArray(forKey: Keys.floatingTypeKeys) ?? [])
        self.excludedBundleIDs = Set(defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? [])
    }

    func isAppForcedFloating(_ appName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.defaultFloatingApps.contains(appName) || floatingApps.contains(appName)
    }

    func isBuiltInAppRule(_ appName: String) -> Bool {
        Self.defaultFloatingApps.contains(appName)
    }

    func allForcedFloatingApps() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return floatingApps.union(Self.defaultFloatingApps)
    }

    func builtInFloatingApps() -> [String] {
        Array(Self.defaultFloatingApps).sorted()
    }

    func userDefinedFloatingApps() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(floatingApps).sorted()
    }

    func isTypeForcedFloating(_ descriptor: WindowTypeDescriptor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return floatingTypeKeys.contains(descriptor.typeKey)
    }

    func isBundleExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        lock.lock()
        defer { lock.unlock() }
        return Self.defaultExcludedBundleIDs.contains(bundleID) || excludedBundleIDs.contains(bundleID)
    }

    func isBuiltInExcludedBundle(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.defaultExcludedBundleIDs.contains(bundleID)
    }

    func allExcludedBundleIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return excludedBundleIDs.union(Self.defaultExcludedBundleIDs)
    }

    func builtInExcludedBundleIDs() -> [String] {
        Array(Self.defaultExcludedBundleIDs).sorted()
    }

    func userDefinedExcludedBundleIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(excludedBundleIDs).sorted()
    }

    func userDefinedFloatingTypeDescriptors() -> [WindowTypeDescriptor] {
        lock.lock()
        let keys = Array(floatingTypeKeys)
        lock.unlock()

        return keys.compactMap { parseTypeKey($0) }
            .sorted {
                if $0.role != $1.role { return $0.role < $1.role }
                return $0.subrole < $1.subrole
            }
    }

    func setAppForcedFloating(_ appName: String, enabled: Bool) {
        lock.lock()
        if enabled {
            floatingApps.insert(appName)
        } else {
            floatingApps.remove(appName)
        }
        defaults.set(Array(floatingApps).sorted(), forKey: Keys.floatingApps)
        lock.unlock()
    }

    func setTypeForcedFloating(_ descriptor: WindowTypeDescriptor, enabled: Bool) {
        lock.lock()
        if enabled {
            floatingTypeKeys.insert(descriptor.typeKey)
        } else {
            floatingTypeKeys.remove(descriptor.typeKey)
        }
        defaults.set(Array(floatingTypeKeys).sorted(), forKey: Keys.floatingTypeKeys)
        lock.unlock()
    }

    func setBundleExcluded(_ bundleID: String, enabled: Bool) {
        guard !isBuiltInExcludedBundle(bundleID) else {
            return
        }
        lock.lock()
        if enabled {
            excludedBundleIDs.insert(bundleID)
        } else {
            excludedBundleIDs.remove(bundleID)
        }
        defaults.set(Array(excludedBundleIDs).sorted(), forKey: Keys.excludedBundleIDs)
        lock.unlock()
    }

    func snapshot() -> WindowRuleSnapshot {
        lock.lock()
        let apps = floatingApps.union(Self.defaultFloatingApps)
        let typeKeys = floatingTypeKeys
        let bundles = excludedBundleIDs.union(Self.defaultExcludedBundleIDs)
        lock.unlock()

        return WindowRuleSnapshot(
            floatingApps: apps,
            floatingTypeKeys: typeKeys,
            excludedBundleIDs: bundles
        )
    }

    private func parseTypeKey(_ typeKey: String) -> WindowTypeDescriptor? {
        let separator = "::"
        guard let range = typeKey.range(of: separator) else {
            return nil
        }
        let role = String(typeKey[..<range.lowerBound])
        let subrole = String(typeKey[range.upperBound...])
        guard !role.isEmpty, !subrole.isEmpty else {
            return nil
        }
        return WindowTypeDescriptor(role: role, subrole: subrole)
    }
}

final class WindowTypeRegistry {
    private var recordsByID: [String: DiscoveredWindowType] = [:]
    private let maxRecords = 1000

    func record(appName: String, bundleID: String?, descriptor: WindowTypeDescriptor) {
        let key = "\(bundleID ?? "-")||\(appName)||\(descriptor.typeKey)"
        let now = Date()
        if var existing = recordsByID[key] {
            existing.seenCount += 1
            existing.lastSeenAt = now
            recordsByID[key] = existing
            return
        }

        recordsByID[key] = DiscoveredWindowType(
            appName: appName,
            bundleID: bundleID,
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
