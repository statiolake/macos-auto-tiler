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
    private typealias CGSManagedDisplaySetCurrentSpaceFn =
        @convention(c) (CGSConnectionID, CFString, UInt64) -> Void

    private let stateLock = NSLock()
    private var isResolved = false
    private var isAvailable = false
    private var skyLightHandle: UnsafeMutableRawPointer?

    private var mainConnectionIDFn: CGSMainConnectionIDFn?
    private var copySpacesForWindowsFn: CGSCopySpacesForWindowsFn?
    private var copyManagedDisplaySpacesFn: CGSCopyManagedDisplaySpacesFn?
    private var copyBestManagedDisplayForRectFn: CGSCopyBestManagedDisplayForRectFn?
    private var managedDisplaySetCurrentSpaceFn: CGSManagedDisplaySetCurrentSpaceFn?

    private let allSpacesMask: UInt32 = 0x7

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
        guard prepare() else {
            return false
        }
        guard
            let mainConnectionIDFn,
            let copyManagedDisplaySpacesFn,
            let copyBestManagedDisplayForRectFn,
            let managedDisplaySetCurrentSpaceFn
        else {
            return false
        }

        let connection = mainConnectionIDFn()
        let bounds = CGDisplayBounds(displayID)
        guard
            let managedDisplayID = copyBestManagedDisplayForRectFn(connection, bounds)?.takeRetainedValue()
        else {
            return false
        }

        guard let rawDescriptions = copyManagedDisplaySpacesFn(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        guard let displayDescription = rawDescriptions.first(where: {
            ($0["Display Identifier"] as? String) == (managedDisplayID as String)
        }) else {
            return false
        }

        guard
            let currentSpace = displayDescription["Current Space"] as? [String: Any],
            let currentSpaceID = parseSpaceID(currentSpace["ManagedSpaceID"] as AnyObject),
            let spaces = displayDescription["Spaces"] as? [[String: Any]]
        else {
            return false
        }

        let spaceIDs = spaces.compactMap { parseSpaceID($0["ManagedSpaceID"] as AnyObject) }
        guard let currentIndex = spaceIDs.firstIndex(of: currentSpaceID) else {
            return false
        }

        let targetIndex = goLeft ? currentIndex - 1 : currentIndex + 1
        guard targetIndex >= 0, targetIndex < spaceIDs.count else {
            return false
        }

        let targetSpaceID = spaceIDs[targetIndex]
        managedDisplaySetCurrentSpaceFn(connection, managedDisplayID, UInt64(targetSpaceID))
        return true
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
            setCurrentSpace: "CGSManagedDisplaySetCurrentSpace"
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

        if let setCurrentSpacePtr = dlsym(handle, symbolNames.setCurrentSpace) {
            managedDisplaySetCurrentSpaceFn = unsafeBitCast(setCurrentSpacePtr, to: CGSManagedDisplaySetCurrentSpaceFn.self)
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
