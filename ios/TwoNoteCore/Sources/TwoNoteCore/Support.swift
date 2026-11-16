import Foundation

/// A value behind a lock. The body never suspends, so this is safe to use from any context.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A FIFO lock that can be held across suspension points (what `SemaphoreSlim(1, 1)` is in the
/// .NET client). Waiting is not cancellable; holders are expected to finish.
final class AsyncLock: Sendable {
    private struct State {
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Locked(State())

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { s -> Bool in
                if s.held {
                    s.waiters.append(continuation)
                    return false
                }
                s.held = true
                return true
            }
            if acquired {
                continuation.resume()
            }
        }
    }

    func unlock() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiters.isEmpty {
                s.held = false
                return nil
            }
            return s.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// "Something happened, look again": a one-slot signal with a timed wait, for the sync loop.
final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var generation = 0
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Locked(State())

    /// Wakes the waiter, or the next call to `wait` if nobody is waiting.
    func signal() {
        let waiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.pending = true
            return nil
        }
        waiter?.resume(returning: true)
    }

    /// Waits for a signal. Returns true if signalled, false when the time ran out or the task
    /// was cancelled. One waiter at a time.
    func wait(for timeout: Duration) async -> Bool {
        let generation = state.withLock { s -> Int in
            s.generation += 1
            return s.generation
        }
        let timer = Task { [self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            expire(generation)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = state.withLock { s -> Bool? in
                    if s.pending {
                        s.pending = false
                        return true
                    }
                    if Task.isCancelled || s.generation != generation {
                        return false
                    }
                    s.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            expire(generation)
        }
    }

    private func expire(_ generation: Int) {
        let waiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            guard s.generation == generation else { return nil }
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume(returning: false)
    }
}

extension Duration {
    /// The duration in seconds, for the APIs that still take a `TimeInterval`.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
