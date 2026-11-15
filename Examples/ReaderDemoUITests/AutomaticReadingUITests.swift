import XCTest

@MainActor
final class AutomaticReadingUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--automatic-reader"]
        app.launch()
        XCTAssertTrue(app.staticTexts["automatic-position"].waitForExistence(timeout: 8))
        return app
    }
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 6) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testStyledCoverPreviewCancelsToOriginalPage() {
        let app = XCUIApplication(); app.launchArguments = ["--paged-modes", "--cover-style"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["paged-status"].waitForExistence(timeout: 8))
        let initial = app.staticTexts["paged-status"].label
        app.buttons["paged-preview"].tap()
        waitFor { app.staticTexts["paged-message"].label.contains("当前停在翻页中途") }
        capture(app, name: "覆盖圆角阴影-半翻")
        app.buttons["paged-cancel"].tap()
        XCTAssertEqual(app.staticTexts["paged-status"].label, initial)
        capture(app, name: "覆盖圆角阴影-取消恢复")
        app.buttons["paged-next"].tap()
        waitFor { app.staticTexts["paged-status"].label != initial }
    }
    func testExternalTurnsUseCommandsAndNativeSwipeAndRespectPause() {
        let app = launch(); defer { app.terminate() }
        app.buttons["automatic-next"].tap()
        waitFor { app.staticTexts["automatic-position"].label.contains("源页 2 /") }
        let reader = app.otherElements["automatic-reader"]
        reader.swipeLeft()
        waitFor { app.staticTexts["automatic-position"].label.contains("源页 3 /") }
        app.buttons["automatic-pause"].tap()
        app.buttons["automatic-next"].tap()
        XCTAssertTrue(app.staticTexts["automatic-position"].label.contains("源页 3 /"))
        app.buttons["automatic-pause"].tap()
        app.buttons["automatic-previous"].tap()
        waitFor { app.staticTexts["automatic-position"].label.contains("源页 2 /") }
        capture(app, name: "自动阅读-外部手势与原生滑动")
    }
    func testContinuousSpeedMenuPauseAndTimedPageTurns() {
        let app = launch(); defer { app.terminate() }
        app.segmentedControls["automatic-mode"].buttons["自动滚屏"].tap()
        let initial = app.staticTexts["automatic-position"].label
        waitFor { app.staticTexts["automatic-position"].label != initial }
        app.buttons["automatic-pause"].tap()
        app.buttons["automatic-speed"].tap()
        XCTAssertTrue(app.staticTexts["automatic-state"].label.contains("paused"))
        XCTAssertTrue(app.staticTexts["automatic-position"].label.contains("速度 2x"))
        app.buttons["automatic-menu"].tap()
        let beforeDeniedPan = app.staticTexts["automatic-position"].label
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(app.staticTexts["automatic-position"].label, beforeDeniedPan)
        app.buttons["automatic-menu"].tap()
        app.scrollViews.firstMatch.swipeUp()
        waitFor { app.staticTexts["automatic-position"].label != beforeDeniedPan }
        let paused = app.staticTexts["automatic-position"].label
        XCTAssertTrue(app.staticTexts["automatic-state"].label.contains("paused"))
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.staticTexts["automatic-position"].label != paused }, object: nil)
        unchanged.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 1.2), .completed)
        capture(app, name: "自动阅读-滚屏主动暂停与调速")
        app.segmentedControls["automatic-mode"].buttons["定时翻页"].tap()
        let first = app.staticTexts["automatic-position"].label
        waitFor { app.staticTexts["automatic-position"].label != first }
        app.buttons["automatic-pause"].tap()
        XCTAssertTrue(app.staticTexts["automatic-state"].label.contains("paused"))
        capture(app, name: "自动阅读-定时翻页与进度")
        app.segmentedControls["automatic-mode"].buttons["手势翻页"].tap()
        XCTAssertEqual(app.staticTexts["automatic-state"].label, "手势：等待输入")
    }
}
