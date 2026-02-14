import AppKit
import CoreGraphics

enum DisplayService {
    static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let error = CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        guard error == .success, count > 0 else {
            return nil
        }
        return displayID
    }

    static func bounds(for displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    static func visibleBounds(for displayID: CGDirectDisplayID) -> CGRect {
        guard let screen = screen(for: displayID) else {
            return bounds(for: displayID)
        }

        // NSScreen uses Cocoa coordinates (origin at bottom-left of main display),
        // while CGWindow/AX frames are in Quartz global coordinates (origin at top-left).
        let visible = screen.visibleFrame
        let mainTopY = mainScreenFrame().maxY
        let quartzY = mainTopY - visible.maxY
        return CGRect(x: visible.minX, y: quartzY, width: visible.width, height: visible.height)
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return raw.uint32Value == displayID
        }
    }

    private static func mainScreenFrame() -> CGRect {
        let mainID = CGMainDisplayID()
        if let screen = screen(for: mainID) {
            return screen.frame
        }
        return NSScreen.screens.first?.frame ?? .zero
    }
}
