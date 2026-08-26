import XCTest
@testable import WeightTrainingCore

/// Every weight a lifter reads, in the unit they chose (#67).
///
/// The bar #67 sets is "no pounds visible anywhere", which makes this a test
/// about strings rather than arithmetic: a target rendered in kg beside a
/// rationale rendered in lb is worse than either alone, because the two
/// numbers appear to disagree about the same lift.
final class DisplayUnitTests: XCTestCase {

    private let bench = Exercise(
        name: "Flat Bench",
        muscles: [.primary(.chest)],
        equipment: .barbell,
        progressionRule: .doubleProgression(range: RepRange(5, 8))
    )

    // MARK: - The session screen

    func testTheTargetLineReadsInTheChosenUnit() {
        let target = Prescription(load: Load(100, .kilograms), reps: 5, rpe: RPE(8)!)
        XCTAssertEqual(target.displayLine(in: .kilograms), "100 kg × 5 @ RPE 8")
    }

    /// The same stored weight, read two ways. Nothing on disk changed.
    func testTheSameStoredWeightReadsBothWays() {
        let target = Prescription(load: Load(225), reps: 5, rpe: RPE(8)!)
        XCTAssertEqual(target.displayLine(in: .pounds), "225 lb × 5 @ RPE 8")
        XCTAssertEqual(target.displayLine(in: .kilograms), "102.1 kg × 5 @ RPE 8")
    }

    func testLastTimeReadsInTheChosenUnit() {
        let sets = [
            SetRecord(exerciseID: bench.id, load: Load(60, .kilograms), reps: 8,
                      rpe: RPE(8), performedAt: Date()),
            SetRecord(exerciseID: bench.id, load: Load(60, .kilograms), reps: 7,
                      rpe: RPE(9), performedAt: Date()),
        ]
        let last = LastPerformance(performedAt: Date(), sets: sets)
        XCTAssertEqual(last.displayLine(in: .kilograms), "60 kg × 8, 7")
    }

    // MARK: - Chips and rationales

    func testASuggestionChipReadsInTheChosenUnit() {
        let chip = Suggestion(kind: .load(Load(100, .kilograms)), reason: "felt easy")
        XCTAssertEqual(chip.title(in: .kilograms), "100 kg")

        let deload = Suggestion(kind: .deload(Load(80, .kilograms)), reason: "stalled")
        XCTAssertEqual(deload.title(in: .kilograms), "Deload to 80 kg")
    }

    /// The rationale sits directly under the chip. If one says 100 kg and the
    /// other says 220 lb they read as two different proposals.
    func testARationaleAgreesWithTheChipAboveIt() {
        let result = ProgressionResult(
            state: ProgressState(exerciseID: bench.id),
            change: .addedLoad(from: Load(100, .kilograms), to: Load(102.5, .kilograms))
        )
        XCTAssertEqual(result.summary(in: .kilograms), "Earned it: 100 kg → 102.5 kg")
    }

    func testHoldingAtWeightReadsInTheChosenUnit() {
        let result = ProgressionResult(
            state: ProgressState(exerciseID: bench.id),
            change: .onTarget(Load(60, .kilograms))
        )
        XCTAssertEqual(result.summary(in: .kilograms), "On target — stay at 60 kg")
    }

    // MARK: - Trends

    func testATrendSummaryReadsInTheChosenUnit() {
        let trend = E1RMTrend(exercise: bench, points: (0..<5).map { index in
            TrendPoint(
                date: Date(timeIntervalSince1970: Double(index) * 86_400),
                e1RM: Load(100 + Double(index) * 2.5, .kilograms),
                topSet: SetRecord(exerciseID: bench.id, load: Load(100, .kilograms),
                                  reps: 5, rpe: RPE(8), performedAt: Date())
            )
        })
        XCTAssertEqual(trend.summary(in: .kilograms), "+10 kg over 5 sessions")
        XCTAssertEqual(trend.summary(in: .pounds), "+22 lb over 5 sessions")
    }

    /// A change too small to render is "flat", not "+0 kg" — the latter is a
    /// distinction the lifter cannot see.
    func testAnImperceptibleChangeReadsAsFlat() {
        let trend = E1RMTrend(exercise: bench, points: (0..<5).map { index in
            TrendPoint(
                date: Date(timeIntervalSince1970: Double(index) * 86_400),
                e1RM: Load(100),
                topSet: SetRecord(exerciseID: bench.id, load: Load(100), reps: 5,
                                  rpe: RPE(8), performedAt: Date())
            )
        })
        XCTAssertEqual(trend.summary(in: .kilograms), "Flat over 5 sessions")
    }

    // MARK: - The default is unchanged

    /// The zero-argument forms still exist and still say pounds, which is what
    /// keeps every test written before #67 honest.
    func testThePoundOnlyFormsAreUnchanged() {
        let target = Prescription(load: Load(225), reps: 5, rpe: RPE(8)!)
        XCTAssertEqual(target.displayLine, target.displayLine(in: .pounds))

        let chip = Suggestion(kind: .load(Load(185)), reason: "felt easy")
        XCTAssertEqual(chip.title, chip.title(in: .pounds))
    }
}
