import XCTest
@testable import WeightTrainingCore

/// Records worth telling someone about (#70).
final class PersonalRecordTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func set(
        _ load: Double, _ reps: Int, rpe: RPE? = RPE(8),
        isWarmup: Bool = false, daysAgo: Double
    ) -> SetRecord {
        SetRecord(
            exerciseID: lift("Flat Bench").id,
            load: Load(load), reps: reps, rpe: rpe, isWarmup: isWarmup,
            performedAt: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    private func kinds(_ records: [PersonalRecord]) -> [PersonalRecord.Kind] {
        records.map(\.kind)
    }

    // MARK: - Refusing to celebrate nothing

    /// A first working set is a starting point, not a record. Same reasoning
    /// that stops readiness scoring without a baseline.
    func testFirstEverSetIsNotARecord() {
        let first = set(135, 5, daysAgo: 0)
        XCTAssertTrue(PersonalRecords.set(by: first, history: [first]).isEmpty)
    }

    /// Warmups can't set records.
    func testWarmupsSetNothing() {
        let history = [set(135, 5, daysAgo: 3)]
        let warmup = set(500, 10, rpe: nil, isWarmup: true, daysAgo: 0)
        XCTAssertTrue(PersonalRecords.set(by: warmup, history: history + [warmup]).isEmpty)
    }

    /// Repeating what you already did is not a record.
    func testMatchingTheBestIsNotBeatingIt() {
        let history = [set(185, 5, daysAgo: 7)]
        let same = set(185, 5, daysAgo: 0)
        XCTAssertTrue(PersonalRecords.set(by: same, history: history + [same]).isEmpty)
    }

    // MARK: - The three kinds

    func testHeaviestEverIsARecord() throws {
        let history = [set(185, 5, daysAgo: 7)]
        let heavier = set(195, 3, daysAgo: 0)

        let records = PersonalRecords.set(by: heavier, history: history + [heavier])
        XCTAssertTrue(records.contains { if case .heaviest(Load(195)) = $0.kind { return true }
                                         return false })
        XCTAssertEqual(records.first?.previous, 185)
    }

    /// The record double progression actually rewards: the programme spends
    /// weeks adding reps at an unchanged load before it adds weight, and
    /// without this those weeks contain no records at all.
    func testMoreRepsAtTheSameWeightIsARecord() throws {
        let history = [set(185, 5, daysAgo: 7)]
        let more = set(185, 7, daysAgo: 0)

        let records = PersonalRecords.set(by: more, history: history + [more])
        XCTAssertTrue(records.contains { if case .reps(7, at: Load(185)) = $0.kind { return true }
                                         return false })
    }

    /// A weight never lifted before makes every rep count trivially a "record",
    /// which would fire on every load increase and mean nothing.
    func testRepsAtANewWeightAreNotARepRecord() {
        let history = [set(185, 5, daysAgo: 7)]
        let newWeight = set(190, 5, daysAgo: 0)

        let records = PersonalRecords.set(by: newWeight, history: history + [newWeight])
        XCTAssertFalse(records.contains { if case .reps = $0.kind { return true }; return false })
    }

    /// A ceiling can rise without touching a heavier bar.
    func testEstimatedMaxCanBeatWithoutMoreWeight() {
        let history = [set(185, 5, rpe: RPE(9), daysAgo: 7)]
        let easier = set(185, 5, rpe: RPE(7), daysAgo: 0)   // same set, more left in the tank

        let records = PersonalRecords.set(by: easier, history: history + [easier])
        XCTAssertTrue(records.contains { if case .estimatedMax = $0.kind { return true }
                                         return false })
    }

    // MARK: - Windows

    func testRecentFindsRecordsInTheWindowOnly() {
        let history = [
            set(135, 5, daysAgo: 30),
            set(185, 5, daysAgo: 20),   // a record, but long ago
            set(195, 5, daysAgo: 2),    // a record, this week
        ]
        let recent = PersonalRecords.recent(in: history,
                                            since: now.addingTimeInterval(-7 * 86_400))
        XCTAssertTrue(recent.allSatisfy { $0.set.performedAt >= now.addingTimeInterval(-7 * 86_400) })
        XCTAssertFalse(recent.isEmpty)
    }

    /// Beating a record twice in a week reports both. The second is still a
    /// record, and hiding it would make the week look flatter than it was.
    func testBeatingARecordTwiceReportsBoth() {
        let history = [
            set(185, 5, daysAgo: 20),
            set(190, 5, daysAgo: 3),
            set(195, 5, daysAgo: 1),
        ]
        let recent = PersonalRecords.recent(in: history,
                                            since: now.addingTimeInterval(-7 * 86_400))
        let heaviest = recent.filter { if case .heaviest = $0.kind { return true }; return false }
        XCTAssertEqual(heaviest.count, 2)
    }

    /// Newest first, so a digest reading the top gets the freshest news.
    func testRecentIsNewestFirst() throws {
        let history = [
            set(185, 5, daysAgo: 20),
            set(190, 5, daysAgo: 3),
            set(195, 5, daysAgo: 1),
        ]
        let recent = PersonalRecords.recent(in: history,
                                            since: now.addingTimeInterval(-7 * 86_400))
        let dates = recent.map(\.set.performedAt)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    /// Records are computed, never stored, so deleting the set that set one
    /// takes the record with it (#61).
    func testDeletingTheSetRemovesTheRecord() {
        let history = [set(185, 5, daysAgo: 7), set(225, 5, daysAgo: 1)]
        let withoutIt = [history[0]]

        XCTAssertFalse(PersonalRecords.recent(in: history,
                                              since: now.addingTimeInterval(-7 * 86_400)).isEmpty)
        XCTAssertTrue(PersonalRecords.recent(in: withoutIt,
                                             since: now.addingTimeInterval(-7 * 86_400)).isEmpty)
    }
}
