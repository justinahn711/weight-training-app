import Foundation

extension Collection where Element == SetRecord {

    /// Splits a history into sessions, oldest first, warmups dropped.
    ///
    /// A session is a calendar day. Crude, and correct for the same reason
    /// `LastPerformance` uses it: sessions never span midnight in practice, and
    /// a stored session id would make history depend on the app having been
    /// running when each set was logged.
    public func groupedIntoSessions(calendar: Calendar = .current) -> [[SetRecord]] {
        let working = filter { !$0.isWarmup }.sorted { $0.performedAt < $1.performedAt }
        guard !working.isEmpty else { return [] }

        var sessions: [[SetRecord]] = []
        var current: [SetRecord] = []
        for set in working {
            if let last = current.last,
               !calendar.isDate(last.performedAt, inSameDayAs: set.performedAt) {
                sessions.append(current)
                current = []
            }
            current.append(set)
        }
        sessions.append(current)
        return sessions
    }
}

/// A proposal to back the weight off and rebuild.
public struct DeloadSuggestion: Hashable, Sendable {
    public enum Trigger: Hashable, Sendable {
        /// The same target was missed in consecutive sessions.
        case repeatedMisses(sessions: Int)

        /// Effort climbed at an unchanged load — the same work costing more
        /// every time.
        case rpeCreep(from: RPE, to: RPE, sessions: Int)
    }

    public let from: Load
    public let to: Load
    public let trigger: Trigger

    public init(from: Load, to: Load, trigger: Trigger) {
        self.from = from
        self.to = to
        self.trigger = trigger
    }

    /// Stated as a reason, because a chip that can't explain itself is just a
    /// number to argue with (#12).
    public var summary: String {
        switch trigger {
        case .repeatedMisses(let sessions):
            return "Missed \(sessions) sessions running — back off to \(to) and rebuild"
        case .rpeCreep(let start, let end, let sessions):
            return "Same weight, \(start) → \(end) over \(sessions) sessions — back off to \(to)"
        }
    }
}

/// Decides when a lift has stopped progressing and should be backed off.
///
/// Both triggers are counted in *sessions of this exercise*, never in elapsed
/// weeks. A 3-4 day push/pull/legs cycle drifts against the calendar, so
/// anything keyed to "this week" misfires — three weeks off with an injury
/// isn't three weeks of stalling.
public enum DeloadDetector {

    /// How far back a deload takes the weight.
    public static let deloadFraction = 0.10

    /// Consecutive missed sessions before backing off.
    ///
    /// Two rather than three: by the second miss the weight has been attempted
    /// and failed twice, and a third attempt mostly buys fatigue.
    public static let missesBeforeDeload = 2

    /// Sessions of rising effort at an unchanged load before backing off.
    ///
    /// Three readings, because two is a mood and three is a trend.
    public static let creepSessions = 3

    /// - Parameters:
    ///   - state: supplies `stallCount`, maintained by the engine.
    ///   - history: every set ever logged for this exercise.
    /// - Returns: a proposal, or nil when the lift is progressing normally.
    public static func evaluate(
        exercise: Exercise,
        state: ProgressState,
        history: [SetRecord],
        calendar: Calendar = .current
    ) -> DeloadSuggestion? {
        let sessions = history.groupedIntoSessions(calendar: calendar)

        // Misses first: an outright failure is more definite evidence than a
        // trend in a subjective rating.
        if state.stallCount >= missesBeforeDeload {
            guard let load = state.targetLoad ?? sessions.last?.map(\.load).max() else { return nil }
            let backed = backedOff(load, on: exercise)
            // Already as light as the equipment goes. Proposing "45 → 45" is
            // worse than saying nothing: a lift stalling on an empty bar is an
            // exercise-selection problem, not a loading one.
            guard backed < load else { return nil }
            return DeloadSuggestion(
                from: load,
                to: backed,
                trigger: .repeatedMisses(sessions: state.stallCount)
            )
        }

        return creep(exercise: exercise, sessions: sessions)
    }

    /// RPE climbing at a constant load — the signal that fires weeks before a
    /// rep is actually missed, which is the whole reason RPE is captured on
    /// every working set.
    private static func creep(exercise: Exercise, sessions: [[SetRecord]]) -> DeloadSuggestion? {
        guard sessions.count >= creepSessions else { return nil }
        let recent = sessions.suffix(creepSessions)

        // Compare like with like: the heaviest set of each session, which is
        // what progression turns on.
        let topSets = recent.compactMap { session in
            session.max { $0.load < $1.load }
        }
        guard topSets.count == creepSessions else { return nil }

        // The load has to be unchanged, or rising effort is just the weight
        // going up as intended.
        let loads = Set(topSets.map(\.load))
        guard loads.count == 1, let load = loads.first else { return nil }

        let rpes = topSets.compactMap(\.rpe)
        guard rpes.count == creepSessions else { return nil }

        // Strictly increasing. A flat stretch is holding steady, not creeping.
        let climbing = zip(rpes, rpes.dropFirst()).allSatisfy { $0 < $1 }
        guard climbing, let first = rpes.first, let last = rpes.last else { return nil }

        let backed = backedOff(load, on: exercise)
        guard backed < load else { return nil }

        return DeloadSuggestion(
            from: load,
            to: backed,
            trigger: .rpeCreep(from: first, to: last, sessions: creepSessions)
        )
    }

    /// Backs a load off by 10%, rounded *down* to something buildable.
    ///
    /// Down rather than to nearest: the point of a deload is to be
    /// comfortably lighter, and rounding up would shave the recovery it exists
    /// to provide. A jump so coarse that 10% rounds to nothing still moves at
    /// least one increment, or the suggestion would propose no change at all.
    private static func backedOff(_ load: Load, on exercise: Exercise) -> Load {
        // One increment, not zero. On a 10 lb dumbbell step, backing 10 lb off
        // by 10% snaps to nothing at all — and "back off to 0 lb and rebuild"
        // is not a deload, it's a bug with a friendly sentence around it.
        let floor = exercise.lightestUsableLoad
        let increment = exercise.increment
        let target = Load(load.pounds * (1 - deloadFraction))
        var result = increment.snap(target)
        if result >= load {
            result = Load(load.pounds - increment.pounds)
        }
        // Never below what the equipment can present: an empty bar is as light
        // as a barbell deload gets.
        return max(floor, min(result, load))
    }
}
