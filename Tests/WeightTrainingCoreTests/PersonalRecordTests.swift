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

    // MARK: - Earlier today counts (#213)
    //
    // The banner used to compare a set only with previous *days*, so after a
    // new best of 200 a backoff set of 180 still beat last week's 170 and got
    // celebrated. Every fixture here is anchored to midday and moved by whole
    // days or by minutes within one, because the day is the session boundary
    // and a fixture built near midnight splits one session into two (#79).

    /// Local midday on a fixed date. Nothing here may drift onto another
    /// calendar day, whatever hour the suite happens to run at.
    private var midday: Date {
        Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_760_000_000)
        )!
    }

    /// A set today, `minutes` into the session.
    private func todaySet(_ load: Double, _ reps: Int = 5, minutes: Double) -> SetRecord {
        SetRecord(
            exerciseID: lift("Flat Bench").id,
            load: Load(load), reps: reps, rpe: RPE(8), isWarmup: false,
            performedAt: midday.addingTimeInterval(minutes * 60)
        )
    }

    /// A set on an earlier day, at the same hour, so it can never land on
    /// today by accident.
    private func earlierDaySet(_ load: Double, _ reps: Int = 5, daysAgo: Int) -> SetRecord {
        SetRecord(
            exerciseID: lift("Flat Bench").id,
            load: Load(load), reps: reps, rpe: RPE(8), isWarmup: false,
            performedAt: midday.addingTimeInterval(Double(-daysAgo) * 86_400)
        )
    }

    /// The first thing today that beats everything before it is a record.
    func testTheFirstNewBestTodayIsARecord() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)

        let records = PersonalRecords.set(by: best, history: [past, best])
        XCTAssertTrue(records.contains { if case .heaviest(Load(200)) = $0.kind { return true }
                                         return false })
    }

    /// #213 exactly: 170 last week, 200 today, then a backoff 180. The 180
    /// beat last week and lost to an hour ago, and only the second of those
    /// is the question worth asking.
    func testALowerSetLaterTheSameDayIsNotARecord() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)
        let backoff = todaySet(180, minutes: 20)

        XCTAssertTrue(
            PersonalRecords.set(by: backoff, history: [past, best, backoff]).isEmpty,
            "a set that lost to earlier today has not set anything"
        )
    }

    /// The other half: a set that genuinely improves on today's best is
    /// still a record, and celebrating it twice in one session is correct —
    /// they were two different bests.
    func testAGenuineImprovementLaterTheSameDayIsARecord() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)
        let better = todaySet(210, minutes: 20)

        let records = PersonalRecords.set(by: better, history: [past, best, better])
        XCTAssertTrue(records.contains { if case .heaviest(Load(210)) = $0.kind { return true }
                                         return false })
        XCTAssertEqual(records.first?.previous, 200, "it beat today's 200, not last week's 170")
    }

    /// The reason the old code excluded today in the first place, kept: a
    /// lift with nothing before today is being felt out, and a ramp of three
    /// climbing sets is one session, not three records.
    func testFeelingOutANewLiftAcrossThreeSetsSetsNothing() {
        let sets = [
            todaySet(95, minutes: 0),
            todaySet(135, minutes: 5),
            todaySet(185, minutes: 12),
        ]
        for candidate in sets {
            XCTAssertTrue(
                PersonalRecords.set(by: candidate, history: sets).isEmpty,
                "a lift's first session is a starting point, not a record"
            )
        }
    }

    /// And once the lift has a previous day, the same session's later sets
    /// are judged normally again — the rule is about the first session, not
    /// about today being special.
    func testASecondSessionJudgesItsOwnSetsAgainstEachOther() {
        let firstSession = [
            earlierDaySet(95, daysAgo: 3),
            earlierDaySet(135, daysAgo: 3),
        ]
        let opener = todaySet(140, minutes: 0)
        let better = todaySet(145, minutes: 10)
        let backoff = todaySet(142, minutes: 20)
        let history = firstSession + [opener, better, backoff]

        XCTAssertFalse(PersonalRecords.set(by: opener, history: history).isEmpty)
        XCTAssertFalse(PersonalRecords.set(by: better, history: history).isEmpty)
        XCTAssertTrue(PersonalRecords.set(by: backoff, history: history).isEmpty)
    }

    // MARK: - Corrections move records (#213)

    /// Deleting today's best doesn't only take its own badge away: the set
    /// logged after it, silent at the time because it lost, is now the day's
    /// best and has earned one. This is what the session's badges recompute
    /// against, rather than filtering the deleted id out of a stored set.
    func testDeletingTodaysBestPromotesTheSetThatFollowedIt() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)
        let backoff = todaySet(180, minutes: 20)

        XCTAssertTrue(PersonalRecords.set(by: backoff, history: [past, best, backoff]).isEmpty)
        XCTAssertFalse(
            PersonalRecords.set(by: backoff, history: [past, backoff]).isEmpty,
            "with the 200 gone the 180 is the day's best and beats last week"
        )
    }

    /// The same promotion via a correction rather than a delete — the row
    /// stays, its numbers change, and both badges move.
    func testCorrectingTodaysBestDownwardMovesTheBadge() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)
        let follower = todaySet(180, minutes: 20)
        let corrected = SetRecord(
            id: best.id, exerciseID: best.exerciseID,
            load: Load(160), reps: best.reps, rpe: best.rpe,
            isWarmup: false, performedAt: best.performedAt
        )
        let history = [past, corrected, follower]

        XCTAssertTrue(PersonalRecords.set(by: corrected, history: history).isEmpty,
                      "160 beats nothing")
        XCTAssertFalse(PersonalRecords.set(by: follower, history: history).isEmpty,
                       "the 180 inherits the day")
    }

    // MARK: - One definition everywhere (#213)

    /// The finish sheet reads `recent`, the banner reads `set`. They are the
    /// same rule, and a set the banner refused must not reappear on the
    /// sheet twenty minutes later.
    func testTheSessionWindowAgreesWithThePerSetJudgement() {
        let past = earlierDaySet(170, daysAgo: 7)
        let best = todaySet(200, minutes: 0)
        let backoff = todaySet(180, minutes: 20)
        let history = [past, best, backoff]
        let startOfToday = Calendar.current.startOfDay(for: midday)

        let today = PersonalRecords.recent(in: history, since: startOfToday)
        XCTAssertEqual(today.map(\.set.id).filter { $0 == best.id }.isEmpty, false)
        XCTAssertTrue(today.allSatisfy { $0.set.id != backoff.id },
                      "the sheet cannot celebrate what the banner refused")
    }

    /// And the trend chart's marks, which work a session at a time: a day
    /// whose ceiling never beat an earlier day is not a mark, and a lift's
    /// first day is never one — the same two refusals `set` makes.
    func testTrendMarksAgreeWithTheRecordDefinition() {
        let bench = lift("Flat Bench")
        let history = [
            earlierDaySet(170, daysAgo: 7),
            todaySet(200, minutes: 0),
            todaySet(180, minutes: 20),
        ]
        let trend = E1RMTrendBuilder.trends(history: history, exercises: [bench]).first!

        XCTAssertEqual(trend.points.count, 2, "one point per session")
        XCTAssertEqual(trend.recordPoints.map(\.topSet.id), [history[1].id],
                       "the day is marked by the set that set the record, not the backoff")

        let firstDayOnly = [todaySet(200, minutes: 0), todaySet(210, minutes: 20)]
        let newLift = E1RMTrendBuilder.trends(history: firstDayOnly, exercises: [bench]).first!
        XCTAssertTrue(newLift.recordPoints.isEmpty, "a first session marks nothing")
        XCTAssertTrue(firstDayOnly.allSatisfy {
            PersonalRecords.set(by: $0, history: firstDayOnly).isEmpty
        }, "and sets nothing")
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
