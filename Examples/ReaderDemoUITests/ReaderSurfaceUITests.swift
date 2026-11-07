import XCTest

@MainActor
final class ReaderSurfaceUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--surface-reader"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["surface-geometry"].waitForExistence(timeout: 8))
        return app
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testThreeMotionModesExposeCoordinatesAndRestoreAfterCancellation() {
        for (mode, arguments) in [(0, [String]()), (1, ["--surface-chrome"]), (2, ["--surface-whole"])] {
            let app = launch(arguments)
            let header = app.staticTexts["surface-header-0"]
            let footer = app.staticTexts["surface-footer-0"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let before = header.frame
            let footerBefore = footer.frame
            let layoutBefore = app.staticTexts["surface-geometry"].label
            app.buttons["surface-preview"].tap()
            if mode == 0 {
                XCTAssertEqual(header.frame, before)
                XCTAssertEqual(footer.frame, footerBefore)
            } else {
                XCTAssertLessThan(header.frame.minX, before.minX - 20)
                XCTAssertLessThan(footer.frame.minX, footerBefore.minX - 20)
            }
            XCTAssertEqual(app.staticTexts["surface-geometry"].label, layoutBefore)
            capture(app, name: "外壳三档-\(mode)-半翻预览")
            app.buttons["surface-cancel"].tap()
            XCTAssertEqual(header.frame, before)
            app.buttons["surface-next"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "页眉 · 第 2 页")).firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testContinuousScrollKeepsChromeFixedAndReportsHiddenSlots() {
        let app = launch(["--continuous"])
        let header = app.staticTexts["surface-header-fixed"]
        let footer = app.staticTexts["surface-footer-fixed"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let before = header.frame
        let footerBefore = footer.frame
        let initialText = header.label
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(header.frame, before)
        XCTAssertEqual(footer.frame, footerBefore)
        XCTAssertNotEqual(header.label, initialText)
        capture(app, name: "连续只滚正文-固定页眉页脚背景")
        app.buttons["surface-chrome"].tap()
        XCTAssertFalse(header.exists)
        XCTAssertFalse(footer.exists)
        XCTAssertTrue(app.staticTexts["surface-geometry"].label.contains("页眉  关闭"))
        XCTAssertTrue(app.staticTexts["surface-geometry"].label.contains("页脚  关闭"))
        capture(app, name: "装饰关闭-正文视口展开")
    }
}
