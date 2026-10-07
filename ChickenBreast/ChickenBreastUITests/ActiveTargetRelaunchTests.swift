import XCTest

/// All history is created through the UI, in the isolated UI-test store;
/// no launch-time seed and no real training data is involved.
final class ActiveTargetRelaunchTests: ChickenBreastUITestCase {

    func testStoredPerSetTargetSurvivesRelaunchAfterLogging() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic workout regression is restricted to the simulator.")
        #endif
        // The isolated, reset store every other UI test launches into (#285),
        // rather than whatever the simulator's real store holds: a resumed
        // draft or prior history used to skip this test, so CI, whose
        // simulator other tests have used, could never really run it.
        let locale = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Through the shared helper, which verifies the isolated store
        // really opened (#321). Relaunches below keep it, without a reset.
        let app = launch(arguments: locale)
        defer { app.terminate() }

        let resume = app.buttons["home.resume"]
        try openPushDay(app)
        startSessionIfPreviewed(app)

        let review = app.buttons["session.plan.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        // A fresh lift offers its recommendation as a suggestion (2026-10-07),
        // so the door reads "Change suggested plan"; a lift already started
        // reads "Edit set plan". The test only needs the plan sheet.
        XCTAssertTrue(["Change suggested plan", "Edit set plan"].contains(review.label), review.label)
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
        assertPendingReps(9, in: app)

        _ = launch(arguments: locale, freshState: false)
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        assertTarget(target, equals: expectedSecond)
        // The logging controls must restore the next stored target too.
        assertPendingReps(9, in: app)

        // Persist another set after relaunch and verify the third target is
        // selected, then reopen once more to guard against a replayed set.
        XCTAssertTrue(log.waitForExistence(timeout: 5) && log.isHittable)
        log.tap()
        assertTarget(target, equals: expectedThird)
        _ = launch(arguments: locale, freshState: false)
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        assertTarget(target, equals: expectedThird)
        assertPendingReps(8, in: app)
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement,
                        file: StaticString = #filePath, line: UInt = #line) {
        // The container this names may not exist after main's revamp (the
        // plan sheet is not always a collection view), so fall back to the
        // app, and give the element a moment to appear before swiping.
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<5 where !element.exists || !element.isHittable {
            (scrollView.exists ? scrollView : XCUIApplication()).swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) should be reachable", file: file, line: line)
    }

    /// The reps stepper's value (main's revamp replaced the rep chips this
    /// test first checked with a −/+ stepper).
    private func assertPendingReps(_ reps: Int, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let value = app.buttons["session.reps.value"]
        XCTAssertTrue(wait(for: value, toMatch: "value == '\(reps) reps'", timeout: 5),
                      "Expected \(reps) reps; stepper shows \(String(describing: value.value))",
                      file: file, line: line)
    }

    private func assertTarget(_ target: XCUIElement, equals expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "Expected stored target: \(expected); displayed: \(target.label)", file: file, line: line)
    }
}
