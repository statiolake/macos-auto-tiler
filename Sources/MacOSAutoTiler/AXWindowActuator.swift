import ApplicationServices
import CoreGraphics
import Foundation

final class AXWindowActuator {
    private let applyOriginThreshold: CGFloat = 1.0
    private let applySizeThreshold: CGFloat = 1.0
    private let axEnhancedUserInterfaceAttribute: CFString = "AXEnhancedUserInterface" as CFString

    func apply(targetFrames: [CGWindowID: CGRect], windows: [CGWindowID: WindowRef]) -> [CGWindowID] {
        let sortedIDs = targetFrames.keys.sorted()
        Diagnostics.log("AX apply start for \(sortedIDs.count) windows", level: .debug)
        var failures: [CGWindowID] = []

        for windowID in sortedIDs {
            guard
                let target = targetFrames[windowID],
                let window = windows[windowID],
                let axWindow = resolveAXWindow(for: window)
            else {
                Diagnostics.log("AX resolve failed for windowID=\(windowID)", level: .warn)
                failures.append(windowID)
                continue
            }

            let success = setFrame(target, on: axWindow, windowID: windowID, pid: window.pid)
            if !success {
                failures.append(windowID)
            }
        }

        Diagnostics.log("AX apply completed with failures=\(failures.count)", level: .debug)
        return failures.sorted()
    }

    private func resolveAXWindow(for window: WindowRef) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard windowsResult == .success, let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
            return nil
        }

        var bestWindow: AXUIElement?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for axWindow in axWindows {
            guard let candidateFrame = copyFrame(of: axWindow) else {
                continue
            }
            let score = frameDistance(candidateFrame, window.frame)
            if score < bestScore {
                bestScore = score
                bestWindow = axWindow
            }
        }

        guard let resolved = bestWindow else {
            Diagnostics.log("No matching AX window found for CG windowID=\(window.windowID)", level: .warn)
            return nil
        }
        return resolved
    }

    private func copyFrame(of axWindow: AXUIElement) -> CGRect? {
        guard
            let position = copyCGPoint(attribute: kAXPositionAttribute as CFString, from: axWindow),
            let size = copyCGSize(attribute: kAXSizeAttribute as CFString, from: axWindow)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func copyCGPoint(attribute: CFString, from element: AXUIElement) -> CGPoint? {
        guard let axValue = copyAXValue(attribute: attribute, from: element, type: .cgPoint) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copyCGSize(attribute: CFString, from element: AXUIElement) -> CGSize? {
        guard let axValue = copyAXValue(attribute: attribute, from: element, type: .cgSize) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func copyAXValue(attribute: CFString, from element: AXUIElement, type: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard
            result == .success,
            let rawValue = value,
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == type else {
            return nil
        }
        return axValue
    }

    private func setPosition(_ point: CGPoint, on axWindow: AXUIElement) -> AXError {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on axWindow: AXUIElement) -> AXError {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
    }

    private func setFrame(_ frame: CGRect, on axWindow: AXUIElement, windowID: CGWindowID, pid: pid_t?) -> Bool {
        let work: () -> Bool = { [self] in
            let current = self.copyFrame(of: axWindow)
            let canSetPosition = self.isAttributeSettable(kAXPositionAttribute as CFString, on: axWindow)
            let canSetSize = self.isAttributeSettable(kAXSizeAttribute as CFString, on: axWindow)

            let shouldSetPosition: Bool = {
                guard canSetPosition else { return false }
                guard let current else { return true }
                return
                    abs(current.origin.x - frame.origin.x) >= self.applyOriginThreshold ||
                    abs(current.origin.y - frame.origin.y) >= self.applyOriginThreshold
            }()

            let shouldSetSize: Bool = {
                guard canSetSize else { return false }
                guard let current else { return true }
                return
                    abs(current.size.width - frame.size.width) >= self.applySizeThreshold ||
                    abs(current.size.height - frame.size.height) >= self.applySizeThreshold
            }()

            if !shouldSetPosition, !shouldSetSize {
                return true
            }

            let sizeResultA: AXError = shouldSetSize ? self.setSize(frame.size, on: axWindow) : .success
            let positionResult: AXError = shouldSetPosition ? self.setPosition(frame.origin, on: axWindow) : .success
            let sizeResultB: AXError = shouldSetSize ? self.setSize(frame.size, on: axWindow) : .success

            let ok = sizeResultA == .success && positionResult == .success && sizeResultB == .success
            if !ok {
                Diagnostics.log(
                    "AX set failed windowID=\(windowID) canSetSize=\(canSetSize) canSetPosition=\(canSetPosition) sizeA=\(sizeResultA.rawValue) pos=\(positionResult.rawValue) sizeB=\(sizeResultB.rawValue) target=\(frame)",
                    level: .warn
                )
            }
            return ok
        }

        guard let pid else {
            return work()
        }
        return withEnhancedUIIfNeededDisabled(pid: pid, operation: work)
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return result == .success && settable.boolValue
    }

    private func withEnhancedUIIfNeededDisabled(pid: pid_t, operation: () -> Bool) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        guard
            let flag = copyBooleanAttribute(axEnhancedUserInterfaceAttribute, from: appElement)
        else {
            return operation()
        }

        if !flag {
            return operation()
        }

        _ = setBooleanAttribute(axEnhancedUserInterfaceAttribute, on: appElement, value: false)
        defer {
            _ = setBooleanAttribute(axEnhancedUserInterfaceAttribute, on: appElement, value: true)
        }
        return operation()
    }

    private func copyBooleanAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else {
            return nil
        }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else {
            return nil
        }
        let boolValue = unsafeBitCast(raw, to: CFBoolean.self)
        return CFBooleanGetValue(boolValue)
    }

    private func setBooleanAttribute(_ attribute: CFString, on element: AXUIElement, value: Bool) -> Bool {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute, cfValue) == .success
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDistance = GeometryUtils.centerDistance(lhs, rhs)
        let sizeDistance = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDistance + sizeDistance
    }
}
