import Foundation

final class WindowSnapshotStabilizer {
    enum SettleReason: String {
        case stable
        case timeout
    }

    struct Snapshot {
        let signature: UInt64
        let windowCount: Int
    }

    struct Result {
        let generation: UInt64
        let reason: SettleReason
    }

    typealias SnapshotProvider = () -> Snapshot
    typealias ProbeHandler = (_ generation: UInt64, _ stableCount: Int, _ required: Int, _ windowCount: Int) -> Void

    private let stableSnapshotsRequired: Int
    private let probeInterval: TimeInterval
    private let timeout: TimeInterval
    private let probeQueue: DispatchQueue
    private let snapshotProvider: SnapshotProvider
    private let probeHandler: ProbeHandler?

    private static let generationLock = NSLock()
    private static var nextGeneration: UInt64 = 0

    init(
        stableSnapshotsRequired: Int,
        probeInterval: TimeInterval,
        timeout: TimeInterval,
        probeQueue: DispatchQueue,
        snapshotProvider: @escaping SnapshotProvider,
        probeHandler: ProbeHandler? = nil
    ) {
        self.stableSnapshotsRequired = max(1, stableSnapshotsRequired)
        self.probeInterval = probeInterval
        self.timeout = timeout
        self.probeQueue = probeQueue
        self.snapshotProvider = snapshotProvider
        self.probeHandler = probeHandler
    }

    func waitForStabilize() async -> Result {
        let generation = Self.issueGeneration()
        let startedAt = Date()
        let sleepNanoseconds = UInt64(max(0, probeInterval * 1_000_000_000))

        var lastSignature: UInt64?
        var stableCount = 0

        while true {
            if Task.isCancelled {
                return Result(generation: generation, reason: .timeout)
            }

            let snapshot = await probeSnapshot()
            if snapshot.signature == lastSignature {
                stableCount += 1
            } else {
                lastSignature = snapshot.signature
                stableCount = 1
            }

            probeHandler?(generation, stableCount, stableSnapshotsRequired, snapshot.windowCount)

            if stableCount >= stableSnapshotsRequired {
                return Result(generation: generation, reason: .stable)
            }

            if Date().timeIntervalSince(startedAt) >= timeout {
                return Result(generation: generation, reason: .timeout)
            }

            if sleepNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            } else {
                await Task.yield()
            }
        }
    }

    private func probeSnapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            probeQueue.async { [snapshotProvider] in
                continuation.resume(returning: snapshotProvider())
            }
        }
    }

    private static func issueGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        nextGeneration &+= 1
        return nextGeneration
    }
}
