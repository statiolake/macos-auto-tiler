import CoreGraphics
import Foundation

enum TapEvent {
    case mouseDown(CGPoint)
    case mouseDragged(CGPoint)
    case mouseUp(CGPoint)
    case rightMouseDown(CGPoint)
    /// Option pressed on its own, without any other modifier.
    case optionPressed(CGPoint)
    /// Discrete (mouse wheel) vertical scroll. Trackpad scrolling is never reported.
    case scrollWheel(CGPoint, deltaY: Int64)
}

struct EventTapError: LocalizedError {
    var errorDescription: String? {
        "Could not create the global event tap. Check Accessibility and Input Monitoring permissions."
    }
}

/// Global event tap on the main run loop. The handler returns true to swallow the event.
final class EventTapController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((TapEvent) -> Bool)?
    private var lastFlags: CGEventFlags = []

    func start(handler: @escaping (TapEvent) -> Bool) throws {
        precondition(eventTap == nil, "event tap started twice")
        let eventTypes: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .flagsChanged, .scrollWheel]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            throw EventTapError()
        }

        self.handler = handler
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        handler = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.log("Event tap was disabled by the system (\(type.rawValue)); re-enabling", level: .warn)
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let handler, let tapEvent = tapEvent(type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        return handler(tapEvent) ? nil : Unmanaged.passUnretained(event)
    }

    private func tapEvent(_ type: CGEventType, event: CGEvent) -> TapEvent? {
        let point = event.location
        switch type {
        case .leftMouseDown:
            return .mouseDown(point)
        case .leftMouseDragged:
            return .mouseDragged(point)
        case .leftMouseUp:
            return .mouseUp(point)
        case .rightMouseDown:
            return .rightMouseDown(point)
        case .flagsChanged:
            let wasOptionDown = lastFlags.contains(.maskAlternate)
            lastFlags = event.flags
            let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskCommand, .maskAlphaShift, .maskSecondaryFn, .maskHelp]
            let isOptionOnly = event.flags.contains(.maskAlternate) && event.flags.intersection(otherModifiers).isEmpty
            return !wasOptionDown && isOptionOnly ? .optionPressed(point) : nil
        case .scrollWheel:
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return nil }
            let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let deltaY = lineDelta != 0 ? lineDelta : event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            return deltaY != 0 ? .scrollWheel(point, deltaY: deltaY) : nil
        default:
            return nil
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            preconditionFailure("event tap callback without refcon")
        }
        return Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue().handle(type, event: event)
    }
}
