import AppKit

final class StartupPermissionFlow {
    func run() -> Bool {
        guard ensureAccessibilityPermission() else {
            return false
        }
        guard ensureInputMonitoringPermission() else {
            return false
        }
        return true
    }

    private func ensureAccessibilityPermission() -> Bool {
        if Permissions.ensureAccessibilityPermission(prompt: false) {
            return true
        }

        Diagnostics.log("Accessibility permission is missing at startup", level: .warn)

        while !Permissions.ensureAccessibilityPermission(prompt: false) {
            let response = showAlert(
                title: "Accessibility Permission Required",
                message:
                    "macOS Auto Tiler needs Accessibility permission to move and resize windows.\n\nEnable this app in System Settings → Privacy & Security → Accessibility, then click Retry.",
                primaryButton: "Open System Settings",
                secondaryButton: "Retry",
                tertiaryButton: "Quit"
            )

            switch response {
            case .alertFirstButtonReturn:
                Permissions.openSystemSettingsForAccessibility()
            case .alertSecondButtonReturn:
                continue
            default:
                Diagnostics.log("Startup cancelled while waiting for Accessibility permission", level: .warn)
                return false
            }
        }

        Diagnostics.log("Accessibility permission granted", level: .info)
        return true
    }

    private func ensureInputMonitoringPermission() -> Bool {
        if Permissions.ensureInputMonitoringPermission() {
            return true
        }

        Diagnostics.log("Input Monitoring permission is missing at startup", level: .warn)
        while !Permissions.ensureInputMonitoringPermission() {
            let response = showAlert(
                title: "Input Monitoring Permission Required",
                message:
                    "macOS Auto Tiler needs Input Monitoring permission to detect drag gestures.\n\nEnable this app in System Settings → Privacy & Security → Input Monitoring, then click Retry.",
                primaryButton: "Open System Settings",
                secondaryButton: "Retry",
                tertiaryButton: "Quit"
            )

            switch response {
            case .alertFirstButtonReturn:
                Permissions.openSystemSettingsForInputMonitoring()
            case .alertSecondButtonReturn:
                continue
            default:
                Diagnostics.log("Startup cancelled while waiting for Input Monitoring permission", level: .warn)
                return false
            }
        }

        Diagnostics.log("Input Monitoring permission granted", level: .info)
        return true
    }

    private func showAlert(
        title: String,
        message: String,
        primaryButton: String,
        secondaryButton: String,
        tertiaryButton: String
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: secondaryButton)
        alert.addButton(withTitle: tertiaryButton)

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
