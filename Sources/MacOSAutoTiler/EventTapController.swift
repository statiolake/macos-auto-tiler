import CoreGraphics
import Foundation

enum MouseEventType {
    case down
    case dragged
    case up
    case secondaryDown
    case optionPressed
    case scrollWheel(deltaY: Int64)
}

final class EventTapController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((MouseEventType, CGPoint) -> Bool)?
    private var lastFlags: CGEventFlags = []

    func start(handler: @escaping (MouseEventType, CGPoint) -> Bool) -> Bool {
        stop()
        self.handler = handler
        Diagnostics.log("Starting global mouse event tap", level: .info)

        let mask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)

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
        lastFlags = []
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
        lastFlags = []
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
        var consumed = false

        switch type {
        case .leftMouseDown:
            consumed = handler(.down, point)
        case .leftMouseDragged:
            consumed = handler(.dragged, point)
        case .leftMouseUp:
            consumed = handler(.up, point)
        case .rightMouseDown:
            consumed = handler(.secondaryDown, point)
        case .flagsChanged:
            let flags = event.flags
            let becameOptionOnly = isOptionOnlyPressTransition(from: lastFlags, to: flags)
            lastFlags = flags
            if becameOptionOnly {
                consumed = handler(.optionPressed, point)
            }
        case .scrollWheel:
            let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if deltaY != 0 {
                consumed = handler(.scrollWheel(deltaY: deltaY), point)
            }
        default:
            lastFlags = event.flags
            break
        }

        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    private func isOptionOnlyPressTransition(from previous: CGEventFlags, to current: CGEventFlags) -> Bool {
        let wasOptionDown = previous.contains(.maskAlternate)
        let isOptionDown = current.contains(.maskAlternate)
        return !wasOptionDown && isOptionDown && hasOnlyOptionModifier(current)
    }

    private func hasOnlyOptionModifier(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskAlternate) else {
            return false
        }

        let disallowed: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskCommand,
            .maskAlphaShift,
            .maskSecondaryFn,
            .maskNumericPad,
            .maskHelp,
        ]
        return flags.intersection(disallowed).isEmpty
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
        return controller.handle(type, event: event)
    }
}
