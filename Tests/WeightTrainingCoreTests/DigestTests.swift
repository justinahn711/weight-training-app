import XCTest
@testable import WeightTrainingCore

final class DigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func sets(
        _ name: String, count: Int, load: Double, reps: Int,
        rpe: RPE? = RPE(8), daysAgo: Double
    ) -> [SetRecord] {
        let exercise = lift(name)
        return (0..<count).map { index in
            SetRecord(exerciseID: exercise.id, load: Load(load), reps: reps, rpe: rpe,
                      performedAt: now.addingTimeInterval(-daysAgo * 86_400
                                                          + Double(index) * 300))
        }
    }

    private func digest(
        history: [SetRecord],
        states: [UUID: ProgressState] = [:],
        readiness: Readiness? = nil
    ) -> Digest {
        Digest.build(
            trends: E1RMTrendBuilder.trends(history: history, exercises: ExerciseLibrary.all),
            volume: VolumeReport.trailing(history: history, exercises: ExerciseLibrary.all,
                                          now: now),
            states: states,
            history: history,
            exercises: ExerciseLibrary.all,
            readiness: readiness,
            now: now
        )
    }

    /// A reading with the given score and notes, built directly — the scoring
    /// itself is `ReadinessTests`' problem.
    private func reading(
        score: Int, notes: [String], concerns: [String]? = nil
    ) -> Readiness {
        Readiness(score: score, notes: notes, concerns: concerns ?? notes,
                  hrvDeviation: nil, restingHRDeviation: nil, sleepHours: nil,
                  basis: [.sleep])
    }

    // MARK: - The cap

    /// A digest that lists everything is a report, and a report gets skimmed
    /// once and then ignored.
    func testNeverMoreThanThreeBullets() {
        // Plenty to say: a creeping lift, a starved week, and a climbing lift.
        var history: [SetRecord] = []
        for daysAgo in [5.0, 3.0, 1.0] {
            history += sets("Incline DB Press", count: 3, load: 70, reps: 10,
                            rpe: RPE(daysAgo == 5 ? 8 : daysAgo == 3 ? 8.5 : 9),
                            daysAgo: daysAgo)
        }
        history += sets("Flat Bench", count: 1, load: 185, reps: 5, rpe: RPE(9.5), daysAgo: 20)
        history += sets("Flat Bench", count: 1, load: 195, reps: 5, rpe: RPE(8), daysAgo: 10)
        history += sets("Flat Bench", count: 1, load: 205, reps: 5, rpe: RPE(7.5), daysAgo: 2)

        let states = [lift("Incline DB Press").id:
                        ProgressState(exerciseID: lift("Incline DB Press").id,
                                      targetLoad: Load(70), targetReps: 10)]

        let built = digest(history: history, states: states)
        XCTAssertLessThanOrEqual(built.bullets.count, Digest.maximumBullets)
    }

    // MARK: - Priority

    /// A lift grinding at the same weight is the finding most likely to change
    /// what happens next session, so it leads.
    func testADeloadLeadsTheDigest() throws {
        var history: [SetRecord] = []
        for (daysAgo, rpe) in [(5.0, RPE(8)!), (3.0, RPE(8.5)!), (1.0, RPE(9)!)] {
            history += sets("Incline DB Press", count: 3, load: 70, reps: 10,
                            rpe: rpe, daysAgo: daysAgo)
        }
        let exercise = lift("Incline DB Press")
        let states = [exercise.id: ProgressState(exerciseID: exercise.id,
                                                 targetLoad: Load(70), targetReps: 10)]

        let first = try XCTUnwrap(digest(history: history, states: states).bullets.first)
        XCTAssertTrue(first.text.contains("Incline DB Press"), first.text)
        XCTAssertTrue(first.text.contains("creeping"), first.text)
        XCTAssertEqual(first.action, .deload(exerciseID: exercise.id, to: Load(60)))
        XCTAssertTrue(first.isActionable)
    }

    /// The done-when: a bullet applies its change, so it has to carry enough to
    /// do it without going back to the source data.
    func testADeloadBulletCarriesTheTargetToWrite() throws {
        let exercise = lift("Incline DB Press")
        let states = [exercise.id: ProgressState(exerciseID: exercise.id,
                                                 targetLoad: Load(80), stallCount: 2)]
        let built = digest(history: sets("Incline DB Press", count: 3, load: 80,
                                         reps: 6, rpe: RPE(9.5), daysAgo: 1),
                           states: states)

        let bullet = try XCTUnwrap(built.bullets.first { $0.isActionable })
        guard case .deload(let id, let load) = bullet.action else {
            return XCTFail("expected a deload action")
        }
        XCTAssertEqual(id, exercise.id)
        XCTAssertEqual(load, Load(70), "80 less 10%, snapped to a real dumbbell")
    }

    /// The good news earns its place: a digest that only ever nags gets
    /// silenced, and then the nags stop working too.
    func testProgressIsReportedNotJustProblems() throws {
        var history: [SetRecord] = []
        for (daysAgo, load, rpe) in [(20.0, 185.0, RPE(9.5)!),
                                     (12.0, 195.0, RPE(8.5)!),
                                     (4.0, 205.0, RPE(8)!)] {
            history += sets("Flat Bench", count: 1, load: load, reps: 5,
                            rpe: rpe, daysAgo: daysAgo)
        }

        let bullet = try XCTUnwrap(
            digest(history: history).bullets.first { $0.text.contains("Keep going") }
        )
        XCTAssertTrue(bullet.text.contains("Flat Bench"), bullet.text)
        XCTAssertTrue(bullet.text.contains("e1RM +"), bullet.text)
        XCTAssertFalse(bullet.isActionable, "encouragement changes nothing")
        XCTAssertEqual(bullet.action, .review(.trend(exerciseID: lift("Flat Bench").id)))
    }

    func testTheWorstVolumeHoleIsNamed() throws {
        // A push day only: rear delts get nothing at all.
        let history = sets("Incline DB Press", count: 4, load: 70, reps: 10, daysAgo: 2)
            + sets("Lateral Raise", count: 4, load: 20, reps: 15, daysAgo: 2)

        let bullet = try XCTUnwrap(
            digest(history: history).bullets.first { $0.action == .review(.volume) }
        )
        XCTAssertTrue(bullet.text.contains("hard sets this week"), bullet.text)
        XCTAssertTrue(bullet.text.contains(" of "), bullet.text)
        XCTAssertFalse(bullet.isActionable)
    }

    // MARK: - Silence

    /// Nothing to say means nothing sent. A digest that arrives every week
    /// whether or not it has a finding trains you to ignore it.
    func testAnEmptyWeekWithNothingWrongProducesNothing() {
        let built = Digest.build(
            trends: [], volume: VolumeReport(muscles: [], from: now, to: now),
            states: [:], history: [], exercises: ExerciseLibrary.all, now: now
        )
        XCTAssertTrue(built.isEmpty)
        XCTAssertTrue(built.bullets.isEmpty)
    }

    /// A lift with no stored state can't be assessed and mustn't be guessed at.
    func testLiftsWithoutStateProduceNoDeload() {
        let history = sets("Incline DB Press", count: 3, load: 80, reps: 5,
                           rpe: RPE(9.5), daysAgo: 1)
        XCTAssertTrue(digest(history: history).bullets.allSatisfy { !$0.isActionable })
    }

    // MARK: - No weekdays in the content

    /// #17's rule holds inside the digest text. The delivery may be weekly;
    /// nothing the app *says* may be.
    func testNoBulletMentionsAWeekday() {
        var history: [SetRecord] = []
        for (daysAgo, rpe) in [(5.0, RPE(8)!), (3.0, RPE(8.5)!), (1.0, RPE(9)!)] {
            history += sets("Incline DB Press", count: 3, load: 70, reps: 10,
                            rpe: rpe, daysAgo: daysAgo)
        }
        let exercise = lift("Incline DB Press")
        let built = digest(history: history,
                           states: [exercise.id: ProgressState(exerciseID: exercise.id,
                                                               targetLoad: Load(70))])

        let weekdays = ["monday", "tuesday", "wednesday", "thursday",
                        "friday", "saturday", "sunday"]
        for bullet in built.bullets {
            for weekday in weekdays {
                XCTAssertFalse(bullet.text.lowercased().contains(weekday), bullet.text)
            }
        }
    }

    // MARK: - Recovery (#26)

    /// Readiness reaches the digest as another signal, not as an instruction.
    func testRecoveryAppearsAsAReadOnlyBullet() throws {
        let digest = digest(
            history: sets("Flat Bench", count: 3, load: 185, reps: 5, daysAgo: 2),
            readiness: reading(score: 30, notes: ["HRV 22% below your 14-day average"])
        )

        let bullet = try XCTUnwrap(digest.bullets.first { $0.text.contains("HRV") })
        XCTAssertEqual(bullet.action, .review(.readiness))
        XCTAssertFalse(bullet.isActionable, "recovery never changes a target on its own")
    }

    /// A day with nothing unusual about it says nothing. Reporting "recovery is
    /// normal" every week is how a digest becomes noise.
    func testAnOrdinaryMorningIsNotWorthABullet() {
        let digest = digest(
            history: sets("Flat Bench", count: 3, load: 185, reps: 5, daysAgo: 2),
            readiness: reading(score: 52, notes: [])
        )
        XCTAssertFalse(digest.bullets.contains { $0.action == .review(.readiness) })
    }

    /// No Health data at all is not a finding either.
    func testNoReadingProducesNoBullet() {
        let digest = digest(
            history: sets("Flat Bench", count: 3, load: 185, reps: 5, daysAgo: 2),
            readiness: nil
        )
        XCTAssertFalse(digest.bullets.contains { $0.action == .review(.readiness) })
    }

    /// Recovery qualifies the finding instead of competing with it (#62).
    ///
    /// "Bench effort creeping, slept 5h10" is one thought. The same two facts
    /// on separate lines make the reader join them up, and cost one of three
    /// slots doing it.
    func testRecoveryQualifiesTheDeloadLine() throws {
        let digest = stalling(readiness: reading(score: 25, notes: ["slept 5h10"]))

        let deload = try XCTUnwrap(digest.bullets.first { $0.isActionable })
        XCTAssertTrue(deload.text.contains("Incline DB Press"))
        XCTAssertTrue(deload.text.contains("slept 5h10"), "the reason should be on the line")
        XCTAssertFalse(
            digest.bullets.contains { $0.action == .review(.readiness) },
            "and must not also appear on its own"
        )
    }

    /// Attached to one finding only. Repeating "slept 5h10" under every
    /// stalling lift turns an explanation into nagging.
    func testOnlyOneFindingIsQualified() {
        var history = stallingHistory(for: "Incline DB Press")
        history += stallingHistory(for: "Lat Pulldown", load: 120)
        let states = [
            lift("Incline DB Press").id: state(for: "Incline DB Press"),
            lift("Lat Pulldown").id: state(for: "Lat Pulldown", load: 120),
        ]

        let digest = digest(history: history, states: states,
                            readiness: reading(score: 25, notes: ["slept 5h10"]))

        let mentions = digest.bullets.filter { $0.text.contains("slept 5h10") }
        XCTAssertLessThanOrEqual(mentions.count, 1)
    }

    /// Good news must not be attached to a stall, where it would read as an
    /// excuse that argues against itself.
    func testFavourableRecoveryDoesNotQualifyAStall() throws {
        let digest = stalling(
            readiness: reading(score: 80,
                               notes: ["HRV 14% above your 14-day average"],
                               concerns: [])
        )

        let deload = try XCTUnwrap(digest.bullets.first { $0.isActionable })
        XCTAssertFalse(deload.text.contains("HRV"))
    }

    /// With nothing to qualify, recovery still gets its own line.
    func testRecoveryStandsAloneWhenThereIsNoFinding() {
        let digest = digest(
            history: sets("Flat Bench", count: 3, load: 185, reps: 5, daysAgo: 2),
            readiness: reading(score: 25, notes: ["slept 5h10"])
        )
        XCTAssertTrue(digest.bullets.contains { $0.action == .review(.readiness) })
    }

    // MARK: - Fixtures for the above

    /// Effort climbing at an unchanged load — the shape the deload detector
    /// fires on. Matches `testADeloadLeadsTheDigest`, which is the fixture
    /// known to actually trigger one.
    private func stallingHistory(for name: String, load: Double = 70) -> [SetRecord] {
        var history: [SetRecord] = []
        for (daysAgo, rpe) in [(5.0, RPE(8)!), (3.0, RPE(8.5)!), (1.0, RPE(9)!)] {
            history += sets(name, count: 3, load: load, reps: 10, rpe: rpe, daysAgo: daysAgo)
        }
        return history
    }

    private func state(for name: String, load: Double = 70) -> ProgressState {
        ProgressState(exerciseID: lift(name).id, targetLoad: Load(load), targetReps: 10)
    }

    private func stalling(readiness: Readiness) -> Digest {
        digest(history: stallingHistory(for: "Incline DB Press"),
               states: [lift("Incline DB Press").id: state(for: "Incline DB Press")],
               readiness: readiness)
    }
}
