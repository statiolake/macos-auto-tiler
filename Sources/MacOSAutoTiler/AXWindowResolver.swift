import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class AXWindowResolver {
    static let shared = AXWindowResolver()

    struct ResolvedWindow {
        let element: AXUIElement
        let windowID: CGWindowID
        let frame: CGRect?
        let role: String
        let subrole: String
        let canSetPosition: Bool
        let canSetSize: Bool
    }

    private typealias AXUIElementGetWindowFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let axWindowNumberAttribute: CFString = "AXWindowNumber" as CFString
    private static let getWindowFunction: AXUIElementGetWindowFunction? = AXWindowResolver.loadGetWindowFunction()

    func window(pid: pid_t, windowID: CGWindowID) -> ResolvedWindow? {
        windowsByID(pid: pid)[windowID]
    }

    func windowsByID(pid: pid_t) -> [CGWindowID: ResolvedWindow] {
        guard pid > 0 else {
            return [:]
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard
            windowsResult == .success,
            let axWindows = windowsValue as? [AXUIElement],
            !axWindows.isEmpty
        else {
            return [:]
        }

        var result: [CGWindowID: ResolvedWindow] = [:]
        result.reserveCapacity(axWindows.count)

        for element in axWindows {
            guard let windowID = copyWindowID(from: element) else {
                continue
            }
            guard result[windowID] == nil else {
                continue
            }

            let resolved = ResolvedWindow(
                element: element,
                windowID: windowID,
                frame: copyFrame(of: element),
                role: copyStringAttribute(kAXRoleAttribute as CFString, from: element) ?? "Unknown",
                subrole: copyStringAttribute(kAXSubroleAttribute as CFString, from: element) ?? "Unknown",
                canSetPosition: isAttributeSettable(kAXPositionAttribute as CFString, on: element),
                canSetSize: isAttributeSettable(kAXSizeAttribute as CFString, on: element)
            )
            result[windowID] = resolved
        }

        return result
    }

    private func copyWindowID(from element: AXUIElement) -> CGWindowID? {
        if let windowID = copyWindowIDUsingSymbol(from: element) {
            return windowID
        }
        return copyWindowIDUsingAttribute(from: element)
    }

    private func copyWindowIDUsingSymbol(from element: AXUIElement) -> CGWindowID? {
        guard let getWindowFunction = Self.getWindowFunction else {
            return nil
        }
        var windowID = CGWindowID(0)
        let result = getWindowFunction(element, &windowID)
        guard result == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    private func copyWindowIDUsingAttribute(from element: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, axWindowNumberAttribute, &value)
        guard result == .success, let number = value as? NSNumber else {
            return nil
        }
        return CGWindowID(number.uint32Value)
    }

    private func copyFrame(of element: AXUIElement) -> CGRect? {
        guard
            let position = copyCGPointAttribute(kAXPositionAttribute as CFString, from: element),
            let size = copyCGSizeAttribute(kAXSizeAttribute as CFString, from: element)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private func copyCGPointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        guard let axValue = copyAXValue(attribute: attribute, from: element, type: .cgPoint) else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func copyCGSizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        guard let axValue = copyAXValue(attribute: attribute, from: element, type: .cgSize) else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func copyAXValue(attribute: CFString, from element: AXUIElement, type: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return result == .success && settable.boolValue
    }

    private static func loadGetWindowFunction() -> AXUIElementGetWindowFunction? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ) else {
            Diagnostics.log(
                "AXWindowResolver could not open ApplicationServices handle; falling back to AXWindowNumber attribute",
                level: .warn
            )
            return nil
        }

        guard
            let symbol = dlsym(handle, "AXUIElementGetWindow") ?? dlsym(handle, "_AXUIElementGetWindow")
        else {
            Diagnostics.log(
                "AXWindowResolver could not load AXUIElementGetWindow; falling back to AXWindowNumber attribute",
                level: .warn
            )
            return nil
        }

        return unsafeBitCast(symbol, to: AXUIElementGetWindowFunction.self)
    }
}
