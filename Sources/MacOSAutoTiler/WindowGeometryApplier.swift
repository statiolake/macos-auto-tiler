import CoreGraphics
import Foundation

final class WindowGeometryApplier {
    private let actuator: AXWindowActuator
    private let queue: DispatchQueue

    init(
        actuator: AXWindowActuator = AXWindowActuator(),
        queue: DispatchQueue = DispatchQueue(label: "com.dicen.macosautotiler.actuation")
    ) {
        self.actuator = actuator
        self.queue = queue
    }

    func applySync(
        reason: String,
        targetFrames: [CGWindowID: CGRect],
        windowsByID: [CGWindowID: WindowRef]
    ) -> [CGWindowID] {
        Diagnostics.log(
            "AX apply(sync) reason=\(reason) targets=\(targetFrames.count)",
            level: .debug
        )
        return queue.sync {
            actuator.apply(targetFrames: targetFrames, windows: windowsByID)
        }
    }
}
