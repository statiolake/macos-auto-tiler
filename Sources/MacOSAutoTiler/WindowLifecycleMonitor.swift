import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowLifecycleMonitor {
    typealias ChangeHandler = (String) -> Void

    private let discovery: WindowDiscovery
    private let debounceInterval: TimeInterval
    private let selfPID = getpid()

    private var changeHandler: ChangeHandler?
    private var debounceWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []

    private var observersByPID: [pid_t: AXObserver] = [:]
    private var appElementsByPID: [pid_t: AXUIElement] = [:]

    private let watchedAXNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
    ]

    init(
        discovery: WindowDiscovery = WindowDiscovery(),
        debounceInterval: TimeInterval = 0.18
    ) {
        self.discovery = discovery
        self.debounceInterval = debounceInterval
    }

    func start(changeHandler: @escaping ChangeHandler) {
        stop()
        self.changeHandler = changeHandler

        let windows = discovery.fetchVisibleWindows()
        let pids = runningApplicationPIDs()

        refreshAXObservers(for: pids)
        registerWorkspaceNotifications()

        Diagnostics.log(
            "Lifecycle monitor started (event-driven) windows=\(windows.count) pids=\(pids.count)",
            level: .info
        )
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for observer in observersByPID.values {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observersByPID.removeAll()
        appElementsByPID.removeAll()

        changeHandler = nil
        Diagnostics.log("Lifecycle monitor stopped", level: .debug)
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceLaunch(notification)
        }

        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceTerminate(notification)
        }

        workspaceObservers = [launched, terminated]
    }

    private func handleWorkspaceLaunch(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            refreshAXObservers(for: runningApplicationPIDs())
            enqueueChange(reason: "workspace-launch")
            return
        }

        let pid = app.processIdentifier
        guard pid != selfPID else {
            return
        }

        if observersByPID[pid] == nil {
            addAXObserver(for: pid)
            if observersByPID[pid] != nil {
                Diagnostics.log("Lifecycle monitor added AX observer pid=\(describePID(pid)) (workspace-launch)", level: .debug)
            }
        }

        enqueueChange(reason: "workspace-launch")
    }

    private func handleWorkspaceTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            refreshAXObservers(for: runningApplicationPIDs())
            enqueueChange(reason: "workspace-terminate")
            return
        }

        let pid = app.processIdentifier
        guard pid != selfPID else {
            return
        }

        if observersByPID[pid] != nil {
            removeAXObserver(for: pid)
            Diagnostics.log("Lifecycle monitor removed AX observer pid=\(describePID(pid)) (workspace-terminate)", level: .debug)
        }

        enqueueChange(reason: "workspace-terminate")
    }

    private func runningApplicationPIDs() -> Set<pid_t> {
        Set(
            NSWorkspace.shared.runningApplications
                .map(\.processIdentifier)
                .filter { $0 != selfPID }
        )
    }

    private func refreshAXObservers(for pids: Set<pid_t>) {
        let existingPIDs = Set(observersByPID.keys)

        let removedPIDs = existingPIDs.subtracting(pids)
        for pid in removedPIDs {
            removeAXObserver(for: pid)
        }
        if !removedPIDs.isEmpty {
            let removedList = removedPIDs.sorted().map { describePID($0) }.joined(separator: ", ")
            Diagnostics.log("Lifecycle monitor removed AX observer pids=[\(removedList)]", level: .debug)
        }

        let addedPIDs = pids.subtracting(existingPIDs)
        for pid in addedPIDs {
            addAXObserver(for: pid)
        }
        let nowObserved = Set(observersByPID.keys)
        let actuallyAdded = nowObserved.subtracting(existingPIDs)
        if !actuallyAdded.isEmpty {
            let addedList = actuallyAdded.sorted().map { describePID($0) }.joined(separator: ", ")
            Diagnostics.log("Lifecycle monitor added AX observer pids=[\(addedList)]", level: .debug)
        }
    }

    private func addAXObserver(for pid: pid_t) {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.axCallback, &observer)
        guard result == .success, let observer else {
            Diagnostics.log("Lifecycle monitor failed AXObserverCreate pid=\(describePID(pid)) error=\(result.rawValue)", level: .debug)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var addedAny = false
        for notification in watchedAXNotifications {
            let addResult = AXObserverAddNotification(observer, appElement, notification, refcon)
            switch addResult {
            case .success, .notificationAlreadyRegistered:
                addedAny = true
            case .notificationUnsupported:
                continue
            default:
                continue
            }
        }

        guard addedAny else {
            Diagnostics.log("Lifecycle monitor no supported AX notifications pid=\(describePID(pid))", level: .debug)
            return
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observersByPID[pid] = observer
        appElementsByPID[pid] = appElement
    }

    private func removeAXObserver(for pid: pid_t) {
        guard let observer = observersByPID.removeValue(forKey: pid) else {
            appElementsByPID.removeValue(forKey: pid)
            return
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        appElementsByPID.removeValue(forKey: pid)
    }

    private func handleAXEvent(notification: String) {
        enqueueChange(reason: "ax:\(notification)")
    }

    private func describePID(_ pid: pid_t) -> String {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
        return "\(pid):\(appName)"
    }

    private func enqueueChange(reason: String) {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let changeHandler else {
                return
            }
            changeHandler(reason)
        }

        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private static let axCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else {
            return
        }
        let monitor = Unmanaged<WindowLifecycleMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let notificationName = notification as String
        monitor.handleAXEvent(notification: notificationName)
    }
}
