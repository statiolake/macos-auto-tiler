import ApplicationServices
import CoreGraphics

enum AXValueUtils {
    static func copyFrame(of element: AXUIElement) -> CGRect? {
        guard
            let position: CGPoint = copyValue(kAXPositionAttribute, type: .cgPoint, from: element),
            let size: CGSize = copyValue(kAXSizeAttribute, type: .cgSize, from: element)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func setPosition(_ point: CGPoint, on element: AXUIElement) -> AXError {
        setValue(point, type: .cgPoint, attribute: kAXPositionAttribute, on: element)
    }

    static func setSize(_ size: CGSize, on element: AXUIElement) -> AXError {
        setValue(size, type: .cgSize, attribute: kAXSizeAttribute, on: element)
    }

    private static func copyValue<T: BitwiseCopyable>(_ attribute: String, type: AXValueType, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
            guard AXValueGetValue(axValue, type, buffer.baseAddress!) else { return nil }
            return buffer.baseAddress!.pointee
        }
    }

    private static func setValue<T: BitwiseCopyable>(_ value: T, type: AXValueType, attribute: String, on element: AXUIElement) -> AXError {
        var mutable = value
        guard let axValue = AXValueCreate(type, &mutable) else {
            preconditionFailure("AXValueCreate failed for \(type)")
        }
        return AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }
}
