import XCTest
import SwiftData
import WeightTrainingCore
@testable import WeightTrainingStore

/// A backup is only worth having if it comes back (#87, #88).
///
/// Dates here are anchored to a fixed midday rather than built from `Date()`,
/// because the store groups sets by calendar day and a fixture near midnight
/// straddles two of them (#79).
@MainActor
final class ArchiveTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private var incline: Exercise {
        ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
    }

    private var squat: Exercise {
        ExerciseLibrary.all.first { $0.equipment == .barbell }!
    }

    private func midday(_ dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10 + dayOffset
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// A small but complete history: two lifts, working sets and a warmup,
    /// progression state, a template and a weigh-in.
    @discardableResult
    private func seedHistory() throws -> Exercise {
        let lift = incline
        try store.upsert(lift)
        try store.upsert(squat)

        try store.log(SetRecord(
            exerciseID: lift.id, load: Load(45), reps: 10,
            isWarmup: true, performedAt: midday()
        ))
        try store.log(SetRecord(
            exerciseID: lift.id, load: Load(70), reps: 8,
            rpe: RPE(8)!, performedAt: midday().addingTimeInterval(120)
        ))
        try store.log(SetRecord(
            exerciseID: squat.id, load: Load(225), reps: 5,
            rpe: RPE(9)!, performedAt: midday(1)
        ))

        try store.save(ProgressState(
            exerciseID: lift.id,
            targetLoad: Load(75), targetReps: 8, targetRPE: RPE(8)!,
            lastPerformedAt: midday()
        ))
        try store.record(BodyweightReading(pounds: 178.4, recordedAt: midday()))
        return lift
    }

    // MARK: - Export (#87)

    func testArchiveContainsEveryLoggedSet() throws {
        try seedHistory()

        let archive = try store.archive()

        XCTAssertEqual(archive.sets.count, 3, "every set, warmups included")
        XCTAssertEqual(archive.version, TrainingArchive.currentVersion)
        XCTAssertFalse(archive.isEmpty)
        XCTAssertEqual(archive.exercises.count, 2)
        XCTAssertEqual(archive.progressStates.count, 1)
        XCTAssertEqual(archive.bodyweights.count, 1)
    }

    /// The warmup matters: it's excluded from every statistic, so it is exactly
    /// the row an export written against the insight layer would drop.
    func testArchiveKeepsWarmups() throws {
        try seedHistory()
        let archive = try store.archive()
        XCTAssertEqual(archive.sets.filter(\.isWarmup).count, 1)
    }

    func testArchiveRoundTripsThroughJSON() throws {
        try seedHistory()
        let original = try store.archive(exportedAt: midday())

        let restored = try TrainingArchive(json: original.jsonData())

        XCTAssertEqual(restored, original, "an archive must survive its own file format")
    }

    /// Sub-second precision survives. `Date()` carries it, and truncating on
    /// export would mean the restored history is not the exported one.
    func testTimestampsKeepSubSecondPrecision() throws {
        let lift = incline
        try store.upsert(lift)
        let precise = Date(timeIntervalSince1970: 1_770_000_000.25)
        try store.log(SetRecord(
            exerciseID: lift.id, load: Load(70), reps: 8,
            rpe: RPE(8)!, performedAt: precise
        ))

        let archive = try TrainingArchive(json: try store.archive().jsonData())

        XCTAssertEqual(archive.sets.first?.performedAt, precise)
    }

    /// "Readable without the app" is half the point of having a file.
    func testJSONIsPlainTextWithReadableDates() throws {
        try seedHistory()
        let data = try store.archive(exportedAt: midday()).jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"version\""))
        XCTAssertTrue(text.contains("\"exportedAt\""))
        XCTAssertTrue(text.contains("\n"), "pretty-printed rather than one line")

        // Rendered in UTC, so the expected string comes from the formatter
        // rather than from a hard-coded local offset that would only hold in
        // whichever timezone the test happened to be written in.
        XCTAssertTrue(
            text.contains(ArchiveDate.precise.string(from: midday())),
            "dates readable as dates"
        )
        XCTAssertTrue(text.contains("2026-03-1"), "and readable as this training's dates")
    }

    func testSuggestedFilenameNamesTheDay() throws {
        let archive = TrainingArchive(exportedAt: midday())
        XCTAssertEqual(archive.suggestedFilename, "ChickenBreast-2026-03-10.json")
    }

    // MARK: - Restore (#88)

    /// The whole point: delete the app, reinstall, import the file.
    func testRestoreIntoAnEmptyStoreGivesBackTheHistory() throws {
        try seedHistory()
        let exported = try store.archive()

        let fresh = try TrainingStore.inMemory()
        let report = try fresh.restore(from: exported)

        XCTAssertEqual(report.sets, 3)
        XCTAssertEqual(try fresh.allSets(), try store.allSets())
        XCTAssertEqual(try fresh.exercises(), try store.exercises())
        XCTAssertEqual(try fresh.bodyweights(), try store.bodyweights())
        XCTAssertEqual(
            try fresh.allProgressStates().sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString },
            try store.allProgressStates().sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
        )
    }

    /// Re-exporting a restored store reproduces the same document.
    func testRestoredStoreExportsAnIdenticalArchive() throws {
        try seedHistory()
        let exported = try store.archive(exportedAt: midday())

        let fresh = try TrainingStore.inMemory()
        try fresh.restore(from: exported)

        XCTAssertEqual(try fresh.archive(exportedAt: midday()), exported)
    }

    func testRestoringTwiceChangesNothing() throws {
        try seedHistory()
        let exported = try store.archive()

        let fresh = try TrainingStore.inMemory()
        try fresh.restore(from: exported)
        let afterFirst = try fresh.archive(exportedAt: midday())

        let second = try fresh.restore(from: exported)

        XCTAssertEqual(try fresh.allSets().count, 3, "no second copy of anything")
        XCTAssertEqual(try fresh.archive(exportedAt: midday()), afterFirst)
        XCTAssertTrue(
            second.deduplicated.isEmpty,
            "the import shouldn't create duplicates for the dedupe pass to clean up"
        )
    }

    /// A restore must not silently discard training the phone already has.
    func testRestoreMergesRatherThanReplaces() throws {
        try seedHistory()
        let exported = try store.archive()

        let other = try TrainingStore.inMemory()
        let lift = incline
        try other.upsert(lift)
        let localSet = SetRecord(
            exerciseID: lift.id, load: Load(80), reps: 6,
            rpe: RPE(9)!, performedAt: midday(30)
        )
        try other.log(localSet)

        try other.restore(from: exported)

        let ids = Set(try other.allSets().map(\.id))
        XCTAssertTrue(ids.contains(localSet.id), "local training survives a restore")
        XCTAssertEqual(ids.count, 4, "three imported plus the one already here")
    }

    /// A backup written before the phone kept training must not wind a lift's
    /// target back to what it was when the file was saved.
    func testRestoreKeepsTheLaterProgressState() throws {
        let lift = incline
        try store.upsert(lift)
        try store.save(ProgressState(
            exerciseID: lift.id, targetLoad: Load(70), lastPerformedAt: midday()
        ))
        let stale = try store.archive()

        try store.save(ProgressState(
            exerciseID: lift.id, targetLoad: Load(85), lastPerformedAt: midday(14)
        ))

        try store.restore(from: stale)

        XCTAssertEqual(
            try store.progressState(forExercise: lift.id)?.targetLoad, Load(85),
            "the state that saw the later session wins"
        )
    }

    func testRestoreTakesAnOlderProgressStateWhenNothingIsHere() throws {
        try seedHistory()
        let exported = try store.archive()

        let fresh = try TrainingStore.inMemory()
        try fresh.restore(from: exported)

        XCTAssertEqual(
            try fresh.progressState(forExercise: incline.id)?.targetLoad, Load(75)
        )
    }

    /// Half-importing a file from a later schema is worse than refusing it.
    func testRestoreRefusesANewerFormat() throws {
        var future = try store.archive()
        future.version = TrainingArchive.currentVersion + 1

        XCTAssertThrowsError(try store.restore(from: future)) { error in
            XCTAssertEqual(
                error as? ArchiveError,
                .tooNew(found: TrainingArchive.currentVersion + 1,
                        readable: TrainingArchive.currentVersion)
            )
        }
    }

    func testReadingRefusesANewerFormat() throws {
        var future = TrainingArchive()
        future.version = 99
        let data = try future.jsonData()

        XCTAssertThrowsError(try TrainingArchive(json: data))
    }

    /// A set has to land back on the day it was logged, not the day the import
    /// happened to run (#79).
    func testSetsLandOnTheDayTheyWereLogged() throws {
        let lift = incline
        try store.upsert(lift)
        let performed = midday(3)
        try store.log(SetRecord(
            exerciseID: lift.id, load: Load(70), reps: 8,
            rpe: RPE(8)!, performedAt: performed
        ))

        let fresh = try TrainingStore.inMemory()
        try fresh.restore(from: try store.archive())

        XCTAssertEqual(fresh.allSetsForTest().first?.performedAt, performed)
    }

    // MARK: - Bodyweight

    func testBodyweightSurvivesTheRoundTrip() throws {
        try store.record(BodyweightReading(pounds: 178.4, recordedAt: midday()))
        try store.record(BodyweightReading(pounds: 177.2, recordedAt: midday(7)))

        let fresh = try TrainingStore.inMemory()
        try fresh.restore(from: try TrainingArchive(json: try store.archive().jsonData()))

        XCTAssertEqual(try fresh.bodyweights(), try store.bodyweights())
    }

    /// One reading per day, the same rule `record(_:calendar:)` enforces —
    /// and the one already here is it (#271). A weigh-in's day is its
    /// identity, so a reading logged here after the export is this phone's
    /// newer copy of that row.
    func testRestoreKeepsOneWeighInPerDay() throws {
        try store.record(BodyweightReading(pounds: 178.4, recordedAt: midday()))
        let exported = try store.archive()

        let other = try TrainingStore.inMemory()
        try other.record(BodyweightReading(
            pounds: 999, recordedAt: midday().addingTimeInterval(3600)
        ))

        try other.restore(from: exported)

        XCTAssertEqual(try other.bodyweights().count, 1)
        XCTAssertEqual(try other.bodyweights().first?.pounds, 999, "the reading already here")
    }

    /// Nothing else dedupes bodyweight, so two devices weighing in offline on
    /// the same morning can both land. An import settles it.
    func testRestoreCollapsesDuplicateWeighInsOnOneDay() throws {
        store.modelContext.insert(StoredBodyweight(
            BodyweightReading(pounds: 180, recordedAt: midday())
        ))
        store.modelContext.insert(StoredBodyweight(
            BodyweightReading(pounds: 181, recordedAt: midday().addingTimeInterval(60))
        ))
        try store.saveChanges()
        XCTAssertEqual(try store.bodyweights().count, 2)

        try store.restore(from: TrainingArchive())

        XCTAssertEqual(try store.bodyweights().count, 1)
        XCTAssertEqual(try store.bodyweights().first?.pounds, 181, "the later weigh-in")
    }

    // MARK: - Empty

    func testRestoringAnEmptyArchiveIsANoOp() throws {
        try seedHistory()
        let before = try store.archive(exportedAt: midday())

        let report = try store.restore(from: TrainingArchive())

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try store.archive(exportedAt: midday()), before)
    }


    // MARK: - Restore must not lose what is already here

    /// A restore onto a fresh device used to re-rack every lift to pounds.
    ///
    /// The archive carried no gym, so a reinstall landed on the default pound
    /// gym and `reconcileGym()` rewrote the increment and loading of every lift
    /// that follows it (#67, #73) — a kilogram lifter got their history back
    /// with the numbers converted out from under it.
    func testArchiveCarriesTheGymAndRestoreBringsItBack() throws {
        try seedHistory()
        try store.saveGymConfig(GymConfig(unit: .kilograms))

        let backup = try store.archive()
        XCTAssertEqual(
            backup.gymConfig?.unit, .kilograms,
            "the file has to carry the unit its numbers were read in"
        )

        let fresh = try TrainingStore.inMemory()
        XCTAssertEqual(try fresh.gymConfig().unit, .pounds, "a new store starts in pounds")

        let report = try fresh.restore(from: backup)
        XCTAssertTrue(report.restoredGym)
        XCTAssertEqual(try fresh.gymConfig().unit, .kilograms)

        // And the reconcile that runs at launch now agrees with the file
        // rather than converting it away.
        try fresh.reconcileGym()
        XCTAssertEqual(try fresh.gymConfig().unit, .kilograms)
    }

    /// A file written before the gym was archived still opens, and leaves this
    /// device's gym alone rather than resetting it.
    func testArchiveWithoutAGymLeavesTheLocalOneAlone() throws {
        try seedHistory()
        var backup = try store.archive()
        backup.gymConfig = nil

        let fresh = try TrainingStore.inMemory()
        try fresh.saveGymConfig(GymConfig(unit: .kilograms))
        let report = try fresh.restore(from: backup)

        XCTAssertFalse(report.restoredGym)
        XCTAssertEqual(try fresh.gymConfig().unit, .kilograms)
    }

    /// A file exported before #136 has `"kind":"push"` as a bare JSON string
    /// and no `"name"` key on a day template at all, and its `gymConfig` (when
    /// present) has no `"trainingSplit"` key either. This is the actual shape
    /// on disk for anyone who backed up before this landed, and #87's whole
    /// premise is that the file "has to still open" — proven here against the
    /// real archive-reading path, not just `DayKind`/`DayTemplate` in
    /// isolation (see `DayTemplateTests`).
    func testAPreSplitArchiveStillOpensAndRestores() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2025-01-01T00:00:00Z",
          "exercises": [],
          "sets": [],
          "progressStates": [],
          "dayTemplates": [
            {"id":"CB00000A-0000-4000-8000-000000000001","kind":"push","slots":[]}
          ],
          "bodyweights": [],
          "gymConfig": {"unit":"pounds","availablePlates":[45,35,25,10,5,2.5],
                        "barWeight":{"pounds":45}}
        }
        """
        let archive = try TrainingArchive(json: Data(json.utf8))

        XCTAssertEqual(archive.dayTemplates.first?.kind, .push)
        XCTAssertEqual(archive.dayTemplates.first?.name, "Push",
                       "no stored name falls back to the kind's own word")
        XCTAssertNil(archive.gymConfig?.trainingSplit,
                    "no stored split reads as 'nobody has picked yet', not push/pull/legs")

        let fresh = try TrainingStore.inMemory()
        let report = try fresh.restore(from: archive)
        XCTAssertEqual(report.dayTemplates, 1)
        XCTAssertEqual(try fresh.dayTemplate(kind: .push)?.name, "Push")
    }

    /// A file exported before #174 has no `"restOverride"` key on an exercise
    /// at all — this is the actual shape produced by every build up to this
    /// one, captured directly off `TrainingArchive.encoder` for a dumbbell
    /// lift with no loading style (both fields are nil, and a nil-valued
    /// stored property is omitted by synthesized `Encodable` rather than
    /// written as `null`).
    ///
    /// #174's hard-won lesson (from #136's near miss) is that a shape change
    /// on a domain type that flows straight into `TrainingArchive` — no
    /// `Stored*` blob in between — has to be proven against the literal old
    /// file, not just against `Exercise`'s own initialiser defaults, because
    /// only the real archive-reading path exercises whatever custom decoding
    /// the type carries. `Exercise` has none — it leans on synthesized
    /// `Codable`, which is exactly what makes an added `Optional` stored
    /// property safe: a missing key decodes as `nil` automatically, with no
    /// custom `init(from:)` required to make it so.
    func testAPreRestOverrideArchiveStillOpensAndRestores() throws {
        let json = """
        {
          "version": 1,
          "exportedAt": "2025-01-01T00:00:00Z",
          "exercises": [
            {
              "id": "CB000001-0000-4000-8000-000000000001",
              "name": "Incline DB Press",
              "equipment": "dumbbell",
              "increment": {"pounds": 5, "unit": "pounds"},
              "muscles": [
                {"muscle": "chest", "role": "primary"},
                {"muscle": "frontDelts", "role": "secondary"},
                {"muscle": "triceps", "role": "secondary"}
              ],
              "needsWarmupRamp": false,
              "progressionRule": {
                "doubleProgression": {
                  "range": {"bottom": 8, "top": 12},
                  "consecutiveTopHitsRequired": 2
                }
              }
            }
          ],
          "sets": [],
          "progressStates": [],
          "dayTemplates": [],
          "bodyweights": []
        }
        """
        let archive = try TrainingArchive(json: Data(json.utf8))
        let lift = try XCTUnwrap(archive.exercises.first)

        XCTAssertNil(lift.restOverride,
                    "no stored key reads as 'never set', not as zero seconds")
        XCTAssertTrue(lift.isCompound, "three muscles tagged, so this is a compound")
        XCTAssertEqual(lift.restTarget, 180,
                       "an old file's lift keeps resting exactly as it did before #174")

        let fresh = try TrainingStore.inMemory()
        let report = try fresh.restore(from: archive)
        XCTAssertEqual(report.exercises, 1)
        XCTAssertEqual(try fresh.exercise(id: lift.id)?.restTarget, 180)
    }

    // MARK: - Restore keeps what is already here (#271)

    private var bench: Exercise {
        ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
    }

    /// The issue's scenario. A set corrected after the export (#61) and a lift
    /// renamed after it both survive restoring that export — otherwise the
    /// misheard "eighty" #61 exists to fix comes back through a feature that
    /// exists to prevent loss, while the alert says everything here was kept.
    func testRestoreKeepsACorrectionAndALiftEditMadeAfterTheExport() throws {
        try store.seedLibraryIfNeeded()
        let misheard = SetRecord(
            exerciseID: bench.id, load: Load(185), reps: 80,
            rpe: RPE(8)!, performedAt: midday()
        )
        try store.log(misheard)
        let backup = try store.archive(exportedAt: midday().addingTimeInterval(3600))

        var fixed = misheard
        fixed.reps = 8
        XCTAssertTrue(try store.updateSet(fixed))
        var renamed = bench
        renamed.name = "Paused Bench"
        renamed.restOverride = 240
        try store.upsert(renamed)

        try store.restore(from: backup)

        XCTAssertEqual(try store.allSets().map(\.reps), [8], "the correction survives")
        let lift = try XCTUnwrap(try store.exercise(id: bench.id))
        XCTAssertEqual(lift.name, "Paused Bench", "the rename survives")
        XCTAssertEqual(lift.restOverride, 240)
    }

    func testRestoreKeepsATemplateEditedAfterTheExport() throws {
        try store.seedTemplatesIfNeeded()
        let backup = try store.archive(exportedAt: midday())

        var push = try XCTUnwrap(try store.dayTemplate(kind: .push))
        push.name = "Chest Day"
        try store.upsert(push)

        try store.restore(from: backup)

        XCTAssertEqual(try store.dayTemplate(kind: .push)?.name, "Chest Day")
    }

    /// A deload applied from the digest after the export changes the target
    /// without a new session, so the two states tie on `lastPerformedAt`. The
    /// one already here wins the tie, and wins outright either way.
    func testRestoreKeepsAProgressStateChangedAfterTheExport() throws {
        let lift = incline
        try store.upsert(lift)
        let before = ProgressState(
            exerciseID: lift.id, targetLoad: Load(80), lastPerformedAt: midday()
        )
        try store.save(before)
        let backup = try store.archive(exportedAt: midday(1))

        var deload = before
        deload.targetLoad = Load(70)
        try store.save(deload)

        try store.restore(from: backup)

        XCTAssertEqual(try store.progressState(forExercise: lift.id)?.targetLoad, Load(70))
    }

    /// A fresh install seeds the catalogue before anyone can reach restore.
    /// Those stock rows are nobody's change, so the file's copy of an edited
    /// catalogue lift or template still comes back over them.
    func testRestoreOntoAFreshInstallStillBringsBackEditedCatalogueRows() throws {
        var renamed = bench
        renamed.name = "Paused Bench"
        try store.upsert(renamed)
        try store.seedTemplatesIfNeeded()
        var push = try XCTUnwrap(try store.dayTemplate(kind: .push))
        push.name = "Chest Day"
        try store.upsert(push)
        let backup = try store.archive(exportedAt: midday())

        let fresh = try TrainingStore.inMemory()
        try fresh.seedLibraryIfNeeded()
        try fresh.seedTemplatesIfNeeded()
        try fresh.restore(from: backup)

        XCTAssertEqual(try fresh.exercise(id: bench.id)?.name, "Paused Bench")
        XCTAssertEqual(try fresh.dayTemplate(kind: .push)?.name, "Chest Day")
    }

    /// The gym the lifter set here after the export is theirs.
    func testRestoreKeepsAGymChangedAfterTheExport() throws {
        try store.saveGymConfig(GymConfig(unit: .pounds, barWeight: Load(35)), at: midday())
        let backup = try store.archive(exportedAt: midday())

        try store.saveGymConfig(GymConfig(
            unit: .kilograms,
            trainingSplit: DayTemplateLibrary.split(.upperLower, startedAt: midday()),
            weeklySessionTarget: 5
        ), at: midday(1))
        let mine = try store.gymConfig()

        let report = try store.restore(from: backup)

        XCTAssertEqual(try store.gymConfig(), mine)
        XCTAssertFalse(report.restoredGym)
    }

    /// A fresh install asks for a split before anything else, which writes a
    /// gym row holding the standard pound rack. That rack is nobody's choice:
    /// keeping it would re-rack a kilogram lifter's restored lifts to pounds at
    /// the next launch (#67, #73). The split they just picked is a choice.
    func testRestoreOntoAFreshInstallTakesTheFilesRackAndKeepsThePickedSplit() throws {
        let theirs = GymConfig(
            unit: .kilograms, barWeight: Load(15, .kilograms),
            trainingSplit: DayTemplateLibrary.split(.pushPullLegs, startedAt: midday(-30)),
            weeklySessionTarget: 5
        )
        try store.saveGymConfig(theirs, at: midday())
        let backup = try store.archive(exportedAt: midday())

        let fresh = try TrainingStore.inMemory()
        let picked = DayTemplateLibrary.split(.fullBody, startedAt: midday(2))
        try fresh.saveGymConfig(GymConfig(trainingSplit: picked), at: midday(2))

        let report = try fresh.restore(from: backup)
        try fresh.reconcileGym()

        let gym = try fresh.gymConfig()
        XCTAssertEqual(gym.unit, .kilograms)
        XCTAssertEqual(gym.availablePlates, theirs.availablePlates)
        XCTAssertEqual(gym.barWeight, Load(15, .kilograms))
        XCTAssertEqual(gym.trainingSplit, picked, "the split picked here is kept")
        XCTAssertEqual(gym.weeklySessionTarget, 5, "a default target is nobody's choice")
        XCTAssertTrue(report.restoredGym)
    }

    /// Rows restore adds are counted apart from rows it found already here,
    /// so the alert can say what happened rather than implying an overwrite.
    func testTheReportSeparatesWhatWasAddedFromWhatWasKept() throws {
        try seedHistory()
        let backup = try store.archive(exportedAt: midday(2))

        let first = try TrainingStore.inMemory()
        let added = try first.restore(from: backup)
        XCTAssertEqual(added.sets, 3)
        XCTAssertEqual(added.exercises, 2)
        XCTAssertEqual(added.kept, 0)

        let again = try first.restore(from: backup)
        XCTAssertEqual(again.total, 0, "nothing new the second time")
        XCTAssertEqual(again.kept, backup.sets.count + backup.exercises.count
                       + backup.progressStates.count + backup.bodyweights.count)
        XCTAssertFalse(again.isEmpty, "the file wasn't empty; it was all already here")
    }

}

private extension TrainingStore {
    /// Reads sets without the day grouping the public accessors apply, so a
    /// test can assert on the raw stored instant.
    func allSetsForTest() -> [SetRecord] {
        (try? allSets()) ?? []
    }
}
