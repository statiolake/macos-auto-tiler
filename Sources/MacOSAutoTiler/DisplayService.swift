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

    static func displayID(for frame: CGRect) -> CGDirectDisplayID? {
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
            return nil
        }

        var bestDisplayID: CGDirectDisplayID?
        var bestArea: CGFloat = 0

        for displayID in activeDisplayIDs() {
            let intersection = frame.intersection(bounds(for: displayID))
            guard !intersection.isNull, !intersection.isEmpty else {
                continue
            }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestDisplayID = displayID
            }
        }

        if let bestDisplayID {
            return bestDisplayID
        }

        // Fallback keeps behavior stable when no intersection is reported.
        let midpoint = CGPoint(x: frame.midX, y: frame.midY)
        return displayID(containing: midpoint)
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

    static func isPointInDockRegion(_ point: CGPoint) -> Bool {
        guard let displayID = displayID(containing: point) else {
            return false
        }
        let full = bounds(for: displayID)
        let visible = visibleBounds(for: displayID)

        // Bottom Dock
        if point.y > visible.maxY && point.y <= full.maxY {
            return true
        }
        // Left Dock
        if point.x >= full.minX && point.x < visible.minX {
            return true
        }
        // Right Dock
        if point.x > visible.maxX && point.x <= full.maxX {
            return true
        }
        return false
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
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

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &count)
        guard countResult == .success, count > 0 else {
            return []
        }

        var displays = Array<CGDirectDisplayID>(repeating: 0, count: Int(count))
        var actualCount: UInt32 = 0
        let listResult = CGGetActiveDisplayList(count, &displays, &actualCount)
        guard listResult == .success else {
            return []
        }
        return Array(displays.prefix(Int(actualCount)))
    }
}
