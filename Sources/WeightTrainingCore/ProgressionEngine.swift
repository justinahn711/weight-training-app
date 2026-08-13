import Foundation

/// What the engine decided, and why.
///
/// The reason travels with the decision rather than being reconstructed for
/// display later. The suggestion chips in #12 have to explain themselves — an
/// unexplained "add 10 lb" is a number to argue with, an explained one is a
/// coach — and a rationale rebuilt after the fact can drift from the logic that
/// actually produced the number.
public enum ProgressionChange: Hashable, Sendable {
    /// Reps went up within the range.
    case addedReps(to: Int)

    /// The top of the range was hit cleanly, but not yet enough times in a row
    /// to have earned the load jump.
    case earnedTowardLoad(hits: Int, required: Int)

    /// The top was hit enough times: load goes up, reps reset to the bottom.
    case addedLoad(from: Load, to: Load)

    /// The top was reached, but it cost more effort than the target RPE allows,
    /// so the same weight is repeated rather than banked as a qualifying hit.
    case heldForEffort(rpe: RPE)

    /// Fell short of the bottom of the range. Held, and counted as a stall for
    /// #13 to act on.
    case heldAfterMiss(reps: Int)

    /// RPE-targeted load steered by how the set actually felt.
    case adjustedLoad(from: Load, to: Load, rpeDelta: Double)

    /// RPE-targeted lift landed on its target effort — nothing to change.
    case onTarget(Load)

    /// An RPE-targeted lift logged with no RPE. There's nothing to steer by, so
    /// the load holds rather than being guessed at.
    case noEffortReported

    /// Nothing was performed, so nothing is inferred.
    case noWorkingSets
}

/// The engine's decision: an updated state, and the reasoning behind it.
public struct ProgressionResult: Hashable, Sendable {
    public let state: ProgressState
    public let change: ProgressionChange

    public init(state: ProgressState, change: ProgressionChange) {
        self.state = state
        self.change = change
    }

    /// One line, phrased the way it will be read on a suggestion chip.
    public var summary: String {
        switch change {
        case .addedReps(let reps):
            return "Go for \(reps) reps"
        case .earnedTowardLoad(let hits, let required):
            return "Hit the top \(hits) of \(required) times — repeat it"
        case .addedLoad(let from, let to):
            return "Earned it: \(from) → \(to)"
        case .heldForEffort(let rpe):
            return "Top of the range at \(rpe) — repeat before adding weight"
        case .heldAfterMiss(let reps):
            return "Fell short at \(reps) — hold and rebuild"
        case .adjustedLoad(let from, let to, let delta):
            let direction = to > from ? "easier" : "harder"
            return "\(String(format: "%.1f", abs(delta))) RPE \(direction) than target: \(from) → \(to)"
        case .onTarget(let load):
            return "On target — stay at \(load)"
        case .noEffortReported:
            return "No RPE logged — holding steady"
        case .noWorkingSets:
            return "Nothing logged"
        }
    }
}

/// Turns what was performed into what to do next time.
///
/// The engine is the *only* thing allowed to produce a target. The session
/// screen displays whatever `ProgressState` holds and never computes one, so a
/// number on screen can always be traced back to a decision made here.
///
/// Pure and synchronous: it takes the sets that were performed and returns a
/// new state. Nothing is read from disk and nothing is written, which is what
/// keeps the rules verifiable in milliseconds without a store.
public enum ProgressionEngine {

    /// Computes the next target after an exercise has been performed.
    ///
    /// - Parameters:
    ///   - exercise: supplies the rule and the real load increment.
    ///   - state: the state before this session.
    ///   - performed: this session's sets for this exercise. Warmups are
    ///     ignored — they say nothing about capability.
    public static func advance(
        exercise: Exercise,
        state: ProgressState,
        performed: [SetRecord],
        now: Date = Date()
    ) -> ProgressionResult {
        let working = performed.filter { !$0.isWarmup }
        guard !working.isEmpty else {
            return ProgressionResult(state: state, change: .noWorkingSets)
        }

        switch exercise.progressionRule {
        case .doubleProgression(let range, let required):
            return doubleProgression(
                exercise: exercise, state: state, working: working,
                range: range, required: required, now: now
            )
        case .rpeTargetedLoad(let reps, let targetRPE):
            return rpeTargetedLoad(
                exercise: exercise, state: state, working: working,
                reps: reps, targetRPE: targetRPE, now: now
            )
        }
    }

    // MARK: - Double progression

