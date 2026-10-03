import XCTest
@testable import WeightTrainingCore

final class RecommendationOutcomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(
        decision: RecommendationTrace.Decision = .automaticallyActivated,
        efforts: [RPE?] = [.seven, .seven],
        action: ExerciseRecommendation.Action = .hold,
        reason: ExerciseRecommendation.Reason = .confirmEasyWorkouts(completed: 1, required: 2),
        automaticOrigin: Bool = false
    ) -> (session: RecordedExerciseSession, exposure: ExerciseExposure) {
        let exercise = Exercise(name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
                                progressionRule: .doubleProgression(range: RepRange(8, 12)))
        let targets = [10, 9].map { PlannedWorkingSet(load: 50, reps: $0, rpe: .eight) }
        let start = now.addingTimeInterval(-7_200), finish = now.addingTimeInterval(-3_600)
        let recommendation = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: UUID(), generatedAt: start,
            action: action, sets: targets, reason: reason, evidence: .limited,
            supportingExposureIDs: [UUID(), UUID()], ruleVersion: "historical-v1")
        let trace = RecommendationTrace(recommendation: recommendation, decision: decision,
                                        automaticallyActivatedAt: automaticOrigin ? start : nil)
        var chosen = targets
        if decision == .edited { chosen[0].reps -= 1 }
        let plan = ExercisePlan(exercise: exercise, sets: chosen)
        let workout = UUID()
        let session = RecordedExerciseSession(
            workoutID: workout, exerciseID: exercise.id, startedAt: start, plan: plan,
            recommendationTrace: trace, completion: .completed, completedAt: finish, updatedAt: finish)
        let performed = chosen.enumerated().map { index, target in
            ExposureSet(record: SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps,
                rpe: efforts[index], performedAt: start.addingTimeInterval(Double(index + 1) * 60),
                workoutID: workout, acceptedPlanID: plan.id, effortWasReported: efforts[index] != nil),
                effortSource: efforts[index] == nil ? .unknown : .reported)
        }
        let exposure = ExerciseExposure(id: workout, exerciseID: exercise.id, plan: plan,
            sets: performed, completion: .completed, completedAt: finish)
        return (session, exposure)
    }

    func testAutomaticAndReviewedOutcomeCohortsStaySeparateAfterReviewOrEdit() throws {
        let automaticEasy = fixture()
        let automaticHard = fixture(efforts: [.seven, .nine])
        let reviewedEasy = fixture(decision: .accepted, automaticOrigin: true)
        let reviewedHard = fixture(decision: .accepted, efforts: [.seven, .nine])
        let edited = fixture(decision: .edited, automaticOrigin: true)
        let cases = [automaticEasy, automaticHard, reviewedEasy, reviewedHard, edited]
        let report = RecommendationFeedbackEngine.report(
            sessions: cases.map { $0.session }, exposures: cases.map { $0.exposure }, now: now)

        XCTAssertEqual(report.automaticActivations, 4, "origin survives subsequent review or edit")
        XCTAssertEqual(report.finishedAutomaticPlans, 2)
        XCTAssertEqual(report.automaticCompletedAsPlanned, 2)
        XCTAssertEqual(report.automaticWorkingSets, 4)
        XCTAssertEqual(report.automaticReportedEffortSets, 4)
        XCTAssertEqual(report.automaticAboveTargetEffortSets, 1)
        XCTAssertEqual(report.automaticEffortCoverage, 1)
        XCTAssertEqual(report.automaticCompletedBelowTargetEffort, 1)

        XCTAssertEqual(report.reviewedPlans, 3)
        XCTAssertEqual(report.acceptedAsSuggested, 2)
        XCTAssertEqual(report.editedBeforeUse, 1)
        XCTAssertEqual(report.finishedAcceptedPlans, 2)
        XCTAssertEqual(report.completedAsPlanned, 2)
        XCTAssertEqual(report.acceptedWorkingSets, 4)
        XCTAssertEqual(report.reportedEffortSets, 4)
        XCTAssertEqual(report.aboveTargetEffortSets, 1)
        XCTAssertEqual(report.effortCoverage, 1)
        XCTAssertEqual(report.completedBelowTargetEffort, 1)
        let editedEntry = try XCTUnwrap(report.entries.first { $0.decision == .edited })
        XCTAssertFalse(editedEntry.completedBelowTargetEffort)
        XCTAssertFalse(editedEntry.completedAsPlanned)
        XCTAssertEqual(editedEntry.workingSets, 0)
    }

    func testBelowTargetOutcomeRequiresEveryRPEReportedStrictlyBelowTarget() throws {
        let cases: [(efforts: [RPE?], qualifies: Bool)] = [
            ([.seven, .seven], true),
            ([.seven, .eight], false),
            ([.eight, .eight], false),
            ([.seven, .nine], false),
            ([.seven, nil], false),
            ([nil, nil], false)
        ]
        for decision in [RecommendationTrace.Decision.automaticallyActivated, .accepted] {
            for example in cases {
                let value = fixture(decision: decision, efforts: example.efforts)
                let report = RecommendationFeedbackEngine.report(
                    sessions: [value.session], exposures: [value.exposure], now: now)
                let entry = try XCTUnwrap(report.entries.first)
                XCTAssertTrue(entry.completedAsPlanned, "effort does not change work-completion semantics")
                XCTAssertEqual(entry.completedBelowTargetEffort, example.qualifies)
                XCTAssertEqual(report.automaticCompletedBelowTargetEffort,
                               decision == .automaticallyActivated && example.qualifies ? 1 : 0)
                XCTAssertEqual(report.completedBelowTargetEffort,
                               decision == .accepted && example.qualifies ? 1 : 0)
                if decision == .automaticallyActivated {
                    XCTAssertEqual(report.automaticReportedEffortSets, example.efforts.compactMap { $0 }.count)
                    XCTAssertEqual(report.automaticEffortCoverage,
                                   Double(example.efforts.compactMap { $0 }.count) / 2)
                }
            }
        }
    }

    func testUnreportedOrMissingRPECannotQualifyEvenWhenOtherEffortFieldsSuggestIt() throws {
        var unknown = fixture()
        unknown.exposure.sets[0].effortSource = .unknown
        var missing = fixture()
        missing.exposure.sets[0].record.rpe = nil
        for value in [unknown, missing] {
            let report = RecommendationFeedbackEngine.report(
                sessions: [value.session], exposures: [value.exposure], now: now)
            XCTAssertFalse(try XCTUnwrap(report.entries.first).completedBelowTargetEffort)
            XCTAssertEqual(report.automaticCompletedBelowTargetEffort, 0)
        }
    }

    func testBelowTargetOutcomeRejectsUnfinishedIncompleteExtraChangedAndEmptyWork() throws {
        var unfinished = fixture()
        unfinished.session.completedAt = nil
        var partial = fixture()
        partial.exposure.sets.removeLast()
        partial.exposure.completion = .shortenedForTime
        var extra = fixture()
        extra.exposure.sets.append(extra.exposure.sets[0])
        var extraRep = fixture()
        extraRep.exposure.sets[0].record.reps += 1
        var changedLoad = fixture()
        changedLoad.exposure.sets[0].record.load = 55
        var empty = fixture()
        empty.session.plan?.sets = []
        empty.exposure.plan = empty.session.plan
        empty.exposure.sets = []
        var changedPlan = fixture()
        changedPlan.session.plan?.sets[0].reps -= 1
        changedPlan.exposure.plan = changedPlan.session.plan
        changedPlan.exposure.sets[0].record.reps -= 1
        for value in [unfinished, partial, extra, extraRep, changedLoad, empty, changedPlan] {
            let report = RecommendationFeedbackEngine.report(
                sessions: [value.session], exposures: [value.exposure], now: now)
            XCTAssertFalse(try XCTUnwrap(report.entries.first).completedBelowTargetEffort)
            XCTAssertEqual(report.automaticCompletedBelowTargetEffort, 0)
        }
        let legacyCompletion = RecommendationFeedbackEngine.report(
            sessions: [extraRep.session], exposures: [extraRep.exposure], now: now)
        XCTAssertEqual(legacyCompletion.automaticCompletedAsPlanned, 1,
                       "the existing completion metric still accepts reps above the target")
    }

    func testAutomaticEarlyFinishAndInProgressWorkHaveSeparateDenominators() {
        var early = fixture(efforts: [.seven, nil])
        early.exposure.sets.removeLast()
        early.exposure.completion = .shortenedForTime
        var inProgress = fixture(efforts: [nil, nil])
        inProgress.session.completedAt = nil
        inProgress.exposure.completion = .unknown
        let report = RecommendationFeedbackEngine.report(
            sessions: [early.session, inProgress.session], exposures: [early.exposure, inProgress.exposure], now: now)
        XCTAssertEqual(report.finishedAutomaticPlans, 1)
        XCTAssertEqual(report.automaticCompletedAsPlanned, 0)
        XCTAssertEqual(report.automaticWorkingSets, 3)
        XCTAssertEqual(report.automaticReportedEffortSets, 1)
        XCTAssertEqual(report.automaticEffortCoverage, 1.0 / 3)
        XCTAssertEqual(report.finishedAcceptedPlans, 0)
        XCTAssertNil(report.effortCoverage)
    }

    func testHistoricalMetadataAndCountsPreserveUnknownLegacyReasons() throws {
        let gateReason = ExerciseRecommendation.Reason.confirmEasyWorkouts(completed: 1, required: 2)
        let gate = fixture(reason: gateReason)
        let missingEffort = fixture(decision: .accepted, reason: .missingEffort)
        let progress = fixture(action: .addReps, reason: .addedRep(set: 1))
        var legacy = fixture(decision: .accepted)
        let trace = try XCTUnwrap(legacy.session.recommendationTrace)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any])
        json.removeValue(forKey: "displayedRecommendation")
        legacy.session.recommendationTrace = try JSONDecoder().decode(
            RecommendationTrace.self, from: JSONSerialization.data(withJSONObject: json))
        let cases = [gate, missingEffort, progress, legacy]
        let report = RecommendationFeedbackEngine.report(
            sessions: cases.map { $0.session }, exposures: cases.map { $0.exposure }, now: now)
        let entry = try XCTUnwrap(report.entries.first { $0.id == gate.session.id })
        XCTAssertEqual(entry.reason, gateReason)
        XCTAssertEqual(entry.evidence, .limited)
        XCTAssertEqual(entry.ruleVersion, "historical-v1")
        XCTAssertEqual(entry.supportingExposureCount, 2)
        let legacyEntry = try XCTUnwrap(report.entries.first { $0.id == legacy.session.id })
        XCTAssertNil(legacyEntry.reason)
        XCTAssertNil(legacyEntry.evidence)
        XCTAssertNil(legacyEntry.ruleVersion, "do not backfill missing snapshot metadata from another trace field")
        XCTAssertNil(legacyEntry.supportingExposureCount)
        XCTAssertEqual(report.actionCounts, [.hold: 3, .addReps: 1])
        XCTAssertEqual(report.reasonCounts, [gateReason: 1, .missingEffort: 1, .addedRep(set: 1): 1])
        XCTAssertEqual(report.holdReasonCounts, [gateReason: 1, .missingEffort: 1])
        XCTAssertEqual(report.unknownReasonCount, 1)
    }

    func testEmptyReportHasNoInventedCoverageOrCounts() {
        let report = RecommendationFeedbackEngine.report(sessions: [], exposures: [], now: now)
        XCTAssertEqual(report.finishedAutomaticPlans, 0)
        XCTAssertEqual(report.automaticCompletedBelowTargetEffort, 0)
        XCTAssertNil(report.automaticEffortCoverage)
        XCTAssertTrue(report.actionCounts.isEmpty)
        XCTAssertTrue(report.reasonCounts.isEmpty)
        XCTAssertTrue(report.holdReasonCounts.isEmpty)
        XCTAssertEqual(report.unknownReasonCount, 0)
    }
}
