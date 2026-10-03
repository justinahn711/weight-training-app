import Foundation

/// ActivityKit-free facts for deciding which system activity belongs to the
/// workout being opened.
public struct SessionActivityCandidate: Hashable, Sendable {
    public let id: String
    public let workoutID: String?
    public let dayKind: String

    public init(id: String, workoutID: String?, dayKind: String) {
        self.id = id
        self.workoutID = workoutID
        self.dayKind = dayKind
    }
}

public enum SessionActivitySelection {
    public static func keeperID(
        workoutID: String,
        dayKind: String,
        from candidates: [SessionActivityCandidate]
    ) -> String? {
        candidates.first { $0.workoutID == workoutID }?.id
            ?? candidates.first { $0.workoutID == nil && $0.dayKind == dayKind }?.id
    }

    /// One shared boundary for the foreground controls and Live Activity. The
    /// count is working sets only, so warmups cannot skip a prescription row.
    public static func nextPlannedSet(
        in plan: ExercisePlan?, completedWorkingSets: Int
    ) -> PlannedWorkingSet? {
        guard let plan,
              completedWorkingSets >= 0,
              plan.sets.indices.contains(completedWorkingSets) else { return nil }
        return plan.sets[completedWorkingSets]
    }
}
