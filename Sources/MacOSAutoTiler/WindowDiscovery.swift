import AppKit
import CoreGraphics
import Foundation

/// Reads windows from the window server and decides which of them are tiling candidates.
final class WindowDiscovery {
    private static let minimumWindowExtent: CGFloat = 80

    private let ruleStore: WindowRuleStore
    private let typeRegistry: WindowTypeRegistry
    private let semanticsClassifier: WindowSemanticsClassifier
    private let spaces = CGSSpaceService.shared

    init(ruleStore: WindowRuleStore, typeRegistry: WindowTypeRegistry, resolver: AXWindowResolver) {
        self.ruleStore = ruleStore
        self.typeRegistry = typeRegistry
        semanticsClassifier = WindowSemanticsClassifier(resolver: resolver)
    }

    func snapshot() -> WindowSnapshot {
        let infos = onScreenWindowInfos()
        let visibleSpaces = visibleSpaces()
        let rules = ruleStore.snapshot()
        var isComplete = visibleSpaces.count == DisplayService.activeDisplayIDs().count

        let candidates = infos.filter { info in
            info.layer == 0
                && info.alpha > 0.01
                && info.pid != getpid()
                && info.frame.width >= Self.minimumWindowExtent
                && info.frame.height >= Self.minimumWindowExtent
        }
        let spaceByWindowID = spaces.spacesByWindowID(windowIDs: candidates.map(\.windowID))

        var ownerByPID: [pid_t: NSRunningApplication?] = [:]
        var windows: [ObservedWindow] = []
        for info in candidates {
            let owner = ownerByPID[info.pid] ?? NSRunningApplication(processIdentifier: info.pid)
            ownerByPID[info.pid] = owner
            let bundleID = owner?.bundleIdentifier
            guard owner?.isFinishedLaunching ?? true, !rules.isBundleExcluded(bundleID) else { continue }

            guard let spaceID = spaceByWindowID[info.windowID] else {
                isComplete = false
                continue
            }
            // Mid-transition, windows of the space being left are still reported as on screen.
            guard let space = visibleSpace(withID: spaceID, containing: info.frame, in: visibleSpaces) else {
                continue
            }

            let appName = owner?.localizedName ?? info.ownerName ?? "Unknown"
            let semantics = semanticsClassifier.semantics(windowID: info.windowID, pid: info.pid)
            if let semantics {
                typeRegistry.record(appName: appName, bundleID: bundleID, descriptor: semantics.descriptor)
            }
            let isTilable = owner?.activationPolicy == .regular
                && semantics?.isStandardWindow == true
                && !rules.isAppForcedFloating(appName)
                && !(semantics.map { rules.isTypeForcedFloating($0.descriptor) } ?? false)

            windows.append(
                ObservedWindow(
                    windowID: info.windowID,
                    pid: info.pid,
                    frame: info.frame,
                    title: info.title,
                    appName: appName,
                    bundleID: bundleID,
                    space: space,
                    isTilable: isTilable
                )
            )
        }

        semanticsClassifier.prune(to: Set(infos.map(\.windowID)))
        return WindowSnapshot(windows: windows, visibleSpaces: visibleSpaces, isComplete: isComplete)
    }

    private func visibleSpace(
        withID spaceID: Int,
        containing frame: CGRect,
        in visibleSpaces: [CGDirectDisplayID: SpaceKey]
    ) -> SpaceKey? {
        let showing = visibleSpaces.values.filter { $0.spaceID == spaceID }
        guard showing.count > 1 else { return showing.first }
        // With "Displays have separate Spaces" turned off, one space spans every display; the frame decides.
        return DisplayService.displayID(for: frame).flatMap { visibleSpaces[$0] }
    }

    /// The space each active display currently shows. Displays whose space is unresolvable mid-transition are absent.
    func visibleSpaces() -> [CGDirectDisplayID: SpaceKey] {
        let currentSpaceByDisplay = spaces.currentSpaceByDisplayID(displayIDs: DisplayService.activeDisplayIDs())
        return Dictionary(uniqueKeysWithValues: currentSpaceByDisplay.map {
            ($0.key, SpaceKey(displayID: $0.key, spaceID: $0.value))
        })
    }

    /// IDs of windows on every space, including hidden and minimized ones.
    func allWindowIDs() -> Set<CGWindowID> {
        Set(windowInfos(options: [.excludeDesktopElements]).map(\.windowID))
    }

    func frames(of windowIDs: Set<CGWindowID>) -> [CGWindowID: CGRect] {
        Dictionary(
            onScreenWindowInfos().filter { windowIDs.contains($0.windowID) }.map { ($0.windowID, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func hasVisibleWindow(at point: CGPoint) -> Bool {
        onScreenWindowInfos().contains { $0.layer == 0 && $0.alpha > 0.01 && $0.frame.contains(point) }
    }

    private struct WindowInfo {
        let windowID: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let layer: Int
        let alpha: Double
        let title: String
        let ownerName: String?
    }

    private func onScreenWindowInfos() -> [WindowInfo] {
        windowInfos(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    private func windowInfos(options: CGWindowListOption) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            preconditionFailure("CGWindowListCopyWindowInfo returned nil")
        }
        return raw.compactMap { info in
            guard
                let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                return nil
            }
            return WindowInfo(
                windowID: CGWindowID(windowNumber),
                pid: pid,
                frame: frame,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                title: info[kCGWindowName as String] as? String ?? "",
                ownerName: info[kCGWindowOwnerName as String] as? String
            )
        }
    }
}
