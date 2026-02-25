import ApplicationServices
import CoreGraphics
import Foundation

final class AXWindowActuator {
    private let resolver: AXWindowResolver
    private let applyOriginThreshold: CGFloat = 1.0
    private let applySizeThreshold: CGFloat = 1.0
    private let frameMismatchOriginThreshold: CGFloat = 120.0
    private let frameMismatchSizeThreshold: CGFloat = 80.0
    private let axEnhancedUserInterfaceAttribute: CFString = "AXEnhancedUserInterface" as CFString

    init(resolver: AXWindowResolver = AXWindowResolver()) {
        self.resolver = resolver
    }

    func apply(reason: String, targetFrames: [CGWindowID: CGRect], windows: [CGWindowID: WindowRef]) -> [CGWindowID] {
        let sortedIDs = targetFrames.keys.sorted()
        Diagnostics.log("AX apply start for \(sortedIDs.count) windows", level: .debug)
        var failures: [CGWindowID] = []
        var resolvedByPID: [pid_t: [CGWindowID: AXWindowResolver.ResolvedWindow]] = [:]

        // Resolve every target before applying any frame so same-app operations stay deterministic.
        var resolved: [(windowID: CGWindowID, resolvedAX: AXWindowResolver.ResolvedWindow, target: CGRect, window: WindowRef)] = []
        for windowID in sortedIDs {
            guard let target = targetFrames[windowID] else {
                Diagnostics.log("AX apply skipped windowID=\(windowID): missing target frame", level: .warn)
                failures.append(windowID)
                continue
            }
            guard let window = windows[windowID] else {
                Diagnostics.log("AX apply skipped windowID=\(windowID): missing WindowRef", level: .warn)
                failures.append(windowID)
                continue
            }

            let perPID = resolvedByPID[window.pid] ?? resolver.windowsByID(pid: window.pid)
            resolvedByPID[window.pid] = perPID

            guard let resolvedAX = perPID[window.windowID] else {
                logResolveFailure(
                    window: window,
                    target: target,
                    knownWindowIDs: perPID.keys.sorted()
                )
                failures.append(windowID)
                continue
            }
            logResolvedTarget(window: window, target: target, resolvedAX: resolvedAX)
            resolved.append((windowID: windowID, resolvedAX: resolvedAX, target: target, window: window))
        }

        if let mismatch = firstCriticalFrameMismatch(in: resolved) {
            Diagnostics.log(
                "AX apply canceled reason=\(reason): CG/AX frame mismatch \(windowSummary(mismatch.window)) cgFrame=\(mismatch.cgFrame) axFrame=\(mismatch.axFrame) dx=\(mismatch.dx) dy=\(mismatch.dy) dw=\(mismatch.dw) dh=\(mismatch.dh) thresholds=(origin:\(frameMismatchOriginThreshold),size:\(frameMismatchSizeThreshold))",
                level: .warn
            )
            let aborted = Set(sortedIDs).union(failures)
            return aborted.sorted()
        }

        for entry in resolved {
            let success = setFrame(entry.target, on: entry.resolvedAX, window: entry.window)
            if !success {
                failures.append(entry.windowID)
            }
        }

        Diagnostics.log("AX apply completed with failures=\(failures.count)", level: .debug)
        return failures.sorted()
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

    private func setFrame(
        _ frame: CGRect,
        on resolvedAX: AXWindowResolver.ResolvedWindow,
        window: WindowRef
    ) -> Bool {
        let work: () -> Bool = { [self] in
            let axWindow = resolvedAX.element
            let current = AXValueUtils.copyFrame(of: axWindow)
            let canSetPosition = resolvedAX.canSetPosition
            let canSetSize = resolvedAX.canSetSize

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
                    "AX set failed \(self.windowSummary(window)) role=\(resolvedAX.role) subrole=\(resolvedAX.subrole) canSetSize=\(canSetSize) canSetPosition=\(canSetPosition) sizeA=\(sizeResultA.rawValue) pos=\(positionResult.rawValue) sizeB=\(sizeResultB.rawValue) current=\(String(describing: current)) target=\(frame)",
                    level: .warn
                )
            }
            return ok
        }

        let pid = window.pid
        guard pid > 0 else {
            return work()
        }
        return withEnhancedUIIfNeededDisabled(pid: pid, operation: work)
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

    private func windowSummary(_ window: WindowRef) -> String {
        let bundle = window.bundleID ?? "-"
        return "windowID=\(window.windowID) pid=\(window.pid) app=\(window.appName) bundle=\(bundle) title=\"\(window.title)\" frame=\(window.frame)"
    }

    private func logResolveFailure(window: WindowRef, target: CGRect, knownWindowIDs: [CGWindowID]) {
        let known = knownWindowIDs.map(String.init).joined(separator: ",")
        Diagnostics.log(
            "AX resolve failed exact \(windowSummary(window)) target=\(target) knownAXWindowIDs=[\(known)]",
            level: .warn
        )
    }

    private func logResolvedTarget(
        window: WindowRef,
        target: CGRect,
        resolvedAX: AXWindowResolver.ResolvedWindow
    ) {
        Diagnostics.log(
            "AX resolved exact \(windowSummary(window)) resolvedWindowID=\(resolvedAX.windowID) role=\(resolvedAX.role) subrole=\(resolvedAX.subrole) canSetPos=\(resolvedAX.canSetPosition) canSetSize=\(resolvedAX.canSetSize) cgFrame=\(window.frame) axFrame=\(String(describing: resolvedAX.frame)) target=\(target)",
            level: .debug
        )
    }

    private struct FrameMismatch {
        let window: WindowRef
        let cgFrame: CGRect
        let axFrame: CGRect
        let dx: CGFloat
        let dy: CGFloat
        let dw: CGFloat
        let dh: CGFloat
    }

    private func firstCriticalFrameMismatch(
        in resolved: [(windowID: CGWindowID, resolvedAX: AXWindowResolver.ResolvedWindow, target: CGRect, window: WindowRef)]
    ) -> FrameMismatch? {
        for entry in resolved {
            guard let axFrame = entry.resolvedAX.frame else {
                continue
            }
            let cgFrame = entry.window.frame
            let dx = abs(cgFrame.origin.x - axFrame.origin.x)
            let dy = abs(cgFrame.origin.y - axFrame.origin.y)
            let dw = abs(cgFrame.size.width - axFrame.size.width)
            let dh = abs(cgFrame.size.height - axFrame.size.height)
            guard
                dx > frameMismatchOriginThreshold
                    || dy > frameMismatchOriginThreshold
                    || dw > frameMismatchSizeThreshold
                    || dh > frameMismatchSizeThreshold
            else {
                continue
            }
            return FrameMismatch(
                window: entry.window,
                cgFrame: cgFrame,
                axFrame: axFrame,
                dx: dx,
                dy: dy,
                dw: dw,
                dh: dh
            )
        }
        return nil
    }
}
