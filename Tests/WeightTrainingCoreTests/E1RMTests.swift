import XCTest
@testable import WeightTrainingCore

/// #11's done-when: e1RM matches hand-computed values across the rep range.
///
/// Every expected number here is Epley — `w × (1 + effective reps / 30)` —
/// worked by hand rather than read back from the implementation.
final class E1RMTests: XCTestCase {
    private let exerciseID = UUID()

    private func set(_ load: Double, _ reps: Int, _ rpe: RPE? = nil,
                     warmup: Bool = false) -> SetRecord {
        SetRecord(exerciseID: exerciseID, load: Load(load), reps: reps, rpe: rpe,
                  isWarmup: warmup, performedAt: Date())
    }

    /// The issue's worked example, both halves.
    func testTheIssuesWorkedExample() throws {
        // Plain: 185 × (1 + 5/30) = 215.83
        let unscored = try XCTUnwrap(set(185, 5).e1RM)
        XCTAssertEqual(unscored.pounds, 215.83, accuracy: 0.01)

        // At RPE 6.5 there are 3.5 reps in reserve, so it's an 8.5-rep effort:
        // 185 × (1 + 8.5/30) = 237.42
        let scored = try XCTUnwrap(set(185, 5, RPE(6.5)).e1RM)
        XCTAssertEqual(scored.pounds, 237.42, accuracy: 0.01)
    }

    func testRPEConvertsToRepsInReserve() {
        XCTAssertEqual(set(100, 5, RPE(10)).effectiveReps, 5, "nothing left")
        XCTAssertEqual(set(100, 5, RPE(9)).effectiveReps, 6)
        XCTAssertEqual(set(100, 5, RPE(8)).effectiveReps, 7)
        XCTAssertEqual(set(100, 5, RPE(6.5)).effectiveReps, 8.5)
    }

    func testAtRPETenItIsPlainEpley() throws {
        let value = try XCTUnwrap(set(225, 3, RPE(10)).e1RM)
        XCTAssertEqual(value.pounds, 225 * (1 + 3.0 / 30), accuracy: 0.001)
    }

    /// Hand-computed across the rep ranges the library actually uses.
    func testAcrossTheLibrarysRepRanges() throws {
        let cases: [(load: Double, reps: Int, rpe: Double, expected: Double)] = [
            (70, 8, 8, 93.33),      // 8-12 bottom:  70 × (1 + 10/30)
            (70, 12, 8, 102.67),    // 8-12 top:     70 × (1 + 14/30)
            (50, 15, 8, 78.33),     // 10-15 top:    50 × (1 + 17/30)
            (25, 20, 8, 43.33),     // 12-20 top:    25 × (1 + 22/30)
            (315, 5, 9, 378.0),     // heavy single-digit: 315 × (1 + 6/30)
        ]
        for entry in cases {
            let value = try XCTUnwrap(set(entry.load, entry.reps, RPE(entry.rpe)).e1RM)
            XCTAssertEqual(value.pounds, entry.expected, accuracy: 0.01,
                           "\(entry.load) × \(entry.reps) @ RPE \(entry.rpe)")
        }
    }

    /// A missing RPE contributes no reserve. That understates the set, and
    /// understating is the right direction to be wrong — inventing an RPE
    /// would show up later as a phantom PR.
    func testMissingRPEUnderstatesRatherThanGuesses() throws {
        let unscored = try XCTUnwrap(set(185, 5).e1RM)
        let scored = try XCTUnwrap(set(185, 5, RPE(8)).e1RM)
        XCTAssertLessThan(unscored.pounds, scored.pounds)
    }

    func testWarmupsHaveNoEstimate() {
        XCTAssertNil(set(45, 10, warmup: true).e1RM)
        XCTAssertNil(set(45, 10, RPE(6), warmup: true).e1RM)
    }

    /// The whole point of the adjustment: an easier set at the same weight and
    /// reps must read as more strength, not the same.
    func testEasierSetsReadAsStronger() throws {
        let hard = try XCTUnwrap(set(185, 5, RPE(9.5)).e1RM)
        let easy = try XCTUnwrap(set(185, 5, RPE(6.5)).e1RM)
        XCTAssertGreaterThan(easy.pounds, hard.pounds)
    }

