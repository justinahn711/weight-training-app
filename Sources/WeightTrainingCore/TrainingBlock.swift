import Foundation

/// An optional accumulation/deload cycle. Dates and logged sets remain the
/// source of truth; the current week and tonnage are always derived.
public struct TrainingBlockConfig: Hashable, Codable, Sendable {
    public var startedAt: Date
    public var accumulationWeeks: Int
    public var monthlyIncrease: Double
    public var deloadTonnageFraction: Double

    public init(
        startedAt: Date = Date(),
        accumulationWeeks: Int = 3,
        monthlyIncrease: Double = 0.05,
        deloadTonnageFraction: Double = 0.75
    ) {
        self.startedAt = startedAt.timeIntervalSince1970.isFinite
            ? startedAt : Date(timeIntervalSince1970: 0)
        self.accumulationWeeks = min(max(accumulationWeeks, 2), 6)
        self.monthlyIncrease = monthlyIncrease.isFinite
            ? min(max(monthlyIncrease, 0.05), 0.10) : 0.05
        self.deloadTonnageFraction = deloadTonnageFraction.isFinite
            ? min(max(deloadTonnageFraction, 0.70), 0.80) : 0.75
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt)
                ?? Date(timeIntervalSince1970: 0),
            accumulationWeeks: try values.decodeIfPresent(Int.self, forKey: .accumulationWeeks) ?? 3,
            monthlyIncrease: try values.decodeIfPresent(Double.self, forKey: .monthlyIncrease) ?? 0.05,
            deloadTonnageFraction: try values.decodeIfPresent(Double.self, forKey: .deloadTonnageFraction) ?? 0.75
        )
    }
}

public enum TrainingBlockPhase: Hashable, Sendable {
    case accumulation(week: Int)
    case deload(week: Int)
}

public struct TrainingBlockStatus: Hashable, Sendable {
    public let phase: TrainingBlockPhase
    public let baselineTonnage: Double?
    public let baselineWeeks: Int
    public let currentTonnage: Double
    public let targetTonnage: Double?

    public init(
        phase: TrainingBlockPhase,
        baselineTonnage: Double?,
        baselineWeeks: Int,
        currentTonnage: Double,
        targetTonnage: Double?
    ) {
        self.phase = phase
        self.baselineTonnage = baselineTonnage
        self.baselineWeeks = baselineWeeks
        self.currentTonnage = currentTonnage
        self.targetTonnage = targetTonnage
    }
}

public enum TrainingBlockEngine {
    public static let ruleVersion = "training-block-v1"

