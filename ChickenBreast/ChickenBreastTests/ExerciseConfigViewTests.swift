//
//  ExerciseConfigViewTests.swift
//  ChickenBreastTests
//

import XCTest
import WeightTrainingCore
@testable import ChickenBreast

/// Coverage for what the lift config sheet's Save writes as the empty weight
/// (#243), exercised through `resolveConfigBaseWeight` rather than by
/// instantiating `ExerciseConfigView` — the same shape as
/// `resolveHistoryWeightEdit` in `HistoryViewTests`.
///
/// The rule under test: opening the sheet and tapping Save without touching
/// the field must leave the stored base exactly as it was, whatever unit the
/// lift is now marked in.
final class ExerciseConfigViewTests: XCTestCase {

    /// What `ExerciseConfigView.seed()` puts in the field for `stored`.
    private func seededText(_ stored: Load?, in unit: MassUnit) -> String {
        unit.format((stored ?? unit.standardBar).value(in: unit), withSymbol: false)
    }

    // MARK: - The no-op round trip (#243)

    /// The issue's exact case: a T-bar measured at 35 lb, gym since switched
    /// to kg. The field shows "15.88"; a Save that changes nothing must
    /// write 35 lb back bit-for-bit, not 35.0094.
    func testUntouchedFieldWritesStoredBaseBackExactlyAcrossUnits() {
        let stored = Load(35, .pounds)
        let text = seededText(stored, in: .kilograms)
        XCTAssertEqual(text, "15.88")

        let saved = resolveConfigBaseWeight(
            text: text, seededText: text, stored: stored, unit: .kilograms
        )
        XCTAssertEqual(saved.pounds, stored.pounds)
        XCTAssertEqual(saved, stored)
    }

    /// The other drifts the audit found, both directions.
    func testUntouchedFieldIsLosslessForOtherCrossUnitBases() {
        let cases: [(Load, MassUnit)] = [
            (Load(75, .pounds), .kilograms),
            (Load(90, .pounds), .kilograms),
            (Load(25, .kilograms), .pounds),
            (Load(45.25, .pounds), .kilograms),
            (Load(12.25, .kilograms), .pounds),
        ]
        for (stored, unit) in cases {
            let text = seededText(stored, in: unit)
            let saved = resolveConfigBaseWeight(
                text: text, seededText: text, stored: stored, unit: unit
            )
            XCTAssertEqual(saved.pounds, stored.pounds,
                           "\(stored.pounds) lb shown as \(text) \(unit.symbol)")
        }
    }

    /// Focusing the field and leaving it on something that is not a weight
    /// puts the seeded text back (`onChange(of: isEditingBase)`); a cleared
    /// or half-typed field must also write the stored value, not the
    /// rounded one on screen.
    func testUnparseableFieldFallsBackToStoredBaseExactly() {
        let stored = Load(35, .pounds)
        let seeded = seededText(stored, in: .kilograms)
        for text in ["", "7..", "abc"] {
            let saved = resolveConfigBaseWeight(
                text: text, seededText: seeded, stored: stored, unit: .kilograms
            )
            XCTAssertEqual(saved.pounds, stored.pounds, "text \"\(text)\"")
        }
    }

    // MARK: - Typed values still land as typed (#99)

    func testTypedValueIsStoredExactlyInTheLiftsUnit() {
        let stored = Load(35, .pounds)
        let seeded = seededText(stored, in: .kilograms)
        let saved = resolveConfigBaseWeight(
            text: "16", seededText: seeded, stored: stored, unit: .kilograms
        )
        XCTAssertEqual(saved, Load(16, .kilograms))
    }

    func testTypedValueInSameUnitIsStoredAsTyped() {
        let stored = Load(45, .pounds)
        let seeded = seededText(stored, in: .pounds)
        let saved = resolveConfigBaseWeight(
            text: "45.25", seededText: seeded, stored: stored, unit: .pounds
        )
        XCTAssertEqual(saved, Load(45.25, .pounds))
    }

    // MARK: - Newly measured lift

    /// Turning "measured" on for a lift with no stored base seeds the unit's
    /// standard bar; saving that untouched writes the standard bar.
    func testUnmeasuredLiftSavesStandardBarWhenUntouched() {
        for unit in [MassUnit.pounds, .kilograms] {
            let seeded = seededText(nil, in: unit)
            let saved = resolveConfigBaseWeight(
                text: seeded, seededText: seeded, stored: nil, unit: unit
            )
            XCTAssertEqual(saved, unit.standardBar)
        }
    }
}
