import CoreGraphics
import Darwin
import Foundation

/// Bridge to the private SkyLight space APIs: which space a window lives on, which space each display shows,
/// and switching to the adjacent space through the user's Mission Control shortcut.
final class CGSSpaceService {
    static let shared = CGSSpaceService()

    private typealias MainConnectionIDFn = @convention(c) () -> UInt32
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopyBestManagedDisplayForRectFn = @convention(c) (UInt32, CGRect) -> Unmanaged<CFString>?
    private typealias GetSymbolicHotKeyValueFn = @convention(c) (
        UInt32, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32
    private typealias IsSymbolicHotKeyEnabledFn = @convention(c) (UInt32) -> Bool

    private static let allSpacesMask: UInt32 = 0x7
    private static let moveLeftSpaceHotKey: UInt32 = 79
    private static let moveRightSpaceHotKey: UInt32 = 81

    private let connection: UInt32
    private let copySpacesForWindows: CopySpacesForWindowsFn
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn
    private let copyBestManagedDisplayForRect: CopyBestManagedDisplayForRectFn
    private let getSymbolicHotKeyValue: GetSymbolicHotKeyValueFn
    private let isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabledFn

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            fatalError("SkyLight framework is unavailable")
        }
        func symbol<T>(_ name: String, as _: T.Type) -> T {
            guard let pointer = dlsym(handle, name) else {
                fatalError("SkyLight symbol \(name) is unavailable on this macOS version")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        connection = symbol("CGSMainConnectionID", as: MainConnectionIDFn.self)()
        copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        copyBestManagedDisplayForRect = symbol("CGSCopyBestManagedDisplayForRect", as: CopyBestManagedDisplayForRectFn.self)
        getSymbolicHotKeyValue = symbol("CGSGetSymbolicHotKeyValue", as: GetSymbolicHotKeyValueFn.self)
        isSymbolicHotKeyEnabled = symbol("CGSIsSymbolicHotKeyEnabled", as: IsSymbolicHotKeyEnabledFn.self)
    }

    /// Windows the window server cannot place on a space right now are absent from the result.
    func spacesByWindowID(windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        var result: [CGWindowID: Int] = [:]
        for windowID in windowIDs {
            let spaces = copySpacesForWindows(connection, Self.allSpacesMask, [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
            if let spaceID = spaces?.first?.intValue {
                result[windowID] = spaceID
            }
        }
        return result
    }

    /// Displays whose current space cannot be resolved right now are absent from the result.
    func currentSpaceByDisplayID(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Int] {
        var result: [CGDirectDisplayID: Int] = [:]
        for displayID in displayIDs {
            if let display = managedDisplay(for: displayID), let current = spaceID(display["Current Space"]) {
                result[displayID] = current
            }
        }
        return result
    }

    /// Posts the system "Move left/right a space" shortcut. Returns false when there is no space in that
    /// direction or the user disabled the shortcut.
    func switchToAdjacentSpace(displayID: CGDirectDisplayID, goLeft: Bool) -> Bool {
        guard
            let display = managedDisplay(for: displayID),
            let current = spaceID(display["Current Space"]),
            let spaces = (display["Spaces"] as? [Any])?.compactMap(spaceID),
            let index = spaces.firstIndex(of: current),
            spaces.indices.contains(goLeft ? index - 1 : index + 1)
        else {
            return false
        }

        let hotKey = goLeft ? Self.moveLeftSpaceHotKey : Self.moveRightSpaceHotKey
        guard isSymbolicHotKeyEnabled(hotKey) else {
            Diagnostics.log("Space switch skipped: the Mission Control shortcut is disabled", level: .warn)
            return false
        }
        var keyCode: UInt16 = 0
        var flags: UInt32 = 0
        guard getSymbolicHotKeyValue(hotKey, nil, &keyCode, &flags) == 0 else {
            preconditionFailure("CGSGetSymbolicHotKeyValue failed for enabled hotkey \(hotKey)")
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            preconditionFailure("failed to create keyboard events for space switch")
        }
        keyDown.flags = CGEventFlags(rawValue: UInt64(flags))
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func managedDisplay(for displayID: CGDirectDisplayID) -> [String: Any]? {
        guard
            let identifier = copyBestManagedDisplayForRect(connection, CGDisplayBounds(displayID))?.takeRetainedValue() as String?,
            let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else {
            return nil
        }
        return displays.first { $0["Display Identifier"] as? String == identifier }
    }

    private func spaceID(_ value: Any?) -> Int? {
        ((value as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.intValue
    }
}
