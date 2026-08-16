import XCTest
@testable import WeightTrainingCore

/// Reconstructing resting heart rate from the overnight series (#59).
///
/// Written against the shape of real data: a phone where Oura populates Health's
/// Heart Rate category every night but leaves the dedicated resting type empty,
/// so readiness had no cardiac measure at all despite the beats being right
/// there.
final class RestingHeartRateTests: XCTestCase {

    private let calendar = Calendar.current
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func at(_ hoursFromBase: Double) -> Date {
        base.addingTimeInterval(hoursFromBase * 3600)
    }

    private func night(_ from: Double, _ to: Double) -> SleepInterval {
        SleepInterval(start: at(from), end: at(to))
    }

    private func beats(_ values: [Double], from start: Double, everyMinutes: Double = 5)
        -> [HealthSample]
    {
        values.enumerated().map { index, value in
            HealthSample(date: at(start + Double(index) * everyMinutes / 60), value: value)
        }
    }

    /// The floor of the night, not the average of it.
    func testTakesTheLowEndOfTheNight() throws {
        let asleep = [night(0, 8)]
        let series = beats([70, 62, 58, 55, 54, 57, 60, 68], from: 0, everyMinutes: 55)

        let nights = RestingHeartRate.perNight(heartRate: series, asleep: asleep,
                                               calendar: calendar)
        let resting = try XCTUnwrap(nights.first).value
        XCTAssertLessThanOrEqual(resting, 56, "should sit near the bottom of the night")
        XCTAssertGreaterThanOrEqual(resting, 54, "but not below what was recorded")
    }

    /// Daytime beats are not resting beats. Bounding by the sleep intervals is
    /// the whole point — a clock-hours window would measure someone walking
    /// around after a late night.
    func testBeatsOutsideSleepAreIgnored() throws {
        let asleep = [night(1, 7)]
        var series = beats([58, 56, 55, 57], from: 1.5, everyMinutes: 60)
        series += beats([120, 130, 125], from: 9, everyMinutes: 10)   // awake, moving

        let resting = try XCTUnwrap(
            RestingHeartRate.perNight(heartRate: series, asleep: asleep,
                                      calendar: calendar).first
        ).value
        XCTAssertLessThan(resting, 60, "the walk must not reach the resting figure")
    }

    /// A single artefact should not become the baseline every later night is
    /// judged against, which is why this is a percentile and not a minimum.
    func testOneImplausiblyLowSampleDoesNotWin() throws {
        let asleep = [night(0, 8)]
        var series = beats(Array(repeating: 58.0, count: 60), from: 0, everyMinutes: 8)
        series.append(HealthSample(date: at(3), value: 24))          // artefact

        let resting = try XCTUnwrap(
            RestingHeartRate.perNight(heartRate: series, asleep: asleep,
                                      calendar: calendar).first
        ).value
        XCTAssertGreaterThan(resting, 40, "one bad reading must not set the night")
    }

    /// A night with no heart-rate samples produces nothing, rather than a zero.
    func testNightWithoutBeatsProducesNothing() {
        let nights = RestingHeartRate.perNight(
            heartRate: beats([60, 61], from: 20, everyMinutes: 10),   // long after
            asleep: [night(0, 6)],
            calendar: calendar
        )
        XCTAssertTrue(nights.isEmpty)
    }

    func testNoDataProducesNothing() {
        XCTAssertTrue(RestingHeartRate.perNight(heartRate: [], asleep: []).isEmpty)
    }

    /// Several nights come back in order, one figure each, keyed to the morning.
    func testOneFigurePerNight() {
        let asleep = [night(0, 7), night(24, 31)]
        var series = beats(Array(repeating: 58.0, count: 20), from: 0, everyMinutes: 20)
        series += beats(Array(repeating: 52.0, count: 20), from: 24, everyMinutes: 20)

        let nights = RestingHeartRate.perNight(heartRate: series, asleep: asleep,
                                               calendar: calendar)
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].value, 58, accuracy: 0.01)
        XCTAssertEqual(nights[1].value, 52, accuracy: 0.01)
        XCTAssertLessThan(nights[0].date, nights[1].date)
    }
}
