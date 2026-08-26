import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// #88's done-when, checked across a corpus rather than one fixture: "deleting
/// the app, reinstalling, and importing the file gives back the same history,
/// records and trends — and importing the same file twice changes nothing the
/// second time."
@MainActor
final class RoundTripEvals: XCTestCase {

    func testEveryHistoryInTheCorpusSurvivesTheRoundTrip() throws {
        for shape in Corpus.all {
            for check in try RoundTrip.check(shape) where !check.passed {
                XCTFail("""
                    [\(shape.name)] \(check.name)
                    \(check.detail)
                    """)
            }
        }
    }

    /// A restore is not a reinstall in the common case — it's a phone that has
    /// kept training since the file was written. Both histories have to be
    /// there afterwards.
    func testRestoreOntoAPhoneThatKeptTrainingKeepsBoth() throws {
        for check in try RoundTrip.checkMerge(Corpus.threeWeekBlock,
                                              onto: Corpus.bodyweightLifting)
        where !check.passed {
            XCTFail("\(check.name) — \(check.detail)")
        }
    }

    /// The same file, restored onto a store that already holds exactly it.
    /// This is the second tap of a worried person, and it must be inert.
    func testRestoringOntoAnIdenticalStoreIsInert() throws {
        for shape in Corpus.all {
            let origin = try RoundTrip.store(for: shape)
            let archive = try origin.archive(exportedAt: Corpus.at(day: 100))
            let before = try StoreSnapshot.of(origin)

            try origin.restore(from: archive, calendar: Corpus.calendar)
            let after = try StoreSnapshot.of(origin)

            XCTAssertEqual(after, before, """
                [\(shape.name)] restoring a store's own archive changed it
                \(after.difference(from: before))
                """)
        }
    }

    /// Half-importing a file from a later schema is worse than refusing it,
    /// because a partial restore looks like a successful one.
    func testAFileFromALaterBuildIsRefusedNotPartlyRead() throws {
        let origin = try RoundTrip.store(for: Corpus.threeWeekBlock)
        var archive = try origin.archive(exportedAt: Corpus.at(day: 100))
        archive.version = TrainingArchive.currentVersion + 1

        let target = try TrainingStore.inMemory()
        XCTAssertThrowsError(try target.restore(from: archive, calendar: Corpus.calendar))
        XCTAssertEqual(try StoreSnapshot.of(target).sets.count, 0,
                       "a refused import still wrote rows")
    }
}

/// What the archive format actually preserves in a timestamp.
///
/// `TrainingArchive` carries fractional seconds so that "a backup hands back
/// exactly what it was given". It does, to the millisecond: ISO-8601 fractional
/// seconds are three digits, and a `Date` carries more than that, so a stamp
/// finer than a millisecond comes back up to half a millisecond off.
///
/// That is almost certainly fine for this app — sets are seconds apart and day
/// grouping is nowhere near that resolution — but it is a millisecond contract
/// rather than an exact one, and the difference should be written down rather
/// than discovered during a restore.
@MainActor
final class ArchivePrecisionEvals: XCTestCase {

    func testTimestampsAreExactToTheMillisecond() throws {
        let lift = ExerciseLibrary.all.first!
        for fraction in [0.0, 0.5, 0.125, 0.001, 0.999] {
            let when = Date(timeIntervalSince1970: 1_772_000_000 + fraction)
            let archive = TrainingArchive(
                exportedAt: when,
                exercises: [lift],
                sets: [SetRecord(exerciseID: lift.id, load: Load(100), reps: 5,
                                 performedAt: when)]
            )
            let back = try TrainingArchive(json: try archive.jsonData())
            XCTAssertEqual(back.sets[0].performedAt.timeIntervalSince1970,
                           when.timeIntervalSince1970, accuracy: 0.0000001,
                           "millisecond-aligned stamp \(fraction) did not survive")
        }
    }

    /// Finer than a millisecond is truncated by the format. Asserted rather
    /// than left implicit, so that if the format ever gains precision this
    /// fails and the claim above gets updated with it.
    func testSubMillisecondPrecisionIsTruncated() throws {
        let when = Date(timeIntervalSince1970: 1_772_000_000.123456)
        let archive = TrainingArchive(exportedAt: when)
        let back = try TrainingArchive(json: try archive.jsonData())
        XCTAssertNotEqual(back.exportedAt.timeIntervalSince1970,
                          when.timeIntervalSince1970)
        XCTAssertEqual(back.exportedAt.timeIntervalSince1970,
                       when.timeIntervalSince1970, accuracy: 0.001)
    }
}
