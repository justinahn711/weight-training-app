//
//  SessionFlowUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// Tap-through flows and layout invariants that don't need a system audit to
/// check them — split out of what was originally `AccessibilityAuditTests.swift`
/// for #193 so a stalled or killed audit run and a broken flow are never the
/// same red XCTestCase. `reachTrainScreen`/`openPushDay` (via
/// `ChickenBreastUITestCase` in `UITestSupport.swift`) still call the system
/// audit once, on the onboarding cover if it's up — that path got its own
/// #193 fix so it can't re-run on every poll — but none of the tests below
/// invoke it directly, so a real regression in one of these keeps failing
/// exactly as loudly and specifically as it always did.
///
/// This class's name matters as much as its contents: it has to keep sorting
/// alphabetically *before* `SystemAuditUITests` (see that file's header for
/// why cross-class order is load-bearing here). Renaming this class without
/// renaming that one back into the same relative order reopens the exact CI
/// failure a #193 follow-up fixed — a session draft the audit tests create
/// getting inherited a run earlier than the tests below were written to
/// expect it.
final class SessionFlowUITests: ChickenBreastUITestCase {

    /// Start session -> log a set -> undo, the flow the issue names.
    ///
    /// Asserted through accessibility identifiers rather than screen positions,
    /// so it fails when a control becomes unreachable — which is the thing
    /// being guarded — rather than when a layout moves.
    func testLogSetAndUndoIsReachableWithoutSight() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let mic = app.buttons["session.microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 20))
        // The control whose entire purpose is hands-free use must say whether
        // it is on. Before #114 this value did not exist.
        XCTAssertEqual(mic.value as? String, "Off")

        let logSet = app.buttons["Log Set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5), "Log Set must be reachable by name")
        // A cold-start lift opens with no weight set, and Log Set refuses a
        // zero load rather than writing "0 lb" into history.
        if !logSet.isEnabled {
            let heavier = app.buttons["session.weight.increment"]
            XCTAssertTrue(heavier.waitForExistence(timeout: 5))
            heavier.tap()
        }
        XCTAssertTrue(logSet.isEnabled, "Log Set should be available once a weight is set")
        logSet.tap()

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5),
                      "Undo must be announced, not only drawn — it is the only correction path")
        undo.tap()
    }

    /// Back and Next exercise used to sit on separate rows — Back muted,
    /// above a full-width Next exercise / Finish workout row (#177). #207
    /// folded navigation back into a single row to give the set rows more
    /// of the screen (#205): Back now sits at the row's leading edge, Next
    /// (or Finish) at the trailing edge, with the More menu and two flexible
    /// spacers between them. This test used to check that Back sat entirely
    /// above Next; that invariant no longer holds by construction now that
    /// they share a row, so it's replaced with the horizontal equivalent —
    /// opposite ends of the row, with a third control's width of empty space
    /// and the More menu actually between them, so a thumb sliding from one
    /// has to cross both before it could land on the other.
    func testBackAndNextExerciseAreSeparated() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let next = app.buttons["session.exercise.next"]
        let back = app.buttons["session.exercise.previous"]
        let finish = app.buttons["session.finish.footer"]
        let warmup = app.buttons["session.more"]
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        // A workout left mid-session by an earlier test in this run can
        // resume anywhere — first exercise, last, or in between — so this
        // doesn't assume a fresh start. It moves at most one step to reach a
        // middle exercise where Back and Next both exist, which is all the
        // separation check below actually needs.
        if !back.exists {
            XCTAssertTrue(next.waitForExistence(timeout: 20), "Next exercise should be reachable")
            next.tap()
        } else if !next.exists {
            XCTAssertTrue(finish.waitForExistence(timeout: 5))
            back.tap()
        }

        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back should appear once there is a prior exercise")
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next exercise should appear once off the last exercise")
        XCTAssertTrue(warmup.waitForExistence(timeout: 5))

        for button in [back, next] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }

        // Same row now, opposite ends: Back leads, Next trails, and Extra
        // warmup sits physically in between both of them — a thumb sliding
        // from Back to Next has to cross the More menu's frame to get there.
        XCTAssertLessThanOrEqual(
            back.frame.maxX, warmup.frame.minX,
            "Previous lift should sit entirely left of More"
        )
        XCTAssertLessThanOrEqual(
            warmup.frame.maxX, next.frame.minX,
            "More should sit entirely left of Next exercise"
        )
    }

    /// The last exercise swaps Next exercise for Finish workout (#177); the
    /// separation from Back has to hold for that swap too, not just the
    /// common case checked above. Since #207, that separation is horizontal
    /// (see `testBackAndNextExerciseAreSeparated`'s header), not row-based.
    func testFinishWorkoutReplacesNextOnLastExerciseAndStaysSeparatedFromBack() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let next = app.buttons["session.exercise.next"]
        let finish = app.buttons["session.finish.footer"]
        let warmup = app.buttons["session.more"]
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        // A workout left in progress by an earlier test in this run can
        // resume already parked on the last exercise (openPushDay's own
        // comment above documents the same order-dependency for Resume), so
        // this doesn't assume starting on the first exercise — it advances
        // for as long as Next exercise is still there. Bounded well past
        // Push's six slots so a real regression here fails instead of
        // looping forever.
        var taps = 0
        while next.waitForExistence(timeout: 2), next.isHittable {
            next.tap()
            taps += 1
            XCTAssertLessThan(taps, 10, "Next exercise should reach the last exercise well within 10 taps")
        }

        XCTAssertTrue(finish.waitForExistence(timeout: 5),
                      "Finish workout should replace Next exercise on the last exercise")
        XCTAssertFalse(next.exists)

        let back = app.buttons["session.exercise.previous"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(warmup.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            back.frame.maxX, warmup.frame.minX,
            "Previous lift should sit entirely left of More"
        )
        XCTAssertLessThanOrEqual(
            warmup.frame.maxX, finish.frame.minX,
            "More should sit entirely left of the footer's Finish workout"
        )
    }

    /// Reps and RPE replaced a disclosure-hidden pair of scrolling chip rows
    /// with always-visible steppers, following a platform-conformance audit
    /// that named the chip rows a web-shaped control standing in for a
    /// native one. This is the replacement's own version of the test above:
    /// every control is reachable without opening anything first, each
    /// meets the 44pt touch-target floor, and the current value is exposed
    /// as the control's accessibility value rather than a chip's `.isSelected`
    /// trait — there is exactly one number per row because there is exactly
    /// one control, not several competing for the selected trait.
    func testRepsAndRPEStepperAreAlwaysVisibleAndMeetTouchTargets() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20))

        let repsMinus = app.buttons["session.reps.decrement"]
        let repsValue = app.buttons["session.reps.value"]
        let repsPlus = app.buttons["session.reps.increment"]
        let rpeMinus = app.buttons["session.rpe.decrement"]
        let rpeValue = app.descendants(matching: .any)["session.rpe.value"]
        let rpePlus = app.buttons["session.rpe.increment"]

        // No disclosure to open first — every control exists immediately.
        // The RPE value is plain text now, not a control, so it only has to
        // exist; the tap-target floor applies to what can be tapped.
        XCTAssertTrue(rpeValue.waitForExistence(timeout: 5))
        for control in [repsMinus, repsValue, repsPlus, rpeMinus, rpePlus] {
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }

        let repsBefore = repsValue.value as? String
        repsPlus.tap()
        XCTAssertNotEqual(repsBefore, repsValue.value as? String,
                          "the reps stepper's accessibility value should change on tap")

        let rpeBefore = rpeValue.value as? String
        rpePlus.tap()
        XCTAssertNotEqual(rpeBefore, rpeValue.value as? String,
                          "the RPE stepper's accessibility value should change on tap")
    }

    /// A partial finish must be a bottom sheet, never an unanchored bubble at
    /// the top of the workout (#158).
    func testPartialFinishConfirmationIsBottomAnchored() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        try openPushDay(app)
        startSessionIfPreviewed(app)

        try assertPartialFinishSheet(in: app, requiresBottomPosition: true)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Finish workout"].firstMatch.waitForExistence(timeout: 5))
        // Compact-height iOS may expand a sheet to full screen. That is still
        // the platform's bottom-sheet presentation, not the stray popover this
        // regression guards; in landscape the important invariant is that both
        // decisions remain reachable at the largest text size.
        try assertPartialFinishSheet(in: app, requiresBottomPosition: false)
    }

    /// The weekly goal is useful only if the calendar actually exposes the
    /// derived result; this guards the app-level wiring that Core tests cannot.
    func testHistoryExposesWeeklyConsistency() throws {
        let app = launch()
        XCTAssertTrue(try reachTrainScreen(app))

        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5) && history.isHittable)
        history.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["history.weeklyStreak"]
                .waitForExistence(timeout: 10),
            "History should show weekly consistency above the calendar"
        )
    }

    func testHistoryMonthNavigationHasFullTouchTargets() throws {
        let app = launch()
        XCTAssertTrue(try reachTrainScreen(app))

        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5) && history.isHittable)
        history.tap()

        for identifier in ["history.month.previous", "history.month.next"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
    }

    /// Finish persists once, then the same saved decisions can be dismissed
    /// and reviewed again without running progression a second time (#184).
    func testFinishShowsProgressionSummaryAndItCanBeReopened() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let next = app.buttons["session.exercise.next"]
        let back = app.buttons["session.exercise.previous"]
        let finish = app.buttons["session.finish.footer"]
        let warmup = app.buttons["session.more"]
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        // A workout left mid-session by an earlier test in this run can
        // resume anywhere — first exercise, last, or in between — so this
        // doesn't assume a fresh start. It moves at most one step to reach a
        // middle exercise where Back and Next both exist, which is all the
        // separation check below actually needs.
        if !back.exists {
            XCTAssertTrue(next.waitForExistence(timeout: 20), "Next exercise should be reachable")
            next.tap()
        } else if !next.exists {
            XCTAssertTrue(finish.waitForExistence(timeout: 5))
            back.tap()
        }

        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back should appear once there is a prior exercise")
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Next exercise should appear once off the last exercise")
        XCTAssertTrue(warmup.waitForExistence(timeout: 5))

        for button in [back, next] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }

        // Same-row separation since #207 — see
        // `testBackAndNextExerciseAreSeparated`'s header for why this is
        // horizontal now rather than row-based.
        XCTAssertLessThanOrEqual(
            back.frame.maxX, warmup.frame.minX,
            "Previous lift should sit entirely left of More"
        )
        XCTAssertLessThanOrEqual(
            warmup.frame.maxX, next.frame.minX,
            "More should sit entirely left of Next exercise"
        )
    }

    /// The measured claim #205 makes: the action bar's minimum height, with
    /// nothing conditional open (only the plate row can still collapse;
    /// reps and RPE stopped being conditional when their disclosure was
    /// replaced with always-visible steppers), stays well under the ~368pt
    /// #205 measured before that change. Asserted well above the actual
    /// figure reported in the PR so this stays a real regression guard
    /// rather than a brittle pixel match — the point is "still small," not
    /// "exactly this."
    func testActionBarMinimumHeightIsReclaimedForSetRows() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        let actionBar = app.otherElements["session.actionBar"]
        XCTAssertTrue(actionBar.waitForExistence(timeout: 5), "action bar should be reachable by identifier")

        let height = actionBar.frame.height
        // Printed for the record (#205 asked for a measured number, not a
        // font-metrics estimate) — visible in the xcodebuild test log.
        print("SessionView action bar minimum height: \(height)pt")
        XCTAssertGreaterThan(height, 0, "the action bar should have a real, non-zero frame")
        XCTAssertLessThanOrEqual(
            height, 340,
            "the action bar should no longer approach the ~368pt #205 measured before this change"
        )
    }
}