    private static func doubleProgression(
        exercise: Exercise,
        state: ProgressState,
        working: [SetRecord],
        range: RepRange,
        required: Int,
        now: Date
    ) -> ProgressionResult {
        // The heaviest working set is the reference. With straight sets every
        // set shares a weight anyway; taking the max means a dropped-down
        // final set can't quietly lower the target.
        let load = working.map(\.load).max() ?? Load.zero

        // The *weakest* set decides, not the best one. Double progression is a
        // promise that the whole set of straight sets clears the range — using
        // the top set would advance the lift on the strength of set one and
        // then bury the rest.
        let weakestReps = working.map(\.reps).min() ?? 0

        let targetRPE = exercise.progressionRule.displayRPETarget
        let overreached = working.compactMap(\.rpe).first { $0 > targetRPE }

        var next = state
        next.lastPerformedAt = now
        // Recorded on every session, and only ever allowed to rise on real
        // work — it's the series #24 charts and the signal #13 reads for creep.
        next.lastE1RM = working.bestE1RM
        next.targetRPE = targetRPE

        if weakestReps >= range.top {
            if let rpe = overreached {
                // Hit the top, but it cost too much. Repeat rather than bank it.
                next.targetLoad = load
                next.targetReps = range.top
                next.consecutiveTopHits = 0
                next.stallCount = 0
                return ProgressionResult(state: next, change: .heldForEffort(rpe: rpe))
            }

            let hits = state.consecutiveTopHits + 1
            if hits >= required {
                let raised = Load(load.pounds + exercise.increment.pounds)
                next.targetLoad = raised
                next.targetReps = range.bottom
                next.consecutiveTopHits = 0
                next.stallCount = 0
                return ProgressionResult(state: next, change: .addedLoad(from: load, to: raised))
            }

            next.targetLoad = load
            next.targetReps = range.top
            next.consecutiveTopHits = hits
            next.stallCount = 0
            return ProgressionResult(
                state: next,
                change: .earnedTowardLoad(hits: hits, required: required)
            )
        }

        next.consecutiveTopHits = 0

        if weakestReps < range.bottom {
            // Below the range entirely. Hold the weight and rebuild reps;
            // #13 decides when repeated misses mean a deload.
            next.targetLoad = load
            next.targetReps = range.bottom
            next.stallCount = state.stallCount + 1
            return ProgressionResult(state: next, change: .heldAfterMiss(reps: weakestReps))
        }

        let goal = min(range.top, weakestReps + 1)
        next.targetLoad = load
        next.targetReps = goal
        next.stallCount = 0
        return ProgressionResult(state: next, change: .addedReps(to: goal))
    }

    // MARK: - RPE-targeted load

    /// Load moves by roughly 3% per point of RPE.
    ///
    /// A rough conversion, and treated as such: the result is snapped to what
    /// the equipment can make, which absorbs most of the imprecision anyway.
    static let percentPerRPEPoint = 0.03

    private static func rpeTargetedLoad(
        exercise: Exercise,
        state: ProgressState,
        working: [SetRecord],
        reps: Int,
        targetRPE: RPE,
        now: Date
    ) -> ProgressionResult {
        // Every load this rule produces is a computed proposal, including the
        // ones that hold, so all of them are snapped. Otherwise a target left
        // over from a mis-measured increment (#20) would persist as a weight
        // the equipment can't actually make.
        let load = exercise.increment.snapToNearest(working.map(\.load).max() ?? Load.zero)

        var next = state
        next.lastPerformedAt = now
        // Recorded on every session, and only ever allowed to rise on real
        // work — it's the series #24 charts and the signal #13 reads for creep.
        next.lastE1RM = working.bestE1RM
        next.targetReps = reps
        next.targetRPE = targetRPE

        // Steer by the heaviest set that actually carries an effort reading.
        let scored = working.filter { $0.rpe != nil }.max { $0.load < $1.load }
        guard let reference = scored, let reported = reference.rpe else {
            next.targetLoad = load
            return ProgressionResult(state: next, change: .noEffortReported)
        }

        let delta = targetRPE.value - reported.value
        guard delta != 0 else {
            next.targetLoad = load
            next.stallCount = 0
            return ProgressionResult(state: next, change: .onTarget(load))
        }

        // Easier than target (positive delta) means the load can rise.
        let scaled = Load(reference.load.pounds * (1 + delta * percentPerRPEPoint))
        let proposed = exercise.increment.snapToNearest(scaled)

        next.targetLoad = proposed
        // A set that came in harder than target isn't a stall on its own —
        // that's RPE creep, and #13 owns deciding when it becomes one.
        next.stallCount = 0

        guard proposed != reference.load else {
            return ProgressionResult(state: next, change: .onTarget(proposed))
        }
        return ProgressionResult(
            state: next,
            change: .adjustedLoad(from: reference.load, to: proposed, rpeDelta: delta)
        )
    }
}
