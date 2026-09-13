//
//  SessionFlowUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// Tap-through flows and layout invariants that don't need a system audit to
/// check them — split out of `AccessibilityAuditTests.swift` for #193 so a
/// stalled or killed audit run and a broken flow are never the same red
/// XCTestCase. `reachTrainScreen`/`openPushDay` (via `ChickenBreastUITestCase`
/// in `UITestSupport.swift`) still call the system audit once, on the
/// onboarding cover if it's up — that path got its own #193 fix so it can't
/// re-run on every poll — but none of the tests below invoke it directly, so
/// a real regression in one of these keeps failing exactly as loudly and
/// specifically as it always did.
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
        logSet.tap()

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5),
                      "Undo must be announced, not only drawn — it is the only correction path")
        undo.tap()
    }

    /// Back and Next exercise used to sit side by side, adjacent, and moving
    /// in opposite directions (#177). Both already carry 44pt hit areas from
    /// #114, so this guards the thing #114 didn't: that a mis-tap between
    /// them isn't one slide of a thumb away. Back is now a muted control on
    /// its own row, entirely above the full-width Next exercise / Finish
    /// workout row below it.
    func testBackAndNextExerciseAreSeparated() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let next = app.buttons["session.exercise.next"]
        let back = app.buttons["session.exercise.previous"]
        let finish = app.buttons["session.finish.footer"]
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

        for button in [back, next] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }

        // Separated by row, not merely by width: Back sits entirely above
        // Next exercise rather than beside it, where a thumb sliding to the
        // common action could clip the correction instead.
        XCTAssertLessThanOrEqual(
            back.frame.maxY, next.frame.minY,
            "Back and Next exercise should occupy separate rows, not sit side by side"
        )
    }

    /// The last exercise swaps Next exercise for Finish workout (#177); the
    /// separation from Back has to hold for that swap too, not just the
    /// common case checked above.
    func testFinishWorkoutReplacesNextOnLastExerciseAndStaysSeparatedFromBack() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let next = app.buttons["session.exercise.next"]
        let finish = app.buttons["session.finish.footer"]
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
        XCTAssertLessThanOrEqual(
            back.frame.maxY, finish.frame.minY,
            "Back and the footer's Finish workout should stay on separate rows"
        )
    }

    /// Selection on the rep and RPE chips has to survive being unseen.
    func testChipSelectionIsExposedAsATrait() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20))

        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'rpe.'"))
        XCTAssertGreaterThan(chips.count, 0, "RPE chips should carry stable identifiers")

        var selected = 0
        for index in 0..<chips.count where chips.element(boundBy: index).isSelected {
            selected += 1
        }
        // Exactly one: a row where none is selected reads as "no RPE chosen"
        // when one plainly is, and more than one is incoherent.
        XCTAssertEqual(selected, 1, "exactly one RPE chip should report the selected trait")
    }

    /// A partial finish must be a bottom sheet, never an unanchored bubble at
    /// the top of the workout (#158).
    func testPartialFinishConfirmationIsBottomAnchored() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
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
}
