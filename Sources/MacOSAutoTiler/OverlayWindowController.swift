import AppKit
import CoreGraphics

final class OverlayWindowController {
    private var overlayWindow: NSWindow?
    private var overlayView: OverlayView?
    private var activeDisplayID: CGDirectDisplayID?

    func show(
        displayID: CGDirectDisplayID,
        slotRects: [CGRect],
        hoverIndex: Int?,
        ghostRect: CGRect?
    ) {
        ensureWindow(displayID: displayID)
        guard let overlayView else { return }
        overlayView.slotRects = slotRects
        overlayView.hoverIndex = hoverIndex
        overlayView.ghostRect = ghostRect
        overlayView.needsDisplay = true
        overlayWindow?.orderFrontRegardless()
    }

    func hide() {
        overlayWindow?.orderOut(nil)
    }

    private func ensureWindow(displayID: CGDirectDisplayID) {
        if activeDisplayID == displayID, overlayWindow != nil, overlayView != nil {
            return
        }

        overlayWindow?.close()
        overlayWindow = nil
        overlayView = nil
        activeDisplayID = displayID

        guard let screen = Self.screen(for: displayID) else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let contentView = OverlayView(frame: screen.frame, displayID: displayID)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        overlayWindow = window
        overlayView = contentView
        window.orderFrontRegardless()
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return raw.uint32Value == displayID
        }
    }
}

private final class OverlayView: NSView {
    let displayBounds: CGRect
    var slotRects: [CGRect] = []
    var hoverIndex: Int?
    var ghostRect: CGRect?

    override var isFlipped: Bool {
        true
    }

    init(frame frameRect: NSRect, displayID: CGDirectDisplayID) {
        self.displayBounds = CGDisplayBounds(displayID)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        for (index, slot) in slotRects.enumerated() {
            drawSlot(slot, highlighted: hoverIndex == index)
        }

        if let ghostRect {
            drawGhost(ghostRect)
        }
    }

    private func drawSlot(_ globalRect: CGRect, highlighted: Bool) {
        let rect = toLocal(globalRect)
        let fill = highlighted ? NSColor.systemBlue.withAlphaComponent(0.22) : NSColor.systemBlue.withAlphaComponent(0.09)
        let stroke = highlighted ? NSColor.systemBlue : NSColor.systemTeal.withAlphaComponent(0.7)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = highlighted ? 3 : 1.5
        path.stroke()
    }

    private func drawGhost(_ globalRect: CGRect) {
        let rect = toLocal(globalRect)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        let dash: [CGFloat] = [8, 6]
        path.setLineDash(dash, count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    private func toLocal(_ globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - displayBounds.minX,
            y: globalRect.minY - displayBounds.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}
