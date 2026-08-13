import XCTest
@testable import WeightTrainingCore

final class SuggestionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private var press: Exercise {
        ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
    }

    private func set(_ exercise: Exercise, _ load: Double, _ reps: Int, _ rpe: RPE?,
                     minutesAgo: Double = 0, warmup: Bool = false) -> SetRecord {
        SetRecord(exerciseID: exercise.id, load: Load(load), reps: reps, rpe: rpe,
                  isWarmup: warmup, performedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func suggestions(
        _ exercise: Exercise,
        target: Load? = Load(70),
        targetReps: Int? = 10,
        loggedToday: [SetRecord] = [],
        history: [SetRecord] = [],
        stallCount: Int = 0,
        pendingLoad: Double = 70,
        pendingReps: Int = 10
    ) -> [Suggestion] {
        let state = ProgressState(
            exerciseID: exercise.id, targetLoad: target, targetReps: targetReps,
            targetRPE: .eight, stallCount: stallCount
        )
        return SuggestionEngine.suggestions(
            exercise: exercise,
            prescription: Prescription(exercise: exercise, state: state),
            loggedToday: loggedToday,
            state: state,
            history: history,
            pendingLoad: Load(pendingLoad),
            pendingReps: pendingReps
        )
    }

    // MARK: - Rule 2: every chip states its reason

    /// The issue's own example: "+10, set 1 was RPE 6.5".
    func testAnEasySetProposesMoreWeightAndSaysWhy() throws {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))])
        let chip = try XCTUnwrap(chips.first)
        XCTAssertEqual(chip.kind, .load(Load(80)), "one dumbbell increment up")
        XCTAssertEqual(chip.reason, "set 1 was RPE 6.5")
        XCTAssertEqual(chip.title, "80 lb")
    }

    func testEveryChipCarriesANonEmptyReason() {
        let lift = press
        let cases: [[Suggestion]] = [
            suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))]),
            suggestions(lift, loggedToday: [set(lift, 70, 6, RPE(9.5))]),
            suggestions(lift, stallCount: 2),
            suggestions(lift, pendingReps: 8),
        ]
        for chips in cases {
            for chip in chips {
                XCTAssertFalse(chip.reason.isEmpty, "\(chip.kind) has no reason")
            }
        }
    }

    func testAHardSetProposesLessWeight() throws {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 7, RPE(9.5))])
        let chip = try XCTUnwrap(chips.first)
        XCTAssertEqual(chip.kind, .load(Load(60)))
        XCTAssertEqual(chip.reason, "set 1 was RPE 9.5")
    }

    /// Half a point is inside the noise of a subjective rating, and a chip that
    /// fires on noise trains you to dismiss the ones that matter.
    func testHalfAPointOffTargetSuggestsNothing() {
        let lift = press
        XCTAssertTrue(suggestions(lift, loggedToday: [set(lift, 70, 11, RPE(7.5))]).isEmpty)
        XCTAssertTrue(suggestions(lift, loggedToday: [set(lift, 70, 10, RPE(8.5))]).isEmpty)
    }

    func testOnTargetSuggestsNothing() {
        let lift = press
        XCTAssertTrue(suggestions(lift, loggedToday: [set(lift, 70, 10, RPE(8))]).isEmpty)
    }

    func testTheSetNumberCountsWorkingSetsOnly() throws {
        let lift = press
        let chips = suggestions(lift, loggedToday: [
            set(lift, 45, 10, nil, minutesAgo: 20, warmup: true),
            set(lift, 70, 12, RPE(8), minutesAgo: 10),
            set(lift, 70, 12, RPE(6.5)),
        ])
        XCTAssertEqual(try XCTUnwrap(chips.first).reason, "set 2 was RPE 6.5")
    }

    func testAWarmupNeverDrivesASuggestion() {
        let lift = press
        XCTAssertTrue(suggestions(lift, loggedToday: [
            set(lift, 45, 10, RPE(6), warmup: true)
        ]).isEmpty)
    }

    func testASetLoggedWithoutRPEDrivesNothing() {
        let lift = press
        XCTAssertTrue(suggestions(lift, loggedToday: [set(lift, 70, 12, nil)]).isEmpty)
    }

    // MARK: - Not repeating advice already taken

    /// Once the stepper has been moved up, the chip has done its job and
    /// shouldn't keep nagging at the new weight.
    func testNoChipOnceTheWeightHasAlreadyBeenRaised() {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))],
                                pendingLoad: 80)
        XCTAssertFalse(chips.contains { $0.kind == .load(Load(80)) })
    }

    // MARK: - Deload

    func testAStallingLiftProposesADeloadWithItsReason() throws {
        let lift = press
        let chips = suggestions(lift, stallCount: 2)
        let chip = try XCTUnwrap(chips.first)
        XCTAssertEqual(chip.kind, .deload(Load(60)))
        XCTAssertTrue(chip.reason.contains("Missed 2 sessions"), chip.reason)
        XCTAssertEqual(chip.title, "Deload to 60 lb")
    }

    /// A deload is about the lift, not this set, so it outranks effort advice.
    func testDeloadComesFirst() throws {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))],
                                stallCount: 2)
        XCTAssertEqual(chips.first?.kind, .deload(Load(60)))
    }

    // MARK: - Volume of advice

    /// Three proposals beside one number is a menu, and reading a menu between
    /// sets is the work this app exists to remove.
    func testNeverMoreThanTwoChips() {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))],
                                stallCount: 3, pendingReps: 8)
        XCTAssertLessThanOrEqual(chips.count, 2)
    }

    /// Two chips arguing about the same set is a puzzle, not help.
    func testRepAdviceStaysQuietWhileWeightIsBeingDiscussed() {
        let lift = press
        let chips = suggestions(lift, loggedToday: [set(lift, 70, 12, RPE(6.5))],
                                pendingReps: 99)
        XCTAssertFalse(chips.contains { if case .reps = $0.kind { return true }; return false })
    }

    func testRepChipOffersTheSessionTarget() throws {
        let lift = press
        let chips = suggestions(lift, pendingReps: 8)
        let chip = try XCTUnwrap(chips.first)
        XCTAssertEqual(chip.kind, .reps(10))
        XCTAssertEqual(chip.title, "10 reps")
    }

    func testNothingToSayOnAQuietStart() {
        XCTAssertTrue(suggestions(press).isEmpty)
    }

    // MARK: - Rule 1: chips are inert

    /// The producer is pure — it reads and proposes, and has no way to change a
    /// target, log a set, or move the weight. That makes "the done button
    /// commits exactly what is displayed" a property of the design rather than
    /// a promise to be careful.
    func testSuggestingChangesNothing() {
        let lift = press
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(70),
                                  targetReps: 10, targetRPE: .eight, stallCount: 2)
        let logged = [set(lift, 70, 12, RPE(6.5))]
        let before = state

        _ = SuggestionEngine.suggestions(
            exercise: lift,
            prescription: Prescription(exercise: lift, state: state),
            loggedToday: logged, state: state, history: logged,
            pendingLoad: Load(70), pendingReps: 10
        )

        XCTAssertEqual(state, before)
        XCTAssertEqual(logged.count, 1)
    }

    /// Identity has to survive regeneration, or dismissing a chip wouldn't
    /// keep it dismissed once the next set is logged (rule 3).
    func testIdentityIsStableAcrossRegeneration() {
        let lift = press
        let logged = [set(lift, 70, 12, RPE(6.5))]
        let first = suggestions(lift, loggedToday: logged)
        let second = suggestions(lift, loggedToday: logged)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertFalse(first.isEmpty)
    }

    func testDifferentProposalsHaveDifferentIdentities() {
        XCTAssertNotEqual(
            Suggestion(kind: .load(Load(80)), reason: "a").id,
            Suggestion(kind: .load(Load(60)), reason: "a").id
        )
        XCTAssertNotEqual(
            Suggestion(kind: .load(Load(60)), reason: "a").id,
            Suggestion(kind: .deload(Load(60)), reason: "a").id
        )
    }

    /// Proposals must be loadable, like every other weight the app produces.
    func testProposedLoadsAreAlwaysBuildable() {
        for exercise in ExerciseLibrary.all {
            let start = exercise.equipment.minimumLoad.pounds + exercise.increment.pounds
            for pounds in stride(from: start, through: 205.0, by: exercise.increment.pounds) {
                for rpe in RPE.sessionChips {
                    let logged = [SetRecord(exerciseID: exercise.id, load: Load(pounds),
                                            reps: 10, rpe: rpe, performedAt: now)]
                    let state = ProgressState(exerciseID: exercise.id,
                                              targetLoad: Load(pounds), targetReps: 10,
                                              targetRPE: .eight)
                    let chips = SuggestionEngine.suggestions(
                        exercise: exercise,
                        prescription: Prescription(exercise: exercise, state: state),
                        loggedToday: logged, state: state, history: logged,
                        pendingLoad: Load(pounds), pendingReps: 10
                    )
                    for chip in chips {
                        switch chip.kind {
                        case .load(let load), .deload(let load):
                            XCTAssertTrue(
                                PlateMath.isAchievable(load, equipment: exercise.equipment,
                                                       increment: exercise.increment),
                                "\(exercise.name) proposed \(load) from \(pounds) @ \(rpe)"
                            )
                        case .reps, .swap:
                            break
                        }
                    }
                }
            }
        }
    }
}
