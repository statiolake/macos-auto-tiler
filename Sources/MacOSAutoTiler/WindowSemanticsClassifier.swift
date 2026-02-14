import ApplicationServices
import CoreGraphics
import Foundation

struct WindowSemantics {
    let descriptor: WindowTypeDescriptor
    let isSpecialFloating: Bool
}

final class WindowSemanticsClassifier {
    private var cache: [CGWindowID: WindowSemantics] = [:]

    func semantics(for window: WindowRef) -> WindowSemantics {
        if let cached = cache[window.windowID] {
            return cached
        }

        let semantics = classify(window: window)
        cache[window.windowID] = semantics
        return semantics
    }

    func prune(to liveWindowIDs: Set<CGWindowID>) {
        cache = cache.filter { liveWindowIDs.contains($0.key) }
    }

    private func classify(window: WindowRef) -> WindowSemantics {
        guard let axWindow = resolveAXWindow(window: window) else {
            return WindowSemantics(
                descriptor: WindowTypeDescriptor(role: "AXWindow", subrole: "Unknown"),
                isSpecialFloating: false
            )
        }

        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: axWindow) ?? "AXWindow"
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: axWindow) ?? "None"

        let isSpecialFloating = floatingRoles.contains(role) || floatingSubroles.contains(subrole)
        return WindowSemantics(
            descriptor: WindowTypeDescriptor(role: role, subrole: subrole),
            isSpecialFloating: isSpecialFloating
        )
    }

    private func resolveAXWindow(window: WindowRef) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.pid)
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
            return nil
        }

        var bestWindow: AXUIElement?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for candidate in axWindows {
            guard let frame = copyFrame(of: candidate) else {
                continue
            }
            let score = GeometryUtils.centerDistance(frame, window.frame)
                + abs(frame.width - window.frame.width)
                + abs(frame.height - window.frame.height)
            if score < bestScore {
                bestScore = score
                bestWindow = candidate
            }
        }

        return bestWindow
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

    private let floatingRoles: Set<String> = [
        "AXSheet",
        "AXDrawer",
        "AXPopover",
        "AXDialog",
        "AXSystemDialog",
    ]

    private let floatingSubroles: Set<String> = [
        "AXDialog",
        "AXSystemDialog",
        "AXFloatingWindow",
        "AXSystemFloatingWindow",
        "AXUtilityWindow",
    ]
}
