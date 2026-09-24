import ApplicationServices
import CoreGraphics
import Darwin

/// Maps window-server window IDs to AX elements.
final class AXWindowResolver {
    struct ResolvedWindow {
        let element: AXUIElement
        let windowID: CGWindowID
        let frame: CGRect?
        let role: String
        let subrole: String
        let canSetPosition: Bool
        let canSetSize: Bool
    }

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Private but long-standing; every window manager for macOS relies on it.
    private static let getWindow: GetWindowFunction = {
        guard
            let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let symbol = dlsym(handle, "_AXUIElementGetWindow")
        else {
            fatalError("_AXUIElementGetWindow is unavailable on this macOS version")
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    func window(pid: pid_t, windowID: CGWindowID) -> ResolvedWindow? {
        windowsByID(pid: pid)[windowID]
    }

    func windowsByID(pid: pid_t) -> [CGWindowID: ResolvedWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let axWindows = windowsValue as? [AXUIElement]
        else {
            return [:]
        }

        var result: [CGWindowID: ResolvedWindow] = [:]
        for element in axWindows {
            var windowID = CGWindowID(0)
            guard Self.getWindow(element, &windowID) == .success, windowID != 0, result[windowID] == nil else {
                continue
            }
            result[windowID] = ResolvedWindow(
                element: element,
                windowID: windowID,
                frame: AXValueUtils.copyFrame(of: element),
                role: copyString(kAXRoleAttribute, from: element) ?? "Unknown",
                subrole: copyString(kAXSubroleAttribute, from: element) ?? "Unknown",
                canSetPosition: isSettable(kAXPositionAttribute, on: element),
                canSetSize: isSettable(kAXSizeAttribute, on: element)
            )
        }
        return result
    }

    private func copyString(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
}
