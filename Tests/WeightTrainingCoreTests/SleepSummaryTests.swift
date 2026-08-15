import XCTest
@testable import WeightTrainingCore

/// Hours actually slept, from records that overlap (#26).
///
/// Written after a device build reported an 18.5-hour night: Oura writes a
/// whole-night "asleep" record alongside the core, deep and REM stages covering
/// the same minutes, and summing them counts every night about twice. The bug
/// was invisible in the app — it just scored perfect recovery and said nothing.
final class SleepSummaryTests: XCTestCase {

    private let calendar = Calendar.current

    private func night(_ day: Int, from startHour: Double, to endHour: Double) -> SleepInterval {
        let base = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_760_000_000 + Double(day) * 86_400)
        )
        return SleepInterval(
            start: base.addingTimeInterval(startHour * 3600),
            end: base.addingTimeInterval(endHour * 3600)
        )
    }

    /// The real case: a whole-night record plus stages covering the same time.
    func testStagesInsideAWholeNightAreNotCountedTwice() throws {
        let intervals = [
            night(0, from: 0, to: 8),      // "asleep", the whole night
            night(0, from: 0, to: 3),      // core
            night(0, from: 3, to: 5),      // deep
            night(0, from: 5, to: 8),      // REM
        ]

        let nights = SleepSummary.hoursPerNight(intervals, calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(try XCTUnwrap(nights.first).value, 8, accuracy: 0.01,
                       "summing would have said 16")
    }

    /// Two devices recording the same night is the same bug wearing a hat.
    func testTwoSourcesRecordingOneNightCountOnce() throws {
        let nights = SleepSummary.hoursPerNight([
            night(0, from: 1, to: 8),      // the ring
            night(0, from: 1.2, to: 7.8),  // the watch, near enough
        ], calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(nights.first).value, 7, accuracy: 0.01)
    }

    /// Waking in the night is not sleeping through it. A gap between records
    /// stays a gap.
    func testGapsAreNotFilledIn() throws {
        let nights = SleepSummary.hoursPerNight([
            night(0, from: 0, to: 3),
            night(0, from: 4, to: 7),      // an hour awake
        ], calendar: calendar)

        XCTAssertEqual(try XCTUnwrap(nights.first).value, 6, accuracy: 0.01,
                       "the waking hour must not be credited")
    }

    /// Consecutive stages abut exactly; that shouldn't depend on how finely a
    /// device sliced the night.
    func testAbuttingStagesMergeIntoOneStretch() {
        let merged = SleepSummary.union(of: [
            night(0, from: 0, to: 2),
            night(0, from: 2, to: 4),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.hours, 4)
    }

    /// A night belongs to the morning it ended on, which is how anyone reading
    /// "last night" thinks of it.
    func testNightsAreKeyedByTheMorningTheyEndOn() throws {
        // 23:00 on day 0 through 07:00 on day 1.
        let intervals = [night(0, from: 23, to: 31)]
        let nights = SleepSummary.hoursPerNight(intervals, calendar: calendar)

        let morning = try XCTUnwrap(nights.first)
        XCTAssertEqual(morning.value, 8, accuracy: 0.01)
        XCTAssertEqual(
            calendar.startOfDay(for: morning.date),
            calendar.startOfDay(for: night(1, from: 0, to: 1).start),
            "an overnight sleep belongs to the following morning"
        )
    }

    func testNoRecordsIsNoNights() {
        XCTAssertTrue(SleepSummary.hoursPerNight([]).isEmpty)
    }
}
