import AppKit
import CoreGraphics

protocol TabBarWindowControllerDelegate: AnyObject {
    func tabBar(_ controller: TabBarWindowController, didSelectSetID id: WindowSetID, on displayID: CGDirectDisplayID)
    func tabBar(_ controller: TabBarWindowController, didRequestNewSetOn displayID: CGDirectDisplayID)
    func tabBar(_ controller: TabBarWindowController, didDropWindowID windowID: CGWindowID, ontoSetID setID: WindowSetID, on displayID: CGDirectDisplayID)
}

final class TabBarWindowController {
    struct Presentation {
        let sets: [WindowSet]
        let activeSetID: WindowSetID?
        let windowTitles: [CGWindowID: String]
        let isDragging: Bool
        let shouldShow: Bool
    }

    static let barHeight: CGFloat = 36
    static let topGap: CGFloat = 8
    static let reservedTopInset: CGFloat = barHeight + topGap
    private static let hMargin: CGFloat = 20

    weak var delegate: TabBarWindowControllerDelegate?

    private var windowsByDisplayID: [CGDirectDisplayID: NSWindow] = [:]
    private var viewsByDisplayID: [CGDirectDisplayID: TabBarView] = [:]
    private var visibleByDisplayID: [CGDirectDisplayID: Bool] = [:]
    private var animatingByDisplayID: [CGDirectDisplayID: Bool] = [:]

    func setupWindows(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs where windowsByDisplayID[displayID] == nil {
            createWindow(for: displayID)
        }
    }

