import Foundation

/// The planned-set progression policy. Deliberately separate from the legacy
/// engine until the app can supply accepted plans and reported-effort provenance.
/// This function never writes progress, consumes a streak, or changes a log.
public enum RecommendationEngine {
    public static let ruleVersion = "planned-progression-v1"

    public static func recommend(
        exercise: Exercise,
        plan: ExercisePlan?,
        history: [ExerciseExposure],
        policy: RecommendationPolicy = RecommendationPolicy(),
        context: RecommendationContext = RecommendationContext(),
        now: Date
    ) -> ExerciseRecommendation {
        func result(
            _ action: ExerciseRecommendation.Action,
            _ reason: ExerciseRecommendation.Reason,
            sets: [PlannedWorkingSet] = [],
            evidence: ExerciseRecommendation.Evidence = .insufficient,
            exposures: [ExerciseExposure] = []
        ) -> ExerciseRecommendation {
            ExerciseRecommendation(
                exerciseID: exercise.id, basedOnPlanID: plan?.id, generatedAt: now,
                action: action, sets: sets, reason: reason, evidence: evidence,
                supportingExposureIDs: exposures.map(\.id), ruleVersion: ruleVersion
            )
        }

        if context.painReported { return result(.stop, .pain) }
        guard now.timeIntervalSince1970.isFinite, policy.isValid else {
            return result(.establish, .invalidInput)
        }
        guard let plan else { return result(.establish, .firstPlanNeeded) }
        guard validEquipment(exercise) else { return result(.establish, .invalidInput) }
        // Bodyweight and assistance need explicit effective-load semantics;
        // applying the external-load direction to these would be misleading.
        guard exercise.equipment != .bodyweight,
              !(exercise.equipment.isPlateBuilt && exercise.loading?.isMeasured != true)
        else { return result(.establish, .unsupportedEquipment) }
        guard plan.exercise == exercise else { return result(.establish, .equipmentChanged) }
        guard validPlan(plan, policy: policy) else { return result(.establish, .invalidInput) }

        // Route even unchanged targets through the shared equipment boundary.
        // If that changes the prescription, new evidence is needed at that load.
        let targets = plan.sets.map {
            PlannedWorkingSet(load: exercise.nearestAchievable($0.load), reps: $0.reps, rpe: $0.rpe)
        }
        guard targets.allSatisfy({ validLoad($0.load) && $0.load >= exercise.lightestUsableLoad
            && exercise.canBuild($0.load) }) else {
            return result(.establish, .equipmentChanged)
        }
        guard zip(targets, plan.sets).allSatisfy({ sameLoad($0.load, $1.load) }) else {
            return result(.establish, .equipmentChanged, sets: targets)
        }

        // Duplicate imports cannot turn one workout into two. Conflicting
        // copies must be reconciled by the store rather than arbitrarily picked.
        var byID: [UUID: ExerciseExposure] = [:]
        for exposure in history where exposure.exerciseID == exercise.id {
            guard exposure.completedAt.timeIntervalSince1970.isFinite else {
                return result(.hold, .invalidInput, sets: targets)
            }
            guard exposure.completedAt <= now else { continue }
            if let previous = byID[exposure.id], previous != exposure {
                return result(.hold, .ambiguousHistory, sets: targets)
            }
            byID[exposure.id] = exposure
        }
        let ordered = byID.values.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if let latest = ordered.last, latest.completion == .stoppedForPain {
            return result(.stop, .pain, exposures: [latest])
        }
        if plan.isDeload { return result(.deload, .acceptedDeload, sets: targets) }
        if context.recovery == .poor { return result(.hold, .poorRecovery, sets: targets) }
        guard let latest = ordered.last else {
            return result(.establish, .newPrescription, sets: targets)
        }
        guard now.timeIntervalSince(latest.completedAt) <= policy.historyFreshness else {
            return result(.establish, .staleHistory, sets: targets, exposures: [latest])
        }
        if latest.plan?.isDeload == true {
            return result(.hold, .resumeAfterDeload, sets: targets, exposures: [latest])
        }

        // Never filter failed/unknown exposures out before taking the suffix:
        // doing so would quietly join easy workouts across an intervening miss.
        let recent = Array(ordered.suffix(policy.easyExposuresRequired))
        var setIDs = Set<UUID>()
        for exposure in recent {
            for set in exposure.workingSets {
                guard setIDs.insert(set.record.id).inserted else {
                    return result(.hold, .ambiguousHistory, sets: targets, exposures: recent)
                }
            }
        }
        let latestAssessment = assess(latest, against: plan, policy: policy)

        // Two full comparable misses below the rep floor justify a local load
        // reset. A time-shortened workout or unknown completion never does.
        let lastTwo = Array(recent.suffix(2))
        if lastTwo.count == 2,
           latest.completedAt.timeIntervalSince(lastTwo[0].completedAt) <= policy.historyFreshness,
           lastTwo.allSatisfy({ assess($0, against: plan, policy: policy) == .miss }) {
            if let reduced = reducedTargets(targets, exercise: exercise) {
                return result(.reduce, .repeatedMisses, sets: reduced,
                              evidence: .consistent, exposures: lastTwo)
            }
            let reason: ExerciseRecommendation.Reason = targets[0].load <= exercise.lightestUsableLoad
                ? .minimumLoad : .reductionUnavailable
            return result(.hold, reason, sets: targets, evidence: .consistent, exposures: lastTwo)
        }

        switch latestAssessment {
        case .invalid:
            return result(.hold, .invalidInput, sets: targets, exposures: [latest])
        case .changed:
            return result(.hold, .newPrescription, sets: targets, exposures: [latest])
        case .missingEffort:
            return result(.hold, .missingEffort, sets: targets, exposures: [latest])
        case .incomplete:
            return result(.hold, .incompleteExposure, sets: targets, exposures: [latest])
        case .technique:
            return result(.hold, .techniqueChanged, sets: targets, exposures: [latest])
        case .differentWork:
            return result(.hold, .unexpectedPerformance, sets: targets, exposures: [latest])
        case .tooHard:
            return result(.hold, .effortAboveTarget, sets: targets, evidence: .limited, exposures: [latest])
        case .miss:
            return result(.hold, .incompleteExposure, sets: targets, evidence: .limited, exposures: [latest])
        case .onTarget, .easy:
            break
        }

        var easy: [ExerciseExposure] = []
        var nextDate = now
        for exposure in recent.reversed() {
            guard nextDate.timeIntervalSince(exposure.completedAt) <= policy.historyFreshness,
                  assess(exposure, against: plan, policy: policy) == .easy else { break }
            easy.insert(exposure, at: 0)
            nextDate = exposure.completedAt
        }
        guard easy.count >= policy.easyExposuresRequired else {
            return result(.hold, .confirmEasyWorkouts(completed: easy.count, required: policy.easyExposuresRequired),
                          sets: targets, evidence: .limited, exposures: recent)
        }

        if let index = targets.indices.filter({ targets[$0].reps < policy.repRange.top }).min(by: {
            if targets[$0].reps != targets[$1].reps { return targets[$0].reps < targets[$1].reps }
            return $0 < $1
        }) {
            var increased = targets
            increased[index].reps += 1
            return result(.addReps, .addedRep(set: index + 1), sets: increased,
                          evidence: .consistent, exposures: easy)
        }

        let current = targets[0].load
        guard let next = nextLoad(after: current, exercise: exercise) else {
            return result(.hold, .noHeavierLoad, sets: targets, evidence: .consistent, exposures: easy)
        }
        guard next.pounds / current.pounds - 1 <= policy.maximumLoadIncrease + 0.000_000_1 else {
            return result(.hold, .loadStepTooLarge, sets: targets, evidence: .consistent, exposures: easy)
        }
        let increased = targets.map { PlannedWorkingSet(load: next, reps: policy.repRange.bottom, rpe: $0.rpe) }
        return result(.addLoad, .addedLoad, sets: increased, evidence: .consistent, exposures: easy)
    }

