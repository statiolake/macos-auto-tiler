import ApplicationServices
import CoreGraphics
import Foundation

struct WindowSemantics {
    let descriptor: WindowTypeDescriptor
    let isSpecialFloating: Bool
    let isManageable: Bool
}

final class WindowSemanticsClassifier {
    private let resolver: AXWindowResolver
    private var cache: [CGWindowID: WindowSemantics] = [:]

    init(resolver: AXWindowResolver = AXWindowResolver()) {
        self.resolver = resolver
    }

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
        guard let resolvedAX = resolver.window(pid: window.pid, windowID: window.windowID) else {
            Diagnostics.log(
                "Window semantics unresolved windowID=\(window.windowID) pid=\(window.pid) app=\(window.appName) title=\"\(window.title)\"",
                level: .debug
            )
            return WindowSemantics(
                descriptor: WindowTypeDescriptor(role: "AXWindow", subrole: "Unknown"),
                isSpecialFloating: true,
                isManageable: false
            )
        }
        let role = resolvedAX.role
        let subrole = resolvedAX.subrole
        let isStandardWindow = subrole == (kAXStandardWindowSubrole as String)
        let isMovable = resolvedAX.canSetPosition
        let isManageable = (role == (kAXWindowRole as String)) && isStandardWindow && isMovable

        let isSpecialFloating = !isManageable || floatingRoles.contains(role) || floatingSubroles.contains(subrole)
        if !isManageable {
            Diagnostics.log(
                "Window semantics marked non-manageable windowID=\(window.windowID) app=\(window.appName) title=\"\(window.title)\" role=\(role) subrole=\(subrole) movable=\(isMovable)",
                level: .debug
            )
        }
        return WindowSemantics(
            descriptor: WindowTypeDescriptor(role: role, subrole: subrole),
            isSpecialFloating: isSpecialFloating,
            isManageable: isManageable
        )
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
