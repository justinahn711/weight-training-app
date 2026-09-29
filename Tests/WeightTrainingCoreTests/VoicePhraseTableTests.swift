import XCTest
@testable import WeightTrainingCore

/// The whole voice path, phrase in to `canAutoCommit` out, as one table.
///
/// Each row runs `VoiceGrammar.parse` → `VoiceSnapper.snap` on Flat Bench with
/// 185 lb dialled in, which is exactly what the session does. The rule the
/// table enforces: **when in doubt, don't auto-commit.** A number the grammar
/// heard and couldn't place leaves the parse unsure, so the set waits for a
/// tap on "Log it" rather than committing with the form's stale value (#262).
///
/// Rows are the auditor's probe list: the phrases that were already right
/// (so a fix can't quietly break them) and the ones that weren't (#262,
/// #264, #267).
final class VoicePhraseTableTests: XCTestCase {

    private struct Row {
        let phrase: String
        /// Heard load in pounds, before snapping. Nil means no load.
        let load: Double?
        let reps: Int?
        let rpe: Double?
        let autoCommit: Bool
        let line: UInt

        init(_ phrase: String, load: Double? = nil, reps: Int? = nil, rpe: Double? = nil,
             auto autoCommit: Bool, line: UInt = #line) {
            self.phrase = phrase
            self.load = load
            self.reps = reps
            self.rpe = rpe
            self.autoCommit = autoCommit
            self.line = line
        }
    }

    private let bench = ExerciseLibrary.all.first { $0.name == "Flat Bench" }!

    private func check(_ rows: [Row], file: StaticString = #filePath) {
        for row in rows {
            guard let parse = VoiceGrammar.parse(row.phrase) else {
                XCTFail("[\(row.phrase)] parsed to nothing", file: file, line: row.line)
                continue
            }
            guard case .logSet(let load, let reps, let rpe) = parse.command else {
                XCTFail("[\(row.phrase)] is not a set: \(parse.command)",
                        file: file, line: row.line)
                continue
            }
            XCTAssertEqual(load?.pounds, row.load, "[\(row.phrase)] load",
                           file: file, line: row.line)
            XCTAssertEqual(reps, row.reps, "[\(row.phrase)] reps", file: file, line: row.line)
            XCTAssertEqual(rpe, row.rpe.flatMap { RPE($0) }, "[\(row.phrase)] rpe",
                           file: file, line: row.line)

            let snapped = VoiceSnapper.snap(parse, for: bench, reference: Load(185))
            XCTAssertEqual(snapped?.canAutoCommit ?? false, row.autoCommit,
                           "[\(row.phrase)] canAutoCommit", file: file, line: row.line)
        }
    }

    // MARK: - Already right, and must stay right

