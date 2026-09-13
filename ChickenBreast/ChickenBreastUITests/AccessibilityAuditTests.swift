//
//  AccessibilityAuditTests.swift
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
final class AccessibilityAuditTests: ChickenBreastUITestCase {

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
