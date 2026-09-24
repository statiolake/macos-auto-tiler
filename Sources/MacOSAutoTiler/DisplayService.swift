import AppKit
import CoreGraphics

/// Display geometry in Quartz global coordinates (origin at the top-left of the main display, Y down),
/// which is what CGWindow, AX and CGEvent use.
enum DisplayService {
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            preconditionFailure("CGGetActiveDisplayList failed")
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            preconditionFailure("CGGetActiveDisplayList failed")
        }
        return Array(displays.prefix(Int(count)))
    }

    static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else {
            return nil
        }
        return displayID
    }

    /// The display showing the largest part of `frame`.
    static func displayID(for frame: CGRect) -> CGDirectDisplayID? {
        activeDisplayIDs()
            .map { (displayID: $0, overlap: frame.intersection(CGDisplayBounds($0))) }
            .filter { !$0.overlap.isNull && !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .displayID
    }

    /// The display area not covered by the menu bar and the Dock. Nil while AppKit has not caught up with a
    /// display reconfiguration yet.
    static func visibleBounds(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let displayScreen = screen(for: displayID), let mainScreen = screen(for: CGMainDisplayID()) else {
            return nil
        }
        // NSScreen is in Cocoa coordinates (origin at the bottom-left of the main display, Y up).
        let visible = displayScreen.visibleFrame
        return CGRect(
            x: visible.minX,
            y: mainScreen.frame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
