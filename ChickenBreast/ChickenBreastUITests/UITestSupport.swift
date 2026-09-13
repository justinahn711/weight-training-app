//
//  UITestSupport.swift
//  ChickenBreastUITests
//

import XCTest

/// The first automated coverage the app target has ever had (#114).
///
/// Every rung before this one verified the domain. `swift test` cannot import
/// a SwiftUI view, so the 670+ tests guarding progression, plate math and
/// parsing have never executed a line of the code that puts them on screen —
/// which is why eleven consecutive PRs passed every check and still came back
/// from device review with something real.
///
/// This does not close that gap; a UI test is slow, boots a simulator, and can
/// only reach what it can tap. It closes the specific part of it that a person
/// re-checking by hand is worst at: `AccessibilityAuditTests` runs the
/// system's own accessibility audit, which is mechanical, exhaustive within a
/// screen, and never gets bored.
///
/// Split out of `AccessibilityAuditTests.swift` for #193: that file used to
/// hold the audit tests and the tap-through flow tests (`testLogSetAndUndo`
/// and friends) in one `XCTestCase`, so a red run never said, at a glance,
/// whether the audit had stalled or a flow had actually broken. Both kinds of
/// test still reach a screen the same way — through `reachTrainScreen` and
/// `openPushDay` below — so that logic lives once, here, rather than getting
/// forked into two answers that drift.
class ChickenBreastUITestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Deliberately no launch arguments. A `-seed-sample-data` flag would
        // need a branch in the real launch path, and a test-only branch in
        // production startup is a liability that outlives the test. The suite
        // runs against a freshly installed simulator app instead, whose seeded
        // library is deterministic on its own.
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// The system's own audit, which catches what a hand-written expectation
    /// forgets to ask about: contrast, hit-region size, clipped text at larger
    /// type, and elements with no label at all.
    /// Issue types held open, with the reason each is still failing.
    ///
    /// Not a way to make the suite green. An entry here is a defect that has
    /// been seen, named and left — the audit still runs, still reports it, and
    /// the moment it stops firing the entry becomes a lie the next person
    /// deletes. What it prevents is a suite that fails for a known reason,
    /// because that suite gets ignored and then stops being run at all.
    ///
    /// Empty is the goal. Seven contrast and hit-area defects the audit named
    /// on its first run were fixed in this change. What is held open needs a
    /// layout decision rather than a colour swap:
    ///
    /// - `.dynamicType` — the session's set counter, exercise name, config
    ///   line and the Next/Dumbbell-rack labels are laid out at fixed sizes.
    ///   Letting them grow is #113's compact-layout work, not a one-line fix.
    /// - `.textClipped` — the same lines, seen from the other side.
    /// - `.contrast` — one case remains on the session screen, inside a
    ///   control whose colours carry meaning; recolouring it needs the design
    ///   answer #138 is already circling.
    static let knownIssues: XCUIAccessibilityAuditType = [
        .contrast,
        .textClipped,
        .dynamicType,
    ]

    /// Runs the audit and names every element that fails.
    ///
    /// `performAccessibilityAudit()` reports "Hit area is too small" and stops
    /// there, which tells you a control is wrong and not which one. The handler
    /// logs the element and its frame before deciding, so a failure arrives
    /// with the thing to go and fix.
    ///
    /// Two changes here are for #193, both aimed at `Audit failed to complete
    /// in time` (XCTest code -56) — observed at 41s on a CI run that touched
    /// only a Core string (PR #189), and locally between 37s and 909s on
    /// identical code. That spread is the tell: the audit isn't uniformly
    /// slow, it stalls, and the stall scales with whatever else is competing
    /// for the machine.
    ///
    /// 1. The handler used to build `issue.element?.debugDescription` for
    ///    every issue. Apple's own header comment for `debugDescription` says
    ///    it may include "the entire tree of descendants rooted at the
    ///    element" — each descendant is a synchronous round trip to the app
    ///    process. `.contrast`, `.textClipped` and `.dynamicType` are held
    ///    open (see `knownIssues` above) precisely because they keep firing,
    ///    so this ran on every audit, for every element they name, inside the
    ///    same time budget `performAccessibilityAudit` is racing against to
    ///    avoid -56. Under CPU contention one slow round trip becomes several,
    ///    which is a plausible way for 37s to become 909s without the diff
    ///    changing at all. Replaced with `elementType`, `identifier`, `label`
    ///    and `frame` — four properties of the one element itself, no subtree
    ///    walk, and `frame` is more directly useful than a debug dump anyway
    ///    for the class of defect (#114) this audit exists to catch.
    /// 2. `performAccessibilityAudit` throws when it cannot complete, which is
    ///    a different failure from "it completed and found something" — a
    ///    real finding is recorded as an `XCTIssue` by the audit itself,
    ///    independent of what this method does with the thrown error. So
    ///    retrying here, on that specific thrown error only, cannot hide a
    ///    real finding — there is nothing for it to hide. It retries once: a
    ///    stall from contention on the runner is not reproducible evidence of
    ///    a defect, but retrying more than once would stop being an honest
    ///    signal that something is actually wrong with the environment.
    ///
    /// - Returns: the issues seen, so a caller can assert on them.
    @discardableResult
    func audit(_ app: XCUIApplication,
               file: StaticString = #filePath,
               line: UInt = #line) throws -> [String] {
        do {
            return try runAuditOnce(app)
        } catch let error as NSError where Self.isAuditTimeout(error) {
            XCTContext.runActivity(named: "a11y audit stalled once, retrying (#193)") {
                $0.add(.init(string: error.localizedDescription))
            }
            do {
                return try runAuditOnce(app)
            } catch let secondError as NSError where Self.isAuditTimeout(secondError) {
                // Failed to finish twice in a row. Worded so it never reads as
                // a finding (#193's whole point): nothing was audited, nothing
                // was found, the audit itself did not complete.
                XCTFail(
                    "Accessibility audit did not finish (twice in a row) — " +
                    "this is an infrastructure stall, not a reported a11y " +
                    "issue (#193): \(secondError.localizedDescription)",
                    file: file, line: line
                )
                return []
            }
        }
    }

    private func runAuditOnce(_ app: XCUIApplication) throws -> [String] {
        var seen: [String] = []
        try app.performAccessibilityAudit { issue in
            let element = Self.describe(issue.element)
            let detail = "\(issue.auditType): \(issue.detailedDescription ?? "no detail") — \(element)"
            seen.append(detail)
            XCTContext.runActivity(named: "a11y issue") { $0.add(.init(string: detail)) }
            // Suppressed only for the types listed above, and every issue is
            // still recorded either way — so a held-open type reports the same
            // detail it always did, it simply does not fail the run.
            return Self.knownIssues.contains(issue.auditType)
        }
        return seen
    }

    /// A cheap stand-in for `debugDescription` (see `audit(_:)` above): four
    /// properties XCTest already resolved for this one element, none of which
    /// walk its descendants the way `debugDescription` documents that it does.
    private static func describe(_ element: XCUIElement?) -> String {
        guard let element else { return "unknown element" }
        return "\(element.elementType) id=\"\(element.identifier)\" label=\"\(element.label)\" frame=\(element.frame)"
    }

    /// Matched on code and message rather than domain: the domain XCTest uses
    /// for this error isn't in the public headers, and the evidence this
    /// fix is built on (#189's CI failure, and the local repros in #193) is
    /// the code and the message text, not a private string we'd be guessing
    /// at. Deliberately narrow — this must never catch an assertion failure,
    /// only "the audit itself did not complete."
    private static func isAuditTimeout(_ error: NSError) -> Bool {
        error.code == -56
            && error.localizedDescription.localizedCaseInsensitiveContains("failed to complete in time")
    }

    // MARK: - Shared navigation

    /// Answers first-launch setup when it covers Train, then waits for a day
    /// or resumable workout that can actually receive a tap.
    @discardableResult
    func reachTrainScreen(_ app: XCUIApplication,
                          timeout: TimeInterval = 30) throws -> Bool {
        let push = app.buttons["day.push"]
        let resume = app.buttons["home.resume"]
        let save = app.buttons["splitEditor.save"]

        // Audited at most once per call (#193). This loop polls every 200ms
        // while onboarding is up, and `save.tap()` doesn't dismiss the cover
        // instantly — under load the animation can still be mid-flight on the
        // next poll, which used to mean `save.exists && save.isHittable` was
        // still true and the audit ran again before the tap had even landed.
        // A full audit inside a 200ms polling loop, potentially repeated for
        // as long as the transition is slow to settle, is its own way to turn
        // a contended machine into a multi-minute stall independent of the
        // -56 fix above.
        var auditedOnboarding = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Elements behind a full-screen cover still exist in XCUI's
            // hierarchy. Handle the cover first and require the destination
            // controls to be hittable so a hidden day never wins this race.
            if save.exists && save.isHittable {
                if !auditedOnboarding {
                    auditedOnboarding = true
                    let issues = try audit(app)
                    if !issues.isEmpty {
                        print("Onboarding cover a11y backlog:\n" + issues.joined(separator: "\n"))
                    }
                }
                save.tap()
            }
            if (push.exists && push.isHittable) || (resume.exists && resume.isHittable) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Opens the Push day, waiting for the store to finish its first load.
    ///
    /// The wait is generous because launch does real work — seeding the
    /// library, deduplicating, reconciling the gym — and a first launch on a
    /// cold simulator is the slowest this ever gets.
    func openPushDay(_ app: XCUIApplication) throws {
        XCTAssertTrue(try reachTrainScreen(app), "the Train screen should become reachable")
        // A workout left in progress by an earlier test replaces the day list
        // with Resume — correct behaviour (#132), and it makes these tests
        // order-dependent. Adopting the draft is the honest reaction: the goal
        // is to be in a session, and resuming reaches one.
        let resume = app.buttons["home.resume"]
        if resume.exists && resume.isHittable {
            resume.tap()
            return
        }
        let push = app.buttons["day.push"]
        XCTAssertTrue(push.waitForExistence(timeout: 5) && push.isHittable,
                      "the Push day should be offered and tappable")
        push.tap()
    }

    /// #137 put a roster in front of the session. Tolerated rather than
    /// assumed, so this suite keeps working whichever way that screen goes.
    func startSessionIfPreviewed(_ app: XCUIApplication) {
        let start = app.buttons["Start workout"]
        if start.waitForExistence(timeout: 8) {
            start.tap()
        }
    }

    func assertPartialFinishSheet(
        in app: XCUIApplication,
        requiresBottomPosition: Bool
    ) throws {
        let finish = app.buttons["Finish workout"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 20) && finish.isHittable)
        finish.tap()

        let sheet = app.descendants(matching: .any)["finish.confirmation.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        if requiresBottomPosition {
            XCTAssertGreaterThan(
                sheet.frame.minY,
                app.frame.height * 0.35,
                "partial-finish confirmation should rise from the bottom, not float near the top"
            )
        }
        XCTAssertTrue(app.buttons["finish.confirmation.finish"].isHittable)

        let keepTraining = app.buttons["finish.confirmation.cancel"]
        XCTAssertTrue(keepTraining.isHittable)
        keepTraining.tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 1))
    }
}
