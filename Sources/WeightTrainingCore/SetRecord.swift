import Foundation

/// One performed set.
///
/// Straight sets only — there is deliberately no parent/child nesting for drop
/// sets or superset pairing. That nesting is what turns a lifting log into a
/// form to fill out, and it buys nothing for the way these sessions run.
public struct SetRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let exerciseID: UUID
    public var load: Load
    public var reps: Int

    /// Absent on warmups, which are never scored.
    public var rpe: RPE?

    /// Warmups are excluded from volume counts, e1RM, and every statistic.
    /// Keeping them in the same table (rather than a separate one) means the
    /// session screen can render a workout in document order without a join.
    public var isWarmup: Bool

    public var performedAt: Date

    public init(
        id: UUID = UUID(),
        exerciseID: UUID,
        load: Load,
        reps: Int,
        rpe: RPE? = nil,
        isWarmup: Bool = false,
        performedAt: Date
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.load = load
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.performedAt = performedAt
    }

    /// Whether this set counts toward weekly volume.
    ///
    /// Junk volume shouldn't inflate the guard, so a working set only counts as
    /// "hard" at RPE 7 or above. Sets logged without an RPE are counted, since
    /// the alternative is silently discarding real work.
    public var isHardSet: Bool {
        guard !isWarmup else { return false }
        guard let rpe else { return true }
        return rpe >= RPE(7)!
    }
}
