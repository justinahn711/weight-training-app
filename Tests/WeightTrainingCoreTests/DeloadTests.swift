import XCTest
@testable import WeightTrainingCore

final class DeloadDetectorTests: XCTestCase {
    private let day0 = Date(timeIntervalSince1970: 1_760_000_000)

    private var press: Exercise {
        Exercise(
            id: UUID(uuidString: "CB000001-0000-4000-8000-000000000001")!,
            name: "Incline DB Press",
            muscles: [.primary(.chest)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
    }

    private var bench: Exercise {
        Exercise(
            name: "Flat Bench",
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight)
        )
    }

    /// One session, `sessionsAgo` training days back.
    private func session(
        _ exercise: Exercise,
        load: Double,
        reps: Int,
        rpe: RPE?,
        sessionsAgo: Int,
        sets: Int = 3
    ) -> [SetRecord] {
        // Three days apart, so each session is unambiguously its own calendar
        // day without depending on when the test runs.
        let start = day0.addingTimeInterval(Double(-sessionsAgo) * 3 * 86_400)
        return (0..<sets).map { index in
            SetRecord(
                exerciseID: exercise.id, load: Load(load), reps: reps, rpe: rpe,
                performedAt: start.addingTimeInterval(Double(index) * 200)
            )
        }
    }

    // MARK: - The done-when

    /// A synthetic RPE-creep history must produce a deload *before* any rep is
    /// missed. Every session here hits its target reps; only the effort moves.
    func testCreepFiresBeforeAnyRepIsMissed() throws {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 0)

        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(70),
                                  targetReps: 10, stallCount: 0)
        let suggestion = try XCTUnwrap(
            DeloadDetector.evaluate(exercise: lift, state: state, history: history)
        )

        XCTAssertEqual(state.stallCount, 0, "nothing has been missed")
        XCTAssertEqual(suggestion.trigger, .rpeCreep(from: RPE(8)!, to: RPE(9)!, sessions: 3))
        XCTAssertEqual(suggestion.from, Load(70))
        XCTAssertEqual(suggestion.to, Load(60), "70 - 10% = 63, down to a buildable 60")
    }

    // MARK: - Creep

    func testFlatRPEIsNotCreep() {
        let lift = press
        let history = (0..<3).flatMap {
            session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 2 - $0)
        }
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ), "holding steady is not creeping")
    }

    func testFallingRPEIsNotCreep() {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ))
    }

    /// Two rising readings is a mood; three is a trend.
    func testTwoSessionsIsNotEnough() {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ))
    }

    /// Rising effort while the weight also rises is progress, not creep.
    func testRisingRPEAtRisingLoadIsNotCreep() {
        let lift = press
        let history =
            session(lift, load: 60, reps: 10, rpe: RPE(8), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 1)
            + session(lift, load: 80, reps: 10, rpe: RPE(9), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(80)),
            history: history
        ))
    }

    /// Only the most recent three sessions matter — an old creep that was
    /// already resolved shouldn't fire now.
    func testOnlyTheMostRecentSessionsCount() {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 4)
            + session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 3)
            + session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ))
    }

    func testUnscoredSessionsCannotShowCreep() {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: nil, sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ), "a missing reading can't be part of a trend")
    }

    /// Warmups must not be read as the top set of a session.
    func testWarmupsAreIgnored() throws {
        let lift = press
        var history: [SetRecord] = []
        for (index, rpe) in [RPE(8), RPE(8.5), RPE(9)].enumerated() {
            let ago = 2 - index
            history += [SetRecord(exerciseID: lift.id, load: Load(200), reps: 5,
                                  isWarmup: true,
                                  performedAt: day0.addingTimeInterval(Double(-ago) * 3 * 86_400))]
            history += session(lift, load: 70, reps: 10, rpe: rpe, sessionsAgo: ago)
        }
        let suggestion = try XCTUnwrap(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ))
        XCTAssertEqual(suggestion.from, Load(70), "the 200 lb warmup is not the top set")
    }

    // MARK: - Repeated misses

    func testTwoMissesTriggerADeload() throws {
        let lift = press
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(80),
                                  targetReps: 8, stallCount: 2)
        let suggestion = try XCTUnwrap(DeloadDetector.evaluate(
            exercise: lift, state: state,
            history: session(lift, load: 80, reps: 6, rpe: RPE(9.5), sessionsAgo: 0)
        ))
        XCTAssertEqual(suggestion.trigger, .repeatedMisses(sessions: 2))
        XCTAssertEqual(suggestion.to, Load(70), "80 - 10% = 72, down to a buildable 70")
    }

    func testASingleMissDoesNotTriggerADeload() {
        let lift = press
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(80), stallCount: 1)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift, state: state,
            history: session(lift, load: 80, reps: 6, rpe: RPE(9), sessionsAgo: 0)
        ))
    }

    /// An outright failure is more definite than a trend in a subjective
    /// rating, so it wins when both fire.
    func testMissesTakePrecedenceOverCreep() throws {
        let lift = press
        let history =
            session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 2)
            + session(lift, load: 70, reps: 10, rpe: RPE(8.5), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(9), sessionsAgo: 0)
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(70), stallCount: 2)
        let suggestion = try XCTUnwrap(
            DeloadDetector.evaluate(exercise: lift, state: state, history: history)
        )
        XCTAssertEqual(suggestion.trigger, .repeatedMisses(sessions: 2))
    }

    // MARK: - The backed-off load

    /// A deload must always be buildable, and always actually lighter.
    func testDeloadedLoadIsBuildableAndLighter() {
        let lift = bench
        for pounds in stride(from: 50.0, through: 405.0, by: 5.0) {
            let state = ProgressState(exerciseID: lift.id, targetLoad: Load(pounds), stallCount: 2)
            guard let suggestion = DeloadDetector.evaluate(
                exercise: lift, state: state, history: []
            ) else {
                XCTFail("no suggestion at \(pounds)")
                continue
            }
            XCTAssertLessThan(suggestion.to, suggestion.from, "must be lighter at \(pounds)")
            XCTAssertEqual(suggestion.to.pounds.truncatingRemainder(dividingBy: 5), 0,
                           "\(suggestion.to) can't be built at \(pounds)")
        }
    }

    /// Where the increment is so coarse that 10% rounds to nothing, the
    /// suggestion still has to move — otherwise it proposes no change at all.
    func testCoarseIncrementsStillMoveAtLeastOneStep() throws {
        let lift = press // 10 lb dumbbell steps
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(30), stallCount: 2)
        let suggestion = try XCTUnwrap(
            DeloadDetector.evaluate(exercise: lift, state: state, history: [])
        )
        // 30 - 10% = 27, which snaps back up to 30; one step down is 20.
        XCTAssertEqual(suggestion.to, Load(20))
        XCTAssertLessThan(suggestion.to, suggestion.from)
    }

    /// There is nothing below an empty bar. Proposing "45 → 45" would be a
    /// suggestion that changes nothing; a lift stalling on the bar is an
    /// exercise-selection problem, not a loading one.
    func testNoDeloadIsOfferedAtTheEquipmentsFloor() {
        let lift = bench
        let state = ProgressState(exerciseID: lift.id, targetLoad: Load(45), stallCount: 3)
        XCTAssertNil(DeloadDetector.evaluate(exercise: lift, state: state, history: []))
    }

    func testHealthyProgressSuggestsNothing() {
        let lift = press
        let history =
            session(lift, load: 60, reps: 12, rpe: RPE(8), sessionsAgo: 2)
            + session(lift, load: 70, reps: 8, rpe: RPE(8), sessionsAgo: 1)
            + session(lift, load: 70, reps: 10, rpe: RPE(8), sessionsAgo: 0)
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(70)),
            history: history
        ))
    }

    func testNoHistoryAndNoStallsSuggestsNothing() {
        let lift = press
        XCTAssertNil(DeloadDetector.evaluate(
            exercise: lift, state: ProgressState(exerciseID: lift.id), history: []
        ))
    }
}

