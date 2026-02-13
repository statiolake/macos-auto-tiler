import ApplicationServices
import CoreGraphics
import Foundation

final class AXWindowActuator {
    private var cache: [CGWindowID: AXUIElement] = [:]
    private let maxAttempts = 3
    private let settleDelay: TimeInterval = 0.04
    private let originTolerance: CGFloat = 2.0
    private let sizeTolerance: CGFloat = 3.0

    func apply(targetFrames: [CGWindowID: CGRect], windows: [CGWindowID: WindowRef]) -> [CGWindowID] {
        let sortedIDs = targetFrames.keys.sorted()
        Diagnostics.log("AX apply start for \(sortedIDs.count) windows", level: .debug)
        var failures: [CGWindowID] = []
        var resolved: [CGWindowID: AXUIElement] = [:]

        for windowID in sortedIDs {
            guard
                let window = windows[windowID],
                let axWindow = resolveAXWindow(for: window)
            else {
                Diagnostics.log("AX resolve failed for windowID=\(windowID)", level: .warn)
                failures.append(windowID)
                continue
            }
            resolved[windowID] = axWindow
        }

        var pending = Set(resolved.keys)
        if !pending.isEmpty {
            for attempt in 1...maxAttempts {
                if pending.isEmpty {
                    break
                }
                Diagnostics.log("AX apply attempt=\(attempt) pending=\(pending.count)", level: .debug)

                for windowID in pending {
                    guard
                        let target = targetFrames[windowID],
                        let axWindow = resolved[windowID]
                    else {
                        continue
                    }
                    _ = setFrame(target, on: axWindow, windowID: windowID)
                }

                Thread.sleep(forTimeInterval: settleDelay)

                var stillPending: Set<CGWindowID> = []
                for windowID in pending {
                    guard
                        let target = targetFrames[windowID],
                        let axWindow = resolved[windowID]
                    else {
                        stillPending.insert(windowID)
                        continue
                    }
                    guard let actual = copyFrame(of: axWindow) else {
                        stillPending.insert(windowID)
                        continue
                    }
                    if !isFrameClose(actual, target) {
                        stillPending.insert(windowID)
                        Diagnostics.log(
                            "AX frame mismatch windowID=\(windowID) target=\(target) actual=\(actual)",
                            level: .debug
                        )
                    }
                }
                pending = stillPending
            }
        }

        for windowID in pending {
            cache.removeValue(forKey: windowID)
            failures.append(windowID)
            Diagnostics.log("AX frame did not converge windowID=\(windowID)", level: .warn)
        }

        Diagnostics.log("AX apply completed with failures=\(failures.count)", level: .debug)
        return failures.sorted()
    }

    private func resolveAXWindow(for window: WindowRef) -> AXUIElement? {
        if let cached = cache[window.windowID] {
            return cached
        }
        if let explicit = window.axWindow {
            cache[window.windowID] = explicit
            return explicit
        }

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
        cache[window.windowID] = resolved
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
        guard
            AXValueGetType(axValue) == .cgPoint
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copyCGSize(attribute: CFString, from element: AXUIElement) -> CGSize? {
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
        guard
            AXValueGetType(axValue) == .cgSize
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
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

    private func setFrame(_ frame: CGRect, on axWindow: AXUIElement, windowID: CGWindowID) -> Bool {
        let sizeResultA = setSize(frame.size, on: axWindow)
        let positionResultA = setPosition(frame.origin, on: axWindow)
        if sizeResultA == .success, positionResultA == .success {
            return true
        }

        let positionResultB = setPosition(frame.origin, on: axWindow)
        let sizeResultB = setSize(frame.size, on: axWindow)
        if positionResultB == .success, sizeResultB == .success {
            return true
        }

        Diagnostics.log(
            "AX set failed windowID=\(windowID) sizeA=\(sizeResultA.rawValue) posA=\(positionResultA.rawValue) posB=\(positionResultB.rawValue) sizeB=\(sizeResultB.rawValue) target=\(frame)",
            level: .warn
        )
        return false
    }

    private func isFrameClose(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.origin.x - target.origin.x) <= originTolerance &&
            abs(actual.origin.y - target.origin.y) <= originTolerance &&
            abs(actual.size.width - target.size.width) <= sizeTolerance &&
            abs(actual.size.height - target.size.height) <= sizeTolerance
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        let sizeDistance = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDistance + sizeDistance
    }
}
