import XCTest

/// 独立示例的原生触摸回归，不用程序化翻页冒充实际滚动手势。
@MainActor
final class ReaderDemoUITests: XCTestCase {
    func testNativeDoubleTapAndPinchRetainContentNavigation() {
        let app = launch(["--slide"])
        app.scrollViews.firstMatch.doubleTap()
        drag(app.scrollViews.firstMatch)
        expectGroup(1, in: app)
        screenshot(app, name: "原生双击放大")
        app.buttons["advanced-zoom"].tap()
        app.scrollViews.firstMatch.pinch(withScale: 2, velocity: 1)
        drag(app.scrollViews.firstMatch)
        expectGroup(1, in: app)
        screenshot(app, name: "原生捏合放大")
        app.buttons["advanced-zoom"].tap()
        drag(app.scrollViews.firstMatch)
        expectGroup(2, in: app)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--expanded-reader"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["advanced-status"].waitForExistence(timeout: 8))
        return app
    }

    private func expectGroup(_ number: Int, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "组 \(number)/")
        let condition = XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts["advanced-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed)
    }

    private func drag(_ scroll: XCUIElement, forward: Bool = true, vertical: Bool = false) {
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: vertical ? 0.5 : (forward ? 0.85 : 0.15), dy: vertical ? 0.85 : 0.5))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: vertical ? 0.5 : (forward ? 0.15 : 0.85), dy: vertical ? 0.15 : 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNativePanHandsOffAtFitScaleForLTRAndRTL() {
        for rtl in [false, true] {
            let app = launch(["--slide"] + (rtl ? ["--rtl"] : []))
            expectGroup(1, in: app)
            drag(app.scrollViews.firstMatch, forward: !rtl)
            expectGroup(2, in: app)
            screenshot(app, name: "原生边缘交接-\(rtl ? "RTL" : "LTR")")
            app.terminate()
        }
    }

    func testZoomedContentRetainsDragUntilReset() {
        let app = launch(["--slide"])
        app.buttons["advanced-zoom"].tap()
        drag(app.scrollViews.firstMatch)
        expectGroup(1, in: app)
        app.buttons["advanced-zoom"].tap()
        drag(app.scrollViews.firstMatch)
        expectGroup(2, in: app)
        screenshot(app, name: "放大浏览后复位翻页")
    }

    func testLongImageScrollsInternallyBeforeCrossingPageBoundary() {
        let app = launch(["--slide", "--vertical", "--long-scroll"])
        drag(app.scrollViews.firstMatch, vertical: true)
        expectGroup(1, in: app)
        for _ in 0..<10 {
            if app.staticTexts["advanced-status"].label.hasPrefix("组 2/") { break }
            drag(app.scrollViews.firstMatch, vertical: true)
        }
        expectGroup(2, in: app)
        screenshot(app, name: "长图滚到底后同手势交接")
    }

    func testNativePanDrivesCentralSpreadAndVerticalPaper() {
        for arguments in [["--spread"], ["--vertical", "--arch"]] {
            let app = launch(arguments)
            drag(app.scrollViews.firstMatch, vertical: arguments.contains("--vertical"))
            expectGroup(2, in: app)
            screenshot(app, name: arguments.contains("--spread") ? "中央双页真实手势" : "纵向拱页真实手势")
            app.terminate()
        }
    }
}
