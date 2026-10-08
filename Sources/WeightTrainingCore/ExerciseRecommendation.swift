import Foundation

/// Configurable product heuristics, not a model of an individual's physiology.
public struct RecommendationPolicy: Hashable, Sendable {
    public var repRange: RepRange
    public var easyExposuresRequired: Int
    public var easyRPESlack: Double
    public var maximumLoadIncrease: Double
    public var historyFreshness: TimeInterval

    public init(
        repRange: RepRange = RepRange(8, 12), easyExposuresRequired: Int = 2,
        easyRPESlack: Double = 1, maximumLoadIncrease: Double = 0.05,
        historyFreshness: TimeInterval = 21 * 86_400
    ) {
        self.repRange = repRange
        self.easyExposuresRequired = easyExposuresRequired
        self.easyRPESlack = easyRPESlack
        self.maximumLoadIncrease = maximumLoadIncrease
        self.historyFreshness = historyFreshness
    }

    var isValid: Bool {
        repRange.bottom > 0 && repRange.top >= repRange.bottom
            && (2...6).contains(easyExposuresRequired)
            && easyRPESlack.isFinite && (0.5...2).contains(easyRPESlack)
            && maximumLoadIncrease.isFinite && (0...0.1).contains(maximumLoadIncrease)
            && historyFreshness.isFinite && historyFreshness > 0
    }
}

/// Current self-reported context. Unknown recovery does not manufacture a
/// fatigue diagnosis, nor does a wearable score directly change this value.
public struct RecommendationContext: Hashable, Sendable {
    public enum Recovery: String, Sendable {
        case unknown, acceptable, poor
    }

    public var recovery: Recovery
    public var painReported: Bool

    public init(recovery: Recovery = .unknown, painReported: Bool = false) {
        self.recovery = recovery
        self.painReported = painReported
    }
}

public struct ExerciseRecommendation: Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case establish, hold, addReps, addLoad, addSet, reduce, deload, stop
    }

    public enum Evidence: String, Codable, Sendable {
        case insufficient, limited, consistent
    }

    public enum Reason: Hashable, Codable, Sendable {
        case firstPlanNeeded
        case legacyBaseline
        case invalidInput
        case unsupportedEquipment
        case equipmentChanged
        case ambiguousHistory
        case staleHistory
        case newPrescription
        case missingEffort
        case incompleteExposure
        case techniqueChanged
        case unexpectedPerformance
        case effortAboveTarget
        case confirmEasyWorkouts(completed: Int, required: Int)
        case addedRep(set: Int)
        case addedLoad
        case weeklyVolumeBelowBudget(muscles: [Muscle])
        case loadStepTooLarge
        case noHeavierLoad
        case bodyweightRepCeiling
        case bodyweightRepeatedMisses
        case repeatedMisses
        case minimumLoad
        case reductionUnavailable
        case poorRecovery
        case acceptedDeload
        case resumeAfterDeload
        case scheduledDeload(week: Int)
        case programFatigue
        case pain
    }

    public let exerciseID: UUID
    public let basedOnPlanID: UUID?
    public let generatedAt: Date
    public let action: Action
    /// Empty for a cold start, invalid prescription, or stop recommendation.
    public let sets: [PlannedWorkingSet]
    public let reason: Reason
    public let evidence: Evidence
    public let supportingExposureIDs: [UUID]
    public let ruleVersion: String

    public init(
        exerciseID: UUID,
        basedOnPlanID: UUID?,
        generatedAt: Date,
        action: Action,
        sets: [PlannedWorkingSet],
        reason: Reason,
        evidence: Evidence,
        supportingExposureIDs: [UUID],
        ruleVersion: String
    ) {
        self.exerciseID = exerciseID
        self.basedOnPlanID = basedOnPlanID
        self.generatedAt = generatedAt
        self.action = action
        self.sets = sets
        self.reason = reason
        self.evidence = evidence
        self.supportingExposureIDs = supportingExposureIDs
        self.ruleVersion = ruleVersion
    }

    public var suggestedSetCount: Int? { sets.isEmpty ? nil : sets.count }

    public var summary: String {
        switch reason {
        // Read mid-set under the target, so in the lifter's words and short:
        // what the app noticed, then what it suggests (re-critique,
        // 2026-10-07; the old lines read like engine notes).
        case .firstPlanNeeded: return "Set your starting weight and reps first"
        case .legacyBaseline: return "Based on your last workout"
        case .invalidInput: return "Something in this lift's records looks off — check History"
        case .unsupportedEquipment: return "No automatic progression for this equipment yet"
        case .equipmentChanged: return "Equipment changed — find your new working weight"
        case .ambiguousHistory: return "Conflicting workout records — check History"
        case .staleHistory: return "It's been a while — rebuild before adding weight"
        case .newPrescription: return "New target — repeat it once to compare"
        case .missingEffort: return "Log RPE on every set to progress"
        case .incompleteExposure: return "Last time wasn't finished — repeat it"
        case .techniqueChanged: return "Technique changed — starting a fresh comparison"
        case .unexpectedPerformance: return "Last time differed from the plan — repeat it"
        case .effortAboveTarget: return "A set felt harder than target — hold steady"
        case .confirmEasyWorkouts(let completed, let required):
            return "\(completed) of \(required) easy workouts in a row — repeat it"
        case .addedRep(let set): return "Easy again — add a rep to set \(set)"
        case .addedLoad: return "Easy at the top of your reps — add weight, reset reps"
        case .weeklyVolumeBelowBudget(let muscles):
            let names = muscles.map(\.displayName).joined(separator: " and ")
            return "\(names) short of this week's target — add a set"
        case .loadStepTooLarge: return "The next weight up is too big a jump — hold steady"
        case .noHeavierLoad: return "No heavier weight is set up — hold steady"
        case .bodyweightRepCeiling: return "Easy at the top of your reps — keep the same total load"
        case .bodyweightRepeatedMisses: return "Missed again — check form or set count; load stays the same"
        case .repeatedMisses: return "Missed again — drop the weight and rebuild"
        case .minimumLoad: return "Already at the lightest weight — check the lift or set count"
        case .reductionUnavailable: return "No lighter weight is set up — check the lift or set count"
        case .poorRecovery: return "You reported poor recovery — holding progress"
        case .acceptedDeload: return "Following your recovery plan"
        case .resumeAfterDeload: return "Back from recovery — rebuild at a weight you can sustain"
        case .scheduledDeload(let week): return "Recovery week \(week) — fewer sets, easier effort"
        case .programFatigue: return "Fatigue across several lifts — consider a recovery week"
        case .pain: return "You reported pain — stop this movement; progress is paused"
        }
    }
}
