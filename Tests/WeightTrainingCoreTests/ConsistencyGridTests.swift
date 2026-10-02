import XCTest
@testable import WeightTrainingCore

final class ConsistencyGridTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    /// Thursday 9 Oct 2025, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_760_011_200)

    private func day(_ daysAgo: Int, working: Int) -> TrainingDay {
        let lift = ExerciseLibrary.all[0]
        let date = calendar.startOfDay(for: now.addingTimeInterval(Double(-daysAgo) * 86_400))
        let sets = (0..<working).map {
            SetRecord(exerciseID: lift.id, load: Load(100), reps: 8, performedAt: date.addingTimeInterval(Double($0)))
        }
        return TrainingDay(date: date, kind: nil, exercises: [PerformedExercise(exercise: lift, sets: sets)])
    }

    func testGridIsWholeWeeksEndingWithThisOne() {
        let cells = ConsistencyGrid.cells(weeks: 12, days: [], now: now, calendar: calendar)
        XCTAssertEqual(cells.count, 84)
        XCTAssertEqual(calendar.component(.weekday, from: cells[0].date), 2, "starts on a Monday")
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        XCTAssertEqual(cells[77].date, thisWeek, "the last column is the current week")
        XCTAssertTrue(zip(cells, cells.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    func testTodayIsNotFutureButTomorrowIs() {
        let cells = ConsistencyGrid.cells(weeks: 1, days: [], now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(cells.first { $0.date == today }?.isFuture, false)
        XCTAssertEqual(cells.first { $0.date == today.addingTimeInterval(86_400) }?.isFuture, true)
        XCTAssertEqual(cells.filter(\.isFuture).count, 3, "Friday to Sunday")
    }

    func testWorkingSetsLandOnTheirDayAndSetTheIntensity() {
        let cells = ConsistencyGrid.cells(weeks: 2, days: [day(0, working: 12), day(1, working: 3)],
                                          now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let cell = cells.first { $0.date == today }!
        XCTAssertEqual(cell.workingSets, 12)
        XCTAssertEqual(cell.intensity, .moderate)
        XCTAssertEqual(cells.first { $0.date == today.addingTimeInterval(-86_400) }?.intensity, .light)
        XCTAssertEqual(cells.filter { $0.intensity != .none }.count, 2)
    }

    func testIntensityBands() {
        XCTAssertEqual(TrainingIntensity.level(workingSets: 0), .none)
        XCTAssertEqual(TrainingIntensity.level(workingSets: 1), .light)
        XCTAssertEqual(TrainingIntensity.level(workingSets: 8), .moderate)
        XCTAssertEqual(TrainingIntensity.level(workingSets: 16), .heavy)
        XCTAssertEqual(TrainingIntensity.level(workingSets: 24), .full)
        XCTAssertEqual(TrainingIntensity.level(workingSets: 99), .full)
    }
}

final class TrendRecordPointsTests: XCTestCase {
    private func trend(_ e1RMs: [Double]) -> E1RMTrend {
        let lift = ExerciseLibrary.all[0]
        let base = Date(timeIntervalSince1970: 1_760_011_200)
        let points = e1RMs.enumerated().map { index, value in
            let date = base.addingTimeInterval(Double(index) * 86_400 * 3)
            return TrendPoint(date: date, e1RM: Load(value),
                              topSet: SetRecord(exerciseID: lift.id, load: Load(value), reps: 1, performedAt: date))
        }
        return E1RMTrend(exercise: lift, points: points)
    }

    func testFirstSessionIsNeverARecord() {
        XCTAssertTrue(trend([100]).recordPoints.isEmpty)
        XCTAssertTrue(trend([100, 90, 80]).recordPoints.isEmpty)
    }

    func testEachNewHighIsARecordAndTiesAreNot() {
        let records = trend([100, 110, 110, 105, 120, 120]).recordPoints
        XCTAssertEqual(records.map { $0.e1RM.pounds }, [110, 120])
    }
}