final class SessionGroupingTests: XCTestCase {
    private let day0 = Date(timeIntervalSince1970: 1_760_000_000)
    private let exerciseID = UUID()

    private func set(daysAgo: Double, minutes: Double = 0, warmup: Bool = false) -> SetRecord {
        SetRecord(
            exerciseID: exerciseID, load: Load(70), reps: 10, rpe: RPE(8), isWarmup: warmup,
            performedAt: day0.addingTimeInterval(-daysAgo * 86_400 + minutes * 60)
        )
    }

    func testSetsOnTheSameDayFormOneSession() {
        let sets = [set(daysAgo: 0), set(daysAgo: 0, minutes: 5), set(daysAgo: 0, minutes: 12)]
        XCTAssertEqual(sets.groupedIntoSessions().count, 1)
    }

    func testDifferentDaysSplit() {
        let sets = [set(daysAgo: 6), set(daysAgo: 3), set(daysAgo: 0)]
        XCTAssertEqual(sets.groupedIntoSessions().count, 3)
    }

    func testSessionsComeBackOldestFirst() {
        let sets = [set(daysAgo: 0), set(daysAgo: 6), set(daysAgo: 3)]
        let sessions = sets.groupedIntoSessions()
        let dates = sessions.compactMap { $0.first?.performedAt }
        XCTAssertEqual(dates, dates.sorted())
    }

    func testWarmupsAreDropped() {
        let sets = [set(daysAgo: 0, warmup: true), set(daysAgo: 0, minutes: 5)]
        XCTAssertEqual(sets.groupedIntoSessions().first?.count, 1)
    }

    func testAWarmupOnlyDayIsNotASession() {
        XCTAssertTrue([set(daysAgo: 0, warmup: true)].groupedIntoSessions().isEmpty)
    }

    func testEmptyHistory() {
        XCTAssertTrue([SetRecord]().groupedIntoSessions().isEmpty)
    }
}
