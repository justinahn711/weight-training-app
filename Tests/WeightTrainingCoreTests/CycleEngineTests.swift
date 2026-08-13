import XCTest
@testable import WeightTrainingCore

final class DayTemplateLibraryTests: XCTestCase {

    /// Every slot must resolve to a seeded lift, or a day opens with a hole
    /// in it.
    func testEverySlotResolvesToASeededExercise() {
        let known = Set(ExerciseLibrary.all.map(\.id))
        for template in DayTemplateLibrary.all {
            XCTAssertFalse(template.slots.isEmpty, "\(template.kind) has no slots")
            for slot in template.slots {
                XCTAssertFalse(slot.candidateExerciseIDs.isEmpty,
                               "\(template.kind)/\(slot.name) has no candidates")
                for candidate in slot.candidateExerciseIDs {
                    XCTAssertTrue(known.contains(candidate),
                                  "\(template.kind)/\(slot.name) names an unknown lift")
                }
            }
        }
    }

    /// The shapes named in #16.
    func testDayShapes() {
        XCTAssertEqual(DayTemplateLibrary.push.slots.count, 6, "5 fixed + 1 rotating")
        XCTAssertEqual(DayTemplateLibrary.pull.slots.count, 6)
        XCTAssertEqual(DayTemplateLibrary.legs.slots.count, 5)
    }

    func testOnlyPushRotates() {
        XCTAssertEqual(DayTemplateLibrary.push.slots.filter(\.rotates).count, 1)
        XCTAssertTrue(DayTemplateLibrary.pull.slots.allSatisfy { !$0.rotates })
        XCTAssertTrue(DayTemplateLibrary.legs.slots.allSatisfy { !$0.rotates })
    }

    /// Chest fly and skull crushers alternate across push days.
    func testTheRotatingPairAlternates() throws {
        let slot = try XCTUnwrap(DayTemplateLibrary.push.slots.first(where: \.rotates))
        let fly = ExerciseLibrary.all.first { $0.name == "Chest Fly" }!.id
        let skulls = ExerciseLibrary.all.first { $0.name == "Skull Crushers" }!.id

        XCTAssertEqual(slot.dueCandidate(completionCount: 0), fly)
        XCTAssertEqual(slot.dueCandidate(completionCount: 1), skulls)
        XCTAssertEqual(slot.dueCandidate(completionCount: 2), fly)
        XCTAssertEqual(slot.dueCandidate(completionCount: 3), skulls)
    }

    /// Reverse fly exists because #2 split the library's "face pull/reverse
    /// fly" entry; this is the slot that reconciles it with #16's six pull
    /// slots.
    func testRearDeltSlotOffersBothMovements() throws {
        let slot = try XCTUnwrap(
            DayTemplateLibrary.pull.slots.first { $0.name == "Rear delts" }
        )
        let names = slot.candidateExerciseIDs.compactMap { id in
            ExerciseLibrary.all.first { $0.id == id }?.name
        }
        XCTAssertEqual(names, ["Face Pull", "Reverse Fly"])
        XCTAssertFalse(slot.rotates, "alternatives to choose from, not a rotation")
    }

    func testTemplateAndSlotIdsAreUnique() {
        let templateIDs = DayTemplateLibrary.all.map(\.id)
        XCTAssertEqual(Set(templateIDs).count, templateIDs.count)

        let slotIDs = DayTemplateLibrary.all.flatMap { $0.slots.map(\.id) }
        XCTAssertEqual(Set(slotIDs).count, slotIDs.count)
    }

    /// Every seeded lift should have a home, or it can never be trained.
    func testEverySeededLiftAppearsInADay() {
        let placed = Set(DayTemplateLibrary.all.flatMap { $0.slots.flatMap(\.candidateExerciseIDs) })
        for exercise in ExerciseLibrary.all {
            XCTAssertTrue(placed.contains(exercise.id), "\(exercise.name) is in no day")
        }
    }
}

final class CycleEngineTests: XCTestCase {
    private let day0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    /// One session of a given day, `daysAgo` back.
    private func session(_ kind: DayKind, daysAgo: Double) -> [SetRecord] {
        let names: [String]
        switch kind {
        case .push: names = ["Incline DB Press", "Flat Bench", "Lateral Raise"]
        case .pull: names = ["Chest-Supported T-Bar Row", "Lat Pulldown", "Shrugs"]
        case .legs: names = ["Hack Squat", "RDL", "Leg Curl"]
        }
        return names.enumerated().map { index, name in
            SetRecord(
                exerciseID: lift(name).id, load: Load(100), reps: 8, rpe: RPE(8),
                performedAt: day0.addingTimeInterval(-daysAgo * 86_400 + Double(index) * 600)
            )
        }
    }

    // MARK: - Classification

    func testASessionIsLabelledByWhatWasTrained() {
        XCTAssertEqual(CycleEngine.classify(session: session(.push, daysAgo: 0)), .push)
        XCTAssertEqual(CycleEngine.classify(session: session(.pull, daysAgo: 0)), .pull)
        XCTAssertEqual(CycleEngine.classify(session: session(.legs, daysAgo: 0)), .legs)
    }

    /// A half-finished day still counts as that day.
    func testOneLiftIsEnoughToLabelASession() {
        let single = [SetRecord(exerciseID: lift("Hack Squat").id, load: Load(200),
                                reps: 8, rpe: RPE(8), performedAt: day0)]
        XCTAssertEqual(CycleEngine.classify(session: single), .legs)
    }

