import XCTest

/// Run on a fresh disposable simulator. All history is created through the UI;
/// no launch-time seed branch or physical-device training data is involved.
final class ActiveTargetRelaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testStoredPerSetTargetSurvivesRelaunchAfterLogging() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic workout regression is restricted to the simulator.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let onboardingSave = app.buttons["splitEditor.save"]
        if onboardingSave.waitForExistence(timeout: 8), onboardingSave.isHittable {
            onboardingSave.tap()
        }
        let push = app.buttons["day.push"]
        let resume = app.buttons["home.resume"]
        if resume.waitForExistence(timeout: 2) {
            throw XCTSkip("Run this regression on a fresh simulator; an existing workout must remain untouched.")
        }
        XCTAssertTrue(push.waitForExistence(timeout: 20))
        push.tap()
        let start = app.buttons["Start workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()

        let review = app.buttons["session.plan.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        try XCTSkipUnless(review.label == "Review set plan", "A fresh simulator with no exercise history is required.")
        reveal(review, in: app.scrollViews.firstMatch)
        review.tap()
        XCTAssertTrue(app.navigationBars["Set plan"].waitForExistence(timeout: 5))

        // The seeded first Push movement has three 8-rep targets. Make set two
        // distinct so repeating the previous set after relaunch cannot pass.
        let secondReps = app.steppers["plan.reps.2"]
        reveal(secondReps, in: app.collectionViews.firstMatch)
        let increment = app.buttons["plan.reps.2-Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()
        let save = app.buttons["plan.save"]
        XCTAssertTrue(save.isHittable)
        save.tap()

        let target = app.staticTexts["session.target.line"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.label.hasPrefix("Set 1 of 3 · "), target.label)
        XCTAssertTrue(target.label.contains(" × 8 @ "), target.label)
        let expectedSecond = target.label
            .replacingOccurrences(of: "Set 1 of 3 · ", with: "Set 2 of 3 · ")
            .replacingOccurrences(of: " × 8 @ ", with: " × 9 @ ")
        let expectedThird = target.label.replacingOccurrences(of: "Set 1 of 3 · ", with: "Set 3 of 3 · ")

        let log = app.buttons["session.log-set"]
        XCTAssertTrue(log.waitForExistence(timeout: 5) && log.isHittable)
        log.tap()
        assertTarget(target, equals: expectedSecond)
        XCTAssertTrue(app.buttons["9 reps"].isSelected)

        app.terminate()
        app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        assertTarget(target, equals: expectedSecond)
        XCTAssertTrue(app.buttons["9 reps"].isSelected,
                      "the logging controls must restore the next stored target too")
        XCTAssertFalse(app.buttons["8 reps"].isSelected)

        // Persist another set after relaunch and verify the third target is
        // selected, then reopen once more to guard against a replayed set.
        XCTAssertTrue(log.waitForExistence(timeout: 5) && log.isHittable)
        log.tap()
        assertTarget(target, equals: expectedThird)
        app.terminate()
        app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        assertTarget(target, equals: expectedThird)
        XCTAssertTrue(app.buttons["8 reps"].isSelected)
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<5 where !element.exists || !element.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func assertTarget(_ target: XCUIElement, equals expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "Expected stored target: \(expected); displayed: \(target.label)", file: file, line: line)
    }
}
