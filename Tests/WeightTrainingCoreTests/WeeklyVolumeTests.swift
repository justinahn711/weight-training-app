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
        XCTAssertTrue(points.allSatisfy { $0.muscleCredit == 0 }, "empty weeks are present at zero")
        XCTAssertTrue(points.allSatisfy { $0.hardSetCount == 0 })
    }

    /// The case #214 names specifically: a compound lift with a primary and a
    /// secondary muscle. Incline DB Press is chest primary, front delts and
    /// triceps secondary, so 4 logged sets are 4 literal hard sets but 8 of
    /// muscle credit (4 chest + 2 front delts + 2 triceps) — the two numbers
    /// are supposed to disagree, and a headline built from the wrong one is
    /// exactly the bug this issue is about.
    func testHardSetCountIsLiteralWhileMuscleCreditIsWeighted() {
        let points = weeks(4, sets("Incline DB Press", count: 4, daysAgo: 1))
        let thisWeek = points.last!
        XCTAssertEqual(thisWeek.hardSetCount, 4, "one logged hard set reads as one")
        XCTAssertEqual(thisWeek.setsByMuscle[.chest], 4)
        XCTAssertEqual(thisWeek.setsByMuscle[.frontDelts], 2)
        XCTAssertEqual(thisWeek.setsByMuscle[.triceps], 2)
        XCTAssertEqual(thisWeek.muscleCredit, 8, "credit is not the headline number")
        XCTAssertEqual(thisWeek.muscleCredit(in: .chest), 4)
        XCTAssertEqual(thisWeek.muscleCredit(in: .arms), 2)
        XCTAssertEqual(thisWeek.muscleCredit(in: .legs), 0)
        XCTAssertEqual(thisWeek.muscleCredit(in: nil), thisWeek.muscleCredit)
        XCTAssertTrue(points.dropLast().allSatisfy { $0.muscleCredit == 0 && $0.hardSetCount == 0 })
    }

    func testLastWeekIsLastWeekNotSevenDaysAgo() {
        // Thursday minus 4 days is the previous week's Sunday.
        let points = weeks(2, sets("Incline DB Press", count: 3, daysAgo: 4))
        XCTAssertEqual(points[0].setsByMuscle[.chest], 3)
        XCTAssertEqual(points[0].hardSetCount, 3)
        XCTAssertEqual(points[1].muscleCredit, 0)
        XCTAssertEqual(points[1].hardSetCount, 0)
    }

    func testWarmupsEasySetsAndTheFutureAreNotVolume() {
        let history = sets("Incline DB Press", count: 3, daysAgo: 1, warmup: true)
            + sets("Incline DB Press", count: 3, daysAgo: 1, rpe: RPE(6))
            + sets("Incline DB Press", count: 3, daysAgo: -1)
        let thisWeek = weeks(2, history).last
        XCTAssertEqual(thisWeek?.muscleCredit, 0)
        XCTAssertEqual(thisWeek?.hardSetCount, 0)
    }

    /// A set whose exercise can't be resolved still happened — the literal
    /// count keeps it, even though it can't contribute muscle credit without
    /// knowing what it trained (#214).
    func testHardSetCountKeepsASetWithAnUnresolvedExercise() {
        let orphan = [SetRecord(exerciseID: UUID(), load: Load(100), reps: 10, rpe: RPE(8),
                                performedAt: now.addingTimeInterval(-86_400))]
        let thisWeek = weeks(2, orphan).last
        XCTAssertEqual(thisWeek?.hardSetCount, 1)
        XCTAssertEqual(thisWeek?.muscleCredit, 0, "no exercise means no muscle to credit")
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
    /// Thursday 9 Oct 2025, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_760_011_200)

    private func week(_ back: Int, hardSets: Int) -> WeeklyVolumePoint {
        let current = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current)!
        return WeeklyVolumePoint(weekStart: start, setsByMuscle: [:], hardSetCount: hardSets)
    }

    /// A `VolumeReport` standing in for "the current trailing window", with a
    /// literal hard-set count under the caller's control. Defaults to the
    /// real trailing-7-day window so `windowDays` reads 7 unless a test needs
    /// otherwise.
    private func volume(hardSetCount: Int = 0, windowDays: Int = VolumeReport.windowDays) -> VolumeReport {
        VolumeReport(
            muscles: [],
            from: calendar.date(byAdding: .day, value: -windowDays, to: now)!,
            to: now,
            hardSetCount: hardSetCount
        )
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
            volume: volume ?? self.volume(),
            sessionTarget: target, now: now, calendar: calendar
        )
    }

    /// Sessions now read the same trailing window as the muscles ring (#214),
    /// not the calendar week: 8 days ago is outside a 7-day window even
    /// though "this week" vs "last week" would have drawn the line elsewhere.
    func testSessionsCountDistinctDaysInTheTrailingWindowOnly() {
        let s = summary(days: [day(0), day(6), day(8), day(0, working: 1)], weekly: [])
        XCTAssertEqual(s.sessions, 2, "0 and 6 days ago are inside 7 days; 8 is not")
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
        let weekly = [week(6, hardSets: 100), week(5, hardSets: 0), week(4, hardSets: 40),
                      week(3, hardSets: 50), week(2, hardSets: 60), week(1, hardSets: 50)]
        let s = summary(days: [], weekly: weekly, volume: volume(hardSetCount: 30))
        XCTAssertEqual(s.hardSets, 30)
        XCTAssertEqual(s.usualHardSets, 50, "weeks 4..1; the 100 is a fifth trained week back, the 0 is skipped")
        XCTAssertEqual(s.setProgress!, 0.6, accuracy: 0.001)
    }

    func testNoPreviousWeekMeansNoSetsRing() {
        let s = summary(days: [], weekly: [week(1, hardSets: 0)])
        XCTAssertNil(s.usualHardSets)
        XCTAssertNil(s.setProgress)
    }

    func testProgressClampsAtOne() {
        let s = summary(days: [day(0), day(1), day(2)], weekly: [week(1, hardSets: 10)],
                        volume: volume(hardSetCount: 30), target: 2)
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

    func testWindowDaysMatchesTheVolumeReportItWasBuiltFrom() {
        let s = summary(days: [], weekly: [], volume: volume(windowDays: 7))
        XCTAssertEqual(s.windowDays, 7, "the label on the card must say what the rings actually measured")
    }

    /// #214's headline case at the summary level: a compound lift with a
    /// primary and a secondary muscle must still read as its literal set
    /// count on the ring, never the muscle-credited total.
    func testHardSetsIsLiteralForACompoundLiftEvenThoughItsCreditIsHigher() {
        let lift = ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
        let compoundSets = (0..<4).map { index in
            SetRecord(exerciseID: lift.id, load: Load(100), reps: 10, rpe: RPE(8),
                      performedAt: now.addingTimeInterval(-86_400 + Double(index) * 300))
        }
        let report = VolumeReport.trailing(history: compoundSets, exercises: ExerciseLibrary.all,
                                           now: now, calendar: calendar)
        XCTAssertEqual(report.hardSetCount, 4)
        XCTAssertEqual(report.muscles.reduce(0) { $0 + $1.sets }, 8, "chest 4 + front delts 2 + triceps 2")

        let s = summary(days: [], weekly: [], volume: report)
        XCTAssertEqual(s.hardSets, 4, "the headline is the literal count, not the credited one")
    }
}
