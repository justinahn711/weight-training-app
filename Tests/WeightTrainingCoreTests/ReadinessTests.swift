import XCTest
@testable import WeightTrainingCore

/// The readiness proxy (#26).
///
/// Oura's own score doesn't export, so this is reconstructed from HRV, resting
/// heart rate and sleep. The tests care most about the cases where the honest
/// answer is silence: too little history, or data too old to describe today.
final class ReadinessTests: XCTestCase {

    private let now = Date()
    private let calendar = Calendar.current

    /// `days` back from now, one sample per day, newest last.
    private func series(_ values: [Double], endingDaysAgo offset: Int = 0) -> [HealthSample] {
        values.enumerated().map { index, value in
            let daysAgo = values.count - 1 - index + offset
            return HealthSample(
                date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                value: value
            )
        }
    }

    // MARK: - Refusing to guess

    /// Nothing at all is not a score of zero.
    func testNoDataProducesNothing() {
        XCTAssertNil(Readiness.from(hrv: [], restingHR: [], sleep: [], now: now))
    }

    /// A baseline needs enough days to mean anything. Comparing today against
    /// two other days and calling it a trend is how a wrong reading gets
    /// believed — and this one argues for skipping a session.
    func testTooLittleHistoryProducesNoBaseline() {
        let readiness = Readiness.from(
            hrv: series([60, 62, 58]),
            restingHR: series([50, 51, 50]),
            sleep: [],
            now: now
        )
        XCTAssertNil(readiness)
    }

    /// Sleep needs no baseline — eight hours is good for almost anyone — so it
    /// alone is enough to say something.
    func testSleepAloneIsEnough() throws {
        let readiness = try XCTUnwrap(
            Readiness.from(hrv: [], restingHR: [], sleep: series([8]), now: now)
        )
        XCTAssertEqual(readiness.sleepHours, 8)
        XCTAssertNil(readiness.hrvDeviation)
    }

    /// Data from days ago describes those days. A readiness score computed from
    /// Tuesday's sleep and shown on Friday is simply wrong.
    func testStaleDataIsNotTreatedAsToday() {
        let readiness = Readiness.from(
            hrv: series(Array(repeating: 60, count: 14), endingDaysAgo: 4),
            restingHR: [],
            sleep: [],
            now: now
        )
        XCTAssertNil(readiness, "the newest reading is four days old")
    }

    // MARK: - Scoring

    /// A day sitting exactly on baseline is an ordinary day.
    func testBaselineDayScoresMiddling() throws {
        let flat = Array(repeating: 60.0, count: 15)
        let readiness = try XCTUnwrap(
            Readiness.from(hrv: series(flat), restingHR: [], sleep: [], now: now)
        )
        XCTAssertEqual(readiness.score, 50)
        XCTAssertEqual(readiness.level, .fair)
        XCTAssertTrue(readiness.notes.isEmpty, "an ordinary day has nothing to report")
    }

    /// HRV well below baseline, resting HR up, and a short night all point the
    /// same way, and the score should follow rather than average itself out.
    func testABadMorningScoresLow() throws {
        var hrv = Array(repeating: 60.0, count: 14)
        hrv.append(42)                       // ~30% down
        var hr = Array(repeating: 50.0, count: 14)
        hr.append(58)                        // 8 bpm up

        let readiness = try XCTUnwrap(
            Readiness.from(
                hrv: series(hrv),
                restingHR: series(hr),
                sleep: series([5.0]),
                now: now
            )
        )

        XCTAssertLessThan(readiness.score, 40)
        XCTAssertEqual(readiness.level, .low)
        XCTAssertFalse(readiness.notes.isEmpty)
    }

    /// And the opposite morning.
    func testAGoodMorningScoresHigh() throws {
        var hrv = Array(repeating: 60.0, count: 14)
        hrv.append(75)
        var hr = Array(repeating: 50.0, count: 14)
        hr.append(46)

        let readiness = try XCTUnwrap(
            Readiness.from(
                hrv: series(hrv),
                restingHR: series(hr),
                sleep: series([8.5]),
                now: now
            )
        )

        XCTAssertGreaterThan(readiness.score, 65)
        XCTAssertEqual(readiness.level, .good)
    }

    /// One dreadful night, or a ring worn loose, must not drag the baseline
    /// that today is judged against — which is why the baseline is a median.
    func testOneOutlierDoesNotMoveTheBaseline() throws {
        var withOutlier = Array(repeating: 60.0, count: 14)
        withOutlier[3] = 5                   // artefact
        withOutlier.append(60)               // today, on baseline

        let readiness = try XCTUnwrap(
            Readiness.from(hrv: series(withOutlier), restingHR: [], sleep: [], now: now)
        )
        XCTAssertEqual(readiness.score, 50, "the artefact should not make today look excellent")
    }

    /// The notes are what reaches the digest, so they have to name the measure
    /// and the direction rather than just scoring it.
    func testNotesNameWhatMoved() throws {
        var hrv = Array(repeating: 60.0, count: 14)
        hrv.append(45)

        let readiness = try XCTUnwrap(
            Readiness.from(hrv: series(hrv), restingHR: [], sleep: series([5.5]), now: now)
        )

        XCTAssertTrue(readiness.notes.contains { $0.contains("HRV") && $0.contains("below") })
        XCTAssertTrue(readiness.notes.contains { $0.contains("slept") })
    }

    // MARK: - Saying only what it knows (#26)

    /// Found on a real phone: Oura stopped writing HRV and resting heart rate
    /// to Health a month before sleep did. A score built from sleep alone is
    /// still worth having, but it must not be presented as a full recovery
    /// picture — so the reading records what it actually used.
    func testASleepOnlyReadingSaysSo() throws {
        let readiness = try XCTUnwrap(
            Readiness.from(hrv: [], restingHR: [], sleep: series([5.5]), now: now)
        )

        XCTAssertEqual(readiness.basis, [.sleep])
        XCTAssertTrue(readiness.isSleepOnly)
        XCTAssertFalse(
            readiness.notes.contains { $0.lowercased().contains("hrv") },
            "nothing may claim a measure that was never read"
        )
    }

    /// And a full reading records all three.
    func testAFullReadingRecordsEveryMeasureUsed() throws {
        var hrv = Array(repeating: 60.0, count: 14)
        hrv.append(58)
        var hr = Array(repeating: 50.0, count: 14)
        hr.append(51)

        let readiness = try XCTUnwrap(
            Readiness.from(hrv: series(hrv), restingHR: series(hr),
                           sleep: series([7.5]), now: now)
        )

        XCTAssertEqual(readiness.basis, [.hrv, .restingHR, .sleep])
        XCTAssertFalse(readiness.isSleepOnly)
    }

    /// Stale cardiac data must not sneak into the basis. This is exactly the
    /// July-13 case that prompted the field.
    func testMonthOldCardiacDataIsNotPartOfTheBasis() throws {
        let readiness = try XCTUnwrap(
            Readiness.from(
                hrv: series(Array(repeating: 60.0, count: 15), endingDaysAgo: 30),
                restingHR: [],
                sleep: series([6.0]),
                now: now
            )
        )
        XCTAssertEqual(readiness.basis, [.sleep])
    }
}
