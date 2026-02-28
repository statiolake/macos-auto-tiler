import CoreGraphics
import Foundation

struct QueuedFullReflow {
    let reason: String
}

struct QueuedDropReflow {
    let point: CGPoint
    let draggedWindowID: CGWindowID
    let hoverSlotIndex: Int?
}

enum QueuedReflowRequest {
    case drop(QueuedDropReflow)
    case full(QueuedFullReflow)
}

actor ReflowRequestState {
    private struct PriorityQueue {
        private var dropQueue: [QueuedDropReflow] = []
        private var dropHeadIndex = 0
        private var fullReflowRequested = false
        private var latestFullReflowReason = "manual"

        mutating func enqueue(_ request: QueuedReflowRequest) {
            switch request {
            case let .drop(drop):
                dropQueue.append(drop)
            case let .full(full):
                fullReflowRequested = true
                latestFullReflowReason = full.reason
            }
        }

        mutating func dequeue() -> QueuedReflowRequest? {
            if let drop = dequeueDrop() {
                return .drop(drop)
            }
            guard fullReflowRequested else {
                return nil
            }
            fullReflowRequested = false
            return .full(QueuedFullReflow(reason: latestFullReflowReason))
        }


        private mutating func dequeueDrop() -> QueuedDropReflow? {
            guard dropHeadIndex < dropQueue.count else {
                dropQueue.removeAll(keepingCapacity: true)
                dropHeadIndex = 0
                return nil
            }
            let drop = dropQueue[dropHeadIndex]
            dropHeadIndex += 1

            if dropHeadIndex >= 32, dropHeadIndex * 2 >= dropQueue.count {
                dropQueue.removeFirst(dropHeadIndex)
                dropHeadIndex = 0
            }
            return drop
        }
    }

    private var priorityQueue = PriorityQueue()
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    func enqueue(_ request: QueuedReflowRequest) {
        priorityQueue.enqueue(request)
        waitingContinuation?.resume()
        waitingContinuation = nil
    }

    func nextRequest() async -> QueuedReflowRequest? {
        while true {
            if Task.isCancelled {
                return nil
            }
            if let request = priorityQueue.dequeue() {
                return request
            }
            await withCheckedContinuation { continuation in
                waitingContinuation = continuation
            }
        }
    }

    func reset() {
        priorityQueue = PriorityQueue()
        waitingContinuation?.resume()
        waitingContinuation = nil
    }
}