    private enum Assessment: Equatable {
        case invalid, changed, missingEffort, incomplete, technique, differentWork, tooHard, miss, onTarget, easy
    }

    private static func assess(
        _ exposure: ExerciseExposure, against plan: ExercisePlan, policy: RecommendationPolicy
    ) -> Assessment {
        guard exposure.plan == plan else { return .changed }
        guard exposure.techniqueChanged != true else { return .technique }
        let working = exposure.workingSets
        guard working.allSatisfy({
            $0.record.exerciseID == plan.exercise.id && validLoad($0.record.load)
                && $0.record.reps > 0 && $0.record.reps <= 1_000
                && $0.record.performedAt.timeIntervalSince1970.isFinite
                && $0.record.performedAt <= exposure.completedAt
                && ($0.record.rpe.map { RPE.allowedValues.contains($0.value) } ?? true)
        }) else { return .invalid }
        guard exposure.completion == .completed,
              working.count == plan.sets.count else { return .incomplete }
        guard zip(working, plan.sets).allSatisfy({ sameLoad($0.record.load, $1.load) }) else {
            return .differentWork
        }
        // A missed rep floor is observed performance, even if RPE is absent.
        if working.contains(where: { $0.record.reps < policy.repRange.bottom }) { return .miss }
        guard zip(working, plan.sets).allSatisfy({ $0.record.reps >= $1.reps }) else { return .incomplete }
        guard working.allSatisfy({ $0.effortSource == .reported && $0.record.rpe != nil }) else {
            return .missingEffort
        }
        if zip(working, plan.sets).contains(where: { $0.record.rpe!.value > $1.rpe.value }) { return .tooHard }
        if zip(working, plan.sets).allSatisfy({ $0.record.rpe!.value <= $1.rpe.value - policy.easyRPESlack }) {
            return .easy
        }
        return .onTarget
    }

