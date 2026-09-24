import ApplicationServices
import CoreGraphics
import Foundation

/// Moves and resizes windows through AX on a private serial queue, so a slow or hung app never stalls the
/// main thread (and with it the event tap).
final class AXWindowActuator {
    private static let applyThreshold: CGFloat = 1
    /// CG and AX disagree this much only while the window server is mid-transition (e.g. a space switch).
    private static let mismatchOriginThreshold: CGFloat = 120
    private static let mismatchSizeThreshold: CGFloat = 80
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    private let resolver: AXWindowResolver
    private let queue = DispatchQueue(label: "macos-auto-tiler.ax-actuation")

    init(resolver: AXWindowResolver) {
        self.resolver = resolver
    }

    func apply(_ jobs: [(window: ObservedWindow, target: CGRect)], reason: String) {
        Diagnostics.log("Apply (\(reason)) targets=\(jobs.count)", level: .debug)
        queue.async { [self] in
            let failures = applySync(jobs, reason: reason)
            if !failures.isEmpty {
                Diagnostics.log("Apply (\(reason)) failed for windows \(failures)", level: .warn)
            }
        }
    }

    private func applySync(_ jobs: [(window: ObservedWindow, target: CGRect)], reason: String) -> [CGWindowID] {
        var resolvedByPID: [pid_t: [CGWindowID: AXWindowResolver.ResolvedWindow]] = [:]
        var failures: [CGWindowID] = []
        var resolvedJobs: [(window: ObservedWindow, target: CGRect, ax: AXWindowResolver.ResolvedWindow)] = []

        // Resolve everything first: if any window is mid-transition, applying part of the batch would leave
        // the layout half-updated.
        for job in jobs.sorted(by: { $0.window.windowID < $1.window.windowID }) {
            let perPID = resolvedByPID[job.window.pid] ?? resolver.windowsByID(pid: job.window.pid)
            resolvedByPID[job.window.pid] = perPID
            guard let ax = perPID[job.window.windowID] else {
                Diagnostics.log("AX resolve failed \(describe(job.window))", level: .warn)
                failures.append(job.window.windowID)
                continue
            }
            if let axFrame = ax.frame, isInTransition(cgFrame: job.window.frame, axFrame: axFrame) {
                Diagnostics.log(
                    "Apply (\(reason)) canceled: CG/AX frame mismatch \(describe(job.window)) axFrame=\(axFrame)",
                    level: .warn
                )
                return jobs.map(\.window.windowID)
            }
            resolvedJobs.append((job.window, job.target, ax))
        }

        for job in resolvedJobs where !setFrame(job.target, on: job.ax, pid: job.window.pid) {
            Diagnostics.log("AX set frame failed \(describe(job.window)) target=\(job.target)", level: .warn)
            failures.append(job.window.windowID)
        }
        return failures
    }

    private func isInTransition(cgFrame: CGRect, axFrame: CGRect) -> Bool {
        abs(cgFrame.minX - axFrame.minX) > Self.mismatchOriginThreshold
            || abs(cgFrame.minY - axFrame.minY) > Self.mismatchOriginThreshold
            || abs(cgFrame.width - axFrame.width) > Self.mismatchSizeThreshold
            || abs(cgFrame.height - axFrame.height) > Self.mismatchSizeThreshold
    }

    private func setFrame(_ frame: CGRect, on ax: AXWindowResolver.ResolvedWindow, pid: pid_t) -> Bool {
        let current = AXValueUtils.copyFrame(of: ax.element)
        let needsPosition = ax.canSetPosition && current.map {
            abs($0.minX - frame.minX) >= Self.applyThreshold || abs($0.minY - frame.minY) >= Self.applyThreshold
        } ?? ax.canSetPosition
        let needsSize = ax.canSetSize && current.map {
            abs($0.width - frame.width) >= Self.applyThreshold || abs($0.height - frame.height) >= Self.applyThreshold
        } ?? ax.canSetSize
        guard needsPosition || needsSize else { return true }

        return withEnhancedUserInterfaceDisabled(pid: pid) {
            // Size, position, size: shrinking first lets the move succeed near screen edges, and resizing again
            // fixes apps that clamp the size relative to the old position.
            var results: [AXError] = []
            if needsSize { results.append(AXValueUtils.setSize(frame.size, on: ax.element)) }
            if needsPosition { results.append(AXValueUtils.setPosition(frame.origin, on: ax.element)) }
            if needsSize { results.append(AXValueUtils.setSize(frame.size, on: ax.element)) }
            return results.allSatisfy { $0 == .success }
        }
    }

    /// Apps with AXEnhancedUserInterface enabled (set by assistive tools) animate AX frame changes, which
    /// makes consecutive position/size writes race each other.
    private func withEnhancedUserInterfaceDisabled(pid: pid_t, _ operation: () -> Bool) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, Self.enhancedUserInterfaceAttribute, &value) == .success,
            let enabled = value as? Bool,
            enabled
        else {
            return operation()
        }
        AXUIElementSetAttributeValue(appElement, Self.enhancedUserInterfaceAttribute, kCFBooleanFalse)
        defer { AXUIElementSetAttributeValue(appElement, Self.enhancedUserInterfaceAttribute, kCFBooleanTrue) }
        return operation()
    }

    private func describe(_ window: ObservedWindow) -> String {
        "windowID=\(window.windowID) app=\(window.appName) title=\"\(window.title)\" frame=\(window.frame)"
    }
}
