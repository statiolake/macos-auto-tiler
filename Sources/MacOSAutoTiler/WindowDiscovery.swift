import CoreGraphics
import Foundation

final class WindowDiscovery {
    private let logStateLock = NSLock()
    private var lastDiscoverySignature: UInt64?

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

            let title = (info[kCGWindowName as String] as? String) ?? ""
            let appName = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            windows.append(
                WindowRef(
                    windowID: CGWindowID(windowNumber),
                    pid: pid,
                    frame: frame,
                    title: title,
                    appName: appName
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
}
