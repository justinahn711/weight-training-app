import Foundation

/// The proposal on screen when a prescription was activated or reviewed.
/// Its snapshot makes later evaluation honest: a future engine version cannot
/// rewrite what the app suggested in the past.
public struct RecommendationTrace: Hashable, Codable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case automaticallyActivated
        case accepted
        case edited
    }

    public let generatedAt: Date
    public let action: ExerciseRecommendation.Action
    public let proposedSets: [PlannedWorkingSet]
    public let proposedDeload: Bool
    public let ruleVersion: String
    public var decision: Decision
    /// Absent on historical traces; never reconstruct missing provenance.
    public let displayedRecommendation: ExerciseRecommendation?
    /// Retained when the lifter subsequently reviews or edits an automatic plan.
    public let automaticallyActivatedAt: Date?

    public init(
        recommendation: ExerciseRecommendation,
        decision: Decision = .accepted,
        automaticallyActivatedAt: Date? = nil
    ) {
        generatedAt = recommendation.generatedAt
        action = recommendation.action
        proposedSets = recommendation.sets
        proposedDeload = recommendation.action == .deload
        ruleVersion = recommendation.ruleVersion
        self.decision = decision
        displayedRecommendation = recommendation
        self.automaticallyActivatedAt = automaticallyActivatedAt
    }

    public mutating func recordDecision(for plan: ExercisePlan) {
        decision = plan.sets == proposedSets && plan.isDeload == proposedDeload
            ? .accepted
            : .edited
    }
}

