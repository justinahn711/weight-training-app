//
//  HistoryViewTests.swift
//  ChickenBreastTests
//

import XCTest
import WeightTrainingCore
@testable import ChickenBreast

/// Coverage for the two things #218 fixed in `HistoryView.swift`: the
/// duplicated "RPE RPE 8" row label, and the interaction between the new
/// exact-weight field and `TypedWeight` (#99).
///
/// Both are exercised as free functions (`historyRPEText`,
/// `resolveHistoryWeightEdit`, `canSaveHistoryWeightEdit`) rather than by
/// instantiating `EditSetView`/`SetRow` — those two stay `private` to
/// `HistoryView.swift` and are exercised in the real UI by
/// `ChickenBreastUITests` instead. This suite is for the decision logic
/// behind them, checkable by `swift test`... except `HistoryView.swift` lives
/// in the Xcode app target rather than the SwiftPM package, so it's this
/// target's `xcodebuild test -scheme ChickenBreast` that actually runs it.
final class HistoryViewTests: XCTestCase {

    // MARK: - Fixtures (mirrors `TypedWeightTests` in WeightTrainingCoreTests)

    private func dumbbellCurl() -> Exercise {
        Exercise(name: "Curl", muscles: [], equipment: .dumbbell,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    private func barbellBench() -> Exercise {
        Exercise(name: "Bench", muscles: [], equipment: .barbell,
                 progressionRule: .doubleProgression(range: RepRange(5, 8)))
    }

    // MARK: - historyRPEText (the "RPE RPE 8" bug)

    /// The exact shape of the bug: `RPE.description` already reads "RPE 8",
    /// so this must not add a second "RPE ".
    func testHistoryRPETextReadsOnce() throws {
        let eight = try XCTUnwrap(RPE(8))
        XCTAssertEqual(historyRPEText(eight), "RPE 8")
        XCTAssertFalse(historyRPEText(eight).contains("RPE RPE"))
    }

    func testHistoryRPETextKeepsHalfPoints() throws {
        let sevenAndAHalf = try XCTUnwrap(RPE(7.5))
        XCTAssertEqual(historyRPEText(sevenAndAHalf), "RPE 7.5")
    }

    // MARK: - resolveHistoryWeightEdit

    /// Nothing typed yet — the field still reads what `pounds` committed.
    func testUneditedFieldNeedsNoResolution() {
        let edit = resolveHistoryWeightEdit(
            text: "70", committed: "70", unit: .pounds, exercise: dumbbellCurl()
        )
        XCTAssertEqual(edit, .unedited)
        XCTAssertTrue(canSaveHistoryWeightEdit(edit))
    }

    /// A typed value the equipment can actually be set to.
    func testBuildableTypedValueResolvesExact() {
        let edit = resolveHistoryWeightEdit(
            text: "80", committed: "70", unit: .pounds, exercise: dumbbellCurl()
        )
        XCTAssertEqual(edit, .exact(Load(80)))
        XCTAssertTrue(canSaveHistoryWeightEdit(edit))
    }

    /// 45 lb -> 135 lb is exactly the correction the issue names, and a
    /// barbell can build 135 (two 45s a side over a 45 lb bar).
    func testTheIssuesOwnCorrectionResolvesExact() {
        let edit = resolveHistoryWeightEdit(
            text: "135", committed: "45", unit: .pounds, exercise: barbellBench()
        )
        XCTAssertEqual(edit, .exact(Load(135)))
        XCTAssertTrue(canSaveHistoryWeightEdit(edit))
    }

    /// A typed value this equipment cannot build offers the nearest one
    /// rather than being silently accepted or silently ignored.
    func testUnbuildableTypedValueOffersNearestAndBlocksSave() {
        let edit = resolveHistoryWeightEdit(
            text: "187", committed: "185", unit: .pounds, exercise: barbellBench()
        )
        XCTAssertEqual(edit, .unbuildable(requested: Load(187), achievable: Load(185)))
        XCTAssertFalse(canSaveHistoryWeightEdit(edit))
    }

    /// Junk the decimal pad cannot type — refused, not coerced to zero.
    func testUnparseableTextBlocksSave() {
        let edit = resolveHistoryWeightEdit(
            text: "abc", committed: "70", unit: .pounds, exercise: dumbbellCurl()
        )
        XCTAssertEqual(edit, .unparseable)
        XCTAssertFalse(canSaveHistoryWeightEdit(edit))
    }

    /// A field mid-clear reads empty on every keystroke between the old
    /// value and the new one (#99) — that must not block Save on its own,
    /// since it might resolve the moment the next digit lands, but it also
    /// must not silently claim the old value is still exact.
    func testEmptyFieldWhileClearingIsUnparseableNotZero() {
        let edit = resolveHistoryWeightEdit(
            text: "", committed: "70", unit: .pounds, exercise: dumbbellCurl()
        )
        XCTAssertEqual(edit, .unparseable)
        XCTAssertFalse(canSaveHistoryWeightEdit(edit))
    }
}
