import AppKit
import CoreGraphics
import Foundation

final class WindowDiscovery {
    private struct OwnerProcessInfo {
        let isManageable: Bool
        let appName: String
        let bundleID: String?
    }

    private let ruleStore: WindowRuleStore
    private let logStateLock = NSLock()
    private var lastDiscoverySignature: UInt64?

    init(ruleStore: WindowRuleStore = WindowRuleStore()) {
        self.ruleStore = ruleStore
    }

    func fetchVisibleWindows() -> [WindowRef] {
        guard
            let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }

        let selfPID = getpid()
        var windows: [WindowRef] = []
        windows.reserveCapacity(raw.count)
        var ownerInfoByPID: [pid_t: OwnerProcessInfo] = [:]

        for info in raw {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = info[kCGWindowAlpha as String] as? Double,
                alpha > 0.01,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid != selfPID,
                let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict),
                frame.width >= 80,
                frame.height >= 80
            else {
                continue
            }

            let ownerInfo: OwnerProcessInfo
            if let cached = ownerInfoByPID[pid] {
                ownerInfo = cached
            } else {
                let computed = ownerProcessInfo(pid: pid, fallbackOwnerName: info[kCGWindowOwnerName as String] as? String)
                ownerInfoByPID[pid] = computed
                ownerInfo = computed
            }
            guard ownerInfo.isManageable else {
                continue
            }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            let spaceID = (info["kCGWindowWorkspace"] as? NSNumber)?.intValue
                ?? (info["kCGWindowWorkspace"] as? Int)
                ?? 0
            windows.append(
                WindowRef(
                    windowID: CGWindowID(windowNumber),
                    pid: pid,
                    frame: frame,
                    title: title,
                    appName: ownerInfo.appName,
                    bundleID: ownerInfo.bundleID,
                    spaceID: spaceID
                )
            )
        }

        logDiscoveryIfChanged(windows)
        return windows
    }

    func fetchWindow(windowID: CGWindowID) -> WindowRef? {
        fetchVisibleWindows().first { $0.windowID == windowID }
    }

    private func logDiscoveryIfChanged(_ windows: [WindowRef]) {
        let signature = discoverySignature(for: windows)

        logStateLock.lock()
        let shouldLog = signature != lastDiscoverySignature
        if shouldLog {
            lastDiscoverySignature = signature
        }
        logStateLock.unlock()

        guard shouldLog else {
            return
        }

        Diagnostics.log("Discovered \(windows.count) visible candidate windows", level: .debug)
    }

    private func discoverySignature(for windows: [WindowRef]) -> UInt64 {
        var hash = UInt64(windows.count)
        for id in windows.map(\.windowID).sorted() {
            hash ^= UInt64(id)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private func ownerProcessInfo(pid: pid_t, fallbackOwnerName: String?) -> OwnerProcessInfo {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            // Keep unknown processes eligible to avoid false negatives for legitimate apps.
            return OwnerProcessInfo(
                isManageable: true,
                appName: fallbackOwnerName ?? "Unknown",
                bundleID: nil
            )
        }

        let appName = app.localizedName ?? fallbackOwnerName ?? "Unknown"
        let bundleID = app.bundleIdentifier

        if ruleStore.isBundleExcluded(bundleID) {
            return OwnerProcessInfo(
                isManageable: false,
                appName: appName,
                bundleID: bundleID
            )
        }

        guard app.isFinishedLaunching else {
            return OwnerProcessInfo(
                isManageable: false,
                appName: appName,
                bundleID: bundleID
            )
        }

        return OwnerProcessInfo(
            isManageable: app.activationPolicy == .regular,
            appName: appName,
            bundleID: bundleID
        )
    }
}
