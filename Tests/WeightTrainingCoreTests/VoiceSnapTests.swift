import XCTest
@testable import WeightTrainingCore

final class VoiceSnapTests: XCTestCase {

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func snap(
        _ phrase: String,
        _ exerciseName: String = "Flat Bench",
        reference: Double? = 185
    ) -> SnappedInput? {
        guard let parse = VoiceGrammar.parse(phrase) else { return nil }
        return VoiceSnapper.snap(parse, for: lift(exerciseName),
                                 reference: reference.map { Load($0) })
    }

    // MARK: - The done-when

    /// #22's done-when: no voice input can commit a value that plate math
    /// rejects. Swept across every library lift and a wide span of heard
    /// weights, including ones no bar can build.
    func testNoHeardWeightSurvivesUnlessItCanBeBuilt() {
        for exercise in ExerciseLibrary.all {
            for heard in stride(from: 1.0, through: 405.0, by: 1.0) {
                let parse = VoiceParse(
                    command: .logSet(load: Load(heard), reps: 5, rpe: RPE(8))
                )
                guard let snapped = VoiceSnapper.snap(parse, for: exercise,
                                                      reference: Load(185)),
                      let load = snapped.load else { continue }

                XCTAssertTrue(
                    exercise.canBuild(load),
                    "\(exercise.name) accepted \(load) from a heard \(heard)"
                )
            }
        }
    }

    /// The issue's example: a garbled "one eighty" must not become 1080.
    func testAnOrderOfMagnitudeMishearIsRefused() throws {
        let parse = VoiceParse(command: .logSet(load: Load(1_080), reps: 5, rpe: RPE(8)))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(185))
        )
        XCTAssertNil(snapped.load, "1080 is not a bench press")
        XCTAssertFalse(snapped.rejections.isEmpty)
        XCTAssertFalse(snapped.canAutoCommit)

        // What was heard correctly is kept — one bad field doesn't cost the
        // whole utterance.
        XCTAssertEqual(snapped.reps, 5)
        XCTAssertEqual(snapped.rpe, RPE(8))
    }

    // MARK: - Snapping

    func testAHeardWeightSnapsToTheBar() throws {
        let snapped = try XCTUnwrap(snap("187 for 5 at 8"))
        XCTAssertEqual(snapped.load, Load(185), "no bar makes 187")
        XCTAssertTrue(snapped.wasSnapped)
    }

    /// Anything moved to fit the equipment waits for a tap. The number on
    /// screen isn't quite what was said, and that deserves a glance.
    func testSnappedValuesNeverAutoCommit() throws {
        XCTAssertFalse(try XCTUnwrap(snap("187 for 5 at 8")).canAutoCommit)
        XCTAssertTrue(try XCTUnwrap(snap("185 for 5 at 8")).canAutoCommit)
    }

    func testDumbbellWeightsSnapToRealDumbbells() throws {
        let snapped = try XCTUnwrap(
            snap("72 for 10 at 8", "Incline DB Press", reference: 70)
        )
        XCTAssertEqual(snapped.load, Load(70), "there is no 72 lb dumbbell")
    }

    // MARK: - Plausibility

    func testRepsOutsideAHumanRangeAreRefused() throws {
        let parse = VoiceParse(command: .logSet(load: nil, reps: 60, rpe: nil))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(185))
        )
        XCTAssertNil(snapped.reps)
        XCTAssertFalse(snapped.rejections.isEmpty)
    }

    func testPlausibleRepsSurvive() throws {
        for reps in [1, 5, 12, 20, 30] {
            let parse = VoiceParse(command: .logSet(load: nil, reps: reps, rpe: nil))
            let snapped = try XCTUnwrap(
                VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(185))
            )
            XCTAssertEqual(snapped.reps, reps)
        }
    }

    func testAWeightBelowTheBarIsRefused() throws {
        let parse = VoiceParse(command: .logSet(load: Load(30), reps: 5, rpe: nil))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(185))
        )
        XCTAssertNil(snapped.load)
    }

    /// A real jump between exercises is allowed; an impossible one isn't.
    func testAReasonableChangeFromTheCurrentWeightIsAccepted() throws {
        XCTAssertEqual(try XCTUnwrap(snap("225 for 5 at 8")).load, Load(225))
        XCTAssertEqual(try XCTUnwrap(snap("135 for 5 at 8")).load, Load(135))
    }

    /// With nothing to compare against, only the absolute ceiling applies —
    /// a cold start shouldn't refuse the first weight ever entered.
    func testWithoutAReferenceOnlyTheCeilingApplies() throws {
        XCTAssertEqual(try XCTUnwrap(snap("315 for 5 at 8", reference: nil)).load,
                       Load(315))
        XCTAssertNil(try XCTUnwrap(snap("1500 for 5 at 8", reference: nil)).load)
    }

    // MARK: - RPE

    /// RPE needs no plausibility check: the type only permits 6 to 10 in
    /// halves, so an impossible value never becomes an RPE at all. The payoff
    /// for making it failable back in #1.
    func testRPEIsAlreadyImpossibleToGetWrong() throws {
        XCTAssertEqual(try XCTUnwrap(snap("185 for 5 at 8")).rpe, RPE(8))
        XCTAssertEqual(try XCTUnwrap(snap("185 for 5 at eight and a half")).rpe, RPE(8.5))
        // Heard as 12 — snapped onto the grid by the parser rather than
        // reaching the form as nonsense.
        XCTAssertEqual(try XCTUnwrap(snap("185 for 5 at twelve")).rpe, RPE(10))
    }

    // MARK: - Confidence

    /// A bare number is ambiguous, so it shows but never commits itself.
    func testLowConfidenceNeverAutoCommits() throws {
        let snapped = try XCTUnwrap(snap("185"))
        XCTAssertEqual(snapped.load, Load(185), "still shown")
        XCTAssertFalse(snapped.isConfident)
        XCTAssertFalse(snapped.canAutoCommit)
    }

    func testAFullConfidentUtteranceMayAutoCommit() throws {
        let snapped = try XCTUnwrap(snap("185 for 5 at 8"))
        XCTAssertTrue(snapped.canAutoCommit)
        XCTAssertTrue(snapped.rejections.isEmpty)
        XCTAssertFalse(snapped.wasSnapped)
    }

    /// Nothing usable heard means nothing to show.
    func testAnEmptyResultIsNil() {
        XCTAssertNil(snap("clang"))
        XCTAssertNil(VoiceSnapper.snap(VoiceParse(command: .nextExercise),
                                       for: lift("Flat Bench"), reference: nil),
                     "not a set — the caller handles it directly")
    }

    /// Every rejection says what it threw out, so the screen never silently
    /// drops half of what was said.
    func testRejectionsAreExplained() throws {
        let parse = VoiceParse(command: .logSet(load: Load(1_080), reps: 99, rpe: RPE(8)))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(185))
        )
        XCTAssertEqual(snapped.rejections.count, 2)
        XCTAssertTrue(snapped.rejections.allSatisfy { !$0.isEmpty })
    }
}
