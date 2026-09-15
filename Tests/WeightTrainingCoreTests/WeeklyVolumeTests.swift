import XCTest
@testable import WeightTrainingCore

final class WeeklyVolumeTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday, so the edges below don't move with locale
        return c
    }
    /// Thursday 9 Oct 2025, noon UTC: Monday is 3 days back, so 4 days ago is last week.
    private let now = Date(timeIntervalSince1970: 1_760_011_200)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func sets(_ name: String, count: Int, daysAgo: Double,
                      rpe: RPE? = RPE(8), warmup: Bool = false) -> [SetRecord] {
        let exercise = lift(name)
        return (0..<count).map { index in
            SetRecord(exerciseID: exercise.id, load: Load(100), reps: 10, rpe: rpe, isWarmup: warmup,
                      performedAt: now.addingTimeInterval(-daysAgo * 86_400 + Double(index) * 300))
        }
    }

    private func weeks(_ count: Int = 12, _ history: [SetRecord]) -> [WeeklyVolumePoint] {
        WeeklyVolumeBuilder.weeks(count, history: history, exercises: ExerciseLibrary.all,
                                  now: now, calendar: calendar)
    }

    func testAlwaysReturnsTheRequestedNumberOfWeeksOldestFirst() {
        let points = weeks(12, [])
        XCTAssertEqual(points.count, 12)
        XCTAssertEqual(points.last?.weekStart, calendar.dateInterval(of: .weekOfYear, for: now)?.start)
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.weekStart < $1.weekStart })
        XCTAssertTrue(points.allSatisfy { $0.total == 0 }, "empty weeks are present at zero")
    }

    func testSetsLandInTheirCalendarWeekWithPrimaryFullAndSecondaryHalf() {
        let points = weeks(4, sets("Incline DB Press", count: 4, daysAgo: 1))
        let thisWeek = points.last!
        XCTAssertEqual(thisWeek.setsByMuscle[.chest], 4)
        XCTAssertEqual(thisWeek.setsByMuscle[.triceps], 2)
        XCTAssertEqual(thisWeek.sets(in: .chest), 4)
        XCTAssertEqual(thisWeek.sets(in: .arms), 2)
        XCTAssertEqual(thisWeek.sets(in: .legs), 0)
        XCTAssertEqual(thisWeek.sets(in: nil), thisWeek.total)
        XCTAssertTrue(points.dropLast().allSatisfy { $0.total == 0 })
    }

    func testLastWeekIsLastWeekNotSevenDaysAgo() {
        // Thursday minus 4 days is the previous week's Sunday.
        let points = weeks(2, sets("Incline DB Press", count: 3, daysAgo: 4))
        XCTAssertEqual(points[0].setsByMuscle[.chest], 3)
        XCTAssertEqual(points[1].total, 0)
    }

    func testWarmupsEasySetsAndTheFutureAreNotVolume() {
        let history = sets("Incline DB Press", count: 3, daysAgo: 1, warmup: true)
            + sets("Incline DB Press", count: 3, daysAgo: 1, rpe: RPE(6))
            + sets("Incline DB Press", count: 3, daysAgo: -1)
        XCTAssertEqual(weeks(2, history).last?.total, 0)
    }

    func testEveryMuscleHasARegion() {
        for muscle in Muscle.allCases {
            XCTAssertTrue(MuscleRegion.allCases.contains(muscle.region))
        }
        XCTAssertEqual(Muscle.calves.region, .legs)
        XCTAssertEqual(Muscle.traps.region, .back)
    }
}

