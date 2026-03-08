import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class PrivateWindowFocusController {
    private typealias SetFrontProcessWithOptionsFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordToFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutableRawPointer) -> CGError
    private typealias GetProcessForPIDFn =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private enum FrontProcessMode: UInt32 {
        case allWindows = 0
        case userGenerated = 1
        case noWindows = 2
    }

    private struct KeyWindowEventRecord {
        private static let length = 0xf8
        private static let lengthOffset = 0x04
        private static let phaseOffset = 0x08
        private static let sentinelOffset = 0x20
        private static let sentinelLength = 16
        private static let eventKindOffset = 0x3a
        private static let windowIDOffset = 0x3c
        private static let eventKindValue: UInt16 = 0x10

        private var bytes = [UInt8](repeating: 0, count: length)

        init(windowID: CGWindowID, phase: UInt32) {
            store(UInt32(Self.length), at: Self.lengthOffset)
            store(phase, at: Self.phaseOffset)
            for index in Self.sentinelOffset..<(Self.sentinelOffset + Self.sentinelLength) {
                bytes[index] = 0xff
            }
            store(Self.eventKindValue, at: Self.eventKindOffset)
            store(UInt32(windowID), at: Self.windowIDOffset)
        }

        mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawPointer) -> R) -> R {
            bytes.withUnsafeMutableBytes { rawBuffer in
                body(rawBuffer.baseAddress!)
            }
        }

        private mutating func store(_ value: UInt32, at offset: Int) {
            let littleEndian = value.littleEndian
            withUnsafeBytes(of: littleEndian) { valueBytes in
                bytes.replaceSubrange(offset..<(offset + valueBytes.count), with: valueBytes)
            }
        }

        private mutating func store(_ value: UInt16, at offset: Int) {
            let littleEndian = value.littleEndian
            withUnsafeBytes(of: littleEndian) { valueBytes in
                bytes.replaceSubrange(offset..<(offset + valueBytes.count), with: valueBytes)
            }
        }
    }

    private let stateLock = NSLock()
    private var isResolved = false
    private var isAvailable = false
    private var skyLightHandle: UnsafeMutableRawPointer?
    private var hiServicesHandle: UnsafeMutableRawPointer?
    private var setFrontProcessWithOptionsFn: SetFrontProcessWithOptionsFn?
    private var postEventRecordToFn: PostEventRecordToFn?
    private var getProcessForPIDFn: GetProcessForPIDFn?

    deinit {
        if let skyLightHandle {
            dlclose(skyLightHandle)
        }
        if let hiServicesHandle {
            dlclose(hiServicesHandle)
        }
    }

    @discardableResult
    func focus(windowID: CGWindowID, pid: pid_t, axElement: AXUIElement, isFloating: Bool) -> Bool {
        let category = isFloating ? "floating" : "tiled"

        guard prepare() else {
            Diagnostics.log(
                "Strong focus unavailable windowID=\(windowID) pid=\(pid) kind=\(category); falling back to AXRaise",
                level: .warn
            )
            return performAXRaise(windowID: windowID, pid: pid, axElement: axElement, isFloating: isFloating)
        }

        guard var psn = resolveProcessSerialNumber(pid: pid) else {
            Diagnostics.log(
                "Strong focus failed: unresolved PSN windowID=\(windowID) pid=\(pid) kind=\(category)",
                level: .warn
            )
            return performAXRaise(windowID: windowID, pid: pid, axElement: axElement, isFloating: isFloating)
        }

        let frontResult = setFrontProcess(&psn, windowID: windowID)
        let phaseOneResult = postKeyWindowEvent(to: &psn, windowID: windowID, phase: 0x01)
        let phaseTwoResult = postKeyWindowEvent(to: &psn, windowID: windowID, phase: 0x02)
        let raiseSucceeded = performAXRaise(windowID: windowID, pid: pid, axElement: axElement, isFloating: isFloating)

        Diagnostics.log(
            "Strong focus windowID=\(windowID) pid=\(pid) kind=\(category) front=\(frontResult) key1=\(phaseOneResult) key2=\(phaseTwoResult) ax=\(raiseSucceeded)",
            level: (frontResult == .success && phaseOneResult == .success && phaseTwoResult == .success && raiseSucceeded) ? .debug : .warn
        )

        return frontResult == .success && phaseOneResult == .success && phaseTwoResult == .success && raiseSucceeded
    }

    private func performAXRaise(windowID: CGWindowID, pid: pid_t, axElement: AXUIElement, isFloating: Bool) -> Bool {
        let result = AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        Diagnostics.log(
            "AXRaise windowID=\(windowID) pid=\(pid) kind=\(isFloating ? "floating" : "tiled") result=\(result.rawValue)",
            level: result == .success ? .debug : .warn
        )
        return result == .success
    }

    private func resolveProcessSerialNumber(pid: pid_t) -> ProcessSerialNumber? {
        guard let getProcessForPIDFn else {
            return nil
        }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        let status = getProcessForPIDFn(pid, &psn)
        guard status == noErr else {
            Diagnostics.log("GetProcessForPID failed pid=\(pid) status=\(status)", level: .warn)
            return nil
        }
        return psn
    }

    private func setFrontProcess(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, windowID: CGWindowID) -> CGError {
        guard let setFrontProcessWithOptionsFn else {
            return .failure
        }
        return setFrontProcessWithOptionsFn(psn, windowID, FrontProcessMode.userGenerated.rawValue)
    }

    private func postKeyWindowEvent(
        to psn: UnsafeMutablePointer<ProcessSerialNumber>,
        windowID: CGWindowID,
        phase: UInt32
    ) -> CGError {
        guard let postEventRecordToFn else {
            return .failure
        }
        var record = KeyWindowEventRecord(windowID: windowID, phase: phase)
        return record.withUnsafeMutableBytes { rawPointer in
            postEventRecordToFn(psn, rawPointer)
        }
    }

    private func prepare() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isResolved {
            return isAvailable
        }
        isResolved = true

        let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let skyLightHandle else {
            Diagnostics.log("Strong focus unavailable: failed to open SkyLight", level: .warn)
            return false
        }

        let hiServicesHandle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_NOW
        )
        guard let hiServicesHandle else {
            dlclose(skyLightHandle)
            Diagnostics.log("Strong focus unavailable: failed to open HIServices", level: .warn)
            return false
        }

        guard
            let setFrontProcessSymbol = dlsym(skyLightHandle, "_SLPSSetFrontProcessWithOptions"),
            let postEventRecordSymbol = dlsym(skyLightHandle, "SLPSPostEventRecordTo"),
            let getProcessForPIDSymbol = dlsym(hiServicesHandle, "GetProcessForPID")
        else {
            dlclose(skyLightHandle)
            dlclose(hiServicesHandle)
            Diagnostics.log("Strong focus unavailable: missing focus symbols", level: .warn)
            return false
        }

        setFrontProcessWithOptionsFn = unsafeBitCast(setFrontProcessSymbol, to: SetFrontProcessWithOptionsFn.self)
        postEventRecordToFn = unsafeBitCast(postEventRecordSymbol, to: PostEventRecordToFn.self)
        getProcessForPIDFn = unsafeBitCast(getProcessForPIDSymbol, to: GetProcessForPIDFn.self)
        self.skyLightHandle = skyLightHandle
        self.hiServicesHandle = hiServicesHandle
        isAvailable = true
        Diagnostics.log("Strong focus bridge initialized", level: .info)
        return true
    }
}
