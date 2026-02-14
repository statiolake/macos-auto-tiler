import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowLifecycleMonitor {
    typealias ChangeHandler = (String) -> Void

    private let discovery: WindowDiscovery
    private let debounceInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let pollLeeway: TimeInterval
    private let pollQueue = DispatchQueue(label: "com.dicen.macosautotiler.lifecycle.poll", qos: .utility)

    private var changeHandler: ChangeHandler?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []

    private var lastWindowIDs = Set<CGWindowID>()

    private var observersByPID: [pid_t: AXObserver] = [:]
    private var appElementsByPID: [pid_t: AXUIElement] = [:]

    private let watchedAXNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
    ]

    init(
        discovery: WindowDiscovery = WindowDiscovery(),
        debounceInterval: TimeInterval = 0.18,
        pollInterval: TimeInterval = 2.0,
        pollLeeway: TimeInterval = 0.6
    ) {
        self.discovery = discovery
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
        self.pollLeeway = pollLeeway
    }

    func start(changeHandler: @escaping ChangeHandler) {
        stop()
        self.changeHandler = changeHandler

        let windows = discovery.fetchVisibleWindows()
        let windowIDs = Set(windows.map(\.windowID))
        let pids = Set(windows.map(\.pid))

        pollQueue.sync {
            self.lastWindowIDs = windowIDs
        }

        refreshAXObservers(for: pids)
        startPollingTimer()
        registerWorkspaceNotifications()

        Diagnostics.log(
            "Lifecycle monitor started windows=\(windowIDs.count) pids=\(pids.count)",
            level: .info
        )
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let pollTimer {
            pollTimer.setEventHandler {}
            pollTimer.cancel()
        }
        pollTimer = nil

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

        pollQueue.sync {
            self.lastWindowIDs.removeAll()
        }

        changeHandler = nil
        Diagnostics.log("Lifecycle monitor stopped", level: .debug)
    }

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(Int(pollLeeway * 1000))
        )
        timer.setEventHandler { [weak self] in
            self?.pollVisibleWindows()
        }
        timer.resume()
        pollTimer = timer
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshObserversFromCurrentWindows(triggerReason: "workspace-launch")
        }

        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshObserversFromCurrentWindows(triggerReason: "workspace-terminate")
        }

        workspaceObservers = [launched, terminated]
    }

    private func pollVisibleWindows() {
        let windows = discovery.fetchVisibleWindows()
        let currentIDs = Set(windows.map(\.windowID))
        let pids = Set(windows.map(\.pid))

        // This method already runs on pollQueue via the timer handler.
        // Access queue-owned state directly to avoid self-deadlock.
        let previousIDs = lastWindowIDs
        lastWindowIDs = currentIDs

        let added = currentIDs.subtracting(previousIDs)
        let removed = previousIDs.subtracting(currentIDs)
        if !added.isEmpty || !removed.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.enqueueChange(reason: "cg-diff(+\(added.count),-\(removed.count))")
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.refreshAXObservers(for: pids)
        }
    }

    private func refreshObserversFromCurrentWindows(triggerReason: String) {
        let windows = discovery.fetchVisibleWindows()
        let pids = Set(windows.map(\.pid))
        refreshAXObservers(for: pids)
        enqueueChange(reason: triggerReason)
    }

    private func refreshAXObservers(for pids: Set<pid_t>) {
        let existingPIDs = Set(observersByPID.keys)

        let removedPIDs = existingPIDs.subtracting(pids)
        for pid in removedPIDs {
            removeAXObserver(for: pid)
        }

        let addedPIDs = pids.subtracting(existingPIDs)
        for pid in addedPIDs {
            addAXObserver(for: pid)
        }
    }

    private func addAXObserver(for pid: pid_t) {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.axCallback, &observer)
        guard result == .success, let observer else {
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
