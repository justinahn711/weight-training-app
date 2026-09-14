//
//  ProgressionSummaryRowTests.swift
//  ChickenBreastTests
//

import XCTest
import WeightTrainingCore
@testable import ChickenBreast

/// Coverage for #184: every `ProgressionChange` case the engine can produce
/// gets one row, phrased the way the issue's own examples phrase it.
///
/// `ProgressionSummaryRow.rows` is pure — an `Exercise`, a `ProgressionResult`
/// and the `SetRecord`s that produced it go in, a display row comes out — so
/// this suite never needs `TrainingStore`, `SessionViewModel`, or a
/// simulator. Every fixture below runs its inputs through the real
/// `ProgressionEngine.advance` rather than hand-building a
/// `ProgressionResult`, so a change to the engine's own arithmetic (a
/// different snap, a different reset value) would surface here as a failing
/// assertion instead of a row silently drifting from what actually happened.
@MainActor
final class ProgressionSummaryRowTests: XCTestCase {

    // MARK: - Fixtures

    private func inclinePress() -> Exercise {
        Exercise(
            name: "Incline Press",
            muscles: [.primary(.chest)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12), consecutiveTopHitsRequired: 2)
        )
    }

    private func lateralRaise() -> Exercise {
        Exercise(
            name: "Lateral Raise",
            muscles: [.primary(.sideDelts)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(12, 15))
        )
    }

    private func bench() -> Exercise {
        Exercise(
            name: "Bench",
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight)
        )
    }

    private func set(_ load: Double, _ reps: Int, rpe: RPE? = nil) -> SetRecord {
        SetRecord(exerciseID: UUID(), load: Load(load), reps: reps, rpe: rpe, performedAt: Date())
    }

    /// Runs the real engine, then builds the one row it should produce.
    private func row(
        exercise: Exercise,
        state: ProgressState = ProgressState(exerciseID: UUID()),
        working: [SetRecord],
        unit: MassUnit = .pounds
    ) -> (row: ProgressionSummaryRow?, result: ProgressionResult) {
        let result = ProgressionEngine.advance(exercise: exercise, state: state, performed: working)
        let rows = ProgressionSummaryRow.rows(
            from: [(exercise: exercise, result: result)],
            workingSets: [exercise.id: working],
            unit: unit
        )
        return (rows.first, result)
    }

    // MARK: - Issue's own examples

    /// `Incline Press: 70 × 12 → next 75 × 8 — Earned after 2 top-range
    /// sessions`, verbatim.
    func test_addedLoad_matchesIssueExample() {
        let exercise = inclinePress()
        let state = ProgressState(exerciseID: exercise.id, consecutiveTopHits: 1)
        let (produced, result) = row(exercise: exercise, state: state, working: [set(70, 12), set(70, 13)])

        guard case .addedLoad = result.change else { return XCTFail("expected addedLoad, got \(result.change)") }
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.performedLine, "70 lb × 12")
        XCTAssertEqual(row.nextLine, "75 lb × 8")
        XCTAssertEqual(row.bodyText, "70 lb × 12 → next 75 lb × 8")
        XCTAssertEqual(row.reason, "Earned after 2 top-range sessions")
    }

    /// `Lateral Raise: 15 × 14 → next 15 × 15` — no reason, matching the
    /// issue's example precisely: a plain earned rep needs no sentence.
    func test_addedReps_matchesIssueExample_withNoReason() {
        let exercise = lateralRaise()
        let (produced, result) = row(exercise: exercise, working: [set(15, 14)])

        guard case .addedReps = result.change else { return XCTFail("expected addedReps, got \(result.change)") }
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.performedLine, "15 lb × 14")
        XCTAssertEqual(row.nextLine, "15 lb × 15")
        XCTAssertNil(row.reason)
        XCTAssertEqual(row.bodyText, "15 lb × 14 → next 15 lb × 15")
    }

    /// `Bench: hold 185 × 5 — RPE 9 was above target`, verbatim. `Bench` here
    /// is on double progression specifically because `heldForEffort` is that
    /// rule's overreach branch — the issue's naming is illustrative, not a
    /// claim about how the real "Bench" exercise is configured.
    func test_heldForEffort_matchesIssueExample() {
        let exercise = Exercise(
            name: "Bench",
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(1, 5))
        )
        let (produced, result) = row(exercise: exercise, working: [set(185, 5, rpe: .nine)])

        guard case .heldForEffort = result.change else { return XCTFail("expected heldForEffort, got \(result.change)") }
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.bodyText, "hold 185 lb × 5")
        XCTAssertEqual(row.reason, "RPE 9 was above target")
    }

    // MARK: - Every remaining `ProgressionChange` case (#184 acceptance criteria)

    func test_earnedTowardLoad_holdsAndCountsTowardTheBank() {
        let exercise = inclinePress()
        let (produced, result) = row(exercise: exercise, working: [set(70, 12)])

        guard case .earnedTowardLoad(let hits, let required) = result.change else {
            return XCTFail("expected earnedTowardLoad, got \(result.change)")
        }
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(required, 2)
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.bodyText, "hold 70 lb × 12")
        XCTAssertEqual(row.reason, "Hit the top 1 of 2 — repeat it to bank the jump")
    }

    /// The case that catches a real bug if `performedLine` ever reads from
    /// `ProgressState` instead of the logged sets: the engine holds
    /// `targetReps` at the range's *bottom* (8) to rebuild toward, which is
    /// not what was performed (6). Showing 8 here would overstate a miss as
    /// a made rep count.
    func test_heldAfterMiss_showsWhatWasActuallyPerformed_notTheRebuildTarget() {
        let exercise = inclinePress()
        let (produced, result) = row(exercise: exercise, working: [set(185, 6)])

        guard case .heldAfterMiss(let reps) = result.change else {
            return XCTFail("expected heldAfterMiss, got \(result.change)")
        }
        XCTAssertEqual(reps, 6)
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.bodyText, "hold 185 lb × 6", "must show the missed rep count, not the range bottom")
        XCTAssertEqual(row.reason, "Fell short of the range — hold and rebuild")
        XCTAssertFalse(row.reason?.lowercased().contains("miss") ?? false, "no shaming language")
        XCTAssertFalse(row.reason?.lowercased().contains("fail") ?? false, "no shaming language")
    }

    func test_noEffortReported_holdsAndNamesTheGap() {
        let exercise = bench()
        let (produced, result) = row(exercise: exercise, working: [set(185, 5)])

        guard case .noEffortReported = result.change else {
            return XCTFail("expected noEffortReported, got \(result.change)")
        }
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.bodyText, "hold 185 lb × 5")
        XCTAssertEqual(row.reason, "No RPE logged — holding steady")
    }

    func test_onTarget_holdsWithNoReason() {
        let exercise = bench()
        let (produced, result) = row(exercise: exercise, working: [set(185, 5, rpe: .eight)])

        guard case .onTarget = result.change else { return XCTFail("expected onTarget, got \(result.change)") }
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.bodyText, "hold 185 lb × 5")
        XCTAssertNil(row.reason)
    }

    func test_adjustedLoad_changesAndNamesTheDirection() {
        let exercise = bench()
        let (produced, result) = row(exercise: exercise, working: [set(185, 5, rpe: .seven)])

        guard case .adjustedLoad(let from, let to, let delta) = result.change else {
            return XCTFail("expected adjustedLoad, got \(result.change)")
        }
        XCTAssertEqual(from, Load(185))
        XCTAssertGreaterThan(to, from, "RPE 7 against an RPE 8 target came in easier, so load should rise")
        let row = try! XCTUnwrap(produced)
        XCTAssertEqual(row.performedLine, "185 lb × 5")
        XCTAssertEqual(row.nextLine, "\(to.formatted(in: .pounds)) × 5")
        XCTAssertEqual(row.reason, "\(String(format: "%.1f", abs(delta))) RPE easier than target")
    }

    // MARK: - Guardrails

    /// A missing `workingSets` entry (defensive — `applyProgression` never
    /// actually produces one) drops that row instead of guessing at numbers
    /// nobody logged, while leaving every other row intact.
    func test_rows_dropsAnEntryWithNoWorkingSets() {
        let earned = inclinePress()
        let skipped = lateralRaise()
        let earnedResult = ProgressionEngine.advance(
            exercise: earned, state: ProgressState(exerciseID: earned.id), performed: [set(70, 12)]
        )
        let skippedResult = ProgressionEngine.advance(
            exercise: skipped, state: ProgressState(exerciseID: skipped.id), performed: [set(15, 14)]
        )

        let rows = ProgressionSummaryRow.rows(
            from: [
                (exercise: earned, result: earnedResult),
                (exercise: skipped, result: skippedResult)
            ],
            workingSets: [earned.id: [set(70, 12)]],  // `skipped` deliberately has none
            unit: .pounds
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.exerciseName, "Incline Press")
    }

    /// #67: a row built in kilograms reads in kilograms end to end, not a
    /// pounds number with a kilograms label stapled on.
    func test_rows_respectsTheConfiguredUnit() {
        let exercise = inclinePress()
        let state = ProgressState(exerciseID: exercise.id, consecutiveTopHits: 1)
        let (produced, _) = row(exercise: exercise, state: state, working: [set(70, 12)], unit: .kilograms)

        let row = try! XCTUnwrap(produced)
        let expectedPerformed = Load(70).formatted(in: .kilograms)
        XCTAssertEqual(row.performedLine, "\(expectedPerformed) × 12")
        XCTAssertFalse(row.performedLine.contains("lb"))
    }

    /// VoiceOver reads one sentence per row, in a fixed order, regardless of
    /// whether a reason is present.
    func test_accessibilityLabel_readsExerciseTargetAndReasonTogether() {
        let withReason = ProgressionSummaryRow(
            id: UUID(), exerciseName: "Incline Press",
            performedLine: "70 lb × 12", nextLine: "75 lb × 8",
            reason: "Earned after 2 top-range sessions"
        )
        XCTAssertEqual(
            withReason.accessibilityLabel,
            "Incline Press. 70 lb × 12 → next 75 lb × 8. Earned after 2 top-range sessions."
        )

        let withoutReason = ProgressionSummaryRow(
            id: UUID(), exerciseName: "Lateral Raise",
            performedLine: "15 lb × 14", nextLine: "15 lb × 15", reason: nil
        )
        XCTAssertEqual(withoutReason.accessibilityLabel, "Lateral Raise. 15 lb × 14 → next 15 lb × 15.")
    }
}
