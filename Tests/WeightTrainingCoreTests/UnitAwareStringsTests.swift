import XCTest
@testable import WeightTrainingCore

/// Every weight the app writes in a sentence is in the lifter's unit (#306).
///
/// `Load.description` is always pounds, so a `"\(load)"` in a user-facing
/// string tells a kg lifter "198.4 lb" beside a chip that says "90 kg".
final class UnitAwareStringsTests: XCTestCase {

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func assertNoPounds(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("lb"), "a kg lifter reads: \(text)", file: file, line: line)
    }

    // MARK: - Deload reason

    func testDeloadReasonForMissesIsInKilograms() {
        let deload = DeloadSuggestion(from: Load(100, .kilograms), to: Load(90, .kilograms),
                                      trigger: .repeatedMisses(sessions: 2))
        XCTAssertEqual(deload.summary(in: .kilograms),
                       "Missed 2 sessions running — back off to 90 kg and rebuild")
    }

    func testDeloadReasonForCreepIsInKilograms() {
        let deload = DeloadSuggestion(from: Load(100, .kilograms), to: Load(90, .kilograms),
                                      trigger: .rpeCreep(from: RPE(8)!, to: RPE(9)!, sessions: 3))
        XCTAssertEqual(deload.summary(in: .kilograms),
                       "Same weight, RPE 8 → RPE 9 over 3 sessions — back off to 90 kg")
    }

    func testPoundsReasonIsUnchanged() {
        let deload = DeloadSuggestion(from: Load(200), to: Load(180),
                                      trigger: .repeatedMisses(sessions: 2))
        XCTAssertEqual(deload.summary, "Missed 2 sessions running — back off to 180 lb and rebuild")
        XCTAssertEqual(deload.summary(in: .pounds), deload.summary)
    }

    /// The chip's reason, which is where the deload summary is read (#12).
    func testDeloadChipReasonMatchesItsTitleUnit() throws {
        let press = lift("Incline DB Press")
        let state = ProgressState(exerciseID: press.id, targetLoad: Load(80), stallCount: 2)
        let chip = try XCTUnwrap(SuggestionEngine.suggestions(
            exercise: press, prescription: Prescription(exercise: press, state: state),
            loggedToday: [], state: state, history: [],
            pendingLoad: Load(80), pendingReps: 8
        ).first)
        guard case .deload = chip.kind else { return XCTFail("expected the deload chip first") }

        XCTAssertTrue(chip.title(in: .kilograms).hasSuffix("kg"))
        assertNoPounds(chip.reason(in: .kilograms))
        XCTAssertTrue(chip.reason(in: .kilograms).contains("back off to"), chip.reason(in: .kilograms))
        XCTAssertEqual(chip.reason(in: .pounds), chip.reason)
    }

    // MARK: - Voice rejection

    func testVoiceRejectionIsInKilograms() throws {
        let parse = VoiceParse(command: .logSet(load: Load(900, .kilograms), reps: 5, rpe: nil))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(100, .kilograms))
        )
        XCTAssertNil(snapped.load)
        XCTAssertEqual(snapped.rejections(in: .kilograms), ["900 kg doesn't look right"])
        XCTAssertFalse(snapped.canAutoCommit)
    }

    func testVoiceRepsRejectionIsUnitless() throws {
        let parse = VoiceParse(command: .logSet(load: nil, reps: 80, rpe: nil))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: lift("Flat Bench"), reference: Load(100, .kilograms))
        )
        XCTAssertEqual(snapped.rejections(in: .kilograms), ["80 reps doesn't look right"])
    }

    // MARK: - Digest deload bullet

    func testDigestDeloadBulletIsInKilograms() throws {
        let press = lift("Incline DB Press")
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let history = (0..<3).map { index in
            SetRecord(exerciseID: press.id, load: Load(80), reps: 6, rpe: RPE(9.5),
                      performedAt: now.addingTimeInterval(-86_400 + Double(index) * 300))
        }
        let digest = Digest.build(
            trends: [], volume: VolumeReport.trailing(history: history, exercises: [press], now: now),
            states: [press.id: ProgressState(exerciseID: press.id, targetLoad: Load(80), stallCount: 2)],
            history: history, exercises: [press], unit: .kilograms, now: now
        )
        let bullet = try XCTUnwrap(digest.bullets.first { $0.isActionable })
        assertNoPounds(bullet.text)
        XCTAssertTrue(bullet.text.contains("kg"), bullet.text)
    }
}
