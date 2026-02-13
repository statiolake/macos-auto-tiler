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
}
