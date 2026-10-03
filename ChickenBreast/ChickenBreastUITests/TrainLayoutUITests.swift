//
//  TrainLayoutUITests.swift
//  ChickenBreastUITests
//

import XCTest

/// Train has to fit — or scroll — on the smallest phone and at the largest
/// text size (#249).
///
/// Train used to be a `VStack` centred between two `Spacer`s with no scroll
/// view. When the stack was taller than the screen it overflowed at both ends:
/// the sync badge and the cycle line drew on top of the large title, and the
/// digest and volume rows sat behind the tab bar where swiping could never
/// bring them out. On an iPhone SE that happened at the *default* text size.
///
/// The digest row only exists once something has been logged, so this test
/// finishes a workout to make one. Since #285 every test starts from an empty
/// store, so that finished workout no longer leaks into any other test.
final class TrainLayoutUITests: ChickenBreastUITestCase {

    func testTrainNeverOverlapsTitleOrTabBarAtDefaultSize() throws {
        try assertTrainLayout(arguments: [], sizeName: "default")
    }

    /// The raw value is the short `UICTContentSizeCategoryAccessibilityXXXL`;
    /// the long spelling is silently ignored and the test would pass at the
    /// default size without saying so.
    func testTrainNeverOverlapsTitleOrTabBarAtAccessibilityXXXL() throws {
        try assertTrainLayout(
            arguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ],
            sizeName: "AccessibilityXXXL"
        )
    }

    // MARK: -

    private func assertTrainLayout(arguments: [String], sizeName: String) throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(arguments: arguments)
        XCTAssertTrue(reachTrainScreen(app), "Train should become reachable")

        // Measured with the day buttons showing, which is the taller of the
        // two stacks: one Resume card replaces three day buttons.
        if app.buttons["home.resume"].exists || !digestRow(in: app).waitForExistence(timeout: 10) {
            // A fresh store has nothing to digest. One logged set is a first
            // record, which is a bullet; finishing also clears the draft.
            // Relaunched on the same store, which is the point (#285).
            try logOneSetAndFinish(app)
            app.terminate()
            app = launch(arguments: arguments, freshState: false)
            XCTAssertTrue(reachTrainScreen(app), "Train should come back after finishing")
        }

        let digest = digestRow(in: app)
        let volume = volumeRow(in: app)
        XCTAssertTrue(digest.waitForExistence(timeout: 15), "the digest row should appear once there is a record")
        XCTAssertTrue(volume.waitForExistence(timeout: 15), "the volume row is unconditional once insights load")
        // Let the insights' late arrival settle before measuring anything.
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(app, "\(sizeName)-train-at-rest")

        // 1. Nothing on Train draws over the large title, at rest.
        let title = app.navigationBars.staticTexts["ChickenBreast"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the large title should be on screen")
        let titleFrame = title.frame
        print("#249 [\(sizeName)] nav title frame: \(titleFrame)")
        let overlapping = try trainTextFrames(in: app).filter { $0.frame.intersects(titleFrame) }
        for text in overlapping {
            print("#249 [\(sizeName)] OVERLAPS TITLE: \"\(text.label)\" \(text.frame)")
        }
        XCTAssertTrue(
            overlapping.isEmpty,
            "[\(sizeName)] Train text overlaps the navigation title \(titleFrame): " +
            overlapping.map { "\"\($0.label)\" \($0.frame)" }.joined(separator: ", ")
        )

        // 2. The digest and volume rows can be scrolled fully above the tab bar.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "the tab bar should be on screen")
        // The Health card only shows until Health has been answered, so it is
        // evidence rather than an assertion: #249 found it truncated to
        // "Use re…" / "Sleep an…" at AccessibilityXXXL.
        let health = app.staticTexts["Use recovery data"]
        if health.exists, scrollUntilClearOfTabBar(health, tabBar: tabBar, in: app) {
            print("#249 [\(sizeName)] health card title frame: \(health.frame)")
            attachScreenshot(app, "\(sizeName)-train-health-card")
        }
        for (name, row) in [("digest", digest), ("volume", volume)] {
            let visible = scrollUntilClearOfTabBar(row, tabBar: tabBar, in: app)
            print("#249 [\(sizeName)] \(name) row frame: \(row.frame) hittable: \(row.isHittable) tab bar minY: \(tabBar.frame.minY)")
            XCTAssertTrue(
                visible,
                "[\(sizeName)] the \(name) row should be reachable by scrolling and sit fully above the tab bar " +
                "(row \(row.frame), tab bar \(tabBar.frame))"
            )
        }
        attachScreenshot(app, "\(sizeName)-train-scrolled")

        // 3. The digest row is a full-size target.
        print("#249 [\(sizeName)] digest row height: \(digest.frame.height)")
        XCTAssertGreaterThanOrEqual(digest.frame.height, 44, "[\(sizeName)] the digest row should be at least 44pt tall")
    }

    private func digestRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "to look at")).firstMatch
    }

    private func volumeRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Behind on", "Volume this week"
        )).firstMatch
    }

    /// Swipes until `row` is hittable with its whole frame above the tab bar.
    /// "Hittable" alone is not enough: XCUI only checks the centre point, so a
    /// row half under the bar can pass it.
    private func scrollUntilClearOfTabBar(_ row: XCUIElement, tabBar: XCUIElement,
                                          in app: XCUIApplication) -> Bool {
        func clear() -> Bool {
            row.exists && row.isHittable && row.frame.maxY <= tabBar.frame.minY
        }
        var swipes = 0
        while !clear() && swipes < 6 {
            // Dragged from the upper half of the screen so it never starts on
            // the tab bar, and slowly enough to stop where it lands.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
        return clear()
    }

    /// Every visible static text outside the navigation and tab bars.
    private func trainTextFrames(in app: XCUIApplication) throws -> [(label: String, frame: CGRect)] {
        let snapshot = try app.snapshot()
        var found: [(String, CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .navigationBar || node.elementType == .tabBar { return }
            if node.elementType == .staticText, !node.frame.isEmpty, !node.label.isEmpty {
                found.append((node.label, node.frame))
            }
            for child in node.children { walk(child) }
        }
        walk(snapshot)
        return found
    }

    private func logOneSetAndFinish(_ app: XCUIApplication) throws {
        try openPushDay(app)
        startSessionIfPreviewed(app)
        let logSet = app.buttons["Log Set"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 20), "Log Set should be reachable")
        makeLogSetAvailable(app, logSet)
        logSet.tap()

        let finish = app.buttons["Finish workout"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 20))
        if !finish.isHittable { app.swipeUp() }
        finish.tap()
        // An early finish asks why (#316); "Another reason" finishes without a cause.
        let confirm = app.buttons["finish.reason.unknown"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        let done = app.buttons["completion.done"]
        if done.waitForExistence(timeout: 25) {
            if !done.isHittable { app.swipeUp() }
            done.tap()
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
