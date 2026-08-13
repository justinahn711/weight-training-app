import Foundation

/// The per-exercise brain: what to prescribe next time this movement comes up.
///
/// Progression lives on the exercise rather than on a program week, because the
/// split is a shape rather than a script. Choosing incline press on push day
/// yields a target immediately, even if it was last performed three weeks ago.
public struct ProgressState: Hashable, Codable, Sendable {
    public let exerciseID: UUID

    /// Nil until the exercise has been performed once. The cold start is
    /// explicit rather than guessed: the first session logs blind and
    /// suggestions switch on the second time the lift is seen.
    public var targetLoad: Load?
    public var targetReps: Int?
    public var targetRPE: RPE?

    /// Sessions in a row that failed to meet the target — counted in sessions
    /// of *this exercise*, never in elapsed weeks, because a 3–4 day PPL cycle
    /// drifts against the calendar.
    public var stallCount: Int

    /// Consecutive sessions hitting the top of the rep range, used by double
    /// progression to decide when a load jump has been earned.
    public var consecutiveTopHits: Int

    public var lastE1RM: Load?
    public var lastPerformedAt: Date?

    public init(
        exerciseID: UUID,
        targetLoad: Load? = nil,
        targetReps: Int? = nil,
        targetRPE: RPE? = nil,
        stallCount: Int = 0,
        consecutiveTopHits: Int = 0,
        lastE1RM: Load? = nil,
        lastPerformedAt: Date? = nil
    ) {
        self.exerciseID = exerciseID
        self.targetLoad = targetLoad
        self.targetReps = targetReps
        self.targetRPE = targetRPE
        self.stallCount = stallCount
        self.consecutiveTopHits = consecutiveTopHits
        self.lastE1RM = lastE1RM
        self.lastPerformedAt = lastPerformedAt
    }

    /// True before the exercise has ever been performed, when the session
    /// screen shows "first time — just log it" instead of a target.
    public var isColdStart: Bool { targetLoad == nil }
}