    /// A real PR must not log as a flat week. Same reps, same RPE, more weight.
    func testMoreWeightAtEqualEffortIsAPR() throws {
        let before = try XCTUnwrap(set(185, 5, RPE(8)).e1RM)
        let after = try XCTUnwrap(set(195, 5, RPE(8)).e1RM)
        XCTAssertGreaterThan(after.pounds, before.pounds)
    }

    // MARK: - Best of a session

    func testBestIgnoresWarmupsAndBackOffSets() throws {
        let session = [
            set(45, 10, warmup: true),
            set(185, 5, RPE(8)),
            set(135, 8, RPE(8)),
        ]
        let best = try XCTUnwrap(session.bestE1RM)
        XCTAssertEqual(best.pounds, 185 * (1 + 7.0 / 30), accuracy: 0.01)
    }

    func testBestOfNothingIsNil() {
        XCTAssertNil([SetRecord]().bestE1RM)
        XCTAssertNil([set(45, 10, warmup: true)].bestE1RM)
    }

    /// A lighter set taken much closer to failure can genuinely out-rank a
    /// heavier easy one, and the estimate should say so.
    func testHigherRepSetCanOutrankAHeavierMaximalOne() throws {
        // A heavy triple taken to failure: 200 × (1 + 3/30) = 220.
        // A lighter eight with one left:   185 × (1 + 9/30) = 240.5.
        let session = [set(200, 3, RPE(10)), set(185, 8, RPE(9))]
        let best = try XCTUnwrap(session.bestE1RM)
        XCTAssertEqual(best.pounds, 240.5, accuracy: 0.01)
    }

    /// The converse, which is the more common case: a heavy set with reps in
    /// reserve outranks a lighter set closer to failure.
    func testHeavierSetWithReserveOutranksALighterGrind() throws {
        // 200 × (1 + 7/30) = 246.67 beats 185 × (1 + 9/30) = 240.5.
        let session = [set(200, 3, RPE(6)), set(185, 8, RPE(9))]
        let best = try XCTUnwrap(session.bestE1RM)
        XCTAssertEqual(best.pounds, 246.67, accuracy: 0.01)
    }
}

/// e1RM has to reach `ProgressState`, since that's what #24 charts and what
/// #13 will read for creep.
final class E1RMProgressionIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private var bench: Exercise {
        Exercise(
            name: "Flat Bench",
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight)
        )
    }

    private var press: Exercise {
        Exercise(
            name: "Incline DB Press",
            muscles: [.primary(.chest)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
    }

    func testEngineRecordsE1RMOnRPETargetedLifts() throws {
        let lift = bench
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(185)),
            performed: [SetRecord(exerciseID: lift.id, load: Load(185), reps: 5,
                                  rpe: RPE(6.5), performedAt: now)]
        )
        let stored = try XCTUnwrap(result.state.lastE1RM)
        XCTAssertEqual(stored.pounds, 237.42, accuracy: 0.01)
    }

    func testEngineRecordsE1RMOnDoubleProgressionLifts() throws {
        let lift = press
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70), targetReps: 10),
            performed: [
                SetRecord(exerciseID: lift.id, load: Load(45), reps: 10,
                          isWarmup: true, performedAt: now),
                SetRecord(exerciseID: lift.id, load: Load(70), reps: 10,
                          rpe: RPE(8), performedAt: now.addingTimeInterval(180)),
            ]
        )
        let stored = try XCTUnwrap(result.state.lastE1RM)
        XCTAssertEqual(stored.pounds, 70 * (1 + 12.0 / 30), accuracy: 0.01,
                       "the warmup must not set the estimate")
    }

    func testNoWorkingSetsLeavesTheEstimateAlone() {
        let lift = press
        let before = ProgressState(exerciseID: lift.id, targetLoad: Load(70),
                                   lastE1RM: Load(100))
        let result = ProgressionEngine.advance(exercise: lift, state: before, performed: [])
        XCTAssertEqual(result.state.lastE1RM, Load(100), "untouched")
    }
}
