import Foundation

enum FNV1a64 {
    private static let prime: UInt64 = 1_099_511_628_211

    static func combine(_ hash: inout UInt64, _ value: UInt64) {
        hash ^= value
        hash = hash &* prime
    }

    static func combine(_ hash: inout UInt64, signed value: Int) {
        combine(&hash, UInt64(bitPattern: Int64(value)))
    }
}