    func testCanonicalFormsStillAutoCommit() {
        check([
            Row("185 for 5", load: 185, reps: 5, auto: true),
            Row("185 for 5 at 8", load: 185, reps: 5, rpe: 8, auto: true),
            Row("one eighty five for five at eight", load: 185, reps: 5, rpe: 8, auto: true),
            Row("185 for five at eight and a half", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("five reps", reps: 5, auto: true),
            Row("for 5 at 8", reps: 5, rpe: 8, auto: true),
            Row("two twenty five for 5", load: 225, reps: 5, auto: true),
            Row("a hundred and five for 5", load: 105, reps: 5, auto: true),
            Row("one hundred eighty five for 5", load: 185, reps: 5, auto: true),
            Row("three fifteen for 3", load: 315, reps: 3, auto: true),
            Row("185 for two", load: 185, reps: 2, auto: true),
            Row("185 for 5 at eight and a half", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("185 for 5 at eight point five", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("185 pounds for 5", load: 185, reps: 5, auto: true),
            Row("185 for 5 reps", load: 185, reps: 5, auto: true),
            Row("185 x 5 @ 8", load: 185, reps: 5, rpe: 8, auto: true),
            Row("one 85 for 8", load: 185, reps: 8, auto: true),
        ])
    }

    /// Filler around a complete phrase is not a number, so it costs nothing.
    func testFillerWordsAreHarmless() {
        check([
            Row("log 185 for 8 at 8", load: 185, reps: 8, rpe: 8, auto: true),
            Row("okay 185 for 5 at 8 please", load: 185, reps: 5, rpe: 8, auto: true),
            Row("185 for 5.", load: 185, reps: 5, auto: true),
            Row("One eighty-five for five at eight.", load: 185, reps: 5, rpe: 8, auto: true),
            Row("225 for 5, at 8", load: 225, reps: 5, rpe: 8, auto: true),
        ])
    }

    /// Snapping, refusing and bare numbers already waited for a tap (#22).
    func testWhatAlreadyWaitedStillWaits() {
        check([
            Row("185", load: 185, auto: false),
            Row("187 for 5", load: 187, reps: 5, auto: false),
            Row("1080 for 5", load: 1_080, reps: 5, auto: false),
            Row("185 for 40", load: 185, reps: 40, auto: false),
            Row("forty five for 10", load: 45, reps: 10, auto: false),
        ])
    }

    // MARK: - #274: a weight with no reps waits, however it was said

    /// Only a weight, and the app would log it with whatever reps are dialled
    /// in. Bare `185` always waited; the same weight in words auto-committed,
    /// because "bare" was decided by counting words rather than by what was
    /// heard.
    func testAWeightWithNoRepsWaits() {
        check([
            Row("185", load: 185, auto: false),
            Row("one eighty five", load: 185, auto: false),
            Row("a hundred and five", load: 105, auto: false),
            Row("two twenty five", load: 225, auto: false),
            Row("log 185", load: 185, auto: false),
            Row("185 pounds", load: 185, auto: false),
            Row("185 at 8", load: 185, rpe: 8, auto: false),
        ])
    }

    /// The same weights with reps heard are complete, and still commit.
    func testAWeightWithRepsStillAutoCommits() {
        check([
            Row("one eighty five for five", load: 185, reps: 5, auto: true),
            Row("one eighty five for five at eight", load: 185, reps: 5, rpe: 8, auto: true),
            Row("a hundred and five for eight", load: 105, reps: 8, auto: true),
            Row("two twenty five for 5", load: 225, reps: 5, auto: true),
            Row("185 pounds 8 reps", load: 185, reps: 8, auto: true),
        ])
    }

    // MARK: - #262: a number the grammar drops leaves the parse unsure

    /// Every row here used to report `canAutoCommit == true` and log the
    /// form's stale value in place of what was said. The banner still shows
    /// what was understood, so a tap still commits it.
    func testADroppedNumberBlocksAutoCommit() {
        check([
            Row("180 5 for 5", load: 180, reps: 5, auto: false),
            Row("eight reps at 185", reps: 8, auto: false),
            Row("185 for 5 at 85", load: 185, reps: 5, auto: false),
            Row("185 for 5 at eight five", load: 185, reps: 5, rpe: 8, auto: false),
            Row("185 for to", load: 185, auto: false),
            Row("185 for too", load: 185, auto: false),
            Row("185 5 8", load: 185, auto: false),
            Row("185 pounds 5", load: 185, auto: false),
            Row("185 45", load: 185, auto: false),
            Row("185 for 0", load: 185, auto: false),
            Row("185 for 5 and 8", load: 185, reps: 5, auto: false),
            Row("185 for 5 at 3", load: 185, reps: 5, auto: false),
            Row("185 8 8", load: 185, auto: false),
            Row("185 for 5 for 6", load: 185, reps: 5, auto: false),
            Row("185 for 5.5", load: 185, auto: false),
        ])
    }

    /// A marker with nothing after it means its number went unheard.
    func testADanglingMarkerBlocksAutoCommit() {
        check([
            Row("185 for", load: 185, auto: false),
            Row("185 for 5 at", load: 185, reps: 5, auto: false),
        ])
    }

    // MARK: - #264: decimals

    func testDecimalsAreHeardWhole() {
        check([
            Row("185 for 5 at 8.5", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("185 for 5 at 7.5", load: 185, reps: 5, rpe: 7.5, auto: true),
            Row("185 for 5 at 9.5", load: 185, reps: 5, rpe: 9.5, auto: true),
            Row("185 for 5 at 8 1/2", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("185 for 5 at 8½", load: 185, reps: 5, rpe: 8.5, auto: true),
            Row("187.5 for 5", load: 187.5, reps: 5, auto: false),
        ])
    }

    /// The kg cases from #264, where truncation happened to land on the grid.
    func testKilogramDecimalsAreNotTruncatedOntoTheGrid() throws {
        var stack = bench
        stack.increment = LoadIncrement(1, .kilograms)
        stack.loading = nil
        for phrase in ["32.5 for 10", "27.5 for 10"] {
            let parse = try XCTUnwrap(VoiceGrammar.parse(phrase, in: .kilograms))
            let snapped = try XCTUnwrap(
                VoiceSnapper.snap(parse, for: stack, reference: Load(30, .kilograms))
            )
            XCTAssertFalse(snapped.canAutoCommit, "\(phrase) must not commit as a whole kilo")
        }

        var kgBench = bench
        kgBench.increment = LoadIncrement(2.5, .kilograms)
        kgBench.loading = nil
        let parse = try XCTUnwrap(VoiceGrammar.parse("60 for 5 at 8.5", in: .kilograms))
        let snapped = try XCTUnwrap(
            VoiceSnapper.snap(parse, for: kgBench, reference: Load(60, .kilograms))
        )
        XCTAssertEqual(snapped.rpe, RPE(8.5))
        XCTAssertTrue(snapped.canAutoCommit)
    }

    // MARK: - #267: number words stop at a complete load

    func testATrailingNumberWordIsNotAddedToTheLoad() {
        check([
            Row("one eighty five five", load: 185, auto: false),
            Row("two twenty five five", load: 225, auto: false),
            Row("one thirty five eight", load: 135, auto: false),
            Row("one eighty five 5", load: 185, auto: false),
            Row("one oh five for 8", load: 105, reps: 8, auto: true),
        ])
    }

    // MARK: - Snapping never auto-commits

    /// Whatever the grammar decides, a load moved to fit the bar still waits.
    func testASnappedLoadNeverAutoCommits() throws {
        for phrase in ["187 for 5", "183 for 5 at 8", "one eighty seven for five",
                       "187.5 for 5"] {
            let parse = try XCTUnwrap(VoiceGrammar.parse(phrase))
            let snapped = try XCTUnwrap(
                VoiceSnapper.snap(parse, for: bench, reference: Load(185))
            )
            XCTAssertTrue(snapped.wasSnapped, phrase)
            XCTAssertFalse(snapped.canAutoCommit, phrase)
        }
    }
}
