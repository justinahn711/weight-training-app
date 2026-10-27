import XCTest
@testable import WeightTrainingCore

/// Calendar replays for the optional block layer. These keep the coordinated
/// recovery rule separate from the exercise progression season simulations.
final class TrainingBlockEvals: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func testTwelveWeekReplaySchedulesThreeReviewableRecoveryWeeks() {
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 5, hour: 12
        ))!
        let config = TrainingBlockConfig(startedAt: start, accumulationWeeks: 3)
        let phases = (0..<12).map { offset in
            TrainingBlockEngine.phase(
                for: config,
                now: calendar.date(byAdding: .weekOfYear, value: offset, to: start)!,
                calendar: calendar
            )
        }
        XCTAssertEqual(phases.enumerated().compactMap { index, phase in
            if case .deload = phase { return index + 1 }
            return nil
        }, [4, 8, 12])
    }

    func testRecoveryProposalNeverRaisesLoadRepsOrSetCount() {
        let exercise = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let plan = ExercisePlan(exercise: exercise, sets: [8, 9, 10, 11, 12].map {
            PlannedWorkingSet(load: 80, reps: $0, rpe: .eight)
        })
        let recommendation = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: plan.id, generatedAt: Date(),
            action: .addLoad, sets: plan.sets, reason: .addedLoad,
            evidence: .consistent, supportingExposureIDs: [], ruleVersion: "replay"
        )
        let recovery = TrainingBlockEngine.applyingDeload(
            to: recommendation, plan: plan, phase: .deload(week: 4), adaptiveDeload: false
        )
        XCTAssertLessThan(recovery.sets.count, plan.sets.count)
        XCTAssertTrue(zip(recovery.sets, plan.sets).allSatisfy {
            $0.load <= $1.load && $0.reps <= $1.reps && $0.rpe <= $1.rpe
        })
    }

    func testTimePressureAloneNeverBecomesProgramFatigue() {
        let exercises = [Muscle.chest, .lats, .quads].map { muscle in
            Exercise(name: muscle.displayName, muscles: [.primary(muscle)], equipment: .dumbbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let history = exercises.flatMap { exercise in
            (1...3).map { offset in
                ExerciseExposure(
                    id: UUID(), exerciseID: exercise.id, plan: nil, sets: [],
                    completion: .shortenedForTime,
                    completedAt: now.addingTimeInterval(Double(-offset) * 86_400)
                )
            }
        }
        XCTAssertFalse(TrainingBlockEngine.adaptiveDeloadNeeded(history: history, now: now))
    }

    // MARK: - Changing the default rest is not fatigue (#341)

    /// The rest default dropping from 1:30 to 1:00 on accessories changes what
    /// every accessory plan asks of the lifter, so the first plan after it is
    /// a different demand from the last before it. Effort that runs hotter at
    /// a shorter rest says nothing about recovery.
    ///
    /// This replays the lifter whose accessories were on the old 90 seconds
    /// and who then takes the new 60: the same two lifts, the same load and
    /// reps, every session logged one RPE above target. Straddling the change
    /// that must not count as fatigue. Before it, and again once two sessions
    /// have been done at the new rest, the identical effort must still be read
    /// as fatigue, so the guard is a seam at the change and not a blind spot.
    func testChangingTheAccessoryRestDefaultNeverReadsAsFatigue() {
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        let before = RestDefaults(compound: 180, accessory: 90)
        let after = RestDefaults.standard
        let accessories = [Muscle.sideDelts, .biceps].map { muscle in
            Exercise(name: muscle.displayName, muscles: [.primary(muscle)], equipment: .dumbbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        XCTAssertTrue(accessories.allSatisfy { !$0.isCompound }, "these have to follow the accessory default")

        // Each session plans its rest the way the app does: from the lift's
        // `restTarget` under the defaults in force that day.
        func session(_ exercise: Exercise, on day: Int, defaults: RestDefaults) -> ExerciseExposure {
            let targets = Array(repeating: PlannedWorkingSet(load: 25, reps: 10, rpe: .eight), count: 3)
            let plan = ExercisePlan(
                exercise: exercise, sets: targets,
                restSeconds: Int(exercise.restTarget(using: defaults)))
            let sets = targets.enumerated().map { index, target in
                ExposureSet(record: SetRecord(
                    exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .nine,
                    performedAt: date(day).addingTimeInterval(Double(index) * 60)
                ), effortSource: .reported)
            }
            return ExerciseExposure(
                id: UUID(), exerciseID: exercise.id, plan: plan, sets: sets,
                completion: .completed, completedAt: date(day).addingTimeInterval(600))
        }
        func history(_ days: [(day: Int, defaults: RestDefaults)]) -> [ExerciseExposure] {
            accessories.flatMap { exercise in
                days.map { session(exercise, on: $0.day, defaults: $0.defaults) }
            }
        }

        XCTAssertEqual(accessories[0].restTarget(using: before), 90)
        XCTAssertEqual(accessories[0].restTarget(using: after), 60)

        // Control: two sessions at the old rest, hot effort, is fatigue.
        XCTAssertTrue(TrainingBlockEngine.adaptiveDeloadNeeded(
            history: history([(7, before), (10, before)]), now: date(12)),
            "the fixture has to be one the detector reads as fatigue, or the rest below proves nothing")

        // The seam: one session before the change, one after. Not comparable.
        XCTAssertFalse(TrainingBlockEngine.adaptiveDeloadNeeded(
            history: history([(7, before), (10, before), (14, after)]), now: date(15)),
            "a lift's first session at a new default rest read as fatigue")

        // Past the seam: two sessions at the new rest are comparable again,
        // and the same effort is once more a real signal.
        XCTAssertTrue(TrainingBlockEngine.adaptiveDeloadNeeded(
            history: history([(7, before), (10, before), (14, after), (17, after)]), now: date(18)),
            "the guard must expire once the demand has been steady for two sessions")
    }
}
