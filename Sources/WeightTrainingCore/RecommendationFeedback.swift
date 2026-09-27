import Foundation

/// The proposal that was on screen when a lifter reviewed a set plan. Keeping
/// this small snapshot makes later evaluation honest: a future engine version
/// cannot rewrite what the app suggested in the past.
public struct RecommendationTrace: Hashable, Codable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case accepted
        case edited
    }

    public let generatedAt: Date
    public let action: ExerciseRecommendation.Action
    public let proposedSets: [PlannedWorkingSet]
    public let proposedDeload: Bool
    public let ruleVersion: String
    public var decision: Decision

    public init(
        recommendation: ExerciseRecommendation,
        decision: Decision = .accepted
    ) {
        generatedAt = recommendation.generatedAt
        action = recommendation.action
        proposedSets = recommendation.sets
        proposedDeload = recommendation.action == .deload
        ruleVersion = recommendation.ruleVersion
        self.decision = decision
    }

    public mutating func recordDecision(for plan: ExercisePlan) {
        decision = plan.sets == proposedSets && plan.isDeload == proposedDeload
            ? .accepted
            : .edited
    }
}

/// A rolling, derived quality report for proposals the user actually reviewed.
/// Raw plans and sets remain the source of truth, so corrections reflow here.
public struct RecommendationFeedbackReport: Hashable, Sendable {
    public let days: Int
    public let reviewedPlans: Int
    public let acceptedAsSuggested: Int
    public let editedBeforeUse: Int
    public let finishedAcceptedPlans: Int
    public let completedAsPlanned: Int
    public let reportedEffortSets: Int
    public let acceptedWorkingSets: Int
    public let aboveTargetEffortSets: Int
    /// Newest-first detail for every proposal included in the aggregate. This
    /// makes shadow evaluation actionable without storing another result row.
    public let entries: [RecommendationFeedbackEntry]

    public init(
        days: Int,
        reviewedPlans: Int,
        acceptedAsSuggested: Int,
        editedBeforeUse: Int,
        finishedAcceptedPlans: Int,
        completedAsPlanned: Int,
        reportedEffortSets: Int,
        acceptedWorkingSets: Int,
        aboveTargetEffortSets: Int,
        entries: [RecommendationFeedbackEntry] = []
    ) {
        self.days = days
        self.reviewedPlans = reviewedPlans
        self.acceptedAsSuggested = acceptedAsSuggested
        self.editedBeforeUse = editedBeforeUse
        self.finishedAcceptedPlans = finishedAcceptedPlans
        self.completedAsPlanned = completedAsPlanned
        self.reportedEffortSets = reportedEffortSets
        self.acceptedWorkingSets = acceptedWorkingSets
        self.aboveTargetEffortSets = aboveTargetEffortSets
        self.entries = entries
    }

    public var effortCoverage: Double? {
        acceptedWorkingSets > 0
            ? Double(reportedEffortSets) / Double(acceptedWorkingSets)
            : nil
    }
}

public struct RecommendationFeedbackEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let exerciseID: UUID
    public let generatedAt: Date
    public let action: ExerciseRecommendation.Action
    public let decision: RecommendationTrace.Decision
    public let finished: Bool
    public let completion: ExerciseExposure.Completion?
    public let completedAsPlanned: Bool
    public let reportedEffortSets: Int
    public let workingSets: Int
    public let aboveTargetEffortSets: Int

    public var effortCoverage: Double? {
        workingSets > 0 ? Double(reportedEffortSets) / Double(workingSets) : nil
    }
}

public enum RecommendationFeedbackEngine {
    public static func report(
        sessions: [RecordedExerciseSession],
        exposures: [ExerciseExposure],
        now: Date = Date(),
        days: Int = 28
    ) -> RecommendationFeedbackReport {
        let boundedDays = min(max(days, 1), 365)
        let start = now.addingTimeInterval(-Double(boundedDays) * 86_400)
        let reviewed = sessions.filter {
            guard let trace = $0.recommendationTrace else { return false }
            return trace.generatedAt >= start && trace.generatedAt <= now
        }
        let accepted = reviewed.filter { $0.recommendationTrace?.decision == .accepted }
        let exposureByKey = Dictionary(
            exposures.map { (key(workoutID: $0.id, exerciseID: $0.exerciseID), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var finishedAcceptedPlans = 0
        var completedAsPlanned = 0
        var reportedEffortSets = 0
        var acceptedWorkingSets = 0
        var aboveTargetEffortSets = 0
        var entries: [RecommendationFeedbackEntry] = []

        for session in reviewed {
            guard let trace = session.recommendationTrace else { continue }
            let plan = session.plan
            let exposure = exposureByKey[key(
                workoutID: session.workoutID,
                exerciseID: session.exerciseID
            )]
            let working = exposure?.workingSets ?? []
            let comparable = Array(working.prefix(plan?.sets.count ?? 0))
            let reported = comparable.filter { $0.effortSource == .reported }.count
            let aboveTarget = plan.map { plan in
                zip(comparable, plan.sets).filter { performed, target in
                    performed.effortSource == .reported
                        && performed.record.rpe.map { $0 > target.rpe } == true
                }.count
            } ?? 0
            let followedExactly = plan.map { plan in
                exposure?.completion == .completed
                    && working.count == plan.sets.count
                    && zip(working, plan.sets).allSatisfy { performed, target in
                        performed.record.load == target.load && performed.record.reps >= target.reps
                    }
            } ?? false

            if trace.decision == .accepted, plan != nil, exposure != nil {
                acceptedWorkingSets += comparable.count
                reportedEffortSets += reported
                aboveTargetEffortSets += aboveTarget
                if session.completedAt != nil {
                    finishedAcceptedPlans += 1
                    if followedExactly { completedAsPlanned += 1 }
                }
            }

            entries.append(RecommendationFeedbackEntry(
                id: session.id,
                exerciseID: session.exerciseID,
                generatedAt: trace.generatedAt,
                action: trace.action,
                decision: trace.decision,
                finished: session.completedAt != nil,
                completion: exposure?.completion,
                completedAsPlanned: trace.decision == .accepted && followedExactly,
                reportedEffortSets: trace.decision == .accepted ? reported : 0,
                workingSets: trace.decision == .accepted ? comparable.count : 0,
                aboveTargetEffortSets: trace.decision == .accepted ? aboveTarget : 0
            ))
        }

        return RecommendationFeedbackReport(
            days: boundedDays,
            reviewedPlans: reviewed.count,
            acceptedAsSuggested: accepted.count,
            editedBeforeUse: reviewed.count - accepted.count,
            finishedAcceptedPlans: finishedAcceptedPlans,
            completedAsPlanned: completedAsPlanned,
            reportedEffortSets: reportedEffortSets,
            acceptedWorkingSets: acceptedWorkingSets,
            aboveTargetEffortSets: aboveTargetEffortSets,
            entries: entries.sorted {
                if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
                return $0.id < $1.id
            }
        )
    }

    private static func key(workoutID: UUID, exerciseID: UUID) -> String {
        "\(workoutID.uuidString)/\(exerciseID.uuidString)"
    }
}
