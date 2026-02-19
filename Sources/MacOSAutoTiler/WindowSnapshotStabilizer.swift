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

    typealias SnapshotProvider = () -> Snapshot
    typealias ProbeHandler = (_ generation: UInt64, _ stableCount: Int, _ required: Int, _ windowCount: Int) -> Void
    typealias SettledHandler = (_ generation: UInt64, _ reason: SettleReason) -> Void

    private let stableSnapshotsRequired: Int
    private let probeInterval: TimeInterval
    private let timeout: TimeInterval
    private let probeQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let snapshotProvider: SnapshotProvider
    private let probeHandler: ProbeHandler?
    private let settledHandler: SettledHandler

    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var startedAt: Date?
    private var lastSignature: UInt64?
    private var stableCount = 0
    private var probeWorkItem: DispatchWorkItem?

    init(
        stableSnapshotsRequired: Int,
        probeInterval: TimeInterval,
        timeout: TimeInterval,
        probeQueue: DispatchQueue,
        callbackQueue: DispatchQueue = .main,
        snapshotProvider: @escaping SnapshotProvider,
        probeHandler: ProbeHandler? = nil,
        settledHandler: @escaping SettledHandler
    ) {
        self.stableSnapshotsRequired = max(1, stableSnapshotsRequired)
        self.probeInterval = probeInterval
        self.timeout = timeout
        self.probeQueue = probeQueue
        self.callbackQueue = callbackQueue
        self.snapshotProvider = snapshotProvider
        self.probeHandler = probeHandler
        self.settledHandler = settledHandler
    }

    var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeGeneration != nil
    }

    @discardableResult
    func start() -> UInt64 {
        let generation: UInt64
        stateLock.lock()
        self.generation &+= 1
        generation = self.generation
        activeGeneration = generation
        startedAt = Date()
        lastSignature = nil
        stableCount = 0
        probeWorkItem?.cancel()
        probeWorkItem = nil
        stateLock.unlock()

        probe(generation: generation)
        return generation
    }

    func cancel() {
        stateLock.lock()
        generation &+= 1
        activeGeneration = nil
        startedAt = nil
        lastSignature = nil
        stableCount = 0
        probeWorkItem?.cancel()
        probeWorkItem = nil
        stateLock.unlock()
    }

    private func probe(generation: UInt64) {
        probeQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshotProvider()
            self.callbackQueue.async { [weak self] in
                self?.handleProbe(generation: generation, snapshot: snapshot)
            }
        }
    }

    private func handleProbe(generation: UInt64, snapshot: Snapshot) {
        let stableCount: Int
        let settledReason: SettleReason?

        stateLock.lock()
        guard activeGeneration == generation else {
            stateLock.unlock()
            return
        }

        if snapshot.signature == lastSignature {
            self.stableCount += 1
        } else {
            lastSignature = snapshot.signature
            self.stableCount = 1
        }
        stableCount = self.stableCount

        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        let reachedStability = stableCount >= stableSnapshotsRequired
        let reachedTimeout = elapsed >= timeout

        if reachedStability || reachedTimeout {
            settledReason = reachedStability ? .stable : .timeout
            activeGeneration = nil
            startedAt = nil
            lastSignature = nil
            self.stableCount = 0
            probeWorkItem?.cancel()
            probeWorkItem = nil
        } else {
            settledReason = nil
        }
        stateLock.unlock()

        probeHandler?(generation, stableCount, stableSnapshotsRequired, snapshot.windowCount)

        if let settledReason {
            settledHandler(generation, settledReason)
            return
        }

        scheduleNextProbe(generation: generation)
    }

    private func scheduleNextProbe(generation: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.probe(generation: generation)
        }

        stateLock.lock()
        guard activeGeneration == generation else {
            stateLock.unlock()
            return
        }
        probeWorkItem?.cancel()
        probeWorkItem = workItem
        stateLock.unlock()

        callbackQueue.asyncAfter(deadline: .now() + probeInterval, execute: workItem)
    }
}
