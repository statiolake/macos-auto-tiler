import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = TilerCoordinator()
    private let startupPermissionFlow = StartupPermissionFlow()
    private var statusItem: NSStatusItem?

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
        statusItem.button?.title = "Tiler"
        statusItem.button?.toolTip = "macOS Auto Tiler"

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
        statusItem.menu = menu

        self.statusItem = statusItem
        Diagnostics.log("Menu bar item initialized", level: .debug)
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
