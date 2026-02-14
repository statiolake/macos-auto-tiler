import ApplicationServices
import Foundation
import AppKit

enum Permissions {
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Diagnostics.log(
            "Accessibility trust check (prompt=\(prompt)) => \(trusted)",
            level: trusted ? .debug : .warn
        )
        return trusted
    }

    static func ensureInputMonitoringPermission() -> Bool {
        // Probe by creating a minimal event tap.
        let testMask = (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: testMask,
            callback: { _, _, event, _ in
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) != nil else {
            Diagnostics.log("Input Monitoring permission check failed", level: .warn)
            return false
        }
        Diagnostics.log("Input Monitoring permission granted", level: .debug)
        return true
    }

    static func openSystemSettingsForInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring") {
            NSWorkspace.shared.open(url)
        } else {
            // fallback: 全般のセキュリティ設定を開く
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    static func presentInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring Permission Needed"
        alert.informativeText = "To detect mouse drag events, the app needs Input Monitoring permission.\n\nGo to System Settings → Privacy & Security → Input Monitoring and enable it for this app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            openSystemSettingsForInputMonitoring()
        }
    }
}