final class WeeklySummaryTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday, so the edges below don't move with locale
        return c
    }
    private let now = Date(timeIntervalSince1970: 1_760_011_200)

    private func week(_ back: Int, total: Double) -> WeeklyVolumePoint {
        let current = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current)!
        return WeeklyVolumePoint(weekStart: start, setsByMuscle: [.chest: total])
    }

    private func day(_ daysAgo: Int, working: Int = 3) -> TrainingDay {
        let lift = ExerciseLibrary.all[0]
        let date = calendar.startOfDay(for: now.addingTimeInterval(Double(-daysAgo) * 86_400))
        let sets = (0..<working).map {
            SetRecord(exerciseID: lift.id, load: Load(100), reps: 8, performedAt: date.addingTimeInterval(Double($0)))
        }
        return TrainingDay(date: date, kind: nil, exercises: [PerformedExercise(exercise: lift, sets: sets)])
    }

    private func summary(days: [TrainingDay], weekly: [WeeklyVolumePoint],
                         volume: VolumeReport? = nil, target: Int = 3) -> WeeklySummary {
        WeeklySummary.current(
            days: days, weekly: weekly,
            volume: volume ?? VolumeReport.trailing(history: [], exercises: ExerciseLibrary.all, now: now, calendar: calendar),
            sessionTarget: target, now: now, calendar: calendar
        )
    }

    func testSessionsCountDistinctDaysThisWeekOnly() {
        // Thursday: 0 and 2 days ago are this week, 4 days ago is last week.
        let s = summary(days: [day(0), day(2), day(4), day(0, working: 1)], weekly: [])
        XCTAssertEqual(s.sessions, 2)
        XCTAssertEqual(s.sessionTarget, 3)
        XCTAssertEqual(s.sessionProgress, 2.0 / 3.0, accuracy: 0.001)
    }

    func testAWarmupOnlyDayIsNotASession() {
        let lift = ExerciseLibrary.all[0]
        let date = calendar.startOfDay(for: now)
        let warm = TrainingDay(date: date, kind: nil, exercises: [PerformedExercise(
            exercise: lift,
            sets: [SetRecord(exerciseID: lift.id, load: Load(60), reps: 8, isWarmup: true, performedAt: date)]
        )])
        XCTAssertEqual(summary(days: [warm], weekly: []).sessions, 0)
    }

    func testUsualIsTheMeanOfUpToFourPreviousTrainedWeeks() {
        let weekly = [week(6, total: 100), week(5, total: 0), week(4, total: 40),
                      week(3, total: 50), week(2, total: 60), week(1, total: 50), week(0, total: 30)]
        let s = summary(days: [], weekly: weekly)
        XCTAssertEqual(s.hardSets, 30)
        XCTAssertEqual(s.usualHardSets, 50, "weeks 4..1; the 100 is a fifth trained week back, the 0 is skipped")
        XCTAssertEqual(s.setProgress!, 0.6, accuracy: 0.001)
    }

    func testNoPreviousWeekMeansNoSetsRing() {
        let s = summary(days: [], weekly: [week(1, total: 0), week(0, total: 30)])
        XCTAssertNil(s.usualHardSets)
        XCTAssertNil(s.setProgress)
    }

    func testProgressClampsAtOne() {
        let s = summary(days: [day(0), day(1), day(2)], weekly: [week(1, total: 10), week(0, total: 30)], target: 2)
        XCTAssertEqual(s.sessionProgress, 1)
        XCTAssertEqual(s.setProgress, 1)
        XCTAssertEqual(s.sessions, 3, "the overflow is still reported as a number")
    }

    func testMusclesOnTargetCountsEverythingNotStarved() {
        let report = VolumeReport(muscles: [
            MuscleVolume(muscle: .chest, sets: 12, target: 10...20),
            MuscleVolume(muscle: .lats, sets: 25, target: 10...20),
            MuscleVolume(muscle: .calves, sets: 2, target: 8...16),
        ], from: now, to: now)
        let s = summary(days: [], weekly: [], volume: report)
        XCTAssertEqual(s.musclesOnTarget, 2, "overreaching is not a hole")
        XCTAssertEqual(s.muscleCount, 3)
        XCTAssertEqual(s.muscleProgress, 2.0 / 3.0, accuracy: 0.001)
    }
}