    /// A day that borrowed one lift from elsewhere is still mostly itself.
    func testMajorityWins() {
        let mixed = session(.pull, daysAgo: 0) + [
            SetRecord(exerciseID: lift("Lateral Raise").id, load: Load(20), reps: 15,
                      rpe: RPE(8), performedAt: day0.addingTimeInterval(3_000))
        ]
        XCTAssertEqual(CycleEngine.classify(session: mixed), .pull)
    }

    func testWarmupsDoNotDecideTheLabel() {
        let warmupOnly = [SetRecord(exerciseID: lift("Hack Squat").id, load: Load(45),
                                    reps: 5, isWarmup: true, performedAt: day0)]
        XCTAssertNil(CycleEngine.classify(session: warmupOnly))
    }

    func testAnEmptySessionHasNoLabel() {
        XCTAssertNil(CycleEngine.classify(session: []))
    }

    // MARK: - Next day

    func testAFreshInstallStartsAtPush() {
        let position = CycleEngine.position(history: [])
        XCTAssertEqual(position.next, .push)
        XCTAssertTrue(position.lastPerformed.isEmpty)
        XCTAssertEqual(position.summary(now: day0), "Next: Push — first time")
    }

    func testNextFollowsTheLastDayTrained() {
        XCTAssertEqual(CycleEngine.position(history: session(.push, daysAgo: 1)).next, .pull)
        XCTAssertEqual(CycleEngine.position(history: session(.pull, daysAgo: 1)).next, .legs)
        XCTAssertEqual(CycleEngine.position(history: session(.legs, daysAgo: 1)).next, .push)
    }

    /// #17's done-when: correct across an irregular three-week history. Gaps of
    /// one, two, and four days, and a week off entirely.
    func testIrregularThreeWeekHistory() {
        let schedule: [(DayKind, Double)] = [
            (.push, 20), (.pull, 18), (.legs, 15),   // 2, 3 day gaps
            (.push, 14), (.pull, 12), (.legs, 11),   // 1 day gap
            (.push, 9),                              // then a week off
            (.pull, 2),
        ]
        let history = schedule.flatMap { session($0.0, daysAgo: $0.1) }
        let position = CycleEngine.position(history: history)

        XCTAssertEqual(position.next, .legs, "pull was last, so legs is next")
        XCTAssertEqual(position.daysSince(.legs, now: day0), 11)
        XCTAssertEqual(position.daysSince(.pull, now: day0), 2)
        XCTAssertEqual(position.summary(now: day0),
                       "Next: Legs — last legs was 11 days ago")
    }

    /// A long layoff doesn't skip anything: you come back to the day you hadn't
    /// done, not to whatever the calendar suggests.
    func testALayoffDoesNotSkipADay() {
        let history = session(.push, daysAgo: 30)
        let position = CycleEngine.position(history: history)
        XCTAssertEqual(position.next, .pull)
        XCTAssertEqual(position.summary(now: day0), "Next: Pull — first time")
    }

    func testSessionsLoggedOutOfOrderStillResolve() {
        let history = session(.pull, daysAgo: 2) + session(.push, daysAgo: 5)
        XCTAssertEqual(CycleEngine.position(history: history).next, .legs)
    }

    // MARK: - Summary wording

    func testSummaryReadsNaturallyForRecentDays() {
        let today = CycleEngine.position(history: session(.legs, daysAgo: 3)
                                         + session(.push, daysAgo: 0))
        XCTAssertEqual(today.summary(now: day0), "Next: Pull — first time")

        let yesterday = CycleEngine.position(
            history: session(.pull, daysAgo: 4) + session(.legs, daysAgo: 1)
        )
        XCTAssertEqual(yesterday.summary(now: day0), "Next: Push — first time")

        let repeated = CycleEngine.position(
            history: session(.push, daysAgo: 1) + session(.legs, daysAgo: 0)
        )
        XCTAssertEqual(repeated.summary(now: day0), "Next: Push — last push was yesterday")
    }

    /// No weekday may appear anywhere the app speaks.
    func testNoWeekdayEverAppears() {
        let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday",
                        "Friday", "Saturday", "Sunday", "week"]
        let history = session(.push, daysAgo: 6)
        let summary = CycleEngine.position(history: history).summary(now: day0)
        for weekday in weekdays {
            XCTAssertFalse(summary.localizedCaseInsensitiveContains(weekday), summary)
        }
    }

    // MARK: - Completed counts drive rotation

    func testCompletedSessionsCountPerDay() {
        let history = session(.push, daysAgo: 9) + session(.pull, daysAgo: 7)
            + session(.push, daysAgo: 5) + session(.legs, daysAgo: 3)
            + session(.push, daysAgo: 1)
        XCTAssertEqual(CycleEngine.completedSessions(of: .push, history: history), 3)
        XCTAssertEqual(CycleEngine.completedSessions(of: .pull, history: history), 1)
        XCTAssertEqual(CycleEngine.completedSessions(of: .legs, history: history), 1)
    }

    func testSetsOnTheSameDayAreOneSession() {
        let history = session(.push, daysAgo: 1)
        XCTAssertEqual(CycleEngine.completedSessions(of: .push, history: history), 1)
    }
}