    func render(_ presentation: Presentation, for displayID: CGDirectDisplayID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.viewsByDisplayID[displayID] == nil {
                self.createWindow(for: displayID)
            }
            let window = self.windowsByDisplayID[displayID]
            Diagnostics.log(
                "TabBar render display=\(displayID) shouldShow=\(presentation.shouldShow) dragging=\(presentation.isDragging) sets=\(presentation.sets.count) visibleState=\(self.visibleByDisplayID[displayID] ?? false) windowVisible=\(window?.isVisible ?? false) alpha=\(window?.alphaValue ?? -1) windowNumber=\(window?.windowNumber ?? -1)",
                level: .debug
            )
            guard let view = self.viewsByDisplayID[displayID] else { return }
            view.windowSets = presentation.sets
            view.activeSetID = presentation.activeSetID
            view.windowTitlesByID = presentation.windowTitles
            view.isDragging = presentation.isDragging
            view.needsDisplay = true
            self.animateVisibilityIfNeeded(for: displayID, shouldShow: presentation.shouldShow)
        }
    }

    func setID(at quartzPoint: CGPoint) -> (setID: WindowSetID, displayID: CGDirectDisplayID)? {
        let cocoaPoint = cocoaPoint(fromQuartzPoint: quartzPoint)
        for displayID in windowsByDisplayID.keys {
            guard visibleByDisplayID[displayID] == true,
                  let rect = shownFrame(for: displayID),
                  rect.contains(cocoaPoint) else { continue }
            let localX = cocoaPoint.x - rect.minX
            let localY = cocoaPoint.y - rect.minY
            let viewPoint = CGPoint(x: localX, y: TabBarWindowController.barHeight - localY)
            guard let view = viewsByDisplayID[displayID],
                  let setID = view.setID(at: viewPoint) else { continue }
            return (setID, displayID)
        }
        return nil
    }

    func isPlusZone(at quartzPoint: CGPoint) -> CGDirectDisplayID? {
        let cocoaPoint = cocoaPoint(fromQuartzPoint: quartzPoint)
        for displayID in windowsByDisplayID.keys {
            guard visibleByDisplayID[displayID] == true,
                  let rect = shownFrame(for: displayID),
                  rect.contains(cocoaPoint) else { continue }
            let localX = cocoaPoint.x - rect.minX
            let localY = cocoaPoint.y - rect.minY
            let viewPoint = CGPoint(x: localX, y: TabBarWindowController.barHeight - localY)
            guard let view = viewsByDisplayID[displayID] else { continue }
            if view.isPlusZone(at: viewPoint) { return displayID }
        }
        return nil
    }

    func isPointInTabBar(_ quartzPoint: CGPoint) -> Bool {
        let cocoaPoint = cocoaPoint(fromQuartzPoint: quartzPoint)
        return windowsByDisplayID.keys.contains {
            visibleByDisplayID[$0] == true &&
            shownFrame(for: $0)?.contains(cocoaPoint) == true
        }
    }

    private func animateVisibilityIfNeeded(for displayID: CGDirectDisplayID, shouldShow: Bool) {
        guard let window = windowsByDisplayID[displayID],
              let shown = shownFrame(for: displayID) else { return }

        let wasShown = visibleByDisplayID[displayID] ?? false
        Diagnostics.log(
            "TabBar visibility display=\(displayID) shouldShow=\(shouldShow) wasShown=\(wasShown) animating=\(animatingByDisplayID[displayID] ?? false) windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue) frame=\(window.frame.debugDescription)",
            level: .debug
        )
        guard shouldShow != wasShown else {
            if animatingByDisplayID[displayID] == true {
                Diagnostics.log("TabBar visibility display=\(displayID) skipped while animating", level: .debug)
                return
            }
            if !window.frame.equalTo(shown) {
                window.setFrame(shown, display: true)
            }
            if shouldShow {
                window.alphaValue = 1
                window.orderFrontRegardless()
                Diagnostics.log(
                    "TabBar orderFront display=\(displayID) windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                    level: .debug
                )
            } else {
                window.alphaValue = 0
                window.orderOut(nil)
                Diagnostics.log(
                    "TabBar orderOut display=\(displayID) windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                    level: .debug
                )
            }
            return
        }
        visibleByDisplayID[displayID] = shouldShow

        if !window.frame.equalTo(shown) {
            window.setFrame(shown, display: true)
        }

        if shouldShow {
            window.alphaValue = 0
            window.orderFrontRegardless()
            Diagnostics.log(
                "TabBar animation start display=\(displayID) phase=show windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                level: .debug
            )
        } else {
            Diagnostics.log(
                "TabBar animation start display=\(displayID) phase=hide windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                level: .debug
            )
        }

        animatingByDisplayID[displayID] = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shouldShow ? 0.18 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: shouldShow ? .easeOut : .easeIn)
            window.animator().alphaValue = shouldShow ? 1 : 0
        }, completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            self.animatingByDisplayID[displayID] = false
            guard self.visibleByDisplayID[displayID] == shouldShow else {
                let targetVisibility = self.visibleByDisplayID[displayID] ?? false
                self.animateVisibilityIfNeeded(for: displayID, shouldShow: targetVisibility)
                return
            }
            if shouldShow {
                window.alphaValue = 1
                Diagnostics.log(
                    "TabBar animation finish display=\(displayID) phase=show windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                    level: .debug
                )
            } else {
                window.alphaValue = 0
                window.orderOut(nil)
                Diagnostics.log(
                    "TabBar animation finish display=\(displayID) phase=hide windowVisible=\(window.isVisible) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue)",
                    level: .debug
                )
            }
        })
    }

    private func shownFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = DisplayService.screen(for: displayID) else { return nil }
        let sf = screen.frame
        let vf = screen.visibleFrame
        let m = TabBarWindowController.hMargin
        let h = TabBarWindowController.barHeight
        let width = max(1, sf.width - m * 2)
        return CGRect(
            x: sf.minX + m,
            y: vf.maxY - h - TabBarWindowController.topGap,
            width: width,
            height: h
        )
    }

    private func cocoaPoint(fromQuartzPoint quartzPoint: CGPoint) -> CGPoint {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: quartzPoint.x, y: mainHeight - quartzPoint.y)
    }

    private func createWindow(for displayID: CGDirectDisplayID) {
        guard let shown = shownFrame(for: displayID) else { return }

        let window = NSWindow(contentRect: shown, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let chromeView = NSVisualEffectView(frame: CGRect(origin: .zero, size: shown.size))
        chromeView.material = .sidebar
        chromeView.blendingMode = .behindWindow
        chromeView.state = .active
        chromeView.autoresizingMask = [.width, .height]
        chromeView.wantsLayer = true
        chromeView.layer?.cornerRadius = 10
        chromeView.layer?.masksToBounds = true
        window.contentView = chromeView

        let tabView = TabBarView(frame: CGRect(origin: .zero, size: shown.size))
        tabView.autoresizingMask = [.width, .height]
        tabView.onSelectSet = { [weak self, displayID] setID in
            guard let self else { return }
            self.delegate?.tabBar(self, didSelectSetID: setID, on: displayID)
        }
        tabView.onNewSet = { [weak self, displayID] in
            guard let self else { return }
            self.delegate?.tabBar(self, didRequestNewSetOn: displayID)
        }
        chromeView.addSubview(tabView)

        windowsByDisplayID[displayID] = window
        viewsByDisplayID[displayID] = tabView
        visibleByDisplayID[displayID] = false
        animatingByDisplayID[displayID] = false

        window.alphaValue = 0
        window.orderOut(nil)
    }
}

