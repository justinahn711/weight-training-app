import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Selecting sets across a bad import or an accidental day and deleting them
/// in one action, rather than opening and deleting every row from #61's
/// editor (#168).
@MainActor
final class BatchDeleteTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private var bench: Exercise {
        ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
    }

    private var chestFly: Exercise {
        ExerciseLibrary.all.first { $0.name == "Chest Fly" }!
    }

    private func logged(_ exercise: Exercise, _ pounds: Double, _ reps: Int,
                        rpe: RPE? = nil, daysAgo: Double) throws -> SetRecord {
        let record = SetRecord(
            exerciseID: exercise.id, load: Load(pounds), reps: reps, rpe: rpe,
            performedAt: Date().addingTimeInterval(-daysAgo * 86_400)
        )
        try store.log(record)
        return record
    }

    // MARK: - The batch itself

    /// The case #168 is named for: a whole erroneous day, gone in one call
    /// rather than N trips through the single-set editor.
    func testDeletesEverySelectedSetAcrossExercises() throws {
        let keptSet = try logged(bench, 185, 5, daysAgo: 10)
        let badBench = try logged(bench, 999, 1, daysAgo: 0)
        let badFly = try logged(chestFly, 999, 1, daysAgo: 0)

        let removed = try store.deleteSets(ids: [badBench.id, badFly.id])

        XCTAssertEqual(removed, [badBench.id, badFly.id])
        let remaining = try store.allSets()
        XCTAssertEqual(remaining, [keptSet])
    }

    /// Ids that don't match anything are skipped, not failed — the same
    /// idempotence the write side gets from `logIfAbsent`, needed here so a
    /// retried delete after a sync merge can't error out.
    func testUnknownIDsAreSkippedNotFailed() throws {
        let real = try logged(bench, 185, 5, daysAgo: 0)
        let unknown = UUID()

        let removed = try store.deleteSets(ids: [real.id, unknown])

        XCTAssertEqual(removed, [real.id])
        XCTAssertTrue(try store.allSets().isEmpty)
    }

    /// Replaying the same ids a second time — a retried request, or a stale
    /// selection resubmitted — must not throw and must not touch anything.
    func testDeletingTheSameSelectionTwiceIsANoOpTheSecondTime() throws {
        let set = try logged(bench, 185, 5, daysAgo: 0)

        XCTAssertEqual(try store.deleteSets(ids: [set.id]), [set.id])
        XCTAssertEqual(try store.deleteSets(ids: [set.id]), [])
    }

    func testEmptySelectionDoesNothing() throws {
        _ = try logged(bench, 185, 5, daysAgo: 0)
        XCTAssertEqual(try store.deleteSets(ids: []), [])
        XCTAssertEqual(try store.allSets().count, 1)
    }

    /// A crash or a kill between the deletes and the progress-state
    /// correction would be exactly the partial state #168 rules out — proven
    /// here by checking a second, independently-opened store sees both sides
    /// of the batch landed together.
    func testBatchIsOneTransactionThatSurvivesAReopen() throws {
        let url = URL.temporaryDirectory.appending(path: "batch-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
            }
        }

        let first = try TrainingStore(url: url)
        try first.seedLibraryIfNeeded()
        let flyExercise = try XCTUnwrap(try first.exercises().first { $0.name == "Chest Fly" })

        let earlySet = SetRecord(exerciseID: flyExercise.id, load: Load(50), reps: 15,
                                 performedAt: Date().addingTimeInterval(-2 * 86_400))
        let lateSet = SetRecord(exerciseID: flyExercise.id, load: Load(50), reps: 15,
                                performedAt: Date())
        try first.log(earlySet)
        try first.log(lateSet)
        // The state both sessions earned, as `applyProgression` would have
        // stored it — the batch only rewrites state the replay authored (#269).
        var earned = ProgressState(exerciseID: flyExercise.id)
        for set in [earlySet, lateSet] {
            earned = ProgressionEngine.advance(
                exercise: flyExercise, state: earned, performed: [set], now: set.performedAt
            ).state
        }
        try first.save(earned)
        _ = try first.deleteSets(ids: [lateSet.id])

        let second = try TrainingStore(url: url)
        XCTAssertEqual(try second.allSets(), [earlySet], "the delete itself committed")
        let state = try XCTUnwrap(second.progressState(forExercise: flyExercise.id))
        // One top-range hit banked, one short of the two required to earn the
        // load jump — the state after the surviving session alone, which is
        // only correct if the recompute committed in the same save.
        XCTAssertEqual(state.consecutiveTopHits, 1)
    }

    // MARK: - Progress state (the issue's "data decision required")

    /// Deleting the session that earned a load jump must not leave the jump
    /// standing on nothing. `ProgressState` is a cumulative snapshot, not a
    /// live read of history the way the digest and e1RM trends are, so the
    /// store has to replay what remains.
    func testDeletingTheEarningSessionRevertsTheProgressState() throws {
        // Chest Fly: doubleProgression(10...15), 2 consecutive top hits to
        // earn a load jump.
        let session1 = try logged(chestFly, 50, 15, daysAgo: 2)
        let session2 = try logged(chestFly, 50, 15, daysAgo: 0)

        // Replay both sessions the way `applyProgression` would, to know what
        // state should exist before the delete.
        var expectedAfterBoth = ProgressState(exerciseID: chestFly.id)
        expectedAfterBoth = ProgressionEngine.advance(
            exercise: chestFly, state: expectedAfterBoth, performed: [session1],
            now: session1.performedAt
        ).state
        expectedAfterBoth = ProgressionEngine.advance(
            exercise: chestFly, state: expectedAfterBoth, performed: [session2],
            now: session2.performedAt
        ).state
        try store.save(expectedAfterBoth)
        XCTAssertEqual(expectedAfterBoth.consecutiveTopHits, 0, "banked: the load jump fired")

        _ = try store.deleteSets(ids: [session2.id])

        let expectedAfterOnly1 = ProgressionEngine.advance(
            exercise: chestFly, state: ProgressState(exerciseID: chestFly.id),
            performed: [session1], now: session1.performedAt
        ).state

        let reloaded = try XCTUnwrap(store.progressState(forExercise: chestFly.id))
        XCTAssertEqual(reloaded, expectedAfterOnly1)
        XCTAssertEqual(reloaded.consecutiveTopHits, 1, "back to one earned hit, not zero")
    }

    /// Deleting every set an exercise has ever logged has to return it all
    /// the way to cold start — not just to some intermediate snapshot — or
    /// the session screen would show a target for a lift with no history.
    func testDeletingAllHistoryClearsProgressStateEntirely() throws {
        // A stale row predating the delete, to prove it's actually removed
        // rather than left however it happened to already be.
        try store.save(ProgressState(exerciseID: bench.id, targetLoad: Load(999), stallCount: 7))

        let onlySet = try logged(bench, 185, 5, rpe: RPE(8), daysAgo: 0)
        _ = try store.deleteSets(ids: [onlySet.id])

        XCTAssertNil(try store.progressState(forExercise: bench.id))
    }

    /// The recompute is scoped to exercises the batch actually touched —
    /// deleting one lift's sets must not disturb another's earned state.
    func testUnaffectedExerciseProgressStateIsUntouched() throws {
        let flySet = try logged(chestFly, 50, 15, daysAgo: 0)
        _ = try logged(bench, 185, 5, rpe: RPE(8), daysAgo: 0)

        let benchState = ProgressState(exerciseID: bench.id, targetLoad: Load(185),
                                       stallCount: 2, lastPerformedAt: Date())
        try store.save(benchState)

        _ = try store.deleteSets(ids: [flySet.id])

        let reloadedBench = try XCTUnwrap(store.progressState(forExercise: bench.id))
        XCTAssertEqual(reloadedBench.stallCount, 2, "untouched by a batch that never named this exercise")
    }

    /// A lift deleted from the library (#76) can still have orphaned sets and
    /// a progress row; a batch that happens to remove its sets shouldn't trip
    /// over the missing exercise definition it needs to replay progression.
    func testDeletingSetsForARemovedExerciseDoesNotThrow() throws {
        let custom = Exercise(id: UUID(), name: "Home Cable Row", muscles: [.primary(.lats)],
                              equipment: .cable, progressionRule: .doubleProgression(range: RepRange(8, 12)))
        try store.create(custom)
        let set = try logged(custom, 80, 10, daysAgo: 0)
        try store.deleteExercise(id: custom.id)

        XCTAssertNoThrow(try store.deleteSets(ids: [set.id]))
        XCTAssertTrue(try store.allSets().isEmpty)
    }

    // MARK: - State the replay can't author (#269)

    /// Midday anchors, never `Date()` with offsets: sets are grouped by
    /// calendar day, and a fixture near midnight splits a session (#79).
    private func midday(_ dayOffset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 10 + dayOffset; components.hour = 12
        return Calendar.current.date(from: components)!
    }

    /// Four push days of Flat Bench — one warmup and three working sets at
    /// 185x4 @9 each — each finished through the live path
    /// (`applyProgression(now: startedAt)`), exactly as `SessionViewModel`
    /// finishes a session. Returns every set, by day.
    private func fourBenchDaysThroughTheLivePath() throws -> [(warmup: SetRecord, working: [SetRecord])] {
        var days: [(warmup: SetRecord, working: [SetRecord])] = []
        for day in 0..<4 {
            let warmup = SetRecord(exerciseID: bench.id, load: Load(95), reps: 5, isWarmup: true,
                                   performedAt: midday(day))
            try store.log(warmup)
            var working: [SetRecord] = []
            for index in 0..<3 {
                let set = SetRecord(exerciseID: bench.id, load: Load(185), reps: 4, rpe: RPE(9)!,
                                    performedAt: midday(day).addingTimeInterval(Double(120 + index * 60)))
                try store.log(set)
                working.append(set)
            }
            let session = try store.startSession(kind: .push, startedAt: midday(day).addingTimeInterval(600))
            try store.applyProgression(for: session, now: session.startedAt)
            days.append((warmup, working))
        }
        return days
    }

    /// What the lifter gets by tapping the digest's deload bullet —
    /// `DigestView.apply`, verbatim.
    private func applyDigestDeload(to pounds: Double) throws -> ProgressState {
        var state = try XCTUnwrap(store.progressState(forExercise: bench.id))
        state.targetLoad = Load(pounds)
        state.stallCount = 0
        state.consecutiveTopHits = 0
        try store.save(state)
        return state
    }

    /// The auditor's case: a digest deload took the target from 180 to 165,
    /// then one warmup from an old day was removed — and the target went
    /// back to 180, the weight the lifter had just been told to back off
    /// from. No progression decision ever reads a warmup, so deleting one
    /// has nothing to correct.
    func testDeletingAWarmupLeavesAnAppliedDeloadAlone() throws {
        let days = try fourBenchDaysThroughTheLivePath()
        let deload = try applyDigestDeload(to: 165)

        _ = try store.deleteSets(ids: [days[0].warmup.id])

        XCTAssertEqual(try store.progressState(forExercise: bench.id), deload)
    }

    /// Warmups never drive progression, so deleting only warmups leaves the
    /// stored state exactly as it was — `lastPerformedAt` included, which the
    /// cold-start replay used to move to the last set's time.
    func testDeletingOnlyWarmupsNeverChangesProgressState() throws {
        let days = try fourBenchDaysThroughTheLivePath()
        let before = try XCTUnwrap(store.progressState(forExercise: bench.id))

        _ = try store.deleteSets(ids: Set(days.map(\.warmup.id)))

        XCTAssertEqual(try store.progressState(forExercise: bench.id), before)
    }

    /// A day older than the lift's latest session didn't produce the current
    /// target — the sessions after it did. Removing a working set from it
    /// (an old accidental entry) leaves the applied deload standing.
    func testDeletingAWorkingSetFromAnOlderDayLeavesAnAppliedDeloadAlone() throws {
        let days = try fourBenchDaysThroughTheLivePath()
        let deload = try applyDigestDeload(to: 165)

        _ = try store.deleteSets(ids: [days[0].working[0].id])

        XCTAssertEqual(try store.progressState(forExercise: bench.id), deload)
    }

    /// Even the latest session's sets can't undo a deload: the deload is a
    /// decision the lifter made *after* that session, and a replay of the
    /// sets has no way to reconstruct it. The store only rewrites state the
    /// replay itself would have produced.
    func testDeletingAWorkingSetFromTheLatestDayLeavesAnAppliedDeloadAlone() throws {
        let days = try fourBenchDaysThroughTheLivePath()
        let deload = try applyDigestDeload(to: 165)

        _ = try store.deleteSets(ids: [days[3].working[2].id])

        XCTAssertEqual(try store.progressState(forExercise: bench.id), deload)
    }

    /// The original purpose (#168) still holds through the live path, not
    /// just a hand-replayed fixture: deleting the whole latest session backs
    /// the state out to what the three earlier sessions earned, and
    /// `lastPerformedAt` lands on the day that is now the latest.
    func testDeletingTheLatestSessionThroughTheLivePathRevertsIt() throws {
        let days = try fourBenchDaysThroughTheLivePath()
        let afterFour = try XCTUnwrap(store.progressState(forExercise: bench.id))

        _ = try store.deleteSets(ids: Set(days[3].working.map(\.id) + [days[3].warmup.id]))

        let reverted = try XCTUnwrap(store.progressState(forExercise: bench.id))
        XCTAssertNotEqual(reverted, afterFour, "the fourth session's step is undone")
        var expected = ProgressState(exerciseID: bench.id)
        for day in days.prefix(3) {
            expected = ProgressionEngine.advance(
                exercise: bench, state: expected, performed: day.working, now: day.working.last!.performedAt
            ).state
        }
        XCTAssertEqual(reverted.targetLoad, expected.targetLoad)
        XCTAssertEqual(reverted.stallCount, expected.stallCount)
        XCTAssertEqual(reverted.consecutiveTopHits, expected.consecutiveTopHits)
        XCTAssertTrue(Calendar.current.isDate(try XCTUnwrap(reverted.lastPerformedAt), inSameDayAs: midday(2)))
    }
}
