//
//  PermissionQueue.swift
//  ChickenBreast
//

import Foundation

/// Runs system permission prompts one at a time (#110).
///
/// A clean launch used to put the notification alert on top of the Health
/// sheet, because `openStore` started readiness in a detached `Task` and then
/// scheduled the digest on its own path. Two independent callers, no shared
/// state, both reaching iOS in the same run loop.
///
/// Being main-actor-isolated is not what fixes that. Isolation is reentrant:
/// a second call entering `run` while the first is suspended at its `await` is
/// admitted immediately — and a permission sheet on screen is nothing *but*
/// suspension, so that is precisely the window the bug lives in. The
/// serialisation is therefore explicit: each caller awaits the tail of the
/// queue before running, and becomes the new tail.
///
/// Main-actor rather than an `actor` because every prompt here is triggered by
/// something on screen and reads main-actor state to decide — a `@Sendable`
/// closure would force `HKHealthStore` and the view model across an isolation
/// boundary to buy concurrency this never wanted.
///
/// The queue is not a permission policy. It does not decide whether to ask, or
/// remember an answer; iOS already remembers, and *when* to ask is a decision
/// each feature makes for itself at the moment its benefit is concrete. This
/// only guarantees that two such moments arriving at once are seen by the
/// person one after the other rather than stacked.
@MainActor
final class PermissionQueue {
    static let shared = PermissionQueue()

    private var tail: Task<Void, Never>?

    /// Runs `work` once every prompt queued before it has finished.
    ///
    /// Cancellation is deliberately not propagated into `work`: a half-shown
    /// system sheet is not something the app can take back, and a caller
    /// going away must not leave the next one waiting forever. The chain is
    /// built from non-throwing, non-cancelling tasks for that reason.
    ///
    /// - Important: `work` must not call `run` again. The inner call would
    ///   wait on a tail whose completion depends on the outer `work` it is
    ///   nested inside, and neither would finish. Two prompts that belong
    ///   together — speech then microphone — go in one closure for this
    ///   reason, which is also the behaviour you want: nothing unrelated can
    ///   be slotted between them.
    @discardableResult
    func run<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        // The tail is the *completion* of that task, erased of its result, so
        // the next caller can wait on it without knowing what this one returns.
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
