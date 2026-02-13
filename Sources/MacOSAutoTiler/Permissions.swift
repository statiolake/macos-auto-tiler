import ApplicationServices
import Foundation

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
}
