import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = TilerCoordinator()
    private let startupPermissionFlow = StartupPermissionFlow()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("Application launched", level: .info)
        setupStatusItem()
        guard startupPermissionFlow.run() else {
            Diagnostics.log("Startup permission flow did not complete; terminating app", level: .warn)
            NSApp.terminate(nil)
            return
        }
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.log("Application terminating", level: .info)
        coordinator.stop()
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButtonAppearance(statusItem.button)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Reflow Now",
            action: #selector(reflowNow),
            keyEquivalent: "r"
        )
        menu.addItem(
            withTitle: "Floating Rules...",
            action: #selector(openFloatingRules),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = nil
        statusMenu = menu

        self.statusItem = statusItem
        Diagnostics.log("Menu bar item initialized", level: .debug)
    }

    private func configureStatusButtonAppearance(_ button: NSStatusBarButton?) {
        guard let button else {
            return
        }

        button.toolTip = "macOS Auto Tiler"
        button.imagePosition = .imageOnly

        if let image = NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: "Auto Tiler") {
            image.isTemplate = true
            button.image = image
            button.title = ""
            return
        }

        // Fallback for environments where SF Symbols are unavailable.
        button.image = nil
        button.title = "Tiler"
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            Diagnostics.log("Status item click with no current event; triggering reflow", level: .debug)
            coordinator.reflowAllVisibleWindows(reason: "status-left-click")
            return
        }

        switch event.type {
        case .rightMouseUp:
            guard let statusItem, let statusMenu else {
                return
            }
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        case .leftMouseUp:
            coordinator.reflowAllVisibleWindows(reason: "status-left-click")
        default:
            break
        }
    }

    @objc
    private func reflowNow() {
        Diagnostics.log("Manual reflow requested from menu", level: .info)
        coordinator.reflowAllVisibleWindows(reason: "menu")
    }

    @objc
    private func openFloatingRules() {
        Diagnostics.log("Floating rules panel requested", level: .info)
        coordinator.showRulesPanel()
    }

    @objc
    private func quitApp() {
        Diagnostics.log("Quit selected from menu", level: .info)
        NSApp.terminate(nil)
    }
}
