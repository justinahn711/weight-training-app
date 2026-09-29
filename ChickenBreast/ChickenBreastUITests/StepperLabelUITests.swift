//
//  StepperLabelUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// The four Form rows that pair a label with a system `Stepper` — Weekly
/// goal and Bar in Settings, Weight and Reps in Correct set — keep their
/// label words whole at the largest accessibility text size (#250).
///
/// Before the fix, `Stepper { LabeledContent(label, value:) }` left the label
/// whatever width remained beside the value and Apple's fixed 94pt −/+
/// control, and at AccessibilityXXXL that was narrower than one word:
/// "Wee / kly / goal", "Weig / ht". The audit never named it — neither
/// `.dynamicType` nor `.textClipped` fires on a mid-word wrap — so this
/// measures the row instead.
///
/// What it asserts is the stacked layout: the label and value sit on their
/// own lines above the control, so the control no longer takes width from
/// them. Read off the accessibility tree as two facts: the stepper element is
/// only as wide as its −/+ buttons (nothing shares their line), and the
/// buttons sit at least one text line below the top of their cell (the label
/// is above them). The visible label is hidden from VoiceOver in that layout
/// because the stepper still carries it — which is the other half of this:
/// the stepper's label must still read "Weekly goal, 3 days", so the value is
/// announced exactly as it was.
///
/// Launched with the short `UICTContentSizeCategoryAccessibilityXXXL` raw
/// value; the long spelling is silently ignored (see `SessionFlowUITests`).
final class StepperLabelUITests: ChickenBreastUITestCase {

    private static let accessibilityXXXL = [
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
    ]

    func testSettingsStepperRowsStackAtAccessibilityText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: Self.accessibilityXXXL)
        XCTAssertTrue(try reachTrainScreen(app))

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()

        // "3 days" / "1 day" and "45 lb" / "20 kg": whatever the stored value
        // is, it has to be in the label, followed by its unit.
        try assertStackedStepper(in: app, title: "Weekly goal", valuePattern: "\\d+ days?")
        try assertStackedStepper(in: app, title: "Bar", valuePattern: "[0-9.]+ (lb|kg)")
    }

    func testCorrectSetStepperRowsStackAtAccessibilityText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: Self.accessibilityXXXL)
        XCTAssertTrue(try reachTrainScreen(app))

        try openTodayInHistory(app)

        // Any set row opens the corrector; set rows are the only buttons in
        // the day's list whose label carries a weight.
        let rows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] ' lb' OR label CONTAINS[c] ' kg'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10),
                      "today's workout should list at least one set")
        rows.firstMatch.tap()

        try assertStackedStepper(in: app, title: "Weight", valuePattern: "[0-9.]+ (lb|kg)")
        try assertStackedStepper(in: app, title: "Reps", valuePattern: "\\d+")

        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
    }

    // MARK: - Measurement

    private func assertStackedStepper(
        in app: XCUIApplication,
        title: String,
        valuePattern: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let stepper = app.steppers
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), "))
            .firstMatch
        var swipes = 0
        while !(stepper.exists && stepper.isHittable), swipes < 12 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(stepper.exists, "the \(title) stepper should be reachable", file: file, line: line)

        // VoiceOver: the value is still part of the stepper's own label, the
        // way it was before (#250 acceptance) — "Weekly goal, 3 days".
        let label = stepper.label
        XCTAssertNotNil(
            label.range(of: "^\(title), \(valuePattern)$", options: .regularExpression),
            "\(title) stepper should still announce its value; label was \"\(label)\"",
            file: file, line: line
        )
        let increment = app.buttons["\(label), Increment"]
        let decrement = app.buttons["\(label), Decrement"]
        XCTAssertTrue(increment.exists && decrement.exists,
                      "\(title)'s −/+ buttons should read the label and value too",
                      file: file, line: line)

        let cell = app.cells.containing(
            NSPredicate(format: "elementType == %lu AND label == %@",
                        XCUIElement.ElementType.stepper.rawValue, label)
        ).firstMatch
        XCTAssertTrue(cell.exists, "the \(title) stepper should sit in a Form cell", file: file, line: line)

        let controls = decrement.frame.union(increment.frame)
        let measured = "\(title): cell=\(cell.frame) stepper=\(stepper.frame) " +
            "decrement=\(decrement.frame) increment=\(increment.frame)"
        print("STEPPER-FRAME|\(measured)")
        XCTContext.runActivity(named: "measured \(title)") { activity in
            activity.add(.init(string: measured))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(title) at AccessibilityXXXL"
            shot.lifetime = .keepAlways
            activity.add(shot)
        }

        // Nothing shares the control's line: before the fix the stepper
        // element spanned the whole row (label + value + control, 311pt on
        // an SE) and the label wrapped mid-word in what was left.
        XCTAssertLessThanOrEqual(
            stepper.frame.width, controls.width + 1,
            "\(title) should stack above its stepper at AccessibilityXXXL, " +
            "not share the control's line — \(measured)",
            file: file, line: line
        )
        // And the label is above it: at least one accessibility-size line
        // (~60pt at XXXL body) between the cell's top and the buttons.
        XCTAssertGreaterThanOrEqual(
            controls.minY - cell.frame.minY, 44,
            "\(title)'s label and value should sit above the stepper — \(measured)",
            file: file, line: line
        )
    }

    // MARK: - Navigation

    /// Opens today's workout in History, logging and finishing one set first
    /// if today has none — the corrector only exists for a logged set.
    private func openTodayInHistory(_ app: XCUIApplication) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let todayID = "history.day.\(formatter.string(from: Date()))"

        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5) && history.isHittable)
        history.tap()

        if !(scrollTo(app.descendants(matching: .any)[todayID], in: app)) {
            // Nothing logged today yet: log one set and finish, then return.
            let train = app.tabBars.buttons.element(boundBy: 0)
            train.tap()
            try logOneSetAndFinish(app)
            XCTAssertTrue(history.waitForExistence(timeout: 10))
            history.tap()
        }
        let today = app.descendants(matching: .any)[todayID]
        XCTAssertTrue(scrollTo(today, in: app), "today should be a trained, tappable day in History")
        today.tap()
    }

    private func logOneSetAndFinish(_ app: XCUIApplication) throws {
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["Log Set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20))
        if !logSet.isEnabled {
            let heavier = app.buttons["session.weight.increment"]
            XCTAssertTrue(heavier.waitForExistence(timeout: 5))
            heavier.tap()
        }
        var swipes = 0
        while !logSet.isHittable, swipes < 4 { app.swipeUp(); swipes += 1 }
        logSet.tap()
        Thread.sleep(forTimeInterval: 1)
        let stay = app.buttons["Stay"]
        if stay.exists && stay.isHittable { stay.tap() }

        let finish = app.buttons["Finish workout"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        swipes = 0
        while !finish.isHittable, swipes < 4 { app.swipeUp(); swipes += 1 }
        finish.tap()
        let confirm = app.buttons["finish.confirmation.finish"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        let done = app.buttons["completion.done"]
        if done.waitForExistence(timeout: 25) {
            swipes = 0
            while !done.isHittable, swipes < 4 { app.swipeUp(); swipes += 1 }
            done.tap()
        }
        XCTAssertTrue(try reachTrainScreen(app, timeout: 15))
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 5), element.isHittable { return true }
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element.exists && element.isHittable
    }
}
