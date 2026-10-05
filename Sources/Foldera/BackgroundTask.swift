import Foundation

/// Owned by the main thread. A new request cancels queued work and makes
/// any result already being computed obsolete, including its UI callback.
final class BackgroundTask {
    static func queue(_ name: String, limit: Int = 2) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = limit
        return queue
    }

    private let queue: OperationQueue
    private var operation: BlockOperation?
    private(set) var generation = 0

    init(queue: OperationQueue) { self.queue = queue }

    func cancel() {
        generation += 1
        operation?.cancel()
        operation = nil
    }

    func run<Value>(_ work: @escaping () -> Value, then deliver: @escaping (Value) -> Void) {
        cancel()
        let generation = self.generation
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let value = autoreleasepool(invoking: work)
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, !operation.isCancelled else { return }
                self.operation = nil
                deliver(value)
            }
        }
        self.operation = operation
        queue.addOperation(operation)
    }

    deinit { operation?.cancel() }
}
