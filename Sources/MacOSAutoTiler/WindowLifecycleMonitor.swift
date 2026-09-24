import AppKit
import ApplicationServices

/// Reports window creation, destruction and (de)miniaturization, and app launches and terminations.
final class WindowLifecycleMonitor {
    private static let watchedNotifications = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]
    /// AX notifications arrive before the window server reflects the change.
    private static let settleDelay: TimeInterval = 0.1

    /// Registering AX observers can block for seconds on an unresponsive app, so it runs off the main thread.
    /// `observersByPID` is only touched on this queue.
    private let registrationQueue = DispatchQueue(label: "macos-auto-tiler.ax-observer-registration")
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var onChange: ((String) -> Void)?

    func start(onChange: @escaping (String) -> Void) {
        precondition(self.onChange == nil, "lifecycle monitor started twice")
        self.onChange = onChange

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] in
                self?.handleWorkspace($0, reason: "app-launch") { $0.addObserver(for: $1) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] in
                self?.handleWorkspace($0, reason: "app-terminate") { $0.removeObserver(for: $1) }
            },
        ]

        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        registrationQueue.async { [self] in
            pids.forEach(addObserver)
            Diagnostics.log("Lifecycle monitor observing \(observersByPID.count)/\(pids.count) apps", level: .info)
        }
    }

    func stop() {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        onChange = nil
        registrationQueue.sync {
            Array(observersByPID.keys).forEach(removeObserver)
        }
    }

    private func handleWorkspace(_ notification: Notification, reason: String, update: @escaping (WindowLifecycleMonitor, pid_t) -> Void) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            preconditionFailure("\(notification.name) without an application")
        }
        let pid = app.processIdentifier
        registrationQueue.async { [self] in update(self, pid) }
        onChange?(reason)
    }

    private func addObserver(for pid: pid_t) {
        guard pid != getpid(), observersByPID[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else {
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let registered = Self.watchedNotifications.filter { notification in
            let result = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            return result == .success || result == .notificationAlreadyRegistered
        }
        // Apps without AX support (background agents, helpers) accept nothing; they have no windows to tile.
        guard !registered.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observersByPID[pid] = observer
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observersByPID.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Runs on the main run loop, where the observer sources are scheduled.
    private func handleAXNotification(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            self?.onChange?("ax:\(name)")
        }
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else {
            preconditionFailure("AX observer callback without refcon")
        }
        Unmanaged<WindowLifecycleMonitor>.fromOpaque(refcon).takeUnretainedValue().handleAXNotification(notification as String)
    }
}
