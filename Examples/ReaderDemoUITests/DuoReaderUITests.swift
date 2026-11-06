import XCTest

/// 原生窗口变化验收；真实折叠姿态由 Device Hub 单独驱动并保留截图证据。
@MainActor
final class DuoReaderUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--duo-reader", "--duo-source=5"]
        app.launch()
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeRotationKeepsSourcePageAndControlsReachable() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["duo-next"].isHittable)
        XCTAssertTrue(app.buttons["duo-settings"].isHittable)
        capture(app, name: "自适应阅读-横向-源页5")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        app.buttons["duo-next"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-6"].waitForExistence(timeout: 5))
        capture(app, name: "自适应阅读-纵向-翻至源页6")
    }

    func testSystemMenuChangesLayoutWithoutResettingSourceAnchor() {
        let app = launch()
        app.buttons["duo-settings"].tap()
        app.buttons["始终单页"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["duo-spread"].exists)
        app.buttons["duo-settings"].tap()
        app.buttons["自动单双页"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        capture(app, name: "自适应阅读-自动编排保位")
    }

    func testRotationPreservesAnchorAndAllowsPaperCancellation() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["duo-settings"].tap()
        app.buttons["半翻预览"].tap()
        let before = app.otherElements["duo-reader"].frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let after = app.otherElements["duo-reader"].frame
        let geometry = XCTAttachment(string: "旋转前 \(before)，旋转后 \(after)\n\(app.debugDescription)")
        geometry.name = "Duo旋转视口证据"
        geometry.lifetime = .keepAlways
        add(geometry)
        if before == after {
            // Duo 可以接受物理旋转而保持应用形状；不把这种情况冒充布局变化。
            let value = app.otherElements["duo-reader"].value as? String
            XCTAssertTrue(value?.hasPrefix("第 5 页，") == true)
            if !app.staticTexts["duo-source-5"].exists {
                app.buttons["duo-settings"].tap()
                app.buttons["取消翻页"].tap()
            }
        }
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5), "旋转前 \(before)，旋转后 \(after)")
        app.buttons["duo-next"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-6"].waitForExistence(timeout: 5))
        capture(app, name: "自适应阅读-旋转后取消预览并继续")
    }
}