// MARK: - TabBarView

final class TabBarView: NSView {
    private static let tabWidth: CGFloat = 160
    private static let plusWidth: CGFloat = 32
    private static let tabHeight: CGFloat = 24
    private static let tabCorner: CGFloat = 6
    private static let spacing: CGFloat = 6
    private static let hPad: CGFloat = 10
    private static let tabTopY: CGFloat = (36 - 24) / 2  // = 6

    var windowSets: [WindowSet] = []
    var activeSetID: WindowSetID?
    var isDragging: Bool = false
    var windowTitlesByID: [CGWindowID: String] = [:]

    var onSelectSet: ((WindowSetID) -> Void)?
    var onNewSet: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let tabY = TabBarView.tabTopY
        var tabX = TabBarView.hPad

        for set in windowSets {
            let rect = CGRect(x: tabX, y: tabY, width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            drawTab(set: set, in: rect)
            tabX += TabBarView.tabWidth + TabBarView.spacing
        }

        if isDragging {
            let plusRect = CGRect(x: tabX, y: tabY, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
            drawPlus(in: plusRect)
        }
    }

    private func drawTab(set: WindowSet, in rect: CGRect) {
        let isActive = set.id == activeSetID
        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.tabCorner,
                                yRadius: TabBarView.tabCorner)

        if isActive {
            NSColor(white: 1, alpha: 0.28).setFill()
        } else {
            NSColor(white: 1, alpha: 0.10).setFill()
        }
        path.fill()

        NSColor(white: 1, alpha: isActive ? 0.45 : 0.20).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let label: String = {
            let names = set.orderedWindowIDs.compactMap { id -> String? in
                guard let t = windowTitlesByID[id] else { return nil }
                let trimmed = t.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return names.isEmpty ? "Set" : names.joined(separator: " | ")
        }()

        let font = NSFont.systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: font
        ]

        let inset: CGFloat = 7
        let maxW = rect.width - inset * 2
        let attrStr = NSAttributedString(string: label, attributes: attrs)
        let measured = attrStr.boundingRect(
            with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin
        )
        let textTopY = floor(rect.midY - measured.height / 2)
        let textRect = CGRect(x: rect.minX + inset, y: textTopY, width: maxW, height: measured.height)
        attrStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPlus(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: TabBarView.tabCorner,
                                yRadius: TabBarView.tabCorner)
        NSColor(white: 1, alpha: 0.10).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.22).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let font = NSFont.systemFont(ofSize: 14, weight: .thin)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: font
        ]
        let str = "+" as NSString
        let sz = str.size(withAttributes: attrs)
        let y = floor(rect.midY - (font.ascender + font.capHeight) / 2)
        str.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: y), withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = hitSetID(at: point) {
            onSelectSet?(id)
        } else if isDragging, isPlusZone(at: point) {
            onNewSet?()
        }
    }

    // MARK: - Hit testing（isFlipped=true 座標系）

    func setID(at point: CGPoint) -> WindowSetID? {
        hitSetID(at: point)
    }

    func isPlusZone(at point: CGPoint) -> Bool {
        guard isDragging else { return false }
        let tabX = CGFloat(windowSets.count) * (TabBarView.tabWidth + TabBarView.spacing) + TabBarView.hPad
        let r = CGRect(x: tabX, y: TabBarView.tabTopY, width: TabBarView.plusWidth, height: TabBarView.tabHeight)
        return r.contains(point)
    }

    private func hitSetID(at point: CGPoint) -> WindowSetID? {
        var tabX = TabBarView.hPad
        for set in windowSets {
            let r = CGRect(x: tabX, y: TabBarView.tabTopY,
                           width: TabBarView.tabWidth, height: TabBarView.tabHeight)
            if r.contains(point) { return set.id }
            tabX += TabBarView.tabWidth + TabBarView.spacing
        }
        return nil
    }
}
