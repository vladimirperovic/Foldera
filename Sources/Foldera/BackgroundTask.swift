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
    private var cancellation: CancelFlag?
    private(set) var generation = 0

    init(queue: OperationQueue) { self.queue = queue }

    func cancel() {
        generation += 1
        operation?.cancel()
        operation = nil
        cancellation?.set()
        cancellation = nil
    }

    /// Ahead of the queue's other work, as for the picture on screen.
    func hurry() {
        operation?.queuePriority = .veryHigh
    }

    func run<Value>(_ work: @escaping () -> Value, then deliver: @escaping (Value) -> Void) {
        runCancellable({ _ in work() }, then: deliver)
    }

    /// Running filesystem/parser work checks this token between its units;
    /// invalidating only the eventual UI callback leaves expensive work alive.
    func runCancellable<Value>(_ work: @escaping (CancelFlag) -> Value, then deliver: @escaping (Value) -> Void) {
        cancel()
        let generation = self.generation
        let cancelled = CancelFlag()
        cancellation = cancelled
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let value = autoreleasepool { work(cancelled) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, !operation.isCancelled else { return }
                self.operation = nil
                self.cancellation = nil
                deliver(value)
            }
        }
        self.operation = operation
        queue.addOperation(operation)
    }

    deinit { operation?.cancel(); cancellation?.set() }
}

/// A burst of main-thread events gets one pass over the latest state. Unlike
/// a debounce, continuous scrolling cannot postpone work indefinitely.
final class CoalescedTask {
    private let delay: TimeInterval
    private let action: () -> Void
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval, action: @escaping () -> Void) {
        self.delay = delay
        self.action = action
    }

    func request() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.action()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() { pending?.cancel(); pending = nil }
    deinit { pending?.cancel() }
}
