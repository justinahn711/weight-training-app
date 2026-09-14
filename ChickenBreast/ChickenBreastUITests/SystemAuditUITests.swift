//
//  SystemAuditUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// The two screens the system audit runs against directly.
///
/// Everything the audit itself is (`knownIssues`, the -56 handling, the
/// element description) lives in `ChickenBreastUITestCase` /
/// `UITestSupport.swift` now, shared with `SessionFlowUITests` — split out
/// for #193 so a stalled or killed audit run reads, from the class name
/// alone, as "the audit," never as "the tap-through flow broke." Before this
/// split, `testLogSetAndUndoIsReachableWithoutSight` lived in this same file
/// and the same `XCTestCase`, which meant a red run here said nothing about
/// which of the two had actually happened.
///
/// Named `SystemAuditUITests` rather than the original `AccessibilityAuditTests`
/// for a load-bearing reason, not a cosmetic one (#193 follow-up on the split
/// itself, from CI on PR #196): without a test plan, this target's classes run
/// in alphabetical-by-name order (verified empirically on the macos-26/Xcode
/// 26.6 runner this project builds with — Xcode's "Randomize execution order"
/// is off by default, and off means alphabetical). `SessionFlowUITests` and
/// `openPushDay`/`reachTrainScreen` already lean on that same property *within*
/// a class — the Back/Chip/Finish/History/History/Log/Partial chain only makes
/// sense in that exact alphabetical sequence, and the file header there has
/// always said so. Before the split, the two tests below sorted after all of
/// `SessionFlowUITests`'s methods inside one shared class (`Session...` and
/// `Train...` both start with letters past `B`, `C`, `F`, `H`, `L`, `P`), so
/// they always ran last and never had to think about what session state a
/// flow test had already created. Splitting into two classes kept the method
/// order inside each class but reset the question of order *between* classes
/// — and `AccessibilityAuditTests` sorted first (`A` < `S`), which flipped the
/// two groups: the audits ran first on CI, left a session draft behind exactly
/// as they always have, and `SessionFlowUITests` inherited it a run earlier
/// than before. `testBackAndNextExerciseAreSeparated` failed after 146s
/// resuming into that draft under CI's load — its own tolerance for "any
/// starting position" is real (see that file), but paying for an extra resume
/// hop, and for two full accessibility-tree walks happening immediately
/// before it, is not free under contention, and was never a cost this test
/// used to have to absorb. Naming this class so it still sorts after
/// `SessionFlowUITests` restores the exact sequence the whole suite always
/// ran in — audits last — while keeping the two kinds of test in the separate
/// files/classes #193 wanted them in.
final class SystemAuditUITests: ChickenBreastUITestCase {

    func testTrainScreenPassesSystemAudit() throws {
        let app = launch()
        // Either shape of the Train screen is valid; both must pass the audit.
        XCTAssertTrue(try reachTrainScreen(app),
                      "Train should offer a day to start or a workout to resume")
        let issues = try audit(app)
        // Printed rather than asserted to zero: the held-open types above are
        // known, and this is where the list to work through comes from.
        if !issues.isEmpty { print("Train screen a11y backlog:\n" + issues.joined(separator: "\n")) }
    }

    func testSessionScreenPassesSystemAudit() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")
        let issues = try audit(app)
        if !issues.isEmpty { print("Session screen a11y backlog:\n" + issues.joined(separator: "\n")) }
    }
}