    private static func validLoad(_ load: Load) -> Bool {
        load.pounds.isFinite && load.pounds > 0 && load.pounds <= 100_000
    }

    private static func validEquipment(_ exercise: Exercise) -> Bool {
        guard validLoad(Load(exercise.increment.pounds)) else { return false }
        if let loading = exercise.loading {
            guard (1...8).contains(loading.sleeves), loading.availablePlates.allSatisfy({
                $0.isFinite && $0 > 0 && $0 <= 10_000
            }) else { return false }
            if let base = loading.baseWeight {
                guard base.pounds.isFinite && (0...100_000).contains(base.pounds) else { return false }
            }
        }
        return true
    }

    private static func validPlan(_ plan: ExercisePlan, policy: RecommendationPolicy) -> Bool {
        guard (1...20).contains(plan.sets.count),
              plan.restSeconds.map({ $0 > 0 }) ?? true,
              let first = plan.sets.first else { return false }
        return plan.sets.allSatisfy {
            validLoad($0.load) && $0.load >= plan.exercise.lightestUsableLoad
                && sameLoad($0.load, first.load)
                && policy.repRange.contains($0.reps) && RPE.allowedValues.contains($0.rpe.value)
        }
    }

    private static func sameLoad(_ a: Load, _ b: Load) -> Bool {
        abs(a.pounds - b.pounds) < 0.000_001
    }

    private static func nextLoad(after load: Load, exercise: Exercise) -> Load? {
        let candidate: Load
        if let loading = exercise.loading, loading.isMeasured {
            guard let next = loading.nextBuildable(after: load) else { return nil }
            candidate = next
        } else {
            candidate = Load(load.pounds + exercise.increment.pounds)
        }
        let snapped = exercise.nearestAchievable(candidate)
        guard validLoad(snapped), snapped > load, exercise.canBuild(snapped) else { return nil }
        return snapped
    }

    private static func reducedTargets(_ targets: [PlannedWorkingSet], exercise: Exercise) -> [PlannedWorkingSet]? {
        let current = targets[0].load
        // A 10% reduction is approximate. Do not force a coarse equipment jump
        // beyond it merely to make the number move.
        let requested = Load(current.pounds * 0.9)
        var snapped = exercise.nearestAchievable(requested)
        if snapped.pounds < requested.pounds - 0.000_001 {
            guard let next = nextLoad(after: snapped, exercise: exercise) else { return nil }
            snapped = next
        }
        guard validLoad(snapped), snapped < current,
              snapped >= exercise.lightestUsableLoad, exercise.canBuild(snapped),
              snapped.pounds >= requested.pounds - 0.000_001 else { return nil }
        return targets.map { PlannedWorkingSet(load: snapped, reps: $0.reps, rpe: $0.rpe) }
    }
}
