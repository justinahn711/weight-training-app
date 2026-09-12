//
//  SyncStatusTests.swift
//  ChickenBreastTests
//

import XCTest
@testable import ChickenBreast

/// `SyncStatus.State` is the cleanest kind of case for this issue (#181): it
/// has no dependency on `TrainingStore`, CloudKit, or even a `SyncStatus`
/// instance to construct — it's a plain enum with formatting logic, reachable
/// from any test target with zero setup. That it lived in a file that imports
/// `CloudKit` was never a reason it needed a simulator; nothing here talks to
/// CloudKit at all.
@MainActor
final class SyncStatusTests: XCTestCase {

    func test_summary_describesEveryState() {
        XCTAssertEqual(SyncStatus.State.checking.summary, "Checking iCloud…")
        XCTAssertEqual(SyncStatus.State.syncing.summary, "Syncing with iCloud")
        XCTAssertEqual(
            SyncStatus.State.noAccount.summary,
            "Not signed into iCloud — training is saved on this phone only"
        )
        XCTAssertEqual(SyncStatus.State.restricted.summary, "iCloud is restricted on this device")
        XCTAssertEqual(
            SyncStatus.State.failed("network unreachable").summary,
            "iCloud unavailable: network unreachable"
        )
    }

    /// `.syncing` is the only state that means sync is actually working;
    /// every other state — including `.checking`, which is not a failure —
    /// must read as not-yet-healthy.
    func test_isHealthy_trueOnlyWhileSyncing() {
        XCTAssertFalse(SyncStatus.State.checking.isHealthy)
        XCTAssertTrue(SyncStatus.State.syncing.isHealthy)
        XCTAssertFalse(SyncStatus.State.noAccount.isHealthy)
        XCTAssertFalse(SyncStatus.State.restricted.isHealthy)
        XCTAssertFalse(SyncStatus.State.failed("timeout").isHealthy)
    }
}
