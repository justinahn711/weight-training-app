import XCTest
@testable import WeightTrainingCore

final class BodyweightRecommendationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var lift: Exercise {
        Exercise(name: "Pull-up", muscles: [.primary(.lats), .secondary(.biceps)],
                 equipment: .bodyweight,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    private func plan(load: Load = Load(173.4), reps: [Int] = [10, 10, 9]) -> ExercisePlan {
        ExercisePlan(exercise: lift, sets: reps.map { PlannedWorkingSet(load: load, reps: $0) })
    }

    private func exposure(_ plan: ExercisePlan, daysAgo: Double, reps: [Int]? = nil) -> ExerciseExposure {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return ExerciseExposure(id: UUID(), exerciseID: plan.exercise.id, plan: plan,
            sets: plan.sets.enumerated().map { index, target in
                ExposureSet(record: SetRecord(exerciseID: plan.exercise.id, load: target.load,
                    reps: reps?[index] ?? target.reps, rpe: .seven, performedAt: date), effortSource: .reported)
            }, completion: .completed, completedAt: date)
    }

    private func recommend(_ plan: ExercisePlan, _ history: [ExerciseExposure],
                           context: RecommendationContext = .init()) -> ExerciseRecommendation {
        RecommendationEngine.recommend(exercise: plan.exercise, plan: plan, history: history,
                                       context: context, now: now)
    }

    func testBodyweightUsesExactTotalLoadAndAddsOneRepAfterRepeatedEasyWork() {
        let target = plan()
        XCTAssertTrue(target.exercise.supportsPlannedProgression)
        XCTAssertFalse(target.exercise.canBuild(target.sets[0].load), "Total bodyweight is not rack weight")
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .addReps)
        XCTAssertEqual(result.sets.map(\.reps), [10, 10, 10])
        XCTAssertEqual(result.sets.map(\.load), target.sets.map(\.load))
    }

    func testBodyweightCeilingNeverAddsWeightOrUnbudgetedSets() {
        let target = plan(reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .hold)
        XCTAssertEqual(result.reason, .bodyweightRepCeiling)
        XCTAssertEqual(result.evidence, .consistent)
        XCTAssertEqual(result.sets, target.sets)
    }

    func testRepeatedMissesNeverReduceFrozenBodyweight() {
        let target = plan()
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [7, 7, 7]),
                                        exposure(target, daysAgo: 2, reps: [7, 7, 7])])
        XCTAssertEqual(result.action, .hold)
        XCTAssertEqual(result.reason, .bodyweightRepeatedMisses)
        XCTAssertEqual(result.sets, target.sets)
    }

    func testIncompleteUnknownOrHardEffortNeverEarnsReps() {
        let target = plan()
        let easy = exposure(target, daysAgo: 4)
        var unknown = exposure(target, daysAgo: 2)
        unknown.sets[0].effortSource = .unknown
        var missing = unknown
        missing.sets[0].record.rpe = nil
        var hard = exposure(target, daysAgo: 2)
        hard.sets[2].record.rpe = .nine
        var incomplete = exposure(target, daysAgo: 2)
        incomplete.completion = .shortenedForTime
        for (latest, reason) in [(unknown, ExerciseRecommendation.Reason.missingEffort),
                                  (missing, .missingEffort), (hard, .effortAboveTarget),
                                  (incomplete, .incompleteExposure)] {
            let result = recommend(target, [easy, latest])
            XCTAssertEqual(result.action, .hold)
            XCTAssertEqual(result.reason, reason)
            XCTAssertEqual(result.sets, target.sets)
        }
    }

    func testDuplicateOrChangedLoadCannotEarnProgression() {
        let target = plan()
        let easy = exposure(target, daysAgo: 4)
        XCTAssertEqual(recommend(target, [easy, easy]).reason,
                       .confirmEasyWorkouts(completed: 1, required: 2))
        var changed = exposure(target, daysAgo: 2)
        changed.sets[0].record.load = Load(174)
        XCTAssertEqual(recommend(target, [easy, changed]).reason, .unexpectedPerformance)
        var newPlan = target
        newPlan.sets = target.sets.map { PlannedWorkingSet(load: 174, reps: $0.reps) }
        XCTAssertEqual(recommend(newPlan, [easy, exposure(target, daysAgo: 2)]).reason, .newPrescription)
    }

    func testPainAndPoorRecoveryStillTakePrecedence() {
        let target = plan(reps: [12, 12, 12])
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        XCTAssertEqual(recommend(target, history, context: .init(painReported: true)).action, .stop)
        XCTAssertEqual(recommend(target, history, context: .init(recovery: .poor)).reason, .poorRecovery)
    }

    func testMixedOrInvalidTotalLoadsRequireReview() {
        for load in [Load.zero, Load(-5), Load(.nan), Load(.infinity), Load(100_001)] {
            XCTAssertEqual(recommend(plan(load: load), []).reason, .invalidInput)
        }
        var mixed = plan()
        mixed.sets[0].load = 180
        XCTAssertEqual(recommend(mixed, []).reason, .invalidInput)
    }

    func testCeilingCanAddOnlyBudgetedVolumeAtUnchangedTotalLoad() {
        let target = plan(reps: [12, 12, 12])
        let base = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        func report(biceps: Double) -> VolumeReport {
            VolumeReport(muscles: Muscle.allCases.map {
                MuscleVolume(muscle: $0, sets: $0 == .biceps ? biceps : 0, target: $0.weeklySetTarget)
            }, from: now.addingTimeInterval(-7 * 86_400), to: now)
        }
        let allowed = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: target.exercise, report: report(biceps: 0))
        XCTAssertEqual(allowed.action, .addSet)
        XCTAssertEqual(allowed.sets.count, 4)
        XCTAssertTrue(allowed.sets.allSatisfy { $0 == target.sets[0] })
        let full = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: target.exercise, report: report(biceps: Double(Muscle.biceps.weeklySetTarget.upperBound)))
        XCTAssertEqual(full, base)
        let misses = recommend(target, [exposure(target, daysAgo: 4, reps: [7, 7, 7]),
                                       exposure(target, daysAgo: 2, reps: [7, 7, 7])])
        XCTAssertEqual(VolumeAllocationEngine.applyingWeeklyVolume(
            to: misses, exercise: target.exercise, report: report(biceps: 0)), misses)
    }

    func testLegacyBodyweightBaselinePreservesTotalAndDoesNotEarnProgress() throws {
        let target = plan()
        let history = exposure(target, daysAgo: 2).sets.map(\.record)
        let result = try XCTUnwrap(LegacyPlanBootstrapEngine.recommend(
            exercise: target.exercise, history: history, now: now))
        XCTAssertEqual(result.action, .establish)
        XCTAssertEqual(result.reason, .legacyBaseline)
        XCTAssertEqual(result.sets, target.sets)
    }

    func testLegacyMixedBodyweightLoadsCannotBeFlattenedIntoInventedPrescription() {
        let target = plan()
        var history = exposure(target, daysAgo: 2).sets.map(\.record)
        history[0].load = 180
        XCTAssertNil(LegacyPlanBootstrapEngine.recommend(exercise: target.exercise, history: history, now: now))
    }

    func testBodyweightReasonsRoundTrip() throws {
        let target = plan(reps: [12, 12, 12])
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        for result in [recommend(target, history), recommend(target, [
            exposure(target, daysAgo: 4, reps: [7, 7, 7]), exposure(target, daysAgo: 2, reps: [7, 7, 7])])] {
            XCTAssertEqual(try JSONDecoder().decode(ExerciseRecommendation.self,
                from: JSONEncoder().encode(result)), result)
        }
    }
}
