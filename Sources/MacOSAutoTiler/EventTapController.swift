import CoreGraphics
import Foundation

enum MouseEventType {
    case down
    case dragged
    case up
    case secondaryDown
}

final class EventTapController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((MouseEventType, CGPoint) -> Void)?

    func start(handler: @escaping (MouseEventType, CGPoint) -> Void) -> Bool {
        stop()
        self.handler = handler
        Diagnostics.log("Starting global mouse event tap", level: .info)

        let mask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: EventTapController.callback,
                userInfo: refcon
            )
        else {
            Diagnostics.log("Failed to create CGEvent tap", level: .error)
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Diagnostics.log("Failed to create run loop source for event tap", level: .error)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Diagnostics.log("Global mouse event tap enabled", level: .info)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        handler = nil
        Diagnostics.log("Global mouse event tap stopped", level: .debug)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.log("Event tap was disabled by system, re-enabling", level: .warn)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let handler else {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        switch type {
        case .leftMouseDown:
            handler(.down, point)
        case .leftMouseDragged:
            handler(.dragged, point)
        case .leftMouseUp:
            handler(.up, point)
        case .rightMouseDown:
            handler(.secondaryDown, point)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
        return controller.handle(type, event: event)
    }
}
