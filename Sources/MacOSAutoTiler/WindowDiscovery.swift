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
    private let cgsSpaceService: CGSSpaceService
    private let logStateLock = NSLock()
    private var lastDiscoverySignature: UInt64?

    init(
        ruleStore: WindowRuleStore = WindowRuleStore(),
        cgsSpaceService: CGSSpaceService = .shared
    ) {
        self.ruleStore = ruleStore
        self.cgsSpaceService = cgsSpaceService
    }

    func fetchVisibleWindows() -> [WindowRef] {
        guard
            let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }

        let selfPID = getpid()
        var displayByWindowID: [CGWindowID: CGDirectDisplayID] = [:]
        displayByWindowID.reserveCapacity(raw.count)
        let allWindowIDs = raw.compactMap { info -> CGWindowID? in
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32 else {
                return nil
            }
            return CGWindowID(windowNumber)
        }
        let spaceByWindowID = cgsSpaceService.spacesByWindowID(windowIDs: allWindowIDs)

        var displayIDs = Set<CGDirectDisplayID>()
        for info in raw {
            guard
                let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            let windowID = CGWindowID(windowNumber)
            if let displayID = DisplayService.displayID(for: frame) {
                displayIDs.insert(displayID)
                displayByWindowID[windowID] = displayID
            }
        }
        let currentSpaceByDisplayID = cgsSpaceService.currentSpaceByDisplayID(displayIDs: displayIDs)
        let visibleSpaceIDs = Set(currentSpaceByDisplayID.values)

        var windows: [WindowRef] = []
        windows.reserveCapacity(raw.count)
        var ownerInfoByPID: [pid_t: OwnerProcessInfo] = [:]
        var droppedMissingDisplay = 0
        var droppedMissingSpace = 0
        var droppedOffVisibleSpaces = 0
        var inferredSpaceFromDisplay = 0

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
            let windowID = CGWindowID(windowNumber)
            guard let displayID = displayByWindowID[windowID] else {
                droppedMissingDisplay += 1
                continue
            }
            let resolvedSpaceID: Int
            if let spaceID = spaceByWindowID[windowID] {
                resolvedSpaceID = spaceID
                if !visibleSpaceIDs.isEmpty, !visibleSpaceIDs.contains(spaceID) {
                    droppedOffVisibleSpaces += 1
                    continue
                }
            } else if let displaySpaceID = currentSpaceByDisplayID[displayID] {
                // Prefer keeping currently visible windows managed even when per-window
                // CGS lookup is transiently unavailable.
                resolvedSpaceID = displaySpaceID
                droppedMissingSpace += 1
                inferredSpaceFromDisplay += 1
            } else {
                droppedMissingSpace += 1
                continue
            }

            windows.append(
                WindowRef(
                    windowID: windowID,
                    pid: pid,
                    displayID: displayID,
                    frame: frame,
                    title: title,
                    appName: ownerInfo.appName,
                    bundleID: ownerInfo.bundleID,
                    spaceID: resolvedSpaceID
                )
            )
        }

        if droppedMissingDisplay > 0 || droppedMissingSpace > 0 || droppedOffVisibleSpaces > 0 || inferredSpaceFromDisplay > 0 {
            Diagnostics.log(
                "CGS space filter dropped windows missingDisplay=\(droppedMissingDisplay) missingSpace=\(droppedMissingSpace) inferredSpace=\(inferredSpaceFromDisplay) offVisibleSpaces=\(droppedOffVisibleSpaces)",
                level: .debug
            )
        }

        logDiscoveryIfChanged(windows)
        return windows
    }

    func fetchWindow(windowID: CGWindowID) -> WindowRef? {
        fetchVisibleWindows().first { $0.windowID == windowID }
    }

    func fetchWindowFrames(for windowIDs: Set<CGWindowID>) -> [CGWindowID: CGRect] {
        guard
            !windowIDs.isEmpty,
            let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return [:]
        }
        var result: [CGWindowID: CGRect] = [:]
        for info in raw {
            guard
                let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                windowIDs.contains(CGWindowID(windowNumber)),
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            result[CGWindowID(windowNumber)] = frame
            if result.count == windowIDs.count {
                break
            }
        }
        return result
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
