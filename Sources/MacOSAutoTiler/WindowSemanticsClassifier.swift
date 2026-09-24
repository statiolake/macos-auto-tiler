import ApplicationServices
import CoreGraphics

struct WindowSemantics {
    let descriptor: WindowTypeDescriptor
    /// A movable window with the standard role and subrole; dialogs, sheets, panels and the like are not.
    let isStandardWindow: Bool
}

/// Caches the AX role/subrole of windows. AX queries are slow, and a window's kind never changes.
final class WindowSemanticsClassifier {
    private let resolver: AXWindowResolver
    private var cache: [CGWindowID: WindowSemantics] = [:]

    init(resolver: AXWindowResolver) {
        self.resolver = resolver
    }

    /// Nil while the window is not resolvable through AX yet (e.g. right after creation). Not cached, so the
    /// next snapshot asks again.
    func semantics(windowID: CGWindowID, pid: pid_t) -> WindowSemantics? {
        if let cached = cache[windowID] {
            return cached
        }
        guard let resolved = resolver.window(pid: pid, windowID: windowID) else {
            return nil
        }
        let semantics = WindowSemantics(
            descriptor: WindowTypeDescriptor(role: resolved.role, subrole: resolved.subrole),
            isStandardWindow: resolved.role == kAXWindowRole
                && resolved.subrole == kAXStandardWindowSubrole
                && resolved.canSetPosition
        )
        cache[windowID] = semantics
        return semantics
    }

    func prune(to liveWindowIDs: Set<CGWindowID>) {
        cache = cache.filter { liveWindowIDs.contains($0.key) }
    }
}
