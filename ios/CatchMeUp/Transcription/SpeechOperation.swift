import Foundation

/// A deadline that can finish even when a system API ignores cancellation.
/// A task-group race would still wait for that uncooperative child to exit.
/// The losing operation is cancelled; late results cannot resume the caller twice.
final class SpeechOperation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var lastActivity = ContinuousClock.now

    func heartbeat() {
        lock.lock(); defer { lock.unlock() }
        lastActivity = .now
    }

    private func expired(after timeout: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ContinuousClock.now - lastActivity >= timeout
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func attach(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { tasks.append(task) }
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }

    static func run(
        timeout: Duration,
        timeoutError: Error,
        operation: @escaping (SpeechOperation<Value>) async throws -> Value
    ) async throws -> Value {
        let gate = SpeechOperation<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.attach(Task {
                    do {
                        try Task.checkCancellation()
                        gate.finish(.success(try await operation(gate)))
                    } catch { gate.finish(.failure(error)) }
                })
                gate.attach(Task {
                    do {
                        while true {
                            try await Task.sleep(for: min(timeout, .seconds(1)))
                            if gate.expired(after: timeout) {
                                gate.finish(.failure(timeoutError))
                                return
                            }
                        }
                    } catch { /* Completion or cancellation stopped the watchdog. */ }
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}
