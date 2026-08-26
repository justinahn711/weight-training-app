import Foundation

/// What the session screen shows above a set: the target to beat, or an honest
/// admission that there isn't one yet.
///
/// Deliberately a *display* concern, not a decision. It reads whatever
/// `ProgressState` already holds and falls back to the rule's defaults; it
/// never computes a new target. Deciding what the next target should be is the
/// progression engine's job (#9-#15), and keeping that out of here means the
/// screen can't quietly invent a number nobody earned.
public struct Prescription: Hashable, Sendable {
    /// Nil the first time a lift is seen. The screen says so rather than
    /// guessing a starting weight — a wrong guess costs a working set.
    public var load: Load?
    public var reps: Int
    public var rpe: RPE

    /// True when this is the first time the exercise has been performed.
    public var isColdStart: Bool { load == nil }

    public init(load: Load?, reps: Int, rpe: RPE) {
        self.load = load
        self.reps = reps
        self.rpe = rpe
    }

    /// Reads the target off the exercise's stored state, with the progression
    /// rule supplying the reps and RPE whenever state doesn't.
    ///
    /// The stored target is snapped to what the equipment can currently be set
    /// to, rather than echoed. State outlives configuration: a stack corrected
    /// from 10 lb to 15 (#20), or a machine whose plate set was recorded (#39),
    /// leaves behind targets the equipment can no longer make. Snapping here is
    /// what makes a correction reflow the next target immediately instead of
    /// waiting for the next session to advance it.
    public init(exercise: Exercise, state: ProgressState?) {
        self.load = state?.targetLoad.map { exercise.nearestAchievable($0) }
        self.reps = state?.targetReps ?? exercise.progressionRule.displayRepTarget
        self.rpe = state?.targetRPE ?? exercise.progressionRule.displayRPETarget
    }

    /// The target as one line, read at arm's length between sets.
    ///
    /// Pound-only, for tests and debugging. Anything a lifter reads goes
    /// through `displayLine(in:)` with the unit their gym is marked in (#67).
    public var displayLine: String { displayLine(in: .pounds) }

    /// The target in the unit the lifter thinks in.
    public func displayLine(in unit: MassUnit) -> String {
        guard let load else { return "First time — just log it" }
        return "\(load.formatted(in: unit)) × \(reps) @ \(rpe)"
    }
}

/// How an exercise went the last time it was performed.
///
/// Shown next to the target because the target alone doesn't answer the
/// question actually being asked at the rack: *what did I do last time?*
public struct LastPerformance: Hashable, Sendable {
    public let performedAt: Date

    /// Working sets only, in the order performed. Warmups are excluded — they
    /// say nothing about what the lift is capable of.
    public let sets: [SetRecord]

    public init(performedAt: Date, sets: [SetRecord]) {
        self.performedAt = performedAt
        self.sets = sets
    }

    /// The most recent session's working sets, pulled out of a full history.
    ///
    /// A "session" is the calendar day of the most recent set. That's crude,
    /// and it's correct here: sessions are hours long and never span midnight
    /// in practice, and the alternative — a stored session id — would make
    /// history depend on the app having been running when the set was logged.
    public static func mostRecent(
        in history: [SetRecord],
        calendar: Calendar = .current
    ) -> LastPerformance? {
        let working = history.filter { !$0.isWarmup }
        guard let latest = working.map(\.performedAt).max() else { return nil }

        let sets = working
            .filter { calendar.isDate($0.performedAt, inSameDayAs: latest) }
            .sorted { $0.performedAt < $1.performedAt }
        return LastPerformance(performedAt: latest, sets: sets)
    }

    /// Compact enough for a subtitle: `70 lb × 11, 10, 8`.
    ///
    /// Load is stated once when every set used the same weight, which is the
    /// normal case for straight sets and keeps the line short.
    public var displayLine: String { displayLine(in: .pounds) }

    /// The same line, in the unit the lifter thinks in (#67).
    public func displayLine(in unit: MassUnit) -> String {
        guard !sets.isEmpty else { return "—" }
        let reps = sets.map { String($0.reps) }.joined(separator: ", ")
        let loads = Set(sets.map(\.load))
        if loads.count == 1, let load = loads.first {
            return "\(load.formatted(in: unit)) × \(reps)"
        }
        return sets.map { "\($0.load.formatted(in: unit)) × \($0.reps)" }
            .joined(separator: ", ")
    }

    /// The heaviest working set, which is what progression actually turns on.
    public var topSet: SetRecord? {
        sets.max { $0.load < $1.load }
    }
}