    public static func phase(
        for config: TrainingBlockConfig,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingBlockPhase {
        let start = calendar.dateInterval(of: .weekOfYear, for: config.startedAt)?.start
            ?? calendar.startOfDay(for: config.startedAt)
        let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let elapsedDays = calendar.dateComponents([.day], from: start, to: current).day ?? 0
        let elapsed = max(0, elapsedDays / 7)
        let cycleLength = config.accumulationWeeks + 1
        let cycleWeek = elapsed % cycleLength + 1
        return cycleWeek <= config.accumulationWeeks
            ? .accumulation(week: cycleWeek)
            : .deload(week: cycleWeek)
    }

    public static func status(
        config: TrainingBlockConfig,
        history: [ExerciseExposure],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingBlockStatus {
        let phase = phase(for: config, now: now, calendar: calendar)
        let baseline = baselineWeeks(before: config.startedAt, history: history, calendar: calendar)
        let baselineTonnage = baseline.count >= 2 ? median(baseline.map(\.tonnage)) : nil
        let currentInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let currentTonnage = currentInterval.map { interval in
            tonnage(history.filter { $0.completedAt >= interval.start && $0.completedAt < interval.end })
        } ?? 0
        let target = baselineTonnage.map { baseline in
            switch phase {
            case .accumulation:
                return baseline * (1 + config.monthlyIncrease)
            case .deload:
                return baseline * config.deloadTonnageFraction
            }
        }
        return TrainingBlockStatus(
            phase: phase,
            baselineTonnage: baselineTonnage,
            baselineWeeks: baseline.count,
            currentTonnage: currentTonnage,
            targetTonnage: target
        )
    }

    /// Scheduled and broad adaptive deloads are proposals. The returned sets
    /// become a deload only if the lifter accepts them as a new plan.
    public static func applyingDeload(
        to recommendation: ExerciseRecommendation,
        plan: ExercisePlan,
        phase: TrainingBlockPhase,
        adaptiveDeload: Bool,
        resumePlan: ExercisePlan? = nil
    ) -> ExerciseRecommendation {
        guard !recommendation.sets.isEmpty else { return recommendation }
        if plan.isDeload {
            if case .deload = phase { return recommendation }
            if adaptiveDeload { return recommendation }
            let resumedSets = resumePlan?.sets ?? plan.sets
            return ExerciseRecommendation(
                exerciseID: recommendation.exerciseID,
                basedOnPlanID: recommendation.basedOnPlanID,
                generatedAt: recommendation.generatedAt,
                action: .hold,
                sets: resumedSets,
                reason: .resumeAfterDeload,
                evidence: .limited,
                supportingExposureIDs: recommendation.supportingExposureIDs,
                ruleVersion: "\(recommendation.ruleVersion)+\(ruleVersion)"
            )
        }
        let reason: ExerciseRecommendation.Reason
        switch phase {
        case .deload(let week): reason = .scheduledDeload(week: week)
        case .accumulation:
            guard adaptiveDeload else { return recommendation }
            reason = .programFatigue
        }
        let source = recommendation.sets
        let reducedCount = max(1, Int(floor(Double(source.count) * 2 / 3)))
        let recoveryRPE = RPE(7)!
        let reduced = source.prefix(reducedCount).map {
            PlannedWorkingSet(load: $0.load, reps: $0.reps, rpe: min($0.rpe, recoveryRPE))
        }
        return ExerciseRecommendation(
            exerciseID: recommendation.exerciseID,
            basedOnPlanID: recommendation.basedOnPlanID,
            generatedAt: recommendation.generatedAt,
            action: .deload,
            sets: reduced,
            reason: reason,
            evidence: adaptiveDeload ? .consistent : .limited,
            supportingExposureIDs: recommendation.supportingExposureIDs,
            ruleVersion: "\(recommendation.ruleVersion)+\(ruleVersion)"
        )
    }

    /// Requires the two latest comparable exposures on at least two distinct
    /// exercises to show fatigue. Time pressure, pain, unknown completion, and
    /// a single bad movement never trigger a program-wide deload.
    public static func adaptiveDeloadNeeded(
        history: [ExerciseExposure],
        now: Date = Date(),
        freshness: TimeInterval = 21 * 86_400
    ) -> Bool {
        let eligible = history.filter {
            $0.completedAt <= now && now.timeIntervalSince($0.completedAt) <= freshness
        }
        let byExercise = Dictionary(grouping: eligible, by: \.exerciseID)
        let affected = byExercise.values.filter { exposures in
            let ordered = exposures.sorted { $0.completedAt < $1.completedAt }
            let lastTwo = ordered.suffix(2)
            return lastTwo.count == 2 && lastTwo.allSatisfy(isFatigued)
        }
        return affected.count >= 2
    }

    private struct BaselineWeek {
        let exerciseIDs: Set<UUID>
        let tonnage: Double
    }

    private static func baselineWeeks(
        before start: Date,
        history: [ExerciseExposure],
        calendar: Calendar
    ) -> [BaselineWeek] {
        guard let startOfBlock = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return [] }
        var weeks: [BaselineWeek] = []
        for offset in stride(from: -3, through: -1, by: 1) {
            guard let date = calendar.date(byAdding: .weekOfYear, value: offset, to: startOfBlock),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            let exposures = history.filter {
                $0.completedAt >= interval.start && $0.completedAt < interval.end
            }
            guard !exposures.isEmpty, exposures.allSatisfy(isTolerated) else {
                weeks.removeAll()
                continue
            }
            let ids = Set(exposures.map(\.exerciseID))
            if let last = weeks.last, last.exerciseIDs != ids {
                weeks.removeAll()
            }
            weeks.append(BaselineWeek(exerciseIDs: ids, tonnage: tonnage(exposures)))
        }
        return Array(weeks.suffix(3))
    }

    private static func isTolerated(_ exposure: ExerciseExposure) -> Bool {
        guard exposure.completion == .completed,
              exposure.techniqueChanged != true,
              let plan = exposure.plan,
              exposure.workingSets.count == plan.sets.count else { return false }
        return zip(exposure.workingSets, plan.sets).allSatisfy { performed, target in
            performed.effortSource == .reported
                && performed.record.load == target.load
                && performed.record.reps >= target.reps
                && performed.record.rpe.map { $0.value <= target.rpe.value } == true
        }
    }

    private static func isFatigued(_ exposure: ExerciseExposure) -> Bool {
        if exposure.completion == .stoppedForFatigue { return true }
        guard exposure.completion == .completed,
              let plan = exposure.plan,
              exposure.workingSets.count == plan.sets.count else { return false }
        return zip(exposure.workingSets, plan.sets).allSatisfy { performed, target in
            performed.effortSource == .reported
                && performed.record.rpe.map { $0.value > target.rpe.value } == true
        }
    }

    private static func tonnage(_ exposures: [ExerciseExposure]) -> Double {
        exposures.flatMap(\.workingSets).reduce(0) {
            $0 + $1.record.load.pounds * Double($1.record.reps)
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