/// A rolling, derived quality report separating automatic activation from review.
/// Raw plans and sets remain the source of truth, so corrections reflow here.
public struct RecommendationFeedbackReport: Hashable, Sendable {
    public let days: Int
    public let reviewedPlans: Int
    public let automaticActivations: Int
    public let acceptedAsSuggested: Int
    public let editedBeforeUse: Int
    public let finishedAcceptedPlans: Int
    public let completedAsPlanned: Int
    public let reportedEffortSets: Int
    public let acceptedWorkingSets: Int
    public let aboveTargetEffortSets: Int
    /// Outcome cohorts use the final decision. An automatically activated plan
    /// later reviewed belongs to the reviewed cohort; its origin is still
    /// counted by automaticActivations.
    public let finishedAutomaticPlans: Int
    public let automaticCompletedAsPlanned: Int
    public let automaticWorkingSets: Int
    public let automaticReportedEffortSets: Int
    public let automaticAboveTargetEffortSets: Int
    public let completedBelowTargetEffort: Int
    public let automaticCompletedBelowTargetEffort: Int
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
        entries: [RecommendationFeedbackEntry] = [],
        automaticActivations: Int = 0,
        finishedAutomaticPlans: Int = 0,
        automaticCompletedAsPlanned: Int = 0,
        automaticWorkingSets: Int = 0,
        automaticReportedEffortSets: Int = 0,
        automaticAboveTargetEffortSets: Int = 0,
        completedBelowTargetEffort: Int = 0,
        automaticCompletedBelowTargetEffort: Int = 0
    ) {
        self.days = days
        self.reviewedPlans = reviewedPlans
        self.automaticActivations = automaticActivations
        self.acceptedAsSuggested = acceptedAsSuggested
        self.editedBeforeUse = editedBeforeUse
        self.finishedAcceptedPlans = finishedAcceptedPlans
        self.completedAsPlanned = completedAsPlanned
        self.reportedEffortSets = reportedEffortSets
        self.acceptedWorkingSets = acceptedWorkingSets
        self.aboveTargetEffortSets = aboveTargetEffortSets
        self.finishedAutomaticPlans = finishedAutomaticPlans
        self.automaticCompletedAsPlanned = automaticCompletedAsPlanned
        self.automaticWorkingSets = automaticWorkingSets
        self.automaticReportedEffortSets = automaticReportedEffortSets
        self.automaticAboveTargetEffortSets = automaticAboveTargetEffortSets
        self.completedBelowTargetEffort = completedBelowTargetEffort
        self.automaticCompletedBelowTargetEffort = automaticCompletedBelowTargetEffort
        self.entries = entries
    }

    public var effortCoverage: Double? {
        acceptedWorkingSets > 0
            ? Double(reportedEffortSets) / Double(acceptedWorkingSets)
            : nil
    }

    public var automaticEffortCoverage: Double? {
        automaticWorkingSets > 0
            ? Double(automaticReportedEffortSets) / Double(automaticWorkingSets)
            : nil
    }

    /// Counts recorded proposals once per exercise session, including edits
    /// and unfinished sessions. These are not completion or success rates.
    public var actionCounts: [ExerciseRecommendation.Action: Int] {
        entries.reduce(into: [:]) { $0[$1.action, default: 0] += 1 }
    }

    public var reasonCounts: [ExerciseRecommendation.Reason: Int] {
        entries.reduce(into: [:]) { counts, entry in
            if let reason = entry.reason { counts[reason, default: 0] += 1 }
        }
    }

    public var holdReasonCounts: [ExerciseRecommendation.Reason: Int] {
        entries.reduce(into: [:]) { counts, entry in
            if entry.action == .hold, let reason = entry.reason { counts[reason, default: 0] += 1 }
        }
    }

    public var unknownReasonCount: Int { entries.filter { $0.reason == nil }.count }
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
    /// Historical snapshot metadata only. Legacy traces without a displayed
    /// proposal remain unknown instead of being explained by today's engine.
    public let reason: ExerciseRecommendation.Reason?
    public let evidence: ExerciseRecommendation.Evidence?
    public let ruleVersion: String?
    public let supportingExposureCount: Int?
    /// Exact prescribed work, finished without an edit, with every working-set
    /// RPE explicitly reported below its target. This descriptive outcome does
    /// not assert physiological benefit or replace the progression policy.
    public let completedBelowTargetEffort: Bool

    public init(
        id: String, exerciseID: UUID, generatedAt: Date,
        action: ExerciseRecommendation.Action, decision: RecommendationTrace.Decision,
        finished: Bool, completion: ExerciseExposure.Completion?, completedAsPlanned: Bool,
        reportedEffortSets: Int, workingSets: Int, aboveTargetEffortSets: Int,
        reason: ExerciseRecommendation.Reason? = nil,
        evidence: ExerciseRecommendation.Evidence? = nil, ruleVersion: String? = nil,
        supportingExposureCount: Int? = nil, completedBelowTargetEffort: Bool = false
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.generatedAt = generatedAt
        self.action = action
        self.decision = decision
        self.finished = finished
        self.completion = completion
        self.completedAsPlanned = completedAsPlanned
        self.reportedEffortSets = reportedEffortSets
        self.workingSets = workingSets
        self.aboveTargetEffortSets = aboveTargetEffortSets
        self.reason = reason
        self.evidence = evidence
        self.ruleVersion = ruleVersion
        self.supportingExposureCount = supportingExposureCount
        self.completedBelowTargetEffort = completedBelowTargetEffort
    }

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
        let recorded = sessions.filter {
            guard let trace = $0.recommendationTrace else { return false }
            return trace.generatedAt >= start && trace.generatedAt <= now
        }
        let reviewed = recorded.filter { $0.recommendationTrace?.decision != .automaticallyActivated }
        let automaticActivations = recorded.filter {
            $0.recommendationTrace?.automaticallyActivatedAt != nil
                || $0.recommendationTrace?.decision == .automaticallyActivated
        }.count
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
        var finishedAutomaticPlans = 0
        var automaticCompletedAsPlanned = 0
        var automaticWorkingSets = 0
        var automaticReportedEffortSets = 0
        var automaticAboveTargetEffortSets = 0
        var completedBelowTargetEffort = 0
        var automaticCompletedBelowTargetEffort = 0
        var entries: [RecommendationFeedbackEntry] = []

        for session in recorded {
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
            let planWasUsedWithoutEdit = trace.decision != .edited
            let belowTarget = plan.map { plan in
                guard planWasUsedWithoutEdit, session.completedAt != nil,
                      !plan.sets.isEmpty, plan.sets == trace.proposedSets,
                      plan.isDeload == trace.proposedDeload, exposure?.plan == plan,
                      exposure?.completion == .completed, working.count == plan.sets.count else { return false }
                return zip(working, plan.sets).allSatisfy { performed, target in
                    performed.record.exerciseID == session.exerciseID
                        && performed.record.load == target.load && performed.record.reps == target.reps
                        && performed.effortSource == .reported
                        && performed.record.rpe.map { $0 < target.rpe } == true
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
                if belowTarget { completedBelowTargetEffort += 1 }
            }
            if trace.decision == .automaticallyActivated, plan != nil, exposure != nil {
                automaticWorkingSets += comparable.count
                automaticReportedEffortSets += reported
                automaticAboveTargetEffortSets += aboveTarget
                if session.completedAt != nil {
                    finishedAutomaticPlans += 1
                    if followedExactly { automaticCompletedAsPlanned += 1 }
                }
                if belowTarget { automaticCompletedBelowTargetEffort += 1 }
            }

            entries.append(RecommendationFeedbackEntry(
                id: session.id,
                exerciseID: session.exerciseID,
                generatedAt: trace.generatedAt,
                action: trace.action,
                decision: trace.decision,
                finished: session.completedAt != nil,
                completion: exposure?.completion,
                completedAsPlanned: planWasUsedWithoutEdit && followedExactly,
                reportedEffortSets: planWasUsedWithoutEdit ? reported : 0,
                workingSets: planWasUsedWithoutEdit ? comparable.count : 0,
                aboveTargetEffortSets: planWasUsedWithoutEdit ? aboveTarget : 0,
                reason: trace.displayedRecommendation?.reason,
                evidence: trace.displayedRecommendation?.evidence,
                ruleVersion: trace.displayedRecommendation?.ruleVersion,
                supportingExposureCount: trace.displayedRecommendation?.supportingExposureIDs.count,
                completedBelowTargetEffort: belowTarget
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
            },
            automaticActivations: automaticActivations,
            finishedAutomaticPlans: finishedAutomaticPlans,
            automaticCompletedAsPlanned: automaticCompletedAsPlanned,
            automaticWorkingSets: automaticWorkingSets,
            automaticReportedEffortSets: automaticReportedEffortSets,
            automaticAboveTargetEffortSets: automaticAboveTargetEffortSets,
            completedBelowTargetEffort: completedBelowTargetEffort,
            automaticCompletedBelowTargetEffort: automaticCompletedBelowTargetEffort
        )
    }

    private static func key(workoutID: UUID, exerciseID: UUID) -> String {
        "\(workoutID.uuidString)/\(exerciseID.uuidString)"
    }
}
