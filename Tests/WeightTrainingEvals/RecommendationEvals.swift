import XCTest
@testable import WeightTrainingCore

/// Feed accepted recommendations back into subsequent workouts. These check
/// the new policy independently of the still-active legacy progression engine.
final class RecommendationEvals: XCTestCase {
    private struct Step {
        let plan: ExercisePlan
        let recommendation: ExerciseRecommendation
    }

    /// `edit` is the lifter changing the lift's settings between sessions: it
    /// is given the session about to be planned and the lift as it stood, and
    /// returns the lift as it now is. A plan keeps the copy it was activated
    /// with, as the app's do, so an old plan goes on describing the old lift.
    private func run(
        sessions: Int,
        edit: (Int, Exercise) -> Exercise = { $1 },
        perform: (Int, PlannedWorkingSet) -> (Int, RPE?)
    ) -> [Step] {
        var lift = Exercise(name: "Bench", muscles: [.primary(.chest)], equipment: .barbell,
                            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        var plan = ExercisePlan(exercise: lift, sets: [10, 10, 9].map {
            PlannedWorkingSet(load: 100, reps: $0)
        })
        var history: [ExerciseExposure] = []
        var steps: [Step] = []
        let epoch = Date(timeIntervalSince1970: 1_760_011_200)
        for index in 0..<sessions {
            lift = edit(index, lift)
            let date = epoch.addingTimeInterval(Double(index) * 2 * 86_400)
            let sets = plan.sets.enumerated().map { setIndex, target in
                let (reps, effort) = perform(index, target)
                return ExposureSet(record: SetRecord(
                    exerciseID: lift.id, load: target.load, reps: reps, rpe: effort,
                    performedAt: date.addingTimeInterval(Double(setIndex) * 180)
                ), effortSource: effort == nil ? .unknown : .reported)
            }
            let finished = date.addingTimeInterval(1_800)
            history.append(ExerciseExposure(id: UUID(), exerciseID: lift.id, plan: plan,
                sets: sets, completion: .completed, completedAt: finished))
            let recommendation = RecommendationEngine.recommend(
                exercise: lift, plan: plan, history: history, now: finished)
            let repeatRead = RecommendationEngine.recommend(
                exercise: lift, plan: plan, history: history, now: finished)
            XCTAssertEqual(recommendation, repeatRead, "Reading a suggestion cannot spend progress")
            XCTAssertEqual(recommendation.sets.count, 3, "This phase must not add unbudgeted sets")
            XCTAssertTrue(recommendation.sets.allSatisfy {
                lift.canBuild($0.load) && $0.load >= lift.lightestUsableLoad && (8...12).contains($0.reps)
            }, "Session \(index): \(recommendation.summary)")
            if recommendation.action == .addReps {
                XCTAssertEqual(recommendation.sets.map(\.load), plan.sets.map(\.load))
                XCTAssertEqual(recommendation.sets.map(\.reps).reduce(0, +), plan.sets.map(\.reps).reduce(0, +) + 1)
            }
            if recommendation.action == .addLoad {
                XCTAssertLessThanOrEqual(recommendation.sets[0].load.pounds / plan.sets[0].load.pounds, 1.050_001)
                XCTAssertTrue(recommendation.sets.allSatisfy { $0.reps == 8 })
            }
            steps.append(Step(plan: plan, recommendation: recommendation))
            if recommendation.sets != plan.sets, !recommendation.sets.isEmpty {
                // Accepting a changed prescription creates a new comparison
                // segment. Repeating a prescription preserves its identity.
                plan = ExercisePlan(exercise: lift, sets: recommendation.sets)
            }
        }
        return steps
    }

    func testRepeatedEasyWorkProgressesWithoutReusingEvidence() {
        let steps = run(sessions: 44) { _, target in (target.reps, .seven) }
        let loadIncreases = steps.filter { $0.recommendation.action == .addLoad }
        XCTAssertEqual(loadIncreases.count, 2, "Scenario must actually exercise load progression")
        XCTAssertEqual(steps.last?.recommendation.sets.first?.load, Load(110))
        for (previous, next) in zip(steps, steps.dropFirst()) {
            if [.addReps, .addLoad].contains(previous.recommendation.action) {
                XCTAssertEqual(next.recommendation.action, .hold, "Every accepted increase needs fresh confirmation")
            }
        }
    }

    /// Tidying a lift up mid-season (#346): a rename, a muscles correction, a
    /// warmup ramp switched on and a rest time of its own, each at a different
    /// point. None of it changes what the rack can make or how the lift
    /// progresses, so the season has to come out decision for decision as it
    /// does for a lift nobody touched. Before, the first session after any of
    /// them came back "Equipment changed" with no target, and the lifter lost
    /// the weight they had earned.
    func testTidyingALiftMidSeasonDoesNotInterruptItsProgression() {
        let untouched = run(sessions: 44) { _, target in (target.reps, .seven) }
        let tidied = run(sessions: 44, edit: { index, lift in
            var lift = lift
            switch index {
            case 5: lift.name = "Flat Bench Press"
            case 12: lift.muscles = [.primary(.chest), .secondary(.triceps), .secondary(.frontDelts)]
            case 20: lift.needsWarmupRamp = true
            case 31: lift.restOverride = 150
            default: break
            }
            return lift
        }) { _, target in (target.reps, .seven) }

        XCTAssertTrue(untouched.contains { $0.recommendation.action == .addLoad },
                      "Scenario must actually exercise load progression")
        XCTAssertEqual(tidied.map(\.recommendation.action), untouched.map(\.recommendation.action))
        XCTAssertEqual(tidied.map(\.recommendation.reason), untouched.map(\.recommendation.reason))
        XCTAssertEqual(tidied.map(\.recommendation.sets), untouched.map(\.recommendation.sets))
        XCTAssertFalse(tidied.contains { $0.recommendation.reason == .equipmentChanged })
    }

    func testEffortCeilingPreventsRunawayLoadOverManyWorkouts() {
        let steps = run(sessions: 44) { _, target in
            (target.reps, target.load > Load(100) ? .nine : .seven)
        }
        XCTAssertTrue(steps.contains { $0.recommendation.action == .addLoad })
        XCTAssertEqual(steps.last?.recommendation.sets.first?.load, Load(105))
        XCTAssertEqual(steps.last?.recommendation.reason, .effortAboveTarget)
        XCTAssertTrue(steps.allSatisfy { $0.recommendation.sets[0].load <= Load(105) })
    }

    func testMissingEffortEveryOtherWorkoutNeverProducesFalseSuccess() {
        let steps = run(sessions: 24) { index, target in
            (target.reps, index.isMultiple(of: 2) ? .seven : nil)
        }
        XCTAssertTrue(steps.allSatisfy { $0.recommendation.action == .hold })
        XCTAssertEqual(steps.last?.recommendation.sets.map(\.reps), [10, 10, 9])
    }

    func testRepeatedMissesBackOffAndResumeWithFreshEvidence() {
        let steps = run(sessions: 44) { _, target in
            target.load > Load(100) ? (7, .nine) : (target.reps, .seven)
        }
        let resetIndices = steps.indices.filter { steps[$0].recommendation.action == .reduce }
        XCTAssertFalse(resetIndices.isEmpty, "The simulated lifter must reach a reset")
        for index in resetIndices {
            XCTAssertLessThan(steps[index].recommendation.sets[0].load, steps[index].plan.sets[0].load)
            if index + 1 < steps.count {
                XCTAssertEqual(steps[index + 1].recommendation.action, .hold)
            }
        }
    }

    func testVolumeIncreaseRespectsOverlappingMuscleBudgets() {
        let exercise = ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
        let target = PlannedWorkingSet(load: 50, reps: 12, rpe: .eight)
        let base = ExerciseRecommendation(
            exerciseID: exercise.id,
            basedOnPlanID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 1_760_011_200),
            action: .hold,
            sets: Array(repeating: target, count: 3),
            reason: .loadStepTooLarge,
            evidence: .consistent,
            supportingExposureIDs: [UUID(), UUID()],
            ruleVersion: "eval"
        )
        func report(triceps: Double) -> VolumeReport {
            VolumeReport(
                muscles: Muscle.allCases.map { muscle in
                    MuscleVolume(
                        muscle: muscle,
                        sets: muscle == .triceps ? triceps : 0,
                        target: muscle.weeklySetTarget
                    )
                },
                from: Date(timeIntervalSince1970: 1_759_406_400),
                to: Date(timeIntervalSince1970: 1_760_011_200)
            )
        }

        let room = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(triceps: 14)
        )
        XCTAssertEqual(room.action, .addSet)
        XCTAssertEqual(room.sets.count, 4)

        let nearlyFull = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(triceps: 15)
        )
        XCTAssertEqual(nearlyFull, base, "The entire four-set workout must fit the secondary budget")

        let full = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(triceps: 16)
        )
        XCTAssertEqual(full, base, "A full secondary budget must block the chest set")
    }
}
