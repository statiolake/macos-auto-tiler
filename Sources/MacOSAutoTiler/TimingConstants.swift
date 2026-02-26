import Foundation

enum TimingConstants {
    // Small delay to let CG/AX state converge around rapid lifecycle transitions.
    static let shortSettleDelay: TimeInterval = 0.2
    static let shortSettleDelayNanoseconds: UInt64 = 200_000_000
}
