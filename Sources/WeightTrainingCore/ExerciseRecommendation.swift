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

public struct ExerciseRecommendation: Hashable, Sendable {
    public enum Action: String, Sendable {
        case establish, hold, addReps, addLoad, addSet, reduce, deload, stop
    }

    public enum Evidence: String, Sendable {
        case insufficient, limited, consistent
    }

    public enum Reason: Hashable, Sendable {
        case firstPlanNeeded
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
        case repeatedMisses
        case minimumLoad
        case reductionUnavailable
        case poorRecovery
        case acceptedDeload
        case resumeAfterDeload
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

    public var suggestedSetCount: Int? { sets.isEmpty ? nil : sets.count }

    public var summary: String {
        switch reason {
        case .firstPlanNeeded: return "Choose a starting prescription before progressing"
        case .invalidInput: return "Review the plan and workout records before progressing"
        case .unsupportedEquipment: return "This equipment needs its own progression policy"
        case .equipmentChanged: return "Equipment changed — establish a new prescription"
        case .ambiguousHistory: return "Resolve conflicting workout records before progressing"
        case .staleHistory: return "Re-establish this prescription after the break"
        case .newPrescription: return "Repeat this prescription to establish comparable workouts"
        case .missingEffort: return "Report effort for every working set before progressing"
        case .incompleteExposure: return "The full prescription was not confirmed — repeat it"
        case .techniqueChanged: return "Technique changed — establish a new comparison"
        case .unexpectedPerformance: return "The performed loads or sets differed — repeat the plan"
        case .effortAboveTarget: return "A working set exceeded target effort — hold steady"
        case .confirmEasyWorkouts(let completed, let required):
            return "\(completed) of \(required) consecutive easy workouts — repeat it"
        case .addedRep(let set): return "Repeated easy workouts — add one rep to set \(set)"
        case .addedLoad: return "Repeated easy workouts at the rep ceiling — add weight and reset reps"
        case .weeklyVolumeBelowBudget(let muscles):
            let names = muscles.map(\.displayName).joined(separator: " and ")
            return "\(names) remain below your weekly target — add one set"
        case .loadStepTooLarge: return "The next available weight is too large a jump — hold steady"
        case .noHeavierLoad: return "No heavier achievable load is configured — hold steady"
        case .repeatedMisses: return "Repeated comparable misses — reduce weight and rebuild"
        case .minimumLoad: return "Already at the equipment minimum — review the exercise or set count"
        case .reductionUnavailable: return "No suitable smaller load is configured — review the exercise or set count"
        case .poorRecovery: return "Recovery was reported as poor — hold progression"
        case .acceptedDeload: return "Follow the accepted deload prescription"
        case .resumeAfterDeload: return "Resume a sustainable prescription and collect fresh workouts"
        case .pain: return "Pain was reported — stop this movement and pause progression"
        }
    }
}
