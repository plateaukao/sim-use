// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Funnels every request onto the XCTest *test thread*.
///
/// Two reasons this exists rather than handling requests on the socket
/// threads directly:
///
///  1. **Thread affinity.** `XCUIApplication` / `XCUIElement` /
///     `XCUIDevice` are driven from the thread XCTest started the test
///     method on. Calling them from arbitrary socket threads works
///     most of the time and then intermittently deadlocks against
///     `XCTRunnerDaemonSession`'s reply queue — the same class of hang
///     the Android bridge hit with concurrent `rootInActiveWindow`
///     calls and solved with a semaphore.
///  2. **Serialization.** Two overlapping synthesized-event streams
///     (say a `/swipe` and a `/tap`) produce interleaved touch phases
///     that the system rejects wholesale. One in flight at a time is
///     the only sane contract, and matches what the CLI actually does.
///
/// The test method calls `drainForever()` and never returns; socket
/// threads call `submit` and block until their closure has run.
final class SerialWorkQueue {
    private final class Job {
        let work: () -> Void
        let done = DispatchSemaphore(value: 0)
        init(work: @escaping () -> Void) { self.work = work }
    }

    private let condition = NSCondition()
    private var pending: [Job] = []
    private var stopped = false

    /// Runs `work` on the draining thread and returns its value.
    /// Returns `nil` once the queue has been stopped, which callers
    /// surface as a 503 — the same shape the Android router uses when
    /// its AccessibilityService instance has gone away.
    func submit<T>(timeout: TimeInterval, _ work: @escaping () -> T) -> T? {
        var result: T?
        let job = Job { result = work() }

        condition.lock()
        if stopped {
            condition.unlock()
            return nil
        }
        pending.append(job)
        condition.signal()
        condition.unlock()

        // A handler that wedges (a stuck XCUI query, a modal system
        // alert swallowing events) must not wedge the socket thread
        // forever. On timeout we abandon the result; the job stays
        // queued and will still run, but its writes go to a `result`
        // nobody reads.
        guard job.done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result
    }

    /// Consumes jobs until `stop()` is called. Invoked from the XCTest
    /// test method, so "forever" is the intended lifetime.
    func drainForever() {
        while true {
            condition.lock()
            while pending.isEmpty && !stopped {
                condition.wait()
            }
            if stopped && pending.isEmpty {
                condition.unlock()
                return
            }
            let job = pending.removeFirst()
            condition.unlock()

            job.work()
            job.done.signal()
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}
