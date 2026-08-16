import XCTest
@testable import WeightTrainingCore

/// Reading training back out of what was logged (#63).
final class TrainingHistoryTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_760_000_000)
    private let calendar = Calendar.current

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func set(
        _ name: String, load: Double, reps: Int, isWarmup: Bool = false,
        daysAgo: Int, minute: Double = 0
    ) -> SetRecord {
        SetRecord(
            exerciseID: lift(name).id,
            load: Load(load),
            reps: reps,
            rpe: isWarmup ? nil : RPE(8),
            isWarmup: isWarmup,
            performedAt: base.addingTimeInterval(-Double(daysAgo) * 86_400 + minute * 60)
        )
    }

    private func days(_ history: [SetRecord]) -> [TrainingDay] {
        TrainingHistory.days(history: history, exercises: ExerciseLibrary.all,
                             calendar: calendar)
    }

    func testNoHistoryIsNoDays() {
        XCTAssertTrue(days([]).isEmpty)
    }

    /// Newest first: a history screen opens on what you just did.
    func testDaysAreNewestFirst() {
        let history = [
            set("Flat Bench", load: 185, reps: 5, daysAgo: 4),
            set("Lat Pulldown", load: 120, reps: 10, daysAgo: 1),
        ]
        let result = days(history)
        XCTAssertEqual(result.count, 2)
        XCTAssertGreaterThan(result[0].date, result[1].date)
    }

    /// Lifts appear in the order they were first touched, so reading down the
    /// screen replays the session rather than alphabetising it.
    func testExercisesKeepTheOrderTheyWerePerformedIn() throws {
        let history = [
            set("Lateral Raise", load: 20, reps: 12, daysAgo: 0, minute: 30),
            set("Flat Bench", load: 185, reps: 5, daysAgo: 0, minute: 0),
            set("Flat Bench", load: 185, reps: 5, daysAgo: 0, minute: 5),
            set("Lateral Raise", load: 20, reps: 12, daysAgo: 0, minute: 35),
        ]
        let day = try XCTUnwrap(days(history).first)
        XCTAssertEqual(day.exercises.map(\.exercise.name), ["Flat Bench", "Lateral Raise"])
        XCTAssertEqual(day.exercises[0].sets.count, 2)
    }

    /// Warmups are kept here and dropped everywhere else. This screen answers
    /// "what did I do", and the ramp is part of what you did.
    func testWarmupsAreShownButNotCountedAsWork() throws {
        let history = [
            set("Flat Bench", load: 95, reps: 5, isWarmup: true, daysAgo: 0, minute: 0),
            set("Flat Bench", load: 185, reps: 5, daysAgo: 0, minute: 5),
        ]
        let day = try XCTUnwrap(days(history).first)
        XCTAssertEqual(day.exercises[0].sets.count, 2)
        XCTAssertEqual(day.exercises[0].workingSets.count, 1)
        XCTAssertEqual(day.workingSetCount, 1)
    }

    /// The heaviest working set is what anyone reading a past session looks for
    /// first, and a warmup must never be it.
    func testTopSetIgnoresWarmups() throws {
        let history = [
            set("Flat Bench", load: 225, reps: 1, isWarmup: true, daysAgo: 0, minute: 0),
            set("Flat Bench", load: 185, reps: 5, daysAgo: 0, minute: 5),
            set("Flat Bench", load: 195, reps: 3, daysAgo: 0, minute: 10),
        ]
        let day = try XCTUnwrap(days(history).first)
        XCTAssertEqual(day.exercises[0].topSet?.load, Load(195))
    }

    /// The day is labelled the same way the cycle labels it, so history and the
    /// home screen never disagree about what Tuesday was.
    func testDaysAreLabelledLikeTheCycleLabelsThem() throws {
        let history = [
            set("Flat Bench", load: 185, reps: 5, daysAgo: 0),
            set("Seated DB OHP", load: 50, reps: 8, daysAgo: 0, minute: 20),
        ]
        let day = try XCTUnwrap(days(history).first)
        XCTAssertEqual(day.kind, .push)
    }

    /// A set whose lift no longer exists is dropped rather than shown as a
    /// blank row — a deleted lift shouldn't leave a hole in last month.
    func testSetsForUnknownExercisesAreDropped() {
        let orphan = SetRecord(exerciseID: UUID(), load: Load(100), reps: 5,
                               rpe: RPE(8), performedAt: base)
        XCTAssertTrue(
            TrainingHistory.days(history: [orphan], exercises: ExerciseLibrary.all,
                                 calendar: calendar).isEmpty
        )
    }

    /// Sets logged either side of midnight are different days, because that's
    /// how anyone looking at a calendar would read them.
    func testSetsAreGroupedByCalendarDay() {
        let midnight = calendar.startOfDay(for: base)
        let history = [
            SetRecord(exerciseID: lift("Flat Bench").id, load: Load(185), reps: 5,
                      rpe: RPE(8), performedAt: midnight.addingTimeInterval(-600)),
            SetRecord(exerciseID: lift("Flat Bench").id, load: Load(185), reps: 5,
                      rpe: RPE(8), performedAt: midnight.addingTimeInterval(600)),
        ]
        XCTAssertEqual(days(history).count, 2)
    }
}
