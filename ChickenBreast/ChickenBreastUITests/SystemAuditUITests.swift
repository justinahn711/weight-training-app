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
/// so it sorted after `SessionFlowUITests` (#193 follow-up, PR #196): without
/// a test plan, classes run alphabetically, and every test then inherited the
/// session draft the one before it left — so which class ran first changed
/// what each one saw. That stopped being true in #285: every test launches
/// from an empty isolated store (`launch(arguments:freshState:)`), so order
/// no longer decides the state an audit runs in. The name stays; nothing
/// depends on it any more.
///
/// This class is the only one that audits (#285). The onboarding cover used
/// to be audited inside `reachTrainScreen`, i.e. by whichever test launched
/// first on a just-booted CI simulator, which is where the -56 stalls on
/// PRs #282 and #286 happened; it has its own test below instead. Each
/// screen is audited once per run, here, with every gating type.
final class SystemAuditUITests: ChickenBreastUITestCase {

    func testTrainScreenPassesSystemAudit() throws {
        let app = launch()
        // Either shape of the Train screen is valid; both must pass the audit.
        XCTAssertTrue(reachTrainScreen(app),
                      "Train should offer a day to start or a workout to resume")
        let issues = try audit(app)
        // Printed rather than asserted to zero: the held-open types above are
        // known, and this is where the list to work through comes from.
        if !issues.isEmpty { print("Train screen a11y backlog:\n" + issues.joined(separator: "\n")) }
    }

    /// The split cover a first launch shows over Train (#136). Always up now,
    /// since every test starts from an empty store (#285).
    func testOnboardingCoverPassesSystemAudit() throws {
        let app = launch()
        let save = app.buttons["splitEditor.save"]
        XCTAssertTrue(wait(for: save, toMatch: "hittable == true", timeout: 30),
                      "a first launch should ask for the training split")
        let issues = try audit(app)
        if !issues.isEmpty { print("Onboarding cover a11y backlog:\n" + issues.joined(separator: "\n")) }
    }

    /// Audited on a fresh Push session: the first exercise, nothing logged,
    /// no rest running. Before #285 this inherited whatever draft
    /// `SessionFlowUITests` left, sometimes with a rest on screen, which is
    /// the state #289's "RESTING" finding needs; that state is #289's to
    /// decide and test on purpose, not this test's to inherit by accident.
    func testSessionScreenPassesSystemAudit() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")
        let issues = try audit(app)
        if !issues.isEmpty { print("Session screen a11y backlog:\n" + issues.joined(separator: "\n")) }
    }

    /// The same screen with a rest running (#289). Its own test, on purpose,
    /// rather than a rest folded into the one above: the session spends most
    /// of its time in one of these two states, both have to pass, and each
    /// test decides its state instead of inheriting it. The rest is started
    /// from More so no set is logged and the card above the bar stays what
    /// the no-rest audit saw.
    func testSessionScreenWithRestRunningPassesSystemAudit() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let more = app.buttons["session.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the session screen should be up")
        more.tap()
        let startRest = app.buttons["session.more.startRest"]
        XCTAssertTrue(startRest.waitForExistence(timeout: 5))
        startRest.tap()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 5),
                      "the rest bar should be on screen before the audit runs")
        let issues = try audit(app)
        if !issues.isEmpty { print("Session screen (resting) a11y backlog:\n" + issues.joined(separator: "\n")) }
    }

    /// The lift library is the second door into `ExerciseConfigView` (#178)
    /// — the one that works without being mid-session on a specific lift.
    /// This guards that the door is actually reachable from Settings, that
    /// its rows carry real 44pt tap targets rather than the
    /// frame-without-`contentShape` mistake #114 already shipped once on a
    /// different screen, and that the screen passes the same system audit
    /// every other screen here answers to.
    func testLiftLibraryIsReachableFromSettingsAndPassesAudit() throws {
        let app = launch()
        XCTAssertTrue(reachTrainScreen(app))

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()

        // Settings is a long Form — the split, gym, and eight-plate-toggle
        // sections all sit above this one, so the row is real but genuinely
        // off-screen until scrolled to, not merely slow to appear.
        let liftLibrary = app.buttons["settings.liftLibrary"]
        var attempts = 0
        while !liftLibrary.exists, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(liftLibrary.waitForExistence(timeout: 5),
                      "Lift library should be reachable from Settings")
        liftLibrary.tap()

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'liftLibrary.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10),
                      "the library should list at least one lift from the seeded library")

        let first = rows.element(boundBy: 0)
        XCTAssertGreaterThanOrEqual(first.frame.width, 44)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)

        let issues = try audit(app)
        if !issues.isEmpty { print("Lift library a11y backlog:\n" + issues.joined(separator: "\n")) }

        // Opens the same sheet the session's config line does — one editor,
        // two doors into it — and closes it without saving.
        first.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "the reused ExerciseConfigView should present its usual Cancel/Save toolbar")
        cancel.tap()
    }
}
