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

    func setDragging(_ isDragging: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for view in self.viewsByDisplayID.values {
                view.isDragging = isDragging
                view.needsDisplay = true
            }
        }
    }

    /// Hit-test a Quartz-coordinate point. Returns groupID + displayID if a tab is hit.
    func groupID(at quartzPoint: CGPoint) -> (groupID: WindowGroupID, displayID: CGDirectDisplayID)? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: quartzPoint.x, y: mainHeight - quartzPoint.y)

        for (displayID, window) in windowsByDisplayID {
            guard window.frame.contains(cocoaPoint) else { continue }
            let localX = cocoaPoint.x - window.frame.minX
            let localY = cocoaPoint.y - window.frame.minY
            // TabBarView は isFlipped=true なので Y を反転
            let viewPoint = CGPoint(x: localX, y: TabBarWindowController.barHeight - localY)
            guard
                let view = viewsByDisplayID[displayID],
                let groupID = view.groupID(at: viewPoint)
            else { continue }
            return (groupID, displayID)
        }
        return nil
    }

    /// ドラッグ中に "+" ゾーンにいるか判定。ヒットしたディスプレイIDを返す。
    func isPlusZone(at quartzPoint: CGPoint) -> CGDirectDisplayID? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: quartzPoint.x, y: mainHeight - quartzPoint.y)

        for (displayID, window) in windowsByDisplayID {
            guard window.frame.contains(cocoaPoint) else { continue }
            let localX = cocoaPoint.x - window.frame.minX
            let localY = cocoaPoint.y - window.frame.minY
            let viewPoint = CGPoint(x: localX, y: TabBarWindowController.barHeight - localY)
            guard let view = viewsByDisplayID[displayID] else { continue }
            if view.isPlusZone(at: viewPoint) { return displayID }
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
        // メニューバーのすぐ下 (Cocoa Y-up: visibleFrame.maxY が最上端)
        let barRect = CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.maxY - TabBarWindowController.barHeight,
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
    // Layout
    private static let tabWidth: CGFloat = 140
    private static let plusWidth: CGFloat = 40
    private static let tabHeight: CGFloat = 30
    private static let cornerRadius: CGFloat = 7
    private static let spacing: CGFloat = 6
    private static let verticalPad: CGFloat = 7
    private static let hPad: CGFloat = 12

    var groups: [WindowGroup] = []
    var activeGroupID: WindowGroupID?
    var isDragging: Bool = false

    var onSelectGroup: ((WindowGroupID) -> Void)?
    var onNewGroup: (() -> Void)?

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 背景は透明なので何も塗らない
        let tabY = TabBarView.verticalPad

        var tabX: CGFloat = TabBarView.hPad
        for group in groups {
            let rect = CGRect(x: tabX, y: tabY, width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            drawTab(group: group, in: rect)
            tabX += TabBarView.tabWidth + TabBarView.spacing
        }

        if isDragging {
            let plusRect = CGRect(x: tabX, y: tabY, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
            drawPlus(in: plusRect)
        }
    }

    private func drawTab(group: WindowGroup, in rect: CGRect) {
        let isActive = group.id == activeGroupID

        // シャドウで「浮いてる感」を出す
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.cornerRadius, yRadius: TabBarView.cornerRadius)
        if isActive {
            NSColor.controlAccentColor.setFill()
        } else {
            // ライト/ダークモード自動対応
            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
        }
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // テキスト
        let name = group.name
        let count = group.windowIDs.count
        let displayText = count > 0 ? "\(name)  \(count)" : name

        let textColor: NSColor = isActive ? .white : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        ]
        let str = displayText as NSString
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
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.cornerRadius, yRadius: TabBarView.cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.75).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 17, weight: .thin)
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = tabGroupID(at: point) {
            onSelectGroup?(id)
        } else if isDragging, isPlusZone(at: point) {
            onNewGroup?()
        }
    }

    // MARK: - Hit testing

    func groupID(at point: CGPoint) -> WindowGroupID? {
        tabGroupID(at: point)
    }

    func isPlusZone(at point: CGPoint) -> Bool {
        guard isDragging else { return false }
        let tabX = CGFloat(groups.count) * (TabBarView.tabWidth + TabBarView.spacing) + TabBarView.hPad
        let plusRect = CGRect(x: tabX, y: TabBarView.verticalPad, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
        return plusRect.contains(point)
    }

    private func tabGroupID(at point: CGPoint) -> WindowGroupID? {
        var tabX: CGFloat = TabBarView.hPad
        let tabY = TabBarView.verticalPad
        for group in groups {
            let rect = CGRect(x: tabX, y: tabY, width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            if rect.contains(point) { return group.id }
            tabX += TabBarView.tabWidth + TabBarView.spacing
        }
        return nil
    }
}
