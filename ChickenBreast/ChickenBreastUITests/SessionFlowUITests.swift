//
//  SessionFlowUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// Tap-through flows and layout invariants that don't need a system audit to
/// check them — split out of what was originally `AccessibilityAuditTests.swift`
/// for #193 so a stalled or killed audit run and a broken flow are never the
/// same red XCTestCase. Nothing in this class runs the system audit any more:
/// `reachTrainScreen` used to audit the onboarding cover, which made the
/// first test of every CI run the one that paid for an audit on a
/// just-booted simulator — and the one that failed with -56 (#285). The
/// cover is audited in `SystemAuditUITests` now.
///
/// Each test launches from an empty isolated store (#285), so none of them
/// inherits a draft, a rest or a logged set from the test before it, and the
/// class's name no longer has to sort in any particular place.
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
        makeLogSetAvailable(app, logSet)
        logSet.tap()

        // The set is confirmed by its own row, and Undo is on that row — not
        // on a banner repeating it (#337).
        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should be the newest row under Today")
        let undo = app.buttons["session.set.latest.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5),
                      "Undo must be announced, not only drawn — it is the only correction path")
        XCTAssertEqual(undo.label, "Undo")
        assertUndo(undo, sitsBeside: latest)
        assertNoLoggedSetBanner(app)
        undo.tap()
        XCTAssertTrue(wait(for: latest, toMatch: "exists == false", timeout: 5),
                      "Undo should take back the set whose row it sits on")
        XCTAssertFalse(undo.exists, "with the set gone there is nothing left to undo")
    }

    /// Owner's gym test (#337): the stack read "1  20 lb × 20", then "Set
    /// logged 20 lb × 20 · Undo", then "Log 20 lb × 20" — the same numbers
    /// three times in ~200pt. The row and the dock's next-set button are the
    /// two that belong; nothing else above the dock may repeat the numbers.
    ///
    /// Read off the row's own label rather than hard-coded, since a cold
    /// lift's first weight is whatever one increment makes it. Both spellings
    /// are looked for: the row reads "20 lb × 20", but the banner's
    /// accessibility label was "Set logged, 20 lb, 20 reps" — a check on the
    /// first form alone could never have seen it. Checked before anything
    /// that depends on Undo's identifier, so it says what it found on any
    /// build that still has a banner.
    func testLoggedSetNumbersAppearOnceAboveTheDock() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)
        logSet.tap()

        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should have a spot above the dock")
        let numbers = try XCTUnwrap(Self.loadAndReps(in: latest.label),
                                    "the newest row should read as load × reps (label: \(latest.label))")
        let parts = numbers.components(separatedBy: " × ")
        let spoken = "\(parts[0]), \(parts[1]) reps"
        // The rest bar springs in; frames are read after it has.
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot("337-logged-once")

        assertNoLoggedSetBanner(app)
        let barTop = app.otherElements["session.actionBar"].frame.minY
        // Anything that shows above the dock, wholly or in part: a banner
        // sitting a few points under its top edge is still on screen.
        let repeats = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", numbers, spoken))
            .allElementsBoundByIndex
            .filter { !$0.frame.isEmpty && $0.frame.minY < barTop }
        // The row and its own text sit inside the row's frame; a second
        // copy elsewhere above the dock is the banner this issue removed.
        let row = latest.frame.insetBy(dx: -1, dy: -1)
        for element in repeats {
            XCTAssertTrue(row.contains(element.frame),
                          "\(numbers) is repeated outside the newest row above the dock: "
                          + "\(element.elementType) id=\"\(element.identifier)\" label=\"\(element.label)\" frame=\(element.frame)")
        }
        XCTAssertFalse(repeats.isEmpty, "the newest row should show \(numbers) above the dock")
        XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5))
    }

    /// Undo has to be there when the hand reaches for it, on the smallest
    /// supported screen, five working sets in — and so does the lift's name,
    /// which is what the lifter is there to read between sets. The banner was
    /// pinned above the dock, so it was always in view and nothing scrolled;
    /// the just-logged row keeps that slot (#337). Checked after every set,
    /// not only the last: scrolling the Today list to its newest row costs
    /// the header once the list outgrows the screen, which on an iPhone 17 is
    /// the fourth set. Run on the SE and on an iPhone 17: regular portrait
    /// lists every row, the compact layout shows only the newest set.
    func testUndoIsOnScreenWithFiveWorkingSetsLogged() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)

        let latest = app.buttons["session.set.latest"]
        let undo = app.buttons["session.set.latest.undo"]
        for count in 1...5 {
            tapWhenSettled(logSet)
            XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '\(count),'", timeout: 10),
                          "set \(count) should be the newest row (label: \(latest.label))")
            XCTAssertTrue(undo.waitForExistence(timeout: 5), "set \(count) should carry Undo")
            // Settled: the rest bar springs in above the context.
            Thread.sleep(forTimeInterval: 1)
            assertContextInView(app, "fresh lift, set \(count)", expectsStay: false)
        }
        attachScreenshot("337-five-sets")
        let window = app.windows.firstMatch.frame
        let barTop = app.otherElements["session.actionBar"].frame.minY
        XCTAssertTrue(window.contains(undo.frame), "Undo should be wholly on screen (\(undo.frame) in \(window))")
        XCTAssertLessThanOrEqual(latest.frame.maxY, barTop + 0.5, "the newest row should sit wholly above the dock")
        assertUndo(undo, sitsBeside: latest)

        // One tap, and it took back the fifth set — not an older one.
        undo.tap()
        XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '4,'", timeout: 5),
                      "Undo should remove the fifth set and leave the fourth as the newest")
    }

    /// The case the gym actually opens on: a lift with history, so the full
    /// plan card is up, and a first set that matches last time's count — which
    /// arms Next up in the same moment the rest begins (#337). Everything a
    /// lifter needs after that set has to be on screen at once: the lift's
    /// name, Next up's Stay (the card says the screen will move on its own),
    /// and the new set's Undo. Measured against the dock and the bars rather
    /// than asked of `isHittable`, which calls an element hittable while its
    /// lower half is under the dock.
    ///
    /// Bringing the new row into view by scrolling to it fails this: with
    /// the card and the rest bar still arriving, the row lands below the dock
    /// on an iPhone 17, and on an SE the header goes to y=-80 and Stay sits
    /// under the navigation bar.
    func testHistoryFirstSetKeepsLiftNextUpAndUndoInView() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: ["-UITestSeedYesterday"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)
        tapWhenSettled(logSet)

        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should have a spot above the dock")
        let stay = app.buttons["session.nextUp.stay"]
        XCTAssertTrue(stay.waitForExistence(timeout: 5),
                      "the set that matches yesterday's count should arm Next up")
        // Everything has arrived: the rest bar and Next up spring in.
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot("337-history-first-set")
        assertContextInView(app, "history, set 1", expectsStay: true)
        assertNoLoggedSetBanner(app)
    }

    /// The same lift three sets in. Every log must leave the lift's name and
    /// the new set's Undo on screen, not only the first (#337): the Today
    /// list grows under the card, and a scroll that chased the newest row
    /// would take the header away on the second and third sets.
    func testHistoryFirstThreeSetsKeepLiftNameAndUndoInView() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: ["-UITestSeedYesterday"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)

        let latest = app.buttons["session.set.latest"]
        for count in 1...3 {
            tapWhenSettled(logSet)
            XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '\(count),'", timeout: 10),
                          "set \(count) should be the newest row (label: \(latest.label))")
            XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5),
                          "set \(count) should carry Undo")
            Thread.sleep(forTimeInterval: 2)
            // Stay is asserted on the set that arms it, and wherever else it
            // is still up, but is not required of the later sets.
            attachScreenshot("337-history-set-\(count)")
            assertContextInView(app, "history, set \(count)", expectsStay: count == 1)
        }
    }

    /// At the largest text size the set row stacks Undo under the set rather
    /// than beside it. Undo is then on screen and tappable, and still takes
    /// the set back (#337).
    ///
    /// With the rest skipped first, on purpose: at this size a running rest
    /// card is ~220pt tall and leaves the context a strip about 20pt high on
    /// an SE, so nothing in it is visible, whether it is the Undo on a row or
    /// the banner that used to hold it. That squeeze belongs to the rest card
    /// (#339), not to this row; the named VoiceOver action is not affected.
    func testUndoIsReachableAtAccessibilityTextOnceTheRestIsOutOfTheWay() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)
        tapWhenSettled(logSet)

        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should have a row")
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "a working set should start a rest")
        tapWhenSettled(skip)
        XCTAssertTrue(wait(for: skip, toMatch: "exists == false", timeout: 5), "Skip should end the rest")
        let undo = app.buttons["session.set.latest.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the newest row should carry Undo")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("337-undo-AccessibilityXXXL")
        let window = app.windows.firstMatch.frame
        let barTop = app.otherElements["session.actionBar"].frame.minY
        let navBottom = app.navigationBars.firstMatch.frame.maxY
        print("#337 AccessibilityXXXL: window=\(window) latest=\(latest.frame) undo=\(undo.frame) "
              + "navBar.maxY=\(navBottom) actionBar.minY=\(barTop) logSet=\(logSet.frame)")
        XCTAssertTrue(undo.isHittable, "Undo should be tappable without scrolling at AccessibilityXXXL")
        XCTAssertTrue(window.contains(undo.frame), "Undo should be wholly on screen (\(undo.frame) in \(window))")
        XCTAssertGreaterThanOrEqual(undo.frame.minY, navBottom - 0.5, "Undo should sit below the navigation bar")
        XCTAssertLessThanOrEqual(undo.frame.maxY, barTop + 0.5, "Undo should sit above the action bar")
        undo.tap()
        XCTAssertTrue(wait(for: latest, toMatch: "exists == false", timeout: 5),
                      "Undo should take back the set whose row it sits on")
    }

    /// Warmup rungs get the same treatment as working sets (#337): the rung
    /// tapped in the ramp becomes the newest Today row, and that row carries
    /// Undo. Flat Bench with yesterday's 135 lb is the lift whose ramp exists
    /// (a barbell, with a target); the session opens on a dumbbell press, and
    /// a ramp is collapsed anywhere but the day's first lift.
    func testLoggedWarmupRungGetsTheSameUndoOnItsRow() throws {
        let app = launch(arguments: ["-UITestSeedYesterdayBench"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let choose = app.buttons["session.exercise.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20))
        tapWhenSettled(choose)
        XCTAssertTrue(app.navigationBars["Workout exercises"].waitForExistence(timeout: 10))
        let flatBench = app.buttons["Flat Bench"].firstMatch
        XCTAssertTrue(flatBench.waitForExistence(timeout: 5))
        tapWhenSettled(flatBench)

        let disclosure = app.buttons["session.warmup.disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10), "Flat Bench with a target should offer a warmup ramp")
        revealInContext(app, disclosure)
        if (disclosure.value as? String)?.hasPrefix("Collapsed") == true { tapWhenSettled(disclosure) }
        let rung = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.warmup.log.'")).firstMatch
        XCTAssertTrue(rung.waitForExistence(timeout: 5), "the expanded ramp should list its rungs")
        revealInContext(app, rung)
        tapWhenSettled(rung)

        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged rung should be the newest row under Today")
        XCTAssertTrue(latest.label.contains("Warmup"), "the row should be tagged as a warmup (label: \(latest.label))")
        let undo = app.buttons["session.set.latest.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "a warmup row carries Undo like any other")
        assertUndo(undo, sitsBeside: latest)
        assertNoLoggedSetBanner(app)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("337-warmup-row")
        XCTAssertTrue(undo.isHittable, "Undo should be tappable without scrolling after a warmup rung")

        undo.tap()
        XCTAssertTrue(wait(for: latest, toMatch: "exists == false", timeout: 5),
                      "Undo should take back the warmup whose row it sits on")
    }

    /// A set that sets a record says which kind on its own row, where the
    /// banner used to (#337). Yesterday's 40 lb on the first lift is the
    /// history to beat; one increment up from the suggestion is heavier than
    /// anything done before, so the headline is "heaviest ever".
    func testJustLoggedRecordSaysWhichKindOnItsRow() throws {
        let app = launch(arguments: ["-UITestSeedYesterday"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        let heavier = app.buttons["session.weight.increment"]
        XCTAssertTrue(heavier.waitForExistence(timeout: 5))
        heavier.tap()
        makeLogSetAvailable(app, logSet)
        tapWhenSettled(logSet)

        let kind = "Personal record · heaviest ever"
        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should have a row")
        XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5),
                      "a record row still carries Undo")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("337-record-row")
        XCTAssertTrue(latest.label.contains(kind),
                      "the row should say which record it set (label: \(latest.label))")
        assertNoLoggedSetBanner(app)
        // Said once. A banner's copy would sit outside the row's frame.
        let row = latest.frame.insetBy(dx: -1, dy: -1)
        let saysKind = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", kind))
            .allElementsBoundByIndex
            .filter { !$0.frame.isEmpty }
        XCTAssertFalse(saysKind.isEmpty)
        for element in saysKind {
            XCTAssertTrue(row.contains(element.frame),
                          "the record kind is said outside the newest row: \(element.elementType) label=\"\(element.label)\" frame=\(element.frame)")
        }
    }

    /// The other kind a lifter actually meets on the row (#337): more reps
    /// than ever at a weight already lifted, named with that weight.
    /// Yesterday's 40 lb × 8 is the history; the same weight for one more rep
    /// is not the heaviest ever, so the reps record is the headline. The load
    /// is read off the row rather than assumed, so a different suggestion
    /// fails here with the numbers in the message instead of silently
    /// testing "heaviest ever" twice.
    func testJustLoggedRepsRecordNamesItsLoadOnItsRow() throws {
        let app = launch(arguments: ["-UITestSeedYesterday"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)
        let morePlease = app.buttons["session.reps.increment"]
        XCTAssertTrue(morePlease.waitForExistence(timeout: 5))
        tapWhenSettled(morePlease)
        tapWhenSettled(logSet)

        let latest = app.buttons["session.set.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the logged set should have a row")
        XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5),
                      "a record row still carries Undo")
        XCTAssertTrue(wait(for: latest, toMatch: "label CONTAINS 'Personal record'", timeout: 5),
                      "one more rep at yesterday's weight should be a record (label: \(latest.label))")
        let numbers = try XCTUnwrap(Self.loadAndReps(in: latest.label),
                                    "the newest row should read as load × reps (label: \(latest.label))")
        let load = try XCTUnwrap(numbers.components(separatedBy: " × ").first)
        XCTAssertTrue(latest.label.contains("Personal record · most reps at \(load)"),
                      "the row should name the reps record and its load (label: \(latest.label))")
        assertNoLoggedSetBanner(app)
    }

    /// Undo lasts exactly as long as it did on the banner (#319): until the
    /// next set replaces it or the lifter moves to another lift. No timer, so
    /// nothing here waits for one.
    func testUndoMovesToTheNextSetAndEndsWhenTheLiftChanges() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        makeLogSetAvailable(app, logSet)

        let latest = app.buttons["session.set.latest"]
        let undo = app.buttons["session.set.latest.undo"]
        tapWhenSettled(logSet)
        XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '1,'", timeout: 10))
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the first set should carry Undo")

        // The next set takes the offer with it: one Undo, on the newest row.
        tapWhenSettled(logSet)
        XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '2,'", timeout: 10))
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the second set should carry Undo")
        XCTAssertEqual(
            app.buttons.matching(identifier: "session.set.latest.undo").count, 1,
            "only the newest row offers Undo"
        )

        // Moving to another lift ends it, and coming back does not revive it.
        let next = app.buttons["session.exercise.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        tapWhenSettled(next)
        let back = app.buttons["session.exercise.previous"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        tapWhenSettled(back)
        XCTAssertTrue(wait(for: latest, toMatch: "label BEGINSWITH '2,'", timeout: 10),
                      "both sets are still logged after leaving and returning")
        XCTAssertFalse(undo.exists, "leaving the lift ends the offer; the sets themselves stay")
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

        // Moves at most one step to reach a middle exercise where Back and
        // Next both exist, which is all the separation check below needs.
        // Since #285 this always starts on the first exercise; the other
        // branch is kept so the check doesn't depend on where it starts.
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

        // Advances for as long as Next exercise is still there. Bounded well
        // past Push's six slots so a real regression here fails instead of
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
        XCTAssertTrue(reachTrainScreen(app))

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
        XCTAssertTrue(reachTrainScreen(app))

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

        // Moves at most one step to reach a middle exercise where Back and
        // Next both exist, which is all the separation check below needs.
        // Since #285 this always starts on the first exercise; the other
        // branch is kept so the check doesn't depend on where it starts.
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
    ///
    /// Measured from the bar's top to the bottom of its last row of controls,
    /// not the bar's own frame (#236). The frame carries `.background(.bar)`
    /// down under the home indicator, so on a Face ID phone it included ~34pt
    /// of inset the SE doesn't have — iPhone 17 read 361.7pt and failed, while
    /// taking a smaller share of its screen (41%) than the SE's passing 296.5pt
    /// does of its own (44%). #205 counted controls, so this does too.
    func testActionBarMinimumHeightIsReclaimedForSetRows() throws {
        let app = launch()
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        let actionBar = app.otherElements["session.actionBar"]
        XCTAssertTrue(actionBar.waitForExistence(timeout: 5), "action bar should be reachable by identifier")

        let lastRow = ["session.exercise.previous", "session.more", "session.exercise.next"]
            .map { app.buttons[$0] }
            .filter { $0.exists }
            .map { $0.frame.maxY }
        let controlsBottom = try XCTUnwrap(lastRow.max(), "the Back / More / Next row should be on screen")
        let height = controlsBottom - actionBar.frame.minY
        // Printed for the record (#205 asked for a measured number, not a
        // font-metrics estimate) — visible in the xcodebuild test log.
        print("SessionView action bar minimum height: \(height)pt (frame incl. bottom inset: \(actionBar.frame.height)pt)")
        XCTAssertGreaterThan(height, 0, "the action bar should have a real, non-zero frame")
        XCTAssertLessThanOrEqual(
            height, 340,
            "the action bar should no longer approach the ~368pt #205 measured before this change"
        )
    }

    /// #216's last open criterion, measured rather than argued: with the
    /// plate row open — the one editor in the action bar that still expands,
    /// now that reps and RPE are always-visible steppers — the lift's name,
    /// the newest logged set and Log Set must all still be on screen and
    /// tappable. Opening an editor must not cost the lifter the context the
    /// edit is about, or the one action it leads to.
    /// Warmups are when plates change between every rung, so logging one
    /// leaves the plate row open; the first working set closes it (#320,
    /// re-cut from a shelved commit). Flat Bench with yesterday's 135 lb
    /// has a target, so its ramp leads the form and Log Set logs rungs.
    func testPlateRowStaysOpenForWarmupsAndClosesForAWorkingSet() throws {
        let app = launch(arguments: ["-UITestSeedYesterdayBench"])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let choose = app.buttons["session.exercise.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20))
        tapWhenSettled(choose)
        XCTAssertTrue(app.navigationBars["Workout exercises"].waitForExistence(timeout: 10))
        let flatBench = app.buttons["Flat Bench"].firstMatch
        XCTAssertTrue(flatBench.waitForExistence(timeout: 5))
        tapWhenSettled(flatBench)

        let plates = app.descendants(matching: .any)["session.plates.toggle"]
        XCTAssertTrue(plates.waitForExistence(timeout: 10), "Flat Bench should offer Adjust plates")
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5))
        // Log Set says what it will write: "Warmup, …" while a rung leads.
        let onAWarmup = NSPredicate(format: "value BEGINSWITH 'Warmup'")
        XCTAssertTrue(wait(for: logSet, toMatch: "value BEGINSWITH 'Warmup'", timeout: 5),
                      "a lift with a target should lead with its warmup ramp")

        tapWhenSettled(plates)
        XCTAssertTrue(wait(for: plates, toMatch: "value CONTAINS 'expanded'", timeout: 5))
        // Every rung, through Log Set, as a lifter loading plates would.
        var warmups = 0
        while onAWarmup.evaluate(with: logSet), warmups < 6 {
            let before = logSet.value as? String ?? ""
            tapWhenSettled(logSet)
            warmups += 1
            // The form moves on to the next rung, or to the working weight.
            let movedOn = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", before), object: logSet)
            XCTAssertEqual(XCTWaiter().wait(for: [movedOn], timeout: 5), .completed,
                           "logging warmup \(warmups) should move the form on")
            XCTAssertTrue(wait(for: plates, toMatch: "value CONTAINS 'expanded'", timeout: 2),
                          "warmup \(warmups) is a waypoint: the plate row must stay open for the next rung")
        }
        XCTAssertGreaterThan(warmups, 0)

        // The first working set settles the weight and closes the row (#170).
        tapWhenSettled(logSet)
        XCTAssertTrue(wait(for: plates, toMatch: "value CONTAINS 'collapsed'", timeout: 5),
                      "the first working set should close the plate row")
    }

    func testPlateRowKeepsLiftSetAndLogInView() throws {
        try assertPlateRowKeepsContextInView(arguments: [], sizeName: "default")
    }

    /// The same measurement at the largest accessibility text size, where the
    /// action bar becomes its own scroll view capped at 60% of the height.
    /// The raw value is the short `UICTContentSizeCategoryAccessibilityXXXL` —
    /// the long spelling is silently ignored — and the test proves the
    /// argument took by checking reps and RPE stacked, which only happens at
    /// accessibility sizes.
    ///
    /// A weaker claim than the default-size test, on purpose and measured: at
    /// this size the latest set row alone is ~150pt tall and Log Set ~138pt,
    /// against a context area of ~180pt, so all three cannot share one screen
    /// with the plate row open on any iPhone. What this guards is what does
    /// fit: the lift's name stays on screen, and Log Set stays on screen,
    /// pinned under the action bar's scrolling controls.
    func testPlateRowKeepsLiftInViewAndLogReachableAtAccessibilityText() throws {
        try assertPlateRowKeepsContextInView(
            arguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ],
            sizeName: "AccessibilityXXXL",
            expectsStackedSteppers: true,
            requiresAllOnOneScreen: false
        )
    }

    /// The hero at the largest text size, on the screen a session opens on:
    /// wholly on screen with nothing scrolled. Inside the action bar's
    /// capped scroll view it sat cut off at the bottom edge, "Set a weight
    /// first" sliced through, on an SE and an iPhone 17 alike (re-critique,
    /// 2026-10-07); it is pinned under that scroll view now. Read by frame,
    /// not `isHittable`, since on a first outing the button is disabled.
    func testLogSetIsWhollyOnScreenWithoutScrollingAtAccessibilityText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "the session screen should be up")
        Thread.sleep(forTimeInterval: 1)
        let window = app.windows.firstMatch.frame
        attachScreenshot("log-set-AccessibilityXXXL")
        XCTAssertFalse(logSet.frame.isEmpty)
        XCTAssertTrue(window.contains(logSet.frame),
                      "Log Set should be wholly on screen at AccessibilityXXXL (\(logSet.frame) in \(window))")
    }

    private func assertPlateRowKeepsContextInView(
        arguments: [String],
        sizeName: String,
        expectsStackedSteppers: Bool = false,
        requiresAllOnOneScreen: Bool = true
    ) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: arguments)
        try openPushDay(app)
        startSessionIfPreviewed(app)
        XCTAssertTrue(app.buttons["session.microphone"].waitForExistence(timeout: 20),
                      "the session screen should be up")

        // Only a measured, plate-built lift offers the plate row — on Push
        // that's Flat Bench, a barbell lift. The session need not open on it
        // (and at accessibility sizes Previous and Next can sit scrolled out
        // of the action bar), so jump there through the exercise chooser in
        // the header rather than walking.
        // Queried as any element type: the readout collapses its children
        // into one accessibility element, which XCUI doesn't report as a button.
        let plates = app.descendants(matching: .any)["session.plates.toggle"]
        if !plates.waitForExistence(timeout: 2) {
            let choose = app.buttons["session.exercise.choose"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5))
            tapWhenSettled(choose)
            // The chooser has to be up before its rows can be looked for —
            // #311's run gave up on a row 5s after a tap that may not have
            // presented anything yet (#314).
            XCTAssertTrue(app.navigationBars["Workout exercises"].waitForExistence(timeout: 10),
                          "tapping the exercise chooser should open it")
            // Each row is a Button labelled with the lift's name. Queried as
            // that button, not as the Text inside it: XCUI exposes a labelled
            // button's child text only some of the time (#314).
            let flatBench = app.buttons["Flat Bench"].firstMatch
            XCTAssertTrue(flatBench.waitForExistence(timeout: 5),
                          "Push day should contain a plate-built lift (Flat Bench)")
            tapWhenSettled(flatBench)
        }
        XCTAssertTrue(plates.waitForExistence(timeout: 5), "Flat Bench should offer Adjust plates")
        let liftName = app.buttons["session.exercise.swap"]
        XCTAssertTrue(liftName.waitForExistence(timeout: 5))
        let liftLabel = liftName.label

        // Log one set so there is a latest set to keep in view. Logging also
        // collapses the plate row by design (#170), so the row is opened
        // after, not before.
        let logSet = app.buttons["session.log-set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5))
        makeLogSetAvailable(app, logSet)
        logSet.tap()
        XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5), "the set should have been logged")
        // If that set finished the lift, the app offers the next one without
        // moving; staying is the lifter's choice, and the one this test needs.
        // Given a moment to appear rather than read once (#285).
        let stay = app.buttons["session.nextUp.stay"]
        if wait(for: stay, toMatch: "hittable == true", timeout: 2) { stay.tap() }
        XCTAssertEqual(liftName.label, liftLabel, "the test should still be on the lift it logged")

        let latestSet = app.buttons["session.set.latest"]
        XCTAssertTrue(latestSet.waitForExistence(timeout: 5), "the logged set should have a row")

        attachScreenshot("216-before-plates-\(sizeName)")
        // At accessibility sizes the action bar is its own scroll view and
        // can sit scrolled past the weight readout; bring it back first.
        if !plates.isHittable { logSet.swipeDown() }
        XCTAssertTrue(plates.isHittable, "Adjust plates should be tappable [\(sizeName)]")
        // Settled first: right after a logged set, the rest bar is still
        // springing in above it (#314).
        tapWhenSettled(plates)
        let plateRow = app.otherElements["session.plates.row"]
        XCTAssertTrue(plateRow.waitForExistence(timeout: 5), "tapping Adjust plates should open the plate row")
        // Load a plate, so the row is measured in its taller state — loaded
        // plates and the plates to add — not only at an empty bar.
        let addPlate = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add ' AND label ENDSWITH ' plate'")
        ).firstMatch
        XCTAssertTrue(addPlate.waitForExistence(timeout: 5), "the plate row should offer plates to add")
        if addPlate.isHittable { addPlate.tap() }
        // Let the transitions settle before reading frames.
        Thread.sleep(forTimeInterval: 1)

        if expectsStackedSteppers {
            let reps = app.buttons["session.reps.value"]
            let rpe = app.descendants(matching: .any)["session.rpe.value"]
            if reps.exists && rpe.exists {
                // Stacked rows overlap horizontally; side by side, RPE starts
                // where reps ends.
                XCTAssertLessThan(
                    rpe.frame.minX, reps.frame.maxX,
                    "reps and RPE stack only at accessibility sizes — side by side means the launch argument didn't take"
                )
            }
        }

        attachScreenshot("216-plates-open-\(sizeName)")
        let window = app.windows.firstMatch.frame
        // Printed for the record: #216 asked for the expanded state to be
        // measured on a device-sized screen, not reasoned about.
        print("#216 plate row open [\(sizeName)] window=\(window) "
              + "liftName=\(liftName.frame) latestSet=\(latestSet.frame) "
              + "plateRow=\(plateRow.frame) logSet=\(logSet.frame) "
              + "actionBar=\(app.otherElements["session.actionBar"].frame)")

        var mustBeOnScreen = [("lift name", liftName)]
        if requiresAllOnOneScreen {
            mustBeOnScreen += [("latest set", latestSet), ("Log Set", logSet)]
            // Hittable only proves the centre is uncovered. The row has to
            // clear the action bar entirely, not be clipped by its top edge.
            let barTop = app.otherElements["session.actionBar"].frame.minY
            XCTAssertLessThanOrEqual(latestSet.frame.maxY, barTop + 0.5,
                                     "the latest set should sit wholly above the action bar")
            XCTAssertLessThanOrEqual(liftName.frame.maxY, barTop + 0.5,
                                     "the lift name should sit wholly above the action bar")
        } else {
            XCTAssertTrue(latestSet.exists, "the latest set should still be in the context, if scrolled")
            // Pinned under the scrolling controls at these sizes (re-critique,
            // 2026-10-07), so it is on screen with no scrolling at all. It
            // used to take up to four drags of the action bar to reach.
            mustBeOnScreen.append(("Log Set", logSet))
        }
        for (name, element) in mustBeOnScreen {
            XCTAssertTrue(element.exists, "\(name) should still exist with the plate row open")
            XCTAssertFalse(element.frame.isEmpty, "\(name) should have a real frame")
            XCTAssertTrue(window.contains(element.frame),
                          "\(name) should be fully on screen with the plate row open (\(element.frame) in \(window))")
            XCTAssertTrue(element.isHittable,
                          "\(name) should be tappable with the plate row open, not scrolled or covered away")
        }
    }

    /// "1, 5 lb × 8" -> "5 lb × 8": the numbers a logged row shows, read from
    /// its own label.
    private static func loadAndReps(in label: String) -> String? {
        label.range(of: #"[0-9][0-9.,]* [A-Za-z]+ × [0-9]+"#, options: .regularExpression)
            .map { String(label[$0]) }
    }

    /// Undo sits on the newest row's own line, beside the edit button rather
    /// than inside it (a button in another button's label never gets its own
    /// taps), and does not overlap it.
    private func assertUndo(_ undo: XCUIElement, sitsBeside row: XCUIElement,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(undo.frame.midY - row.frame.midY), row.frame.height / 2,
                                 "Undo should be on the newest row's line (undo \(undo.frame), row \(row.frame))",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(undo.frame.minX, row.frame.maxX - 1,
                                    "Undo should sit beside the row's edit button, not on top of it",
                                    file: file, line: line)
    }

    /// What the lifter reads between sets, wholly on screen at once (#337):
    /// the lift's name, the progress/choose control, Next up's Stay when it is
    /// armed (and wherever it is up regardless), and the newest set's Undo.
    ///
    /// By frame against the bars, never `isHittable`: that only proves the
    /// centre point is uncovered, so an Undo whose lower half is under the
    /// dock passes it. The top edge is the navigation bar, or the rest card
    /// when one is running (read off its Skip, which sits inside it); the
    /// bottom edge is the dock. Prints every frame it checks, so the number
    /// is in the log whether or not it passed.
    private func assertContextInView(_ app: XCUIApplication, _ tag: String, expectsStay: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let barTop = app.otherElements["session.actionBar"].frame.minY
        var top = app.navigationBars.firstMatch.frame.maxY
        let skip = app.buttons["Skip"]
        if skip.exists { top = max(top, skip.frame.maxY) }
        var checked: [(String, XCUIElement)] = [
            ("the lift's name", app.buttons["session.exercise.swap"]),
            ("the exercise chooser", app.buttons["session.exercise.choose"]),
            ("Undo", app.buttons["session.set.latest.undo"]),
        ]
        let stay = app.buttons["session.nextUp.stay"]
        if expectsStay || stay.exists { checked.append(("Next up's Stay", stay)) }
        print("#337 context [\(tag)]: top=\(top) dockTop=\(barTop) "
              + checked.map { "\($0.0)=\($0.1.exists ? "\($0.1.frame)" : "absent")" }.joined(separator: " "))
        for (name, element) in checked {
            XCTAssertTrue(element.exists, "\(name) should be on screen [\(tag)]", file: file, line: line)
            XCTAssertGreaterThanOrEqual(element.frame.minY, top - 0.5,
                                        "\(name) should sit wholly below the bars above it, top edge \(top) [\(tag)] (frame \(element.frame))",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(element.frame.maxY, barTop + 0.5,
                                     "\(name) should sit wholly above the dock, top edge \(barTop) [\(tag)] (frame \(element.frame))",
                                     file: file, line: line)
        }
    }

    /// The "Set logged" / "Warmup logged" banner is gone (#337): the row is
    /// the confirmation. Matched on the banner's wording, which no row uses.
    private func assertNoLoggedSetBanner(_ app: XCUIApplication,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Set logged' OR label BEGINSWITH 'Warmup logged'"))
            .firstMatch
        XCTAssertFalse(banner.exists,
                       "no banner should repeat the logged set (found \"\(banner.label)\")",
                       file: file, line: line)
    }

    /// Scrolls the session's context until `element` can be tapped. The ramp
    /// sits below the header and the plan card, so on a short screen it
    /// starts under the dock.
    private func revealInContext(_ app: XCUIApplication, _ element: XCUIElement) {
        var swipes = 0
        while !element.isHittable, swipes < 4 {
            app.scrollViews.firstMatch.swipeUp()
            swipes += 1
        }
    }

    /// Kept on a green run too: the screenshot is the evidence #216 asked for.
    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The Progress tab's region filter, checked for the two things #217 says
    /// a selected control owes someone: the selected state has to be exposed
    /// as a trait, and colour must not be the only way to see it.
    ///
    /// The non-colour cue is asserted as width rather than by finding the
    /// checkmark glyph: the glyph is deliberately `accessibilityHidden` (the
    /// button already carries `.isSelected`, so reading "checkmark" after the
    /// region name is noise), which means XCUI cannot see it as an element.
    /// What XCUI can see is that selecting a chip makes it render *more* than
    /// an unselected one does — a bolder label and a glyph that was not there
    /// — and that is exactly the property the criterion is about. A chip that
    /// only changed its fill colour would come back the same width and fail
    /// here.
    ///
    /// Reduce Motion itself is not exercised: there is no XCUI or `simctl`
    /// API that flips the system preference for a single test run, so the
    /// animation half of #217 is verified by reading the diff and on the
    /// phone, not here. Said out loud rather than faked with a test that
    /// passes either way.
    func testProgressFilterChipCarriesANonColourSelectedCue() throws {
        let app = launch()

        // The Progress tab draws nothing at all until something has been
        // logged, and every test starts from an empty store (#285), so this
        // one makes its own data.
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["Log Set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20))
        makeLogSetAvailable(app, logSet)
        logSet.tap()
        XCTAssertTrue(app.buttons["session.set.latest.undo"].waitForExistence(timeout: 5),
                      "the set should have been logged")

        // Relaunching is how this test gets out of the session and back to
        // the tab bar, and it also guarantees the Progress tab reads the set
        // from the store rather than from whatever was in memory.
        app.terminate()
        let relaunched = launch(freshState: false)
        XCTAssertTrue(reachTrainScreen(relaunched))

        let progress = relaunched.tabBars.buttons["Progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5) && progress.isHittable)
        progress.tap()

        let all = relaunched.buttons["progress.volume.filter.all"]
        // The first region chip, not a later one: the row scrolls
        // horizontally, and on the narrowest supported screen anything past
        // the second chip starts the run off-screen and unhittable.
        let chest = relaunched.buttons["progress.volume.filter.chest"]
        XCTAssertTrue(all.waitForExistence(timeout: 15),
                      "the volume card's filter row should be on the Progress tab")
        XCTAssertTrue(chest.waitForExistence(timeout: 5))

        // Every chip, not just these two, meets the 44pt floor (#251). The
        // capsule still draws at 36; the tappable frame around it is what
        // XCUI measures and what a thumb hits.
        let chips = relaunched.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "progress.volume.filter.")
        ).allElementsBoundByIndex
        XCTAssertFalse(chips.isEmpty)
        for chip in chips {
            print("Progress filter chip \(chip.identifier) frame=\(chip.frame)")
            XCTAssertGreaterThanOrEqual(chip.frame.height, 44,
                                        "\(chip.identifier) is below the 44pt tap target")
        }

        XCTAssertTrue(all.isSelected, "All is the filter row's default selection")
        XCTAssertFalse(chest.isSelected)

        let unselectedWidth = chest.frame.width
        let selectedWidthOfAll = all.frame.width
        chest.tap()

        XCTAssertTrue(wait(for: chest, toMatch: "selected == true", timeout: 5),
                      "tapping a region chip should select it")
        XCTAssertFalse(all.isSelected, "selection should move, not accumulate")

        // Printed so the measured difference is in the test log rather than
        // only in an assertion message.
        print("Progress filter chip widths — chest unselected \(unselectedWidth)pt, "
              + "selected \(chest.frame.width)pt; all selected \(selectedWidthOfAll)pt, "
              + "unselected \(all.frame.width)pt")
        XCTAssertGreaterThan(
            chest.frame.width, unselectedWidth,
            "a selected chip must show something an unselected one does not — "
            + "colour alone is not a cue (#217)"
        )
        XCTAssertLessThan(
            all.frame.width, selectedWidthOfAll,
            "and the chip that lost the selection must give that cue back"
        )

        // #217's contrast criterion is a measured number, not an opinion, and
        // the only honest place to measure it is the rendered pixels. Attached
        // rather than asserted here: XCUI cannot sample a colour, so the ratio
        // is computed off this image and recorded in the PR. Kept always, so
        // the evidence survives a green run rather than only a red one.
        //
        // Scrolled first because the filter row sits under the floating tab
        // bar at rest, and the bar's glass darkens everything behind it — a
        // sample taken there measures the blend, not the chip.
        relaunched.swipeUp()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "progress-filter-selected"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
