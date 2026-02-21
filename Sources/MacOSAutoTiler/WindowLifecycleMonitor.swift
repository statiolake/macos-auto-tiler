import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowLifecycleMonitor {
    typealias ChangeHandler = (String) -> Void

    private let discovery: WindowDiscovery
    private let selfPID = getpid()
    private let observerOperationQueue = DispatchQueue(
        label: "com.statiolake.macosautotiler.lifecycle-observer-ops",
        qos: .utility
    )
    private let observerOperationQueueKey = DispatchSpecificKey<UInt8>()

    private var changeHandler: ChangeHandler?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isRunning = false
    private let observerOperationState = ObserverOperationState()
    private var observerWorkerTask: Task<Void, Never>?

    private var observersByPID: [pid_t: AXObserver] = [:]
    private var appElementsByPID: [pid_t: AXUIElement] = [:]

    private let watchedAXNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
    ]
    private let slowAXRegistrationThresholdMS = 200
    private let slowAXNotificationAddThresholdMS = 500

    private enum AXObserverAddResult {
        case added(supportedNotificationCount: Int)
        case observerCreateFailed(errorCode: Int32)
        case noSupportedNotifications
    }

    private enum ObserverOperation {
        case syncAll(pids: Set<pid_t>, reason: String, isInitial: Bool, requestedAt: Date)
        case add(pid: pid_t, reason: String)
        case remove(pid: pid_t, reason: String)
    }

    private actor ObserverOperationState {
        private var queue: [ObserverOperation] = []
        private var waitingContinuation: CheckedContinuation<Void, Never>?

        func enqueue(_ operation: ObserverOperation) {
            queue.append(operation)
            waitingContinuation?.resume()
            waitingContinuation = nil
        }

        func nextOperation() async -> ObserverOperation? {
            while true {
                if Task.isCancelled {
                    return nil
                }
                if !queue.isEmpty {
                    return queue.removeFirst()
                }
                await withCheckedContinuation { continuation in
                    waitingContinuation = continuation
                }
            }
        }

        func reset() {
            queue.removeAll(keepingCapacity: true)
            waitingContinuation?.resume()
            waitingContinuation = nil
        }
    }

    init(
        discovery: WindowDiscovery = WindowDiscovery()
    ) {
        self.discovery = discovery
        observerOperationQueue.setSpecific(key: observerOperationQueueKey, value: 1)
    }

    func start(changeHandler: @escaping ChangeHandler) {
        stop()
        self.changeHandler = changeHandler
        isRunning = true
        startObserverWorkerIfNeeded()

        let windows = discovery.fetchVisibleWindows()
        let pids = runningApplicationPIDs()

        registerWorkspaceNotifications()
        enqueueObserverOperation(
            .syncAll(
                pids: pids,
                reason: "startup",
                isInitial: true,
                requestedAt: Date()
            )
        )

        Diagnostics.log(
            "Lifecycle monitor started (event-driven) windows=\(windows.count) pids=\(pids.count)",
            level: .info
        )
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        isRunning = false
        observerWorkerTask?.cancel()
        observerWorkerTask = nil
        Task { [observerOperationState] in
            await observerOperationState.reset()
        }
        changeHandler = nil
        performObserverQueueSync { [weak self] in
            self?.resetObservers()
        }
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
            enqueueObserverOperation(
                .syncAll(
                    pids: runningApplicationPIDs(),
                    reason: "workspace-launch-snapshot",
                    isInitial: false,
                    requestedAt: Date()
                )
            )
            enqueueChange(reason: "workspace-launch")
            return
        }

        let pid = app.processIdentifier
        guard pid != selfPID else {
            return
        }

        enqueueObserverOperation(.add(pid: pid, reason: "workspace-launch"))

        enqueueChange(reason: "workspace-launch")
    }

    private func handleWorkspaceTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            enqueueObserverOperation(
                .syncAll(
                    pids: runningApplicationPIDs(),
                    reason: "workspace-terminate-snapshot",
                    isInitial: false,
                    requestedAt: Date()
                )
            )
            enqueueChange(reason: "workspace-terminate")
            return
        }

        let pid = app.processIdentifier
        guard pid != selfPID else {
            return
        }

        enqueueObserverOperation(.remove(pid: pid, reason: "workspace-terminate"))

        enqueueChange(reason: "workspace-terminate")
    }

    private func runningApplicationPIDs() -> Set<pid_t> {
        Set(
            NSWorkspace.shared.runningApplications
                .map(\.processIdentifier)
                .filter { $0 != selfPID }
        )
    }

    private func enqueueObserverOperation(_ operation: ObserverOperation) {
        Task { [observerOperationState] in
            await observerOperationState.enqueue(operation)
        }
    }

    private func startObserverWorkerIfNeeded() {
        guard observerWorkerTask == nil else {
            return
        }
        observerWorkerTask = Task { [weak self] in
            guard let self else { return }
            await runObserverWorker()
        }
    }

    private func runObserverWorker() async {
        while true {
            if Task.isCancelled {
                return
            }
            guard let operation = await observerOperationState.nextOperation() else {
                continue
            }
            performObserverQueueSync { [weak self] in
                self?.processObserverOperation(operation)
            }
        }
    }

    private func processObserverOperation(_ operation: ObserverOperation) {
        switch operation {
        case let .syncAll(pids, reason, isInitial, requestedAt):
            guard isRunning else {
                return
            }
            refreshAXObservers(for: pids)
            if isInitial {
                let registrationElapsedMS = Int(Date().timeIntervalSince(requestedAt) * 1000)
                Diagnostics.log(
                    "Lifecycle monitor initial AX registration complete candidates=\(pids.count) observed=\(observersByPID.count) elapsedMs=\(registrationElapsedMS)",
                    level: .debug
                )
            } else {
                Diagnostics.log(
                    "Lifecycle monitor AX registration sync complete reason=\(reason) candidates=\(pids.count) observed=\(observersByPID.count)",
                    level: .debug
                )
            }
        case let .add(pid, reason):
            guard isRunning, pid != selfPID else {
                return
            }
            guard observersByPID[pid] == nil else {
                return
            }
            _ = addAXObserver(for: pid)
            if observersByPID[pid] != nil {
                Diagnostics.log("Lifecycle monitor added AX observer pid=\(describePID(pid)) (\(reason))", level: .debug)
            }
        case let .remove(pid, reason):
            guard pid != selfPID else {
                return
            }
            guard observersByPID[pid] != nil else {
                return
            }
            removeAXObserver(for: pid)
            Diagnostics.log("Lifecycle monitor removed AX observer pid=\(describePID(pid)) (\(reason))", level: .debug)
        }
    }

    private func performObserverQueueSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: observerOperationQueueKey) != nil {
            work()
            return
        }
        observerOperationQueue.sync(execute: work)
    }

    private func resetObservers() {
        for observer in observersByPID.values {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observersByPID.removeAll()
        appElementsByPID.removeAll()
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
        var addSucceededCount = 0
        var addUnsupportedCount = 0
        var addCreateFailedCount = 0
        for pid in addedPIDs {
            switch addAXObserver(for: pid) {
            case .added:
                addSucceededCount += 1
            case .noSupportedNotifications:
                addUnsupportedCount += 1
            case .observerCreateFailed:
                addCreateFailedCount += 1
            }
        }
        let nowObserved = Set(observersByPID.keys)
        let actuallyAdded = nowObserved.subtracting(existingPIDs)
        if !actuallyAdded.isEmpty {
            let addedList = actuallyAdded.sorted().map { describePID($0) }.joined(separator: ", ")
            Diagnostics.log("Lifecycle monitor added AX observer pids=[\(addedList)]", level: .debug)
        }
        if !addedPIDs.isEmpty || !removedPIDs.isEmpty {
            Diagnostics.log(
                "Lifecycle monitor AX observer refresh complete addedCandidates=\(addedPIDs.count) added=\(addSucceededCount) unsupported=\(addUnsupportedCount) createFailed=\(addCreateFailedCount) removed=\(removedPIDs.count) observed=\(observersByPID.count)",
                level: .debug
            )
        }
    }

    @discardableResult
    private func addAXObserver(for pid: pid_t) -> AXObserverAddResult {
        let totalStart = Date()

        let createStart = Date()
        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.axCallback, &observer)
        let createElapsedMS = Int(Date().timeIntervalSince(createStart) * 1000)
        guard result == .success, let observer else {
            Diagnostics.log("Lifecycle monitor failed AXObserverCreate pid=\(describePID(pid)) error=\(result.rawValue)", level: .debug)
            let totalElapsedMS = Int(Date().timeIntervalSince(totalStart) * 1000)
            Diagnostics.log(
                "Lifecycle monitor AX observer timing pid=\(describePID(pid)) totalMs=\(totalElapsedMS) createMs=\(createElapsedMS) addMs=0 supported=0 unsupported=0 otherErrors=0 result=create-failed",
                level: .debug
            )
            return .observerCreateFailed(errorCode: result.rawValue)
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let addStart = Date()
        var supportedCount = 0
        var unsupportedCount = 0
        var otherErrorCount = 0
        var otherErrorDetails: [String] = []
        for notification in watchedAXNotifications {
            let notificationStart = Date()
            let addResult = AXObserverAddNotification(observer, appElement, notification, refcon)
            let notificationElapsedMS = Int(Date().timeIntervalSince(notificationStart) * 1000)
            let notificationName = notification as String

            if notificationElapsedMS >= slowAXNotificationAddThresholdMS {
                Diagnostics.log(
                    "Lifecycle monitor slow AX notification add pid=\(describePID(pid)) notification=\(notificationName) elapsedMs=\(notificationElapsedMS)",
                    level: .debug
                )
            }

            switch addResult {
            case .success, .notificationAlreadyRegistered:
                supportedCount += 1
            case .notificationUnsupported:
                unsupportedCount += 1
                continue
            default:
                otherErrorCount += 1
                otherErrorDetails.append(
                    "\(notificationName)=\(describeAXError(addResult))(raw=\(addResult.rawValue),ms=\(notificationElapsedMS))"
                )
                continue
            }
        }
        let addElapsedMS = Int(Date().timeIntervalSince(addStart) * 1000)

        if otherErrorCount > 0 {
            Diagnostics.log(
                "Lifecycle monitor AX observer other error details pid=\(describePID(pid)) details=[\(otherErrorDetails.joined(separator: ", "))]",
                level: .debug
            )
        }

        guard supportedCount > 0 else {
            Diagnostics.log("Lifecycle monitor no supported AX notifications pid=\(describePID(pid))", level: .debug)
            let totalElapsedMS = Int(Date().timeIntervalSince(totalStart) * 1000)
            Diagnostics.log(
                "Lifecycle monitor AX observer timing pid=\(describePID(pid)) totalMs=\(totalElapsedMS) createMs=\(createElapsedMS) addMs=\(addElapsedMS) supported=\(supportedCount) unsupported=\(unsupportedCount) otherErrors=\(otherErrorCount) result=no-supported",
                level: .debug
            )
            return .noSupportedNotifications
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observersByPID[pid] = observer
        appElementsByPID[pid] = appElement
        Diagnostics.log(
            "Lifecycle monitor AX observer registration complete pid=\(describePID(pid)) supportedNotifications=\(supportedCount)/\(watchedAXNotifications.count)",
            level: .debug
        )
        let totalElapsedMS = Int(Date().timeIntervalSince(totalStart) * 1000)
        Diagnostics.log(
            "Lifecycle monitor AX observer timing pid=\(describePID(pid)) totalMs=\(totalElapsedMS) createMs=\(createElapsedMS) addMs=\(addElapsedMS) supported=\(supportedCount) unsupported=\(unsupportedCount) otherErrors=\(otherErrorCount) result=added",
            level: .debug
        )
        if totalElapsedMS >= slowAXRegistrationThresholdMS {
            Diagnostics.log(
                "Lifecycle monitor slow AX observer registration pid=\(describePID(pid)) totalMs=\(totalElapsedMS)",
                level: .debug
            )
        }
        return .added(supportedNotificationCount: supportedCount)
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
        guard let changeHandler else {
            return
        }
        DispatchQueue.main.async {
            changeHandler(reason)
        }
    }

    private func describeAXError(_ error: AXError) -> String {
        switch error {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegal-argument"
        case .invalidUIElement:
            return "invalid-ui-element"
        case .invalidUIElementObserver:
            return "invalid-ui-element-observer"
        case .cannotComplete:
            return "cannot-complete"
        case .attributeUnsupported:
            return "attribute-unsupported"
        case .actionUnsupported:
            return "action-unsupported"
        case .notificationUnsupported:
            return "notification-unsupported"
        case .notImplemented:
            return "not-implemented"
        case .notificationAlreadyRegistered:
            return "notification-already-registered"
        case .notificationNotRegistered:
            return "notification-not-registered"
        case .apiDisabled:
            return "api-disabled"
        case .noValue:
            return "no-value"
        case .parameterizedAttributeUnsupported:
            return "parameterized-attribute-unsupported"
        case .notEnoughPrecision:
            return "not-enough-precision"
        @unknown default:
            return "unknown"
        }
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
