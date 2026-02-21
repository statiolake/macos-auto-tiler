import CoreGraphics
import Foundation
import Darwin

final class CGSSpaceService {
    static let shared = CGSSpaceService()

    private typealias CGSConnectionID = UInt32
    private typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
    private typealias CGSCopySpacesForWindowsFn =
        @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias CGSCopyBestManagedDisplayForRectFn =
        @convention(c) (CGSConnectionID, CGRect) -> Unmanaged<CFString>?
    private typealias CGSGetSymbolicHotKeyValueFn =
        @convention(c) (UInt32, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias CGSIsSymbolicHotKeyEnabledFn = @convention(c) (UInt32) -> Bool

    private let stateLock = NSLock()
    private var isResolved = false
    private var isAvailable = false
    private var skyLightHandle: UnsafeMutableRawPointer?

    private var mainConnectionIDFn: CGSMainConnectionIDFn?
    private var copySpacesForWindowsFn: CGSCopySpacesForWindowsFn?
    private var copyManagedDisplaySpacesFn: CGSCopyManagedDisplaySpacesFn?
    private var copyBestManagedDisplayForRectFn: CGSCopyBestManagedDisplayForRectFn?
    private let moveLeftSpaceKeyCode: CGKeyCode = 123
    private let moveRightSpaceKeyCode: CGKeyCode = 124
    private var getSymbolicHotKeyValueFn: CGSGetSymbolicHotKeyValueFn?
    private var isSymbolicHotKeyEnabledFn: CGSIsSymbolicHotKeyEnabledFn?

    private let spaceLeftHotKey: UInt32 = 79
    private let spaceRightHotKey: UInt32 = 81

    private let allSpacesMask: UInt32 = 0x7

    private struct SpaceSwitchShortcut {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private enum SpaceShortcutResolution {
        case resolved(SpaceSwitchShortcut)
        case disabled
        case unavailable
    }

    private init() {}

    deinit {
        if let skyLightHandle {
            dlclose(skyLightHandle)
        }
    }

    func spacesByWindowID(windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        guard !windowIDs.isEmpty else {
            return [:]
        }
        guard prepare() else {
            return [:]
        }
        guard
            let mainConnectionIDFn,
            let copySpacesForWindowsFn
        else {
            return [:]
        }

        let connection = mainConnectionIDFn()

        var result: [CGWindowID: Int] = [:]
        result.reserveCapacity(windowIDs.count)

        for windowID in windowIDs {
            let windowArray = [NSNumber(value: windowID)] as CFArray
            guard let rawSpaces = copySpacesForWindowsFn(connection, allSpacesMask, windowArray)?.takeRetainedValue() else {
                continue
            }
            let values = rawSpaces as [AnyObject]
            guard let first = values.first, let spaceID = parseSpaceID(first) else {
                continue
            }
            result[windowID] = spaceID
        }
        return result
    }

    func currentSpaceByDisplayID(displayIDs: Set<CGDirectDisplayID>) -> [CGDirectDisplayID: Int] {
        guard !displayIDs.isEmpty else {
            return [:]
        }
        guard prepare() else {
            return [:]
        }
        guard
            let mainConnectionIDFn,
            let copyManagedDisplaySpacesFn,
            let copyBestManagedDisplayForRectFn
        else {
            return [:]
        }

        let connection = mainConnectionIDFn()
        guard let rawDescriptions = copyManagedDisplaySpacesFn(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }

        var spaceIDByManagedDisplayIdentifier: [String: Int] = [:]
        for description in rawDescriptions {
            guard
                let identifier = description["Display Identifier"] as? String,
                let currentSpace = description["Current Space"] as? [String: Any],
                let managedSpaceID = parseSpaceID(currentSpace["ManagedSpaceID"] as AnyObject)
            else {
                continue
            }
            spaceIDByManagedDisplayIdentifier[identifier] = managedSpaceID
        }

        guard !spaceIDByManagedDisplayIdentifier.isEmpty else {
            return [:]
        }

        var result: [CGDirectDisplayID: Int] = [:]
        result.reserveCapacity(displayIDs.count)
        for displayID in displayIDs {
            let bounds = CGDisplayBounds(displayID)
            guard
                let managedDisplayIdentifier =
                    copyBestManagedDisplayForRectFn(connection, bounds)?.takeRetainedValue() as String?,
                let currentSpaceID = spaceIDByManagedDisplayIdentifier[managedDisplayIdentifier]
            else {
                continue
            }
            result[displayID] = currentSpaceID
        }
        return result
    }

    func switchToAdjacentSpace(displayID: CGDirectDisplayID, goLeft: Bool) -> Bool {
        if let canSwitch = canSwitchToAdjacentSpace(displayID: displayID, goLeft: goLeft), !canSwitch {
            return false
        }

        guard postSystemSpaceSwitchShortcut(goLeft: goLeft) else {
            Diagnostics.log("Space switch failed: symbolic hotkey is disabled or event post failed", level: .warn)
            return false
        }
        return true
    }

    private func canSwitchToAdjacentSpace(displayID: CGDirectDisplayID, goLeft: Bool) -> Bool? {
        guard prepare() else {
            return nil
        }
        guard
            let mainConnectionIDFn,
            let copyManagedDisplaySpacesFn,
            let copyBestManagedDisplayForRectFn
        else {
            return nil
        }

        let connection = mainConnectionIDFn()
        let bounds = CGDisplayBounds(displayID)
        guard
            let managedDisplayID = copyBestManagedDisplayForRectFn(connection, bounds)?.takeRetainedValue()
        else {
            return nil
        }

        guard let rawDescriptions = copyManagedDisplaySpacesFn(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        guard let displayDescription = rawDescriptions.first(where: {
            ($0["Display Identifier"] as? String) == (managedDisplayID as String)
        }) else {
            return nil
        }

        guard
            let currentSpace = displayDescription["Current Space"] as? [String: Any],
            let currentSpaceID = parseSpaceID(currentSpace["ManagedSpaceID"] as AnyObject),
            let spaces = displayDescription["Spaces"] as? [[String: Any]]
        else {
            return nil
        }

        let spaceIDs = spaces.compactMap { parseSpaceID($0["ManagedSpaceID"] as AnyObject) }
        guard let currentIndex = spaceIDs.firstIndex(of: currentSpaceID) else {
            return nil
        }

        let targetIndex = goLeft ? currentIndex - 1 : currentIndex + 1
        return targetIndex >= 0 && targetIndex < spaceIDs.count
    }

    private func postSystemSpaceSwitchShortcut(goLeft: Bool) -> Bool {
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        let shortcut: SpaceSwitchShortcut
        switch symbolicHotKeySpaceShortcut(goLeft: goLeft) {
        case let .resolved(value):
            shortcut = value
        case .disabled:
            return false
        case .unavailable:
            shortcut = defaultSpaceShortcut(goLeft: goLeft)
        }

        guard
            let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = shortcut.flags
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func defaultSpaceShortcut(goLeft: Bool) -> SpaceSwitchShortcut {
        SpaceSwitchShortcut(
            keyCode: goLeft ? moveLeftSpaceKeyCode : moveRightSpaceKeyCode,
            flags: .maskControl
        )
    }

    private func symbolicHotKeySpaceShortcut(goLeft: Bool) -> SpaceShortcutResolution {
        guard prepare() else {
            return .unavailable
        }
        guard
            let getSymbolicHotKeyValueFn,
            let isSymbolicHotKeyEnabledFn
        else {
            return .unavailable
        }

        let hotKey = goLeft ? spaceLeftHotKey : spaceRightHotKey
        guard isSymbolicHotKeyEnabledFn(hotKey) else {
            return .disabled
        }

        var keyCode: UInt16 = 0
        var flagsRaw: UInt32 = 0
        let error = getSymbolicHotKeyValueFn(hotKey, nil, &keyCode, &flagsRaw)
        guard error == 0 else {
            return .unavailable
        }

        return .resolved(
            SpaceSwitchShortcut(
                keyCode: CGKeyCode(keyCode),
                flags: CGEventFlags(rawValue: UInt64(flagsRaw))
            )
        )
    }

    private func prepare() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isResolved {
            return isAvailable
        }
        isResolved = true

        let symbolNames = (
            mainConnection: "CGSMainConnectionID",
            copySpaces: "CGSCopySpacesForWindows",
            copyManagedDisplays: "CGSCopyManagedDisplaySpaces",
            bestDisplayForRect: "CGSCopyBestManagedDisplayForRect",
            getSymbolicHotKeyValue: "CGSGetSymbolicHotKeyValue",
            isSymbolicHotKeyEnabled: "CGSIsSymbolicHotKeyEnabled"
        )

        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let handle else {
            Diagnostics.log("CGS unavailable: failed to open SkyLight framework", level: .warn)
            return false
        }

        guard
            let mainConnectionPtr = dlsym(handle, symbolNames.mainConnection),
            let copySpacesPtr = dlsym(handle, symbolNames.copySpaces),
            let copyManagedDisplaysPtr = dlsym(handle, symbolNames.copyManagedDisplays),
            let bestDisplayForRectPtr = dlsym(handle, symbolNames.bestDisplayForRect)
        else {
            dlclose(handle)
            Diagnostics.log("CGS unavailable: required symbols are missing", level: .warn)
            return false
        }

        mainConnectionIDFn = unsafeBitCast(mainConnectionPtr, to: CGSMainConnectionIDFn.self)
        copySpacesForWindowsFn = unsafeBitCast(copySpacesPtr, to: CGSCopySpacesForWindowsFn.self)
        copyManagedDisplaySpacesFn = unsafeBitCast(copyManagedDisplaysPtr, to: CGSCopyManagedDisplaySpacesFn.self)
        copyBestManagedDisplayForRectFn = unsafeBitCast(bestDisplayForRectPtr, to: CGSCopyBestManagedDisplayForRectFn.self)
        if let getSymbolicHotKeyValuePtr = dlsym(handle, symbolNames.getSymbolicHotKeyValue) {
            getSymbolicHotKeyValueFn = unsafeBitCast(getSymbolicHotKeyValuePtr, to: CGSGetSymbolicHotKeyValueFn.self)
        }
        if let isSymbolicHotKeyEnabledPtr = dlsym(handle, symbolNames.isSymbolicHotKeyEnabled) {
            isSymbolicHotKeyEnabledFn = unsafeBitCast(isSymbolicHotKeyEnabledPtr, to: CGSIsSymbolicHotKeyEnabledFn.self)
        }

        skyLightHandle = handle
        isAvailable = true
        Diagnostics.log("CGS API bridge initialized", level: .info)
        return true
    }

    private func parseSpaceID(_ value: AnyObject?) -> Int? {
        guard let value else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let numbers = value as? [NSNumber], let first = numbers.first {
            return first.intValue
        }

        if let dictionary = value as? [String: Any], let managedSpaceNumber = dictionary["ManagedSpaceID"] as? NSNumber {
            return managedSpaceNumber.intValue
        }

        return nil
    }
}
