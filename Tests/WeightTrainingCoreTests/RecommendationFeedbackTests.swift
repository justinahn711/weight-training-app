import XCTest
@testable import WeightTrainingCore

final class RecommendationFeedbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReportSeparatesEditedPlansAndMeasuresAcceptedOutcomes() {
        let exercise = Exercise(
            name: "Press",
            muscles: [.primary(.chest)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let sets = [10, 10, 9].map {
            PlannedWorkingSet(load: 50, reps: $0, rpe: .eight)
        }
        let recommendation = ExerciseRecommendation(
            exerciseID: exercise.id,
            basedOnPlanID: UUID(),
            generatedAt: now.addingTimeInterval(-86_400),
            action: .hold,
            sets: sets,
            reason: .confirmEasyWorkouts(completed: 1, required: 2),
            evidence: .limited,
            supportingExposureIDs: [],
            ruleVersion: "test"
        )
        let acceptedWorkout = UUID()
        let acceptedPlan = ExercisePlan(exercise: exercise, sets: sets)
        var acceptedTrace = RecommendationTrace(recommendation: recommendation)
        acceptedTrace.recordDecision(for: acceptedPlan)
        let acceptedSession = RecordedExerciseSession(
            workoutID: acceptedWorkout,
            exerciseID: exercise.id,
            startedAt: now.addingTimeInterval(-86_400),
            plan: acceptedPlan,
            recommendationTrace: acceptedTrace,
            completion: .completed,
            completedAt: now.addingTimeInterval(-85_000),
            updatedAt: now.addingTimeInterval(-85_000)
        )
        let performed = zip(sets, [RPE.seven, .eight, .nine]).enumerated().map { index, pair in
            ExposureSet(
                record: SetRecord(
                    exerciseID: exercise.id,
                    load: pair.0.load,
                    reps: pair.0.reps,
                    rpe: pair.1,
                    performedAt: now.addingTimeInterval(-86_400 + Double(index * 180))
                ),
                effortSource: .reported
            )
        }
        let exposure = ExerciseExposure(
            id: acceptedWorkout,
            exerciseID: exercise.id,
            plan: acceptedPlan,
            sets: performed,
            completion: .completed,
            completedAt: now.addingTimeInterval(-85_000)
        )

        var editedTrace = RecommendationTrace(recommendation: recommendation)
        var editedSets = sets
        editedSets[0].reps -= 1
        editedTrace.recordDecision(for: ExercisePlan(exercise: exercise, sets: editedSets))
        let editedSession = RecordedExerciseSession(
            workoutID: UUID(),
            exerciseID: exercise.id,
            startedAt: now.addingTimeInterval(-43_200),
            plan: ExercisePlan(exercise: exercise, sets: editedSets),
            recommendationTrace: editedTrace,
            updatedAt: now.addingTimeInterval(-43_200)
        )

        let report = RecommendationFeedbackEngine.report(
            sessions: [acceptedSession, editedSession],
            exposures: [exposure],
            now: now
        )

        XCTAssertEqual(report.reviewedPlans, 2)
        XCTAssertEqual(report.acceptedAsSuggested, 1)
        XCTAssertEqual(report.editedBeforeUse, 1)
        XCTAssertEqual(report.finishedAcceptedPlans, 1)
        XCTAssertEqual(report.completedAsPlanned, 1)
        XCTAssertEqual(report.reportedEffortSets, 3)
        XCTAssertEqual(report.acceptedWorkingSets, 3)
        XCTAssertEqual(report.aboveTargetEffortSets, 1)
        XCTAssertEqual(report.effortCoverage, 1)
    }

    func testOldAndFutureTracesStayOutOfRollingWindow() {
        let exercise = Exercise(
            name: "Row", muscles: [.primary(.lats)], equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        func session(at date: Date) -> RecordedExerciseSession {
            let recommendation = ExerciseRecommendation(
                exerciseID: exercise.id, basedOnPlanID: nil, generatedAt: date,
                action: .hold,
                sets: [PlannedWorkingSet(load: 100, reps: 8)],
                reason: .newPrescription,
                evidence: .limited,
                supportingExposureIDs: [],
                ruleVersion: "test"
            )
            return RecordedExerciseSession(
                workoutID: UUID(), exerciseID: exercise.id, startedAt: date,
                recommendationTrace: RecommendationTrace(recommendation: recommendation),
                updatedAt: date
            )
        }

        let report = RecommendationFeedbackEngine.report(
            sessions: [
                session(at: now.addingTimeInterval(-29 * 86_400)),
                session(at: now.addingTimeInterval(60))
            ],
            exposures: [],
            now: now
        )

        XCTAssertEqual(report.reviewedPlans, 0)
    }

    func testEarlyFinishStaysInCompletionDenominator() {
        let exercise = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let target = PlannedWorkingSet(load: 50, reps: 10, rpe: .eight)
        let recommendation = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: nil, generatedAt: now,
            action: .hold, sets: [target, target], reason: .incompleteExposure,
            evidence: .limited, supportingExposureIDs: [], ruleVersion: "test"
        )
        let workout = UUID()
        let plan = ExercisePlan(exercise: exercise, sets: recommendation.sets)
        let session = RecordedExerciseSession(
            workoutID: workout, exerciseID: exercise.id, startedAt: now,
            plan: plan, recommendationTrace: RecommendationTrace(recommendation: recommendation),
            completion: .shortenedForTime, completedAt: now, updatedAt: now
        )
        let exposure = ExerciseExposure(
            id: workout, exerciseID: exercise.id, plan: plan, sets: [],
            completion: .shortenedForTime, completedAt: now
        )

        let report = RecommendationFeedbackEngine.report(
            sessions: [session], exposures: [exposure], now: now
        )

        XCTAssertEqual(report.finishedAcceptedPlans, 1)
        XCTAssertEqual(report.completedAsPlanned, 0)
    }

    func testSessionWrittenBeforeFeedbackTracingStillDecodes() throws {
        let session = RecordedExerciseSession(
            workoutID: UUID(), exerciseID: UUID(), startedAt: now, updatedAt: now
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        object.removeValue(forKey: "recommendationTrace")

        let decoded = try JSONDecoder().decode(
            RecordedExerciseSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.recommendationTrace)
    }
}
