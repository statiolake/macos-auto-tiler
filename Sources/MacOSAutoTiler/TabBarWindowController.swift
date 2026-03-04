import AppKit
import CoreGraphics

protocol TabBarWindowControllerDelegate: AnyObject {
    func tabBar(_ controller: TabBarWindowController, didSelectGroupID id: WindowGroupID, on displayID: CGDirectDisplayID)
    func tabBar(_ controller: TabBarWindowController, didRequestNewGroupOn displayID: CGDirectDisplayID)
    func tabBar(_ controller: TabBarWindowController, didDropWindowID windowID: CGWindowID, ontoGroupID groupID: WindowGroupID, on displayID: CGDirectDisplayID)
}

final class TabBarWindowController {
    static let barHeight: CGFloat = 44

    weak var delegate: TabBarWindowControllerDelegate?

    private var windowsByDisplayID: [CGDirectDisplayID: NSWindow] = [:]
    private var viewsByDisplayID: [CGDirectDisplayID: TabBarView] = [:]

    func setupWindows(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs where windowsByDisplayID[displayID] == nil {
            createWindow(for: displayID)
        }
    }

    func updateTabs(groups: [WindowGroup], activeGroupID: WindowGroupID?, for displayID: CGDirectDisplayID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.viewsByDisplayID[displayID] else { return }
            view.groups = groups
            view.activeGroupID = activeGroupID
            view.needsDisplay = true
        }
    }

    /// Hit-test a Quartz-coordinate point against all tab bar windows.
    func groupID(at quartzPoint: CGPoint) -> (groupID: WindowGroupID, displayID: CGDirectDisplayID)? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: quartzPoint.x, y: mainHeight - quartzPoint.y)

        for (displayID, window) in windowsByDisplayID {
            guard window.frame.contains(cocoaPoint) else { continue }
            let localX = cocoaPoint.x - window.frame.minX
            let localY = cocoaPoint.y - window.frame.minY
            // Convert Cocoa window-local (Y-up) to flipped view coordinates (Y-down from top).
            let viewPoint = CGPoint(x: localX, y: TabBarWindowController.barHeight - localY)
            guard
                let view = viewsByDisplayID[displayID],
                let groupID = view.groupID(at: viewPoint)
            else { continue }
            return (groupID, displayID)
        }
        return nil
    }

    func isPointInTabBar(_ quartzPoint: CGPoint) -> Bool {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: quartzPoint.x, y: mainHeight - quartzPoint.y)
        return windowsByDisplayID.values.contains { $0.frame.contains(cocoaPoint) }
    }

    // MARK: - Private

    private func createWindow(for displayID: CGDirectDisplayID) {
        guard let screen = DisplayService.screen(for: displayID) else { return }

        let visibleFrame = screen.visibleFrame
        let barRect = CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: TabBarWindowController.barHeight
        )

        let window = NSWindow(
            contentRect: barRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = TabBarView(frame: CGRect(origin: .zero, size: barRect.size))
        view.onSelectGroup = { [weak self, displayID] groupID in
            guard let self else { return }
            self.delegate?.tabBar(self, didSelectGroupID: groupID, on: displayID)
        }
        view.onNewGroup = { [weak self, displayID] in
            guard let self else { return }
            self.delegate?.tabBar(self, didRequestNewGroupOn: displayID)
        }

        window.contentView = view
        window.orderFrontRegardless()

        windowsByDisplayID[displayID] = window
        viewsByDisplayID[displayID] = view
    }
}

// MARK: - TabBarView

final class TabBarView: NSView {
    private static let tabWidth: CGFloat = 160
    private static let plusWidth: CGFloat = 36
    private static let tabHeight: CGFloat = 32
    private static let cornerRadius: CGFloat = 8
    private static let tabSpacing: CGFloat = 4
    private static let verticalInset: CGFloat = 6

    var groups: [WindowGroup] = []
    var activeGroupID: WindowGroupID?

    var onSelectGroup: ((WindowGroupID) -> Void)?
    var onNewGroup: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.92).setFill()
        dirtyRect.fill()

        var tabX: CGFloat = TabBarView.tabSpacing
        let tabY = TabBarView.verticalInset

        for group in groups {
            let rect = CGRect(x: tabX, y: tabY, width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            drawTab(group: group, in: rect)
            tabX += TabBarView.tabWidth + TabBarView.tabSpacing
        }

        let plusRect = CGRect(x: tabX, y: tabY, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
        drawPlus(in: plusRect)
    }

    private func drawTab(group: WindowGroup, in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.cornerRadius, yRadius: TabBarView.cornerRadius)
        if group.id == activeGroupID {
            NSColor.systemBlue.setFill()
        } else {
            NSColor(white: 1.0, alpha: 0.10).setFill()
        }
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let str = group.name as NSString
        let size = str.size(withAttributes: attrs)
        let textRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: textRect, withAttributes: attrs)
    }

    private func drawPlus(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.cornerRadius, yRadius: TabBarView.cornerRadius)
        NSColor(white: 1.0, alpha: 0.10).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 18, weight: .light)
        ]
        let str = "+" as NSString
        let size = str.size(withAttributes: attrs)
        let textRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: textRect, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = tabGroupID(at: point) {
            onSelectGroup?(id)
        } else if isPlusHit(at: point) {
            onNewGroup?()
        }
    }

    /// Hit-test a point already in this view's coordinate system.
    func groupID(at point: CGPoint) -> WindowGroupID? {
        tabGroupID(at: point)
    }

    private func tabGroupID(at point: CGPoint) -> WindowGroupID? {
        var tabX: CGFloat = TabBarView.tabSpacing
        let tabY = TabBarView.verticalInset
        for group in groups {
            let rect = CGRect(x: tabX, y: tabY, width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            if rect.contains(point) { return group.id }
            tabX += TabBarView.tabWidth + TabBarView.tabSpacing
        }
        return nil
    }

    private func isPlusHit(at point: CGPoint) -> Bool {
        let tabX = CGFloat(groups.count) * (TabBarView.tabWidth + TabBarView.tabSpacing) + TabBarView.tabSpacing
        let plusRect = CGRect(x: tabX, y: TabBarView.verticalInset, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
        return plusRect.contains(point)
    }
}
