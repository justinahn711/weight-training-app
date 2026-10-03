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
/// re-checking by hand is worst at: `SystemAuditUITests` runs the system's
/// own accessibility audit, which is mechanical, exhaustive within a screen,
/// and never gets bored.
///
/// Split out of what was originally `AccessibilityAuditTests.swift` for #193:
/// that file used to hold the audit tests and the tap-through flow tests
/// (`testLogSetAndUndo` and friends) in one `XCTestCase`, so a red run never
/// said, at a glance, whether the audit had stalled or a flow had actually
/// broken. Both kinds of test still reach a screen the same way — through
/// `reachTrainScreen` and `openPushDay` below — so that logic lives once,
/// here, rather than getting forked into two answers that drift.
///
/// Until #285 the classes' relative order was load-bearing, because every
/// test inherited the session state on disk that the one before it left
/// (see `SystemAuditUITests.swift`'s header for that history). Each test now
/// launches from a known state instead — see `launch(arguments:freshState:)`.
class ChickenBreastUITestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches the app from a known state (#285).
    ///
    /// Each test used to inherit whatever the test before it left on disk —
    /// a workout draft to resume, parked on any exercise, sometimes with a
    /// rest still running on its Live Activity. The tests grew tolerances for
    /// that ("a draft left by an earlier test can resume anywhere"), but the
    /// state a test ran in still depended on which tests ran first, and one
    /// audit's result did too (#289: a leftover rest put "RESTING" on the
    /// session screen only when `SessionFlowUITests` had run before it).
    ///
    /// So every launch opens an isolated store that never syncs to iCloud,
    /// and by default empties it first and ends any leftover Live Activity
    /// and pending rest alert — the app's side is `UITestLaunchState`, in
    /// `AppStore.swift`, compiled into Debug builds only. The app then does
    /// its real first launch: seeds the library, shows the split cover.
    ///
    /// `freshState: false` is for a test that relaunches on purpose to read
    /// back what it just wrote (the Progress tab, Train after a finish): the
    /// same isolated store, kept.
    func launch(arguments: [String] = [], freshState: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestIsolatedStore"]
            + (freshState ? ["-UITestResetState"] : [])
            + arguments
        retryingOnceOnLaunchTimeout { app.launch() }
        return app
    }

    /// `launch` (in practice `app.launch()`), retried once when — and only
    /// when — XCTest reports that the launch itself timed out (#285).
    ///
    /// Seen on CI as `Failed to launch … Timed out while launching
    /// application via Xcode`, on the first test of a run, on a simulator
    /// the job had just booted; the next test launched the same binary in
    /// seconds. Like the audit retry below, it is one retry of one specific
    /// infrastructure error: a crash on launch is a different error and still
    /// fails, and a second timeout in a row fails as it always did. What it
    /// buys is not having a cold simulator read as a broken app.
    ///
    /// The first attempt runs inside a non-strict `XCTExpectFailure` scoped
    /// to that message, so a timeout is recorded as an expected failure (and
    /// kept in the result bundle) rather than failing the test; anything else
    /// the launch reports is unmatched and fails exactly as before.
    func retryingOnceOnLaunchTimeout(_ launch: () -> Void) {
        final class Flag { var raised = false }
        let timedOut = Flag()
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            guard Self.isLaunchTimeout(issue.compactDescription) else { return false }
            timedOut.raised = true
            return true
        }
        // A recorded failure would otherwise stop the test before the retry.
        let continued = continueAfterFailure
        let failuresBefore = testRun?.totalFailureCount ?? 0
        continueAfterFailure = true
        XCTExpectFailure("app launch timed out; retrying once (#285)", options: options) {
            launch()
        }
        continueAfterFailure = continued
        // Any other launch failure already failed the test above; stop here
        // as the plain `app.launch()` would have, rather than tapping on.
        if (testRun?.totalFailureCount ?? 0) > failuresBefore {
            XCTFail("the app did not launch; stopping")
            return
        }
        guard timedOut.raised else { return }
        XCTContext.runActivity(named: "app launch timed out once, retrying (#285)") { _ in
            launch()
        }
    }

    static func isLaunchTimeout(_ description: String) -> Bool {
        description.localizedCaseInsensitiveContains("failed to launch")
            && description.localizedCaseInsensitiveContains("timed out while launching")
    }

    // MARK: - Waiting

    /// Waits for `element` to satisfy `format`, instead of reading it once.
    ///
    /// A single read of `isEnabled` or `isHittable` right after a tap races
    /// SwiftUI's re-render: the tap returns once the app reports idle, which
    /// under CI's load is not the same moment the new state is on screen.
    /// That race is how `testLogSetAndUndoIsReachableWithoutSight` failed on
    /// PR #282 — the weight tap took 36s to land and Log Set was read at the
    /// instant after (#285).
    @discardableResult
    func wait(for element: XCUIElement, toMatch format: String,
              timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Taps `element` once it is hittable and has stopped moving (#314).
    ///
    /// A tap is delivered at the coordinates XCUI resolved a moment earlier.
    /// On a slow CI runner, the element can still be sliding when that
    /// happens — under a banner springing in after a logged set, or a sheet
    /// still presenting — and the tap lands where it used to be: #299's run
    /// tapped Adjust plates and the row never opened. Waiting for two equal
    /// frame reads a quarter-second apart is a condition, not a fixed sleep:
    /// a settled screen passes on the first pair.
    func tapWhenSettled(_ element: XCUIElement, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element, toMatch: "hittable == true", timeout: timeout),
                      "\(element) should become tappable", file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let current = element.frame
            if current == previous && element.isHittable { break }
            previous = current
        }
        element.tap()
    }

    /// Log Set, enabled. A cold-start lift opens with no weight, and Log Set
    /// refuses a zero load rather than writing "0 lb" into history, so this
    /// adds one increment when the button hasn't become enabled on its own.
    func makeLogSetAvailable(_ app: XCUIApplication, _ logSet: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard !wait(for: logSet, toMatch: "enabled == true", timeout: 3) else { return }
        let heavier = app.buttons["session.weight.increment"]
        XCTAssertTrue(heavier.waitForExistence(timeout: 5), file: file, line: line)
        heavier.tap()
        XCTAssertTrue(wait(for: logSet, toMatch: "enabled == true", timeout: 15),
                      "Log Set should be available once a weight is set", file: file, line: line)
    }

    /// The system's own audit, which catches what a hand-written expectation
    /// forgets to ask about: contrast, hit-region size, clipped text at larger
    /// type, and elements with no label at all.
    /// Issue types held open, with the reason each is still failing.
    ///
    /// Not a way to make the suite green. An entry here is a defect that has
    /// been seen, named and left. What it prevents is a suite that fails for
    /// a known reason, because that suite gets ignored and then stops being
    /// run at all. The moment an entry stops firing it becomes a lie the next
    /// person deletes — and every entry names an open issue, so "is this still
    /// true?" has somewhere to be answered. Empty is the goal.
    ///
    /// Until #260 this held `.contrast`, `.textClipped` and `.dynamicType`,
    /// justified by #113 and #138, which had both closed. Re-audited one type
    /// at a time: `.textClipped` and `.dynamicType` now gate every audited
    /// screen, with the few elements still firing held individually in
    /// `heldElements` below.
    ///
    /// `.contrast` was the last entry, and #276 took it out: the session's
    /// controls were fixed (see `Theme.quietLabel` and `SessionView`'s
    /// forward action, Skip and weight stepper), content scrolled under a
    /// bar is held by `isUnderChrome` below, and the lift library audits
    /// contrast on a filtered list (see
    /// `testLiftLibraryIsReachableFromSettingsAndPassesAudit`). Contrast
    /// failures often arrive with `issue.element == nil`, so a new one names
    /// no element; find it by elimination (#276 did, one control at a time).
    /// Timing, for #193: on an iPhone 17 simulator an audit took 0.5-0.9s
    /// with all three types held, 2.0-2.4s with only `.contrast` held, and
    /// 2.0-6.6s with nothing held — nowhere near where -56 was seen.
    static let knownIssues: XCUIAccessibilityAuditType = []

    /// Single elements held open inside a type that otherwise gates (#260).
    ///
    /// Narrower than `knownIssues` on purpose: holding a whole type for one
    /// element blinds the audit to every *new* defect of that type, which is
    /// how the clipping #249 and #250 fixed reached a phone before a test.
    /// Matched on the audit type and the start of the element's label, and
    /// only while the element is still reported — each entry's issue says
    /// what finishing it means.
    struct HeldElement {
        let type: XCUIAccessibilityAuditType
        let labelPrefix: String
        let issue: Int
    }

    static let heldElements: [HeldElement] = []

    /// The types actually audited — everything except what `knownIssues`
    /// holds open.
    ///
    /// Held-open types were being computed and then discarded: the handler
    /// returned true for them, so they never failed anything, but the audit
    /// had already done the work. Contrast in particular has to render and
    /// sample pixels for every element it checks, which is the expensive kind
    /// of work to do for a result nobody reads (#193).
    ///
    /// The cost of this is real and worth naming: a held-open issue is no
    /// longer reported in the result bundle, so the backlog those entries
    /// describe stops being observable from a test run. That backlog is
    /// written down in `knownIssues` above and tracked in the issues it names, which
    /// is where it belongs — a comment nobody deletes beats a log nobody
    /// reads, and reliability of the checks that *do* gate is worth more.
    static let auditedTypes: XCUIAccessibilityAuditType = {
        var all: XCUIAccessibilityAuditType = .all
        all.subtract(knownIssues)
        return all
    }()

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
    /// `types` narrows the audit for a screen that has to be audited in
    /// two states, each for what that state can show honestly (#276: the
    /// lift library). It is intersected with `auditedTypes`, so it can never
    /// re-open a type `knownIssues` holds.
    ///
    /// `.dynamicType` findings get one second look (#295). On CI the
    /// Dynamic Type check sometimes reads the session screen before it has
    /// redrawn at the text size it just set, and reports whichever label it
    /// reached first: 4 of 23 iterations on the CI image (run 36804873703),
    /// a different element each time, never locally. So the first pass holds
    /// `.dynamicType` findings instead of failing on them (every other type
    /// fails as usual, and every finding is still logged), and if it held
    /// any, a second, ordinary pass decides. A real Dynamic Type defect
    /// fails both — #292's and #294's did, every run — so this can only
    /// pass a finding that didn't reproduce. Not the fix #295 asks for; the
    /// owner chose it as the stopgap while the cause stays open.
    ///
    /// - Returns: the issues seen, so a caller can assert on them.
    @discardableResult
    func audit(_ app: XCUIApplication,
               only types: XCUIAccessibilityAuditType = .all,
               file: StaticString = #filePath,
               line: UInt = #line) throws -> [String] {
        let first = try auditPass(app, types: types, holdsDynamicType: true, file: file, line: line)
        guard first.heldDynamicType else { return first.seen }
        XCTContext.runActivity(named: "a11y .dynamicType finding held once, auditing again (#295)") { _ in }
        print("a11y .dynamicType finding held once, auditing again (#295)")
        return try auditPass(app, types: types, holdsDynamicType: false, file: file, line: line).seen
    }

    private func auditPass(_ app: XCUIApplication,
                           types: XCUIAccessibilityAuditType,
                           holdsDynamicType: Bool,
                           file: StaticString,
                           line: UInt) throws -> (seen: [String], heldDynamicType: Bool) {
        do {
            return try runAuditOnce(app, types: types, holdsDynamicType: holdsDynamicType)
        } catch let error as NSError where Self.isAuditTimeout(error) {
            XCTContext.runActivity(named: "a11y audit stalled once, retrying (#193)") {
                $0.add(.init(string: error.localizedDescription))
            }
            do {
                return try runAuditOnce(app, types: types, holdsDynamicType: holdsDynamicType)
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
                return ([], false)
            }
        }
    }

    private func runAuditOnce(_ app: XCUIApplication,
                              types: XCUIAccessibilityAuditType,
                              holdsDynamicType: Bool) throws -> (seen: [String], heldDynamicType: Bool) {
        var seen: [String] = []
        var heldDynamicType = false
        // Printed, so the -56 history (#193) has numbers in every CI log
        // rather than only in the result bundle. Not printed on a thrown
        // timeout, which `audit(_:)` reports on its own.
        let started = Date()
        let chrome = Self.chrome(in: app)
        try app.performAccessibilityAudit(for: Self.auditedTypes.intersection(types)) { issue in
            // The label is read once and shared by the log line and the hold
            // check: each read is a round trip to the app (#193).
            let label = issue.element?.label
            let element = Self.describe(issue.element, label: label)
            let detail = "\(issue.auditType): \(issue.detailedDescription ?? "no detail") — \(element)"
            seen.append(detail)
            // In the log as well as the bundle: the bundle's own description
            // of a failure is "Contrast failed for SwiftUI.AccessibilityNode",
            // which names no element (#260).
            print("a11y issue: \(detail)")
            XCTContext.runActivity(named: "a11y issue") { $0.add(.init(string: detail)) }
            // Suppressed only for what is named above; every issue is still
            // recorded either way.
            if Self.isUnderChrome(issue, label: label, chrome: chrome) {
                print("a11y issue held: content under chrome (#276) — \(element)")
                return true
            }
            if Self.knownIssues.contains(issue.auditType) || Self.isHeld(issue.auditType, label: label) {
                return true
            }
            if holdsDynamicType, issue.auditType == .dynamicType {
                print("a11y issue held for a second pass (#295) — \(element)")
                heldDynamicType = true
                return true
            }
            return false
        }
        print(String(format: "a11y audit took %.1fs (%@)", Date().timeIntervalSince(started), name))
        return (seen, heldDynamicType)
    }

    /// A cheap stand-in for `debugDescription` (see `audit(_:)` above): four
    /// properties XCTest already resolved for this one element, none of which
    /// walk its descendants the way `debugDescription` documents that it does.
    private static func describe(_ element: XCUIElement?, label: String?) -> String {
        guard let element else { return "unknown element" }
        return "\(element.elementType) id=\"\(element.identifier)\" label=\"\(label ?? "")\" frame=\(element.frame)"
    }

    /// The bars content scrolls under: the tab bar, the navigation bar, and
    /// the session's action bar. Read once per audit, before it starts.
    private static func chrome(in app: XCUIApplication) -> [XCUIElement] {
        [app.tabBars.firstMatch, app.navigationBars.firstMatch,
         app.otherElements["session.actionBar"]].filter { $0.exists }
    }

    /// A contrast failure on content that has scrolled under a bar (#276).
    ///
    /// The contrast audit samples rendered pixels at an element's frame,
    /// and it audits elements scrolled out of sight as well as those in
    /// view. Content under the session's opaque action bar, or under the
    /// floating tab bar's glass and scroll-edge dimming, was failed for the
    /// colour of the bar over it: on the SE simulator "No sets yet" (behind
    /// the action bar) and Train's "1 thing to look at" (behind the tab bar)
    /// both failed while the same styles in the clear passed. That is not a
    /// colour this app chose, and the same text is audited wherever it is in
    /// the clear.
    ///
    /// Narrow on purpose: contrast only; an element XCTest could resolve
    /// (a failure with `issue.element == nil` still fails, since nothing
    /// says where it is); never anything inside a bar, so the controls on
    /// the bars stay fully audited; and only when the frame actually
    /// overlaps one.
    private static func isUnderChrome(_ issue: XCUIAccessibilityAuditIssue, label: String?,
                                      chrome: [XCUIElement]) -> Bool {
        guard issue.auditType == .contrast, let element = issue.element,
              let label, !label.isEmpty else { return false }
        let frame = element.frame
        // Same label *and* frame: a label alone can be on both sides — Log
        // Set's "5 lb × 8" on the action bar and the logged set "5 lb × 8"
        // scrolled under it.
        let sameLabel = NSPredicate(format: "label == %@", label)
        let isOnABar = chrome.contains { bar in
            bar.descendants(matching: .any).matching(sameLabel)
                .allElementsBoundByIndex.contains { $0.frame == frame }
        }
        return !isOnABar && chrome.contains { $0.frame.intersects(frame) }
    }

    private static func isHeld(_ type: XCUIAccessibilityAuditType, label: String?) -> Bool {
        guard let label else { return false }
        return heldElements.contains { $0.type == type && label.hasPrefix($0.labelPrefix) }
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
                          timeout: TimeInterval = 30) -> Bool {
        // Any day, not Push specifically, and not necessarily on screen: since
        // Train scrolls (#249), the badge and the cycle line alone can fill an
        // SE at the accessibility sizes, leaving every day below the fold.
        // With the cover gone, a day that exists is a Train that has loaded;
        // `openPushDay` scrolls to what it needs.
        let day = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "day.")).firstMatch
        let resume = app.buttons["home.resume"]
        let save = app.buttons["splitEditor.save"]

        // No audit here any more (#285). This used to audit the onboarding
        // cover whenever it was up, which on CI meant exactly once per run:
        // in whichever test launched first, seconds after the simulator
        // booted — and that is where every -56 since #280 happened (PRs #282
        // and #286), in a layout test with nothing to do with the cover.
        // With a fresh store per test the cover is up in every test, so it
        // would now audit twenty times. The cover has its own audit test in
        // `SystemAuditUITests` instead.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Elements behind a full-screen cover still exist in XCUI's
            // hierarchy. Handle the cover first and require the destination
            // controls to be hittable so a hidden day never wins this race.
            if save.exists && save.isHittable {
                save.tap()
            }
            let coverGone = !save.exists
            if (day.exists && (day.isHittable || coverGone))
                || (resume.exists && (resume.isHittable || coverGone)) {
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
        XCTAssertTrue(reachTrainScreen(app), "the Train screen should become reachable")
        // A workout in progress replaces the day list with Resume (#132).
        // Since #285 a test starts with none, but one that relaunches with
        // `freshState: false` mid-session can meet one; resuming reaches a
        // session either way.
        let resume = app.buttons["home.resume"]
        let push = app.buttons["day.push"]
        func reachable() -> Bool {
            (resume.exists && resume.isHittable) || (push.exists && push.isHittable)
        }
        // Given a moment after the split cover's Save before any swipe: the
        // cover may still be animating away. Every test meets the cover
        // since #285, so this is the common path now.
        let settle = Date().addingTimeInterval(5)
        while !reachable() && Date() < settle {
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Either can be below the fold at the accessibility sizes (#249).
        var swipes = 0
        while !reachable() && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        // And back down. On an SE at AccessibilityXXXL with a fresh store
        // (day buttons, not a Resume card), Push was not hittable at rest
        // and a full swipe up carries it past the top; one swipe back down
        // leaves it hittable. Before #285 these tests resumed a draft and
        // never met that layout (#285, measured on ChickenBreast-SE).
        swipes = 0
        while !reachable() && swipes < 6 {
            app.swipeDown()
            swipes += 1
        }
        if resume.exists && resume.isHittable {
            resume.tap()
            return
        }
        XCTAssertTrue(push.waitForExistence(timeout: 5) && push.isHittable,
                      "the Push day should be offered and tappable, scrolling if it has to")
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
        // Hittable once the sheet has finished rising, not at first existence.
        // "Keep training" is pinned to the sheet's bottom edge at every text
        // size; the reasons above it scroll, and at accessibility sizes start
        // below the medium detent (#316), so they can't be the signal.
        XCTAssertTrue(wait(for: app.buttons["finish.confirmation.cancel"], toMatch: "hittable == true", timeout: 5))
        if requiresBottomPosition {
            XCTAssertGreaterThan(
                sheet.frame.minY,
                app.frame.height * 0.35,
                "partial-finish confirmation should rise from the bottom, not float near the top"
            )
        }

        let keepTraining = app.buttons["finish.confirmation.cancel"]
        XCTAssertTrue(keepTraining.isHittable)
        keepTraining.tap()
        // Waits for it to go. `XCTAssertFalse(sheet.waitForExistence(...))`
        // returned true the instant the sheet was still mid-dismissal (#285).
        XCTAssertTrue(wait(for: sheet, toMatch: "exists == false", timeout: 5),
                      "Keep training should dismiss the confirmation")
    }
}
