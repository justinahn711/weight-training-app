import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Recording what the lifter weighs (#71).
///
/// A series rather than a number, because the alternative rewrites history: a
/// year of pull-up e1RMs would move every time the scale did.
@MainActor
final class BodyweightTests: XCTestCase {
    private var store: TrainingStore!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    /// Midday `days` ago, for past days.
    ///
    /// Not usable for today: run before noon it returns a time that hasn't
    /// happened yet, and a weigh-in in the future is correctly ignored. That
    /// failed at 00:44 — the same midnight trap as #79, from the other side.
    private func midday(daysAgo: Int) -> Date {
        precondition(daysAgo > 0, "use recently(secondsAgo:) for today")
        return calendar.startOfDay(for: Date())
            .addingTimeInterval(Double(-daysAgo) * 86_400 + 12 * 3_600)
    }

    /// A moment today that has definitely already happened.
    private func recently(secondsAgo: TimeInterval = 1) -> Date {
        Date().addingTimeInterval(-secondsAgo)
    }

    func testNoReadingsMeansNoWeight() throws {
        XCTAssertNil(try store.bodyweight(on: Date()))
    }

    func testAReadingIsStoredAndReadBack() throws {
        try store.record(BodyweightReading(pounds: 175, recordedAt: recently()))
        XCTAssertEqual(try store.bodyweight(on: Date()), 175)
    }

    /// The point of a series: a set performed in March is judged against
    /// March's weight, not today's.
    func testWeightIsWhateverItWasAtTheTime() throws {
        try store.record(BodyweightReading(pounds: 190, recordedAt: midday(daysAgo: 90)))
        try store.record(BodyweightReading(pounds: 175, recordedAt: midday(daysAgo: 1)))

        XCTAssertEqual(try store.bodyweight(on: midday(daysAgo: 60)), 190, "back then")
        XCTAssertEqual(try store.bodyweight(on: Date()), 175, "now")
    }

    /// A weigh-in has no bearing on the days before it.
    func testNothingIsKnownBeforeTheFirstWeighIn() throws {
        try store.record(BodyweightReading(pounds: 175, recordedAt: midday(daysAgo: 5)))
        XCTAssertNil(try store.bodyweight(on: midday(daysAgo: 30)))
    }

    /// A scale stepped on three times in a morning is one measurement. Keeping
    /// all three would weight the series towards whichever day someone fidgeted.
    func testOneReadingPerDay() throws {
        try store.record(BodyweightReading(pounds: 176, recordedAt: recently(secondsAgo: 180)))
        try store.record(BodyweightReading(pounds: 175.4, recordedAt: recently(secondsAgo: 120)))
        try store.record(BodyweightReading(pounds: 175.8, recordedAt: recently(secondsAgo: 60)))

        XCTAssertEqual(try store.bodyweights().count, 1)
        XCTAssertEqual(try store.bodyweight(on: Date()), 175.8, "the last one wins")
    }

    /// Health is read repeatedly — every launch — so importing the same
    /// weigh-in twice must not double the series.
    func testReimportingTheSameDayIsIdempotent() throws {
        let reading = BodyweightReading(pounds: 175, recordedAt: midday(daysAgo: 2))
        try store.record(reading)
        try store.record(reading)
        try store.record(reading)

        XCTAssertEqual(try store.bodyweights().count, 1)
    }

    /// A bodyweight lift stores the total, exactly as a barbell set stores the
    /// bar. The series seeds that number and is never consulted again, so a
    /// past set can't be rewritten by stepping on a scale.
    func testAPastSetIsNotRewrittenByANewWeighIn() throws {
        let pullUps = Exercise(name: "Pull-ups", muscles: [.primary(.lats)],
                               equipment: .bodyweight,
                               progressionRule: .doubleProgression(range: RepRange(5, 10)))
        try store.create(pullUps)
        try store.record(BodyweightReading(pounds: 190, recordedAt: midday(daysAgo: 30)))
        try store.log(SetRecord(exerciseID: pullUps.id, load: Load(190), reps: 6,
                                rpe: RPE(8), performedAt: midday(daysAgo: 30)))

        try store.record(BodyweightReading(pounds: 175, recordedAt: recently()))

        let logged = try XCTUnwrap(store.sets(forExercise: pullUps.id).first)
        XCTAssertEqual(logged.load, Load(190), "what was moved that day, not what he weighs now")
    }
}
