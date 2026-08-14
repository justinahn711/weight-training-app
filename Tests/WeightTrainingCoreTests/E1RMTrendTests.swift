import XCTest
@testable import WeightTrainingCore

final class E1RMTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func session(
        _ name: String,
        load: Double,
        reps: Int,
        rpe: RPE? = RPE(8),
        daysAgo: Double,
        sets: Int = 3
    ) -> [SetRecord] {
        let exercise = lift(name)
        return (0..<sets).map { index in
            SetRecord(
                exerciseID: exercise.id, load: Load(load), reps: reps, rpe: rpe,
                performedAt: now.addingTimeInterval(-daysAgo * 86_400 + Double(index) * 300)
            )
        }
    }

    private func trend(_ history: [SetRecord], _ name: String) -> E1RMTrend? {
        E1RMTrendBuilder.trends(history: history, exercises: ExerciseLibrary.all)
            .first { $0.exercise.name == name }
    }

    // MARK: - The done-when: sparse lifts are honest

    /// Two points always make a straight line, and a straight line always looks
    /// like a trend. The chart has to refuse to draw one.
    func testFewerThanThreeSessionsIsNotATrend() throws {
        let one = session("Flat Bench", load: 185, reps: 5, daysAgo: 3)
        let single = try XCTUnwrap(trend(one, "Flat Bench"))
        XCTAssertFalse(single.isMeaningful)
        XCTAssertEqual(single.sessionsUntilMeaningful, 2)
        XCTAssertEqual(single.summary, "2 more sessions to see a trend")

        let two = one + session("Flat Bench", load: 190, reps: 5, daysAgo: 0)
        let pair = try XCTUnwrap(trend(two, "Flat Bench"))
        XCTAssertFalse(pair.isMeaningful, "two points is a line, not a trend")
        XCTAssertEqual(pair.summary, "One more session to see a trend")
    }

    func testThreeSessionsIsATrend() throws {
        let history =
            session("Flat Bench", load: 185, reps: 5, daysAgo: 14)
            + session("Flat Bench", load: 190, reps: 5, daysAgo: 7)
            + session("Flat Bench", load: 195, reps: 5, daysAgo: 0)

        let built = try XCTUnwrap(trend(history, "Flat Bench"))
        XCTAssertTrue(built.isMeaningful)
        XCTAssertEqual(built.points.count, 3)
        XCTAssertEqual(built.sessionsUntilMeaningful, 0)
    }

    // MARK: - Shape of the series

    /// One point per session, not per set — otherwise back-off sets turn the
    /// line into a scatter.
    func testOnePointPerSessionTakingTheCeiling() throws {
        let exercise = lift("Flat Bench")
        let history = [
            SetRecord(exerciseID: exercise.id, load: Load(185), reps: 5, rpe: RPE(8),
                      performedAt: now),
            SetRecord(exerciseID: exercise.id, load: Load(135), reps: 8, rpe: RPE(8),
                      performedAt: now.addingTimeInterval(300)),
        ]
        let built = try XCTUnwrap(trend(history, "Flat Bench"))
        XCTAssertEqual(built.points.count, 1)
        XCTAssertEqual(built.points.first?.topSet.load, Load(185),
                       "the back-off set is not the session's ceiling")
    }

    func testPointsAreChronological() throws {
        let history =
            session("Flat Bench", load: 195, reps: 5, daysAgo: 0)
            + session("Flat Bench", load: 185, reps: 5, daysAgo: 14)
            + session("Flat Bench", load: 190, reps: 5, daysAgo: 7)

        let dates = try XCTUnwrap(trend(history, "Flat Bench")).points.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testWarmupsAreNotPoints() {
        let exercise = lift("Flat Bench")
        let warmupOnly = [SetRecord(exerciseID: exercise.id, load: Load(45), reps: 5,
                                    isWarmup: true, performedAt: now)]
        XCTAssertNil(trend(warmupOnly, "Flat Bench"))
    }

    /// Lifts never performed are omitted, so the screen isn't sixteen empty
    /// rows burying the three with something to say.
    func testLiftsWithNoHistoryAreOmitted() {
        let history = session("Flat Bench", load: 185, reps: 5, daysAgo: 1)
        let all = E1RMTrendBuilder.trends(history: history, exercises: ExerciseLibrary.all)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.exercise.name, "Flat Bench")
    }

    func testLiftsWithTheMostHistoryComeFirst() {
        let history =
            session("Flat Bench", load: 185, reps: 5, daysAgo: 10)
            + session("Flat Bench", load: 190, reps: 5, daysAgo: 5)
            + session("Flat Bench", load: 195, reps: 5, daysAgo: 0)
            + session("Hack Squat", load: 200, reps: 8, daysAgo: 3)

        let all = E1RMTrendBuilder.trends(history: history, exercises: ExerciseLibrary.all)
        XCTAssertEqual(all.map(\.exercise.name), ["Flat Bench", "Hack Squat"])
    }

    // MARK: - The estimate itself

    /// The RPE adjustment is the whole point: same weight and reps at a lower
    /// RPE has to read as progress, or a real PR logs as a flat week.
    func testAnEasierSessionAtTheSameWeightReadsAsProgress() throws {
        let history =
            session("Flat Bench", load: 185, reps: 5, rpe: RPE(9.5), daysAgo: 14)
            + session("Flat Bench", load: 185, reps: 5, rpe: RPE(8), daysAgo: 7)
            + session("Flat Bench", load: 185, reps: 5, rpe: RPE(6.5), daysAgo: 0)

        let built = try XCTUnwrap(trend(history, "Flat Bench"))
        let values = built.points.map(\.e1RM.pounds)
        XCTAssertEqual(values, values.sorted(), "the line rises although the bar never did")
        // 185 x 5 @ 9.5 has 0.5 in reserve: 185 x (1 + 5.5/30) = 218.92
        // 185 x 5 @ 6.5 has 3.5 in reserve: 185 x (1 + 8.5/30) = 237.42
        XCTAssertEqual(try XCTUnwrap(built.change).pounds, 18.5, accuracy: 0.01)
        XCTAssertEqual(built.summary, "+18.5 lb over 3 sessions")
    }

    func testChangeIsFirstToLatestNotBestToLatest() throws {
        let history =
            session("Flat Bench", load: 185, reps: 5, daysAgo: 14)
            + session("Flat Bench", load: 225, reps: 5, daysAgo: 7)
            + session("Flat Bench", load: 195, reps: 5, daysAgo: 0)

        let built = try XCTUnwrap(trend(history, "Flat Bench"))
        XCTAssertEqual(built.best?.topSet.load, Load(225))
        XCTAssertEqual(built.latest?.topSet.load, Load(195))
        XCTAssertGreaterThan(try XCTUnwrap(built.change).pounds, 0,
                             "still up on where it started")
    }

    func testAFlatStretchSaysSo() throws {
        let history =
            session("Flat Bench", load: 185, reps: 5, daysAgo: 14)
            + session("Flat Bench", load: 185, reps: 5, daysAgo: 7)
            + session("Flat Bench", load: 185, reps: 5, daysAgo: 0)

        XCTAssertEqual(try XCTUnwrap(trend(history, "Flat Bench")).summary,
                       "Flat over 3 sessions")
    }

    func testGoingBackwardsIsReportedPlainly() throws {
        let history =
            session("Flat Bench", load: 225, reps: 5, daysAgo: 14)
            + session("Flat Bench", load: 205, reps: 5, daysAgo: 7)
            + session("Flat Bench", load: 185, reps: 5, daysAgo: 0)

        let built = try XCTUnwrap(trend(history, "Flat Bench"))
        XCTAssertLessThan(try XCTUnwrap(built.change).pounds, 0)
        XCTAssertTrue(built.summary.hasPrefix("-"), built.summary)
    }

    /// A point has to be traceable back to a real set, or it's an unexplained
    /// dot on a chart.
    func testEveryPointCarriesTheSetThatProducedIt() throws {
        let history = session("Flat Bench", load: 185, reps: 5, daysAgo: 1)
        let point = try XCTUnwrap(try XCTUnwrap(trend(history, "Flat Bench")).points.first)
        XCTAssertEqual(point.topSet.load, Load(185))
        XCTAssertEqual(point.topSet.reps, 5)
        XCTAssertEqual(point.e1RM, point.topSet.e1RM)
    }

    func testEmptyHistoryProducesNoTrends() {
        XCTAssertTrue(E1RMTrendBuilder.trends(history: [],
                                              exercises: ExerciseLibrary.all).isEmpty)
    }
}
