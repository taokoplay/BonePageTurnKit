import XCTest
import UIKit

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

    /// 用真实系统栏和窗口截图验证隐藏、扩展、恢复，不用按钮状态冒充可读区域变化。
    func testHidingControlsExpandsReadingAreaAndKeepsFullScreenBackground() throws {
        let app = launch()
        let reading = app.otherElements["duo-reading-viewport"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        let before = reading.frame
        try assertFullScreenBackground(app, readingFrame: before)
        capture(app, name: "Duo控制栏显示-全屏阅读背景")
        app.buttons["duo-settings"].tap()
        app.buttons["隐藏控制栏"].tap()
        let restore = app.buttons["duo-show-controls"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(restore.isHittable)
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        let hidden = reading.frame
        XCTAssertGreaterThan(hidden.width, before.width + 20, "隐藏侧栏后正文必须使用释放出的宽度")
        XCTAssertFalse(app.buttons["duo-settings"].isHittable)
        XCTAssertFalse(app.buttons["duo-next"].isHittable)
        XCTAssertTrue(hidden.contains(restore.frame), "恢复按钮必须位于避开摄像头和折痕的正文区域")
        try assertFullScreenBackground(app, readingFrame: hidden)
        capture(app, name: "Duo控制栏隐藏-正文扩展")
        restore.tap()
        XCTAssertTrue(app.buttons["duo-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["duo-settings"].isHittable)
        XCTAssertTrue(app.buttons["duo-next"].isHittable)
        XCTAssertFalse(restore.isHittable)
        XCTAssertTrue(app.staticTexts["duo-source-5"].exists)
        let restored = reading.frame
        XCTAssertEqual(restored.width, before.width, accuracy: 1)
        try assertFullScreenBackground(app, readingFrame: restored)
        capture(app, name: "Duo控制栏恢复-源页不变")
        let geometry = XCTAttachment(string: "显示 \(before)；隐藏 \(hidden)；恢复 \(restored)")
        geometry.name = "Duo控制栏可读区域尺寸"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    /// 半翻时收起控制栏必须取消旧事务，重新布局后仍能恢复按钮并继续阅读。
    func testHidingControlsCancelsPaperPreviewAndCanResumePaging() {
        let app = launch()
        app.buttons["duo-settings"].tap()
        app.buttons["半翻预览"].tap()
        app.buttons["duo-settings"].tap()
        app.buttons["隐藏控制栏"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-5"].waitForExistence(timeout: 5))
        app.buttons["duo-show-controls"].tap()
        app.buttons["duo-next"].tap()
        XCTAssertTrue(app.staticTexts["duo-source-6"].waitForExistence(timeout: 5))
    }

    /// - Parameters: app: 实际应用；readingFrame: 正文容器窗口坐标；在远离摄像头和控件的四边检查统一底色。
    private func assertFullScreenBackground(_ app: XCUIApplication, readingFrame: CGRect) throws {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let normalized = try XCTUnwrap(context.makeImage())
        let bytes = try XCTUnwrap(normalized.dataProvider?.data) as Data
        let window = app.windows.firstMatch.frame
        func rgb(at point: CGPoint) -> [Int] {
            let x = min(image.width - 1, max(0, Int((point.x - window.minX) / window.width * CGFloat(image.width))))
            let y = min(image.height - 1, max(0, Int((point.y - window.minY) / window.height * CGFloat(image.height))))
            let index = (y * image.width + x) * 4
            return (0..<3).map { Int(bytes[index + $0]) }
        }
        let paper = rgb(at: CGPoint(x: readingFrame.minX + 4, y: readingFrame.midY))
        for point in [CGPoint(x: window.minX + 6, y: window.midY),
                      CGPoint(x: window.maxX - 6, y: window.midY),
                      CGPoint(x: window.midX, y: window.minY + 6),
                      CGPoint(x: window.midX, y: window.maxY - 6)] {
            let edge = rgb(at: point)
            XCTAssertTrue(zip(paper, edge).allSatisfy { abs($0.0 - $0.1) <= 10 },
                          "窗口边缘 \(point) 颜色 \(edge) 应与阅读背景 \(paper) 一致")
        }
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
