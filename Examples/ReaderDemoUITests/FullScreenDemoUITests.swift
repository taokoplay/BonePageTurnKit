import XCTest

@MainActor
final class FullScreenDemoUITests: XCTestCase {
    private func launch(reset: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--fullscreen-reader"] + (reset ? ["--reset-demo-settings"] : [])
        app.launch()
        XCTAssertTrue(app.otherElements["fullscreen-reader-canvas"].waitForExistence(timeout: 10))
        return app
    }
    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 6) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func tapCanvas(_ app: XCUIApplication) {
        app.otherElements["fullscreen-reader-canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func showMenu(_ app: XCUIApplication) {
        if !app.buttons["reader-settings-button"].isHittable { tapCanvas(app) }
        wait { app.buttons["reader-settings-button"].isHittable }
    }
    private func settings(_ app: XCUIApplication) {
        showMenu(app); app.buttons["reader-settings-button"].tap()
        XCTAssertTrue(app.tables["reader-settings"].waitForExistence(timeout: 5))
    }
    private func search(_ field: String, app: XCUIApplication) {
        let search = app.searchFields["settings-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if let text = search.value as? String, !text.isEmpty, text != "搜索设置" {
            if search.buttons.firstMatch.exists { search.buttons.firstMatch.tap() }
            else { search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count)) }
        }
        search.typeText(field)
        XCTAssertTrue(app.cells["setting-\(field)"].waitForExistence(timeout: 5))
    }
    private func choose(_ field: String, _ value: String, app: XCUIApplication) {
        search(field, app: app); app.cells["setting-\(field)"].tap()
        let choice = app.cells["choice-\(field)-\(value)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        XCTAssertTrue(app.tables["reader-settings"].waitForExistence(timeout: 5))
    }
    private func toggle(_ field: String, app: XCUIApplication) {
        search(field, app: app); app.switches["setting-\(field)"].tap()
    }
    private func number(_ field: String, _ value: String, app: XCUIApplication) {
        search(field, app: app); app.cells["setting-\(field)"].tap()
        let input = app.textFields["number-\(field)"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        let old = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
        app.alerts.buttons["确定"].tap()
    }
    private func apply(_ app: XCUIApplication) {
        app.buttons["settings-apply"].tap()
        wait { !app.tables["reader-settings"].exists }
        XCTAssertFalse(app.alerts["无法应用设置"].exists)
    }
    private func action(_ title: String, button: String, app: XCUIApplication) {
        showMenu(app); app.buttons[button].tap()
        let item = app.sheets.buttons[title]
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if item.exists && item.isHittable { break }
            app.sheets.firstMatch.swipeUp()
        }
        XCTAssertTrue(item.exists && item.isHittable, "菜单项不可点击：\(title)")
        item.tap()
    }
    /// 打开二维选择面板；无返回值。
    private func modePicker(_ app: XCUIApplication) {
        showMenu(app); app.buttons["reader-modes"].tap()
        XCTAssertTrue(app.scrollViews["reader-mode-picker"].waitForExistence(timeout: 5))
    }
    /// - Parameters: type: 类型原始值；axis: 中文方向；app: 测试应用。原生选择并应用两个维度。
    private func mode(_ type: String, axis: String, app: XCUIApplication) {
        modePicker(app)
        app.buttons["mode-type-\(type)"].tap()
        let direction = app.segmentedControls["mode-direction"].buttons[axis]
        XCTAssertTrue(direction.isEnabled); direction.tap()
        app.buttons["mode-apply"].tap()
        wait { !app.scrollViews["reader-mode-picker"].exists }
        XCTAssertFalse(app.alerts["无法应用翻页方式"].exists)
    }
    /// 系统列表将标题和值分成子元素，读取屏幕实际显示的文字。
    private func settingText(_ field: String, app: XCUIApplication) -> String {
        app.cells["setting-\(field)"].staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// 无参数；原生快速滑动、文字分区轻点和纵向连续输入都只按实际次数翻页。无返回值。
    func testRapidCurlNativeSwipesAndTextTaps() {
        let app = launch(); defer { app.terminate() }
        let canvas = app.otherElements["fullscreen-reader-canvas"]
        var expected = 0
        /// - Parameters: start: 实际起点；end: 实际终点；delta: 页码变化。无返回值，动作之间不主动等待收尾。
        func swipe(_ start: CGVector, _ end: CGVector, delta: Int) {
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .fast, thenHoldForDuration: 0)
            expected += delta
        }
        /// 无参数；仅在一组输入后核对最终页码，不在连续动作之间展开菜单或等待动画。无返回值。
        func verifyPosition() {
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        mode("curl", axis: "横向", app: app)
        for _ in 0..<3 { swipe(CGVector(dx: 0.85, dy: 0.5), CGVector(dx: 0.12, dy: 0.62), delta: 1) }
        for _ in 0..<2 { swipe(CGVector(dx: 0.15, dy: 0.5), CGVector(dx: 0.88, dy: 0.38), delta: -1) }
        verifyPosition()
        // 点击两侧翻页现在是默认开；不再切换设置，直接验证分区轻点。
        settings(app); apply(app)
        showMenu(app); app.buttons["reader-hide-menu"].tap()
        wait { !app.buttons["reader-settings-button"].isHittable }
        // 先验证普通正文轻点也不会被宿主与 SDK 重复消费。
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)).tap(); expected += 1
        verifyPosition()
        // 一次轻点启动收尾，紧接短按覆盖收尾结束附近的输入；处理方仍由按下时决定。
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.32)).tap(); expected += 1
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.72)).press(forDuration: 0.2); expected += 1
        verifyPosition()
        // 相邻轻点改变高度，避免将连续翻页误用成 TextKit 的双击选词手势。
        for y in [0.32, 0.55, 0.72] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: y)).tap(); expected += 1
        }
        for y in [0.42, 0.68] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: y)).tap(); expected -= 1
        }
        verifyPosition()
        capture(app, "快速连翻-横向滑动与正文轻点")
        mode("curl", axis: "纵向", app: app)
        for _ in 0..<2 { swipe(CGVector(dx: 0.5, dy: 0.85), CGVector(dx: 0.62, dy: 0.12), delta: 1) }
        for _ in 0..<2 { swipe(CGVector(dx: 0.5, dy: 0.15), CGVector(dx: 0.38, dy: 0.88), delta: -1) }
        verifyPosition()
        capture(app, "快速连翻-纵向往返后页码一致")
    }

    /// 无参数；短时间接触后快速滑动要完整落定，短距离慢滑要完整回弹，覆盖正反与横纵。无返回值。
    func testShortTouchCurlCompletesAndCancels() {
        let app = launch(); defer { app.terminate() }
        let canvas = app.otherElements["fullscreen-reader-canvas"]
        var expected = 0
        /// - Parameter title: 当前阶段。无返回值；核对终页后保留真实屏幕证据。
        func verify(_ title: String) {
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            capture(app, title)
        }
        for vertical in [false, true] {
            mode("curl", axis: vertical ? "纵向" : "横向", app: app)
            let nextStart = vertical ? CGVector(dx: 0.5, dy: 0.92) : CGVector(dx: 0.92, dy: 0.5)
            let nextEnd = vertical ? CGVector(dx: 0.51, dy: 0.52) : CGVector(dx: 0.52, dy: 0.51)
            canvas.coordinate(withNormalizedOffset: nextStart).press(forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: nextEnd), withVelocity: .fast, thenHoldForDuration: 0)
            expected += 1; verify("短触快滑-\(vertical ? "纵向" : "横向")-完成")
            let cancelEnd = vertical ? CGVector(dx: 0.5, dy: 0.88) : CGVector(dx: 0.88, dy: 0.5)
            canvas.coordinate(withNormalizedOffset: nextStart).press(forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: cancelEnd), withVelocity: .slow, thenHoldForDuration: 0)
            verify("短触小滑-\(vertical ? "纵向" : "横向")-回弹")
            let previousStart = vertical ? CGVector(dx: 0.5, dy: 0.08) : CGVector(dx: 0.08, dy: 0.5)
            let previousEnd = vertical ? CGVector(dx: 0.49, dy: 0.48) : CGVector(dx: 0.48, dy: 0.49)
            canvas.coordinate(withNormalizedOffset: previousStart).press(forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: previousEnd), withVelocity: .fast, thenHoldForDuration: 0)
            expected -= 1; verify("短触回翻-\(vertical ? "纵向" : "横向")-完成")
        }
    }

    /// 无参数；低速拖动后停住，过半屏即完成，未过半屏则回弹，覆盖横纵与前后方向。无返回值。
    func testSlowCurlReleasesAtCanvasMidpoint() {
        let app = launch(); defer { app.terminate() }
        let paged = app.otherElements["reader-paged"]
        var expected = 0
        /// - Parameters: start: 起点轴向比例；end: 终点轴向比例；vertical: 是否纵向。无返回值。
        func slow(_ start: CGFloat, _ end: CGFloat, vertical: Bool) {
            let a = vertical ? CGVector(dx: 0.5, dy: start) : CGVector(dx: start, dy: 0.5)
            let b = vertical ? CGVector(dx: 0.5, dy: end) : CGVector(dx: end, dy: 0.5)
            paged.coordinate(withNormalizedOffset: a).press(forDuration: 0.01,
                thenDragTo: paged.coordinate(withNormalizedOffset: b), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        /// - Parameter title: 当前动作阶段。无返回值；检查实际页码并保留终页截图。
        func verify(_ title: String) {
            showMenu(app)
            print("HALF_SCREEN_NATIVE \(title) expected=\(expected) actual=\(String(describing: app.staticTexts["reader-position"].value))")
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            capture(app, title)
        }
        for vertical in [false, true] {
            mode("curl", axis: vertical ? "纵向" : "横向", app: app)
            XCTAssertTrue(paged.waitForExistence(timeout: 5))
            slow(0.62, 0.49, vertical: vertical); expected += 1
            verify("慢拖-\(vertical ? "纵向" : "横向")-前翻过半完成")
            slow(0.72, 0.57, vertical: vertical)
            verify("慢拖-\(vertical ? "纵向" : "横向")-前翻未过半回弹")
            slow(0.02, 0.06, vertical: vertical)
            verify("慢拖-\(vertical ? "纵向" : "横向")-回翻未过半回弹")
            slow(0.38, 0.51, vertical: vertical); expected -= 1
            verify("慢拖-\(vertical ? "纵向" : "横向")-回翻过半完成")
        }
    }

    /// 无参数；原生按钮连续点击上一／下一页时，每组接受的方向按顺序完成，覆盖横纵向。无返回值。
    func testRapidPageButtonsKeepCompleteCurlSequence() {
        let app = launch(); defer { app.terminate() }
        var expected = 0
        for vertical in [false, true] {
            mode("curl", axis: vertical ? "纵向" : "横向", app: app)
            showMenu(app)
            let next = app.buttons["reader-next"], previous = app.buttons["reader-previous"]
            XCTAssertTrue(next.isHittable && previous.isHittable)
            // 同向连点组内不等待；分别检查组末页，避免混合净位移提前命中中间页。
            next.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            expected += 3
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            capture(app, "连续按钮-\(vertical ? "纵向" : "横向")-三次前翻完成")
            previous.tap(withNumberOfTaps: 2, numberOfTouches: 1)
            expected -= 2
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            print("RAPID_BUTTON_NATIVE axis=\(vertical ? "vertical" : "horizontal") accepted=next3,previous2 final=\(expected)")
            capture(app, "连续按钮-\(vertical ? "纵向" : "横向")-三次前翻后两次回翻")
        }
    }

    func testFullScreenCanvasAndTapToggleDoNotResizeReadingView() {
        let app = launch(); defer { app.terminate() }
        let canvas = app.otherElements["fullscreen-reader-canvas"]
        let frame = canvas.frame, screen = app.windows.firstMatch.frame
        XCTAssertEqual(frame.width, screen.width, accuracy: 1)
        XCTAssertEqual(frame.height, screen.height, accuracy: 1)
        XCTAssertFalse(app.buttons["reader-settings-button"].isHittable)
        capture(app, "全屏正文-菜单隐藏")
        showMenu(app)
        XCTAssertTrue(app.buttons["reader-debug"].isHittable)
        XCTAssertEqual(canvas.frame, frame)
        capture(app, "全屏正文-导航和底部菜单")
        tapCanvas(app)
        wait { !app.buttons["reader-settings-button"].isHittable }
        XCTAssertEqual(canvas.frame, frame)
        showMenu(app); app.buttons["reader-hide-menu"].tap()
        wait { !app.buttons["reader-settings-button"].isHittable }
        XCTAssertEqual(canvas.frame, frame)
    }

    /// 无参数；中部实际斜拖在横纵方向均可前后翻页，并继续使用唯一翻页事务。无返回值。
    func testMiddleCurlNativeDiagonalsInBothDirectionsAndAxes() {
        let app = launch(); defer { app.terminate() }
        var expected = 0
        /// - Parameters: start: 中部起点；end: 斜向终点；delta: 页码变化。无返回值。
        func drag(_ start: CGVector, _ end: CGVector, delta: Int) {
            let canvas = app.otherElements["fullscreen-reader-canvas"]
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.25)
            expected += delta
            showMenu(app)
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        mode("curl", axis: "横向", app: app)
        for cross: CGFloat in [0.7, 0.3] {
            drag(CGVector(dx: 0.65, dy: 0.5), CGVector(dx: 0.02, dy: cross), delta: 1)
            drag(CGVector(dx: 0.35, dy: 0.5), CGVector(dx: 0.98, dy: 1 - cross), delta: -1)
        }
        capture(app, "中部仿真-横向向下与向上斜拖")
        mode("curl", axis: "纵向", app: app)
        for cross: CGFloat in [0.7, 0.3] {
            drag(CGVector(dx: 0.5, dy: 0.65), CGVector(dx: cross, dy: 0.02), delta: 1)
            drag(CGVector(dx: 0.5, dy: 0.35), CGVector(dx: 1 - cross, dy: 0.98), delta: -1)
        }
        capture(app, "中部仿真-纵向左右斜拖")
    }

    func testArchNativeDiagonalsFollowBothAxesAndCancel() {
        let app = launch(); defer { app.terminate() }
        var expected = 0
        func drag(_ start: CGVector, _ end: CGVector, delta: Int) {
            let canvas = app.otherElements["reader-paged"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.25)
            expected += delta
            showMenu(app)
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        mode("arch", axis: "横向", app: app)
        drag(CGVector(dx: 0.82, dy: 0.56), CGVector(dx: 0.22, dy: 0.35), delta: 1)
        drag(CGVector(dx: 0.18, dy: 0.44), CGVector(dx: 0.78, dy: 0.65), delta: -1)
        drag(CGVector(dx: 0.82, dy: 0.44), CGVector(dx: 0.22, dy: 0.65), delta: 1)
        drag(CGVector(dx: 0.18, dy: 0.56), CGVector(dx: 0.78, dy: 0.35), delta: -1)
        drag(CGVector(dx: 0.80, dy: 0.5), CGVector(dx: 0.76, dy: 0.53), delta: 0)
        capture(app, "拱页-横向双向斜拖与短拖取消")
        mode("arch", axis: "纵向", app: app)
        drag(CGVector(dx: 0.5, dy: 0.82), CGVector(dx: 0.72, dy: 0.22), delta: 1)
        drag(CGVector(dx: 0.5, dy: 0.18), CGVector(dx: 0.28, dy: 0.78), delta: -1)
        drag(CGVector(dx: 0.5, dy: 0.82), CGVector(dx: 0.28, dy: 0.22), delta: 1)
        drag(CGVector(dx: 0.5, dy: 0.18), CGVector(dx: 0.72, dy: 0.78), delta: -1)
        capture(app, "拱页-纵向左右斜拖")
    }

    func testPreviousArchNativeUnfoldsAndShortPullCancels() {
        let app = launch(); defer { app.terminate() }
        mode("arch", axis: "横向", app: app)
        var expected = 0
        func drag(_ start: CGVector, _ end: CGVector, delta: Int) {
            let canvas = app.otherElements["reader-paged"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.3)
            expected += delta
            showMenu(app)
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        drag(CGVector(dx: 0.82, dy: 0.5), CGVector(dx: 0.22, dy: 0.5), delta: 1)
        drag(CGVector(dx: 0.18, dy: 0.5), CGVector(dx: 0.28, dy: 0.51), delta: 0)
        capture(app, "拱页-左到右短拖取消恢复当前页")
        drag(CGVector(dx: 0.18, dy: 0.5), CGVector(dx: 0.78, dy: 0.5), delta: -1)
        capture(app, "拱页-左到右展开上一页")
    }

    @objc func testSpreadArchWholeLeafTurnsAboveSpine() {
        let app = launch(); defer { app.terminate() }
        settings(app)
        choose("effect", "arch", app: app)
        choose("pageLayout", "spread", app: app)
        choose("spine", "center", app: app)
        apply(app)
        XCTAssertTrue(app.otherElements["reader-spread"].waitForExistence(timeout: 5))
        var expected = 0
        func drag(_ start: CGVector, _ end: CGVector, delta: Int) {
            let canvas = app.otherElements["reader-paged"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.3)
            expected += delta * 2
            showMenu(app)
            let actual = Int(app.staticTexts["reader-position"].value as? String ?? "")
            XCTAssertTrue(actual == expected || actual == expected + 1,
                "落定内容必须属于目标双页范围 \(expected)...\(expected + 1)，实际 \(String(describing: actual))")
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        app.buttons["reader-hide-menu"].tap()
        wait { !app.buttons["reader-settings-button"].isHittable }
        drag(CGVector(dx: 0.88, dy: 0.5), CGVector(dx: 0.18, dy: 0.5), delta: 1)
        capture(app, "双栏拱页-过书脊后完成")
        drag(CGVector(dx: 0.12, dy: 0.5), CGVector(dx: 0.82, dy: 0.5), delta: -1)
        drag(CGVector(dx: 0.88, dy: 0.5), CGVector(dx: 0.78, dy: 0.5), delta: 0)
        capture(app, "双栏拱页-短拖取消")
        drag(CGVector(dx: 0.88, dy: 0.5), CGVector(dx: 0.58, dy: 0.5), delta: 1)
        capture(app, "双栏拱页-书脊前松手完成")
    }

    /// 四角真实斜拖、短拖取消、纵向及 RTL 都通过同一公开翻页事务。
    func testCornerCurlNativeCornersCancelAndReadingOrder() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        var expected = 0
        func drag(_ start: CGVector, _ end: CGVector, delta: Int) {
            let canvas = app.otherElements["fullscreen-reader-canvas"]
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.25)
            expected += delta
            showMenu(app)
            XCTAssertEqual(app.staticTexts["reader-position"].value as? String, String(expected))
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
        }
        // 第一页的前向边界不能被角落拖动绕过。
        drag(CGVector(dx: 0.06, dy: 0.14), CGVector(dx: 0.72, dy: 0.35), delta: 0)
        drag(CGVector(dx: 0.94, dy: 0.14), CGVector(dx: 0.26, dy: 0.38), delta: 1)
        drag(CGVector(dx: 0.06, dy: 0.14), CGVector(dx: 0.74, dy: 0.38), delta: -1)
        drag(CGVector(dx: 0.94, dy: 0.86), CGVector(dx: 0.26, dy: 0.62), delta: 1)
        drag(CGVector(dx: 0.06, dy: 0.86), CGVector(dx: 0.74, dy: 0.62), delta: -1)
        drag(CGVector(dx: 0.94, dy: 0.14), CGVector(dx: 0.90, dy: 0.18), delta: 0)
        capture(app, "四角仿真-横向起翻与短拖回弹")
        mode("curl", axis: "纵向", app: app)
        drag(CGVector(dx: 0.12, dy: 0.86), CGVector(dx: 0.38, dy: 0.30), delta: 1)
        drag(CGVector(dx: 0.12, dy: 0.14), CGVector(dx: 0.38, dy: 0.70), delta: -1)
        drag(CGVector(dx: 0.88, dy: 0.86), CGVector(dx: 0.62, dy: 0.30), delta: 1)
        drag(CGVector(dx: 0.88, dy: 0.14), CGVector(dx: 0.62, dy: 0.70), delta: -1)
        settings(app); choose("readingOrder", "rtl", app: app); apply(app)
        mode("curl", axis: "横向", app: app)
        drag(CGVector(dx: 0.06, dy: 0.14), CGVector(dx: 0.74, dy: 0.38), delta: 1)
        drag(CGVector(dx: 0.94, dy: 0.86), CGVector(dx: 0.26, dy: 0.62), delta: -1)
        capture(app, "四角仿真-RTL往返后正文恢复")
    }

    /// 长正文不能先消耗页内拖动；两个方向均直接翻页，连续阅读仍由外层滚动。
    func testPagedTextSwipesTurnWithoutNestedScrolling() {
        let app = launch(); defer { app.terminate() }
        settings(app); number("fontSize", "30", app: app); apply(app)
        mode("slide", axis: "纵向", app: app)
        let body = app.textViews["fullscreen-demo-body"].firstMatch
        let first = body.value as? String
        XCTAssertNotNil(first)
        body.swipeUp()
        wait { body.exists && (body.value as? String) != first }
        showMenu(app)
        XCTAssertEqual(app.staticTexts["reader-position"].value as? String, "1")
        app.buttons["reader-hide-menu"].tap()
        body.swipeDown()
        wait { body.exists && (body.value as? String) == first }
        capture(app, "固定正文-纵向手势直接翻页")
        mode("slide", axis: "横向", app: app)
        body.swipeLeft()
        wait { body.exists && (body.value as? String) != first }
        body.swipeRight()
        wait { body.exists && (body.value as? String) == first }
        showMenu(app); tapCanvas(app)
        wait { !app.buttons["reader-settings-button"].isHittable }
        mode("continuous", axis: "纵向", app: app)
        let before = body.frame.minY
        app.otherElements["fullscreen-reader-canvas"].swipeUp()
        wait { !body.exists || body.frame.minY < before - 24 }
        showMenu(app)
        capture(app, "连续模式-外层滚动保持可用")
    }

    func testAllSupportedTypeDirectionPairsTurnAndKeepFullScreen() {
        let app = launch(); defer { app.terminate() }
        let canvas = app.otherElements["fullscreen-reader-canvas"], initial = canvas.frame
        for (type, axis) in [("none", "横向"), ("none", "纵向"), ("slide", "横向"), ("slide", "纵向"), ("cover", "横向"), ("curl", "横向"), ("curl", "纵向"), ("arch", "横向"), ("arch", "纵向"), ("continuous", "纵向")] {
            mode(type, axis: axis, app: app)
            wait { !app.buttons["reader-settings-button"].isHittable }
            XCTAssertEqual(canvas.frame, initial)
            showMenu(app)
            let before = app.staticTexts["reader-position"].label
            app.buttons["reader-next"].tap()
            wait { app.staticTexts["reader-position"].label != before }
            if app.staticTexts["reader-notice"].exists { XCTAssertFalse(app.staticTexts["reader-notice"].label.contains("无法应用")) }
        }
        app.buttons["reader-hide-menu"].tap()
        app.scrollViews.firstMatch.swipeUp()
        capture(app, "全屏连续滚屏")
    }

    func testModePickerGridRestrictionsCancelAndThemes() {
        let app = launch(); defer { app.terminate() }
        modePicker(app)
        let none = app.buttons["mode-type-none"], slide = app.buttons["mode-type-slide"], cover = app.buttons["mode-type-cover"]
        XCTAssertEqual(none.frame.minY, slide.frame.minY, accuracy: 1)
        XCTAssertEqual(cover.frame.minY, slide.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["mode-type-curl"].frame.minY, slide.frame.minY)
        XCTAssertTrue(slide.isSelected)
        capture(app, "翻页方式-类型网格与独立方向-浅色")
        let directions = app.segmentedControls["mode-direction"]
        directions.buttons["纵向"].tap()
        cover.tap()
        XCTAssertTrue(directions.buttons["横向"].isSelected)
        XCTAssertFalse(directions.buttons["纵向"].isEnabled)
        XCTAssertTrue(app.staticTexts["mode-hint"].label.contains("仅支持横向"))
        app.buttons["mode-type-continuous"].tap()
        XCTAssertTrue(directions.buttons["纵向"].isSelected)
        XCTAssertFalse(directions.buttons["横向"].isEnabled)
        app.buttons["mode-cancel"].tap()
        showMenu(app)
        XCTAssertEqual(app.staticTexts["reader-state"].label, "横向平移")
        modePicker(app)
        XCTAssertTrue(app.buttons["mode-type-slide"].isSelected)
        XCTAssertTrue(directions.buttons["横向"].isSelected)
        app.buttons["mode-type-curl"].tap()
        app.navigationBars["翻页方式"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        wait { !app.scrollViews["reader-mode-picker"].exists }
        settings(app); choose("appearance", "dark", app: app); apply(app)
        modePicker(app)
        for type in ["none", "slide", "cover", "curl", "arch", "continuous"] {
            XCTAssertTrue(app.buttons["mode-type-\(type)"].isHittable)
            XCTAssertGreaterThanOrEqual(app.buttons["mode-type-\(type)"].frame.height, 44)
        }
        XCTAssertTrue(app.buttons["mode-apply"].isHittable)
        capture(app, "翻页方式-类型网格与独立方向-深色")
        app.buttons["mode-cancel"].tap()
    }

    func testInvalidConfigurationKeepsDraftAndValidSpreadRTLApplies() {
        let app = launch(); defer { app.terminate() }
        settings(app)
        choose("effect", "cover", app: app); choose("axis", "vertical", app: app)
        app.buttons["settings-apply"].tap()
        XCTAssertTrue(app.alerts["无法应用设置"].waitForExistence(timeout: 3))
        app.alerts.buttons["确定"].tap()
        choose("axis", "horizontal", app: app)
        choose("effect", "curl", app: app); choose("pageLayout", "spread", app: app)
        choose("readingOrder", "rtl", app: app); choose("spine", "center", app: app)
        toggle("firstPageIsCover", app: app)
        apply(app)
        XCTAssertTrue(app.otherElements["reader-spread"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reader-position"].label.contains("双页"))
        let before = app.staticTexts["reader-position"].label
        app.buttons["reader-next"].tap()
        wait { app.staticTexts["reader-position"].label != before }
        capture(app, "全屏双页-RTL与中央书脊")
        settings(app); choose("pageLayout", "single", app: app); choose("spine", "maximum", app: app)
        apply(app)
        XCTAssertTrue(app.staticTexts["reader-position"].label.contains("单页"))
        XCTAssertFalse(app.otherElements["reader-spread"].exists)
    }

    func testImageSlicingZoomDarkAppearanceAndPersistence() {
        var app = launch()
        settings(app)
        choose("content", "wideImage", app: app); choose("sliceMode", "splitWide", app: app)
        toggle("zoomEnabled", app: app); number("initialZoom", "2", app: app)
        choose("appearance", "dark", app: app); number("coverCorner", "40", app: app)
        choose("effect", "cover", app: app)
        apply(app)
        app.buttons["reader-hide-menu"].tap()
        capture(app, "全屏漫画-宽图切片与深色")
        showMenu(app)
        action("还原图片缩放", button: "reader-debug", app: app)
        settings(app); choose("content", "tallImage", app: app); choose("sliceMode", "vertical", app: app)
        number("sliceRatio", "1", app: app); choose("zoomFit", "width", app: app)
        apply(app)
        app.buttons["reader-hide-menu"].tap()
        capture(app, "全屏漫画-长图分片与缩放")
        app.terminate(); app = launch(reset: false); defer { app.terminate() }
        settings(app)
        search("content", app: app)
        XCTAssertTrue(settingText("content", app: app).contains("长图"))
        search("appearance", app: app)
        XCTAssertTrue(settingText("appearance", app: app).contains("深色"))
        app.buttons["settings-cancel"].tap()
        showMenu(app); app.buttons["reader-hide-menu"].tap()
        app.scrollViews.firstMatch.pinch(withScale: 1.3, velocity: 1)
        showMenu(app)
    }

    func testTimedReadingPauseAndExitRecovery() {
        let app = launch(); defer { app.terminate() }
        settings(app); number("pageInterval", "0.6", app: app); apply(app)
        action("定时翻页", button: "reader-automatic", app: app)
        let firstText = app.textViews.firstMatch.value as? String
        wait { app.textViews.firstMatch.exists && (app.textViews.firstMatch.value as? String) != firstText }
        showMenu(app)
        XCTAssertEqual(app.staticTexts["reader-state"].label, "已暂停")
        let position = app.staticTexts["reader-position"].label
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.staticTexts["reader-position"].label != position }, object: nil)
        unchanged.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 1.2), .completed)
        action("主动暂停", button: "reader-automatic", app: app)
        showMenu(app)
        action("开始退出（可取消）", button: "reader-debug", app: app)
        app.buttons["reader-hide-menu"].tap()
        showMenu(app)
        action("取消退出", button: "reader-debug", app: app)
        XCTAssertTrue(app.staticTexts["reader-notice"].label.contains("已取消退出"))
        action("确认退出并重新打开", button: "reader-debug", app: app)
        wait { app.staticTexts["reader-notice"].label.contains("重新打开") }
        capture(app, "自动阅读暂停-退出协议恢复")
    }

    func testContinuousReplacementWaitsForInstallationAndBindsNewContent() {
        let app = launch(); defer { app.terminate() }
        mode("continuous", axis: "纵向", app: app)
        action("切换调试安装门禁", button: "reader-debug", app: app)
        action("异步回填当前内容", button: "reader-debug", app: app)
        XCTAssertTrue(app.staticTexts["reader-notice"].label.contains("已提交"))
        action("切换调试安装门禁", button: "reader-debug", app: app)
        wait { app.staticTexts["reader-notice"].label.contains("installed") }
        app.buttons["reader-hide-menu"].tap()
        let texts = app.textViews.allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertTrue(texts.contains { $0.contains("回：") || $0.contains("回（續）") })
        XCTAssertFalse(texts.contains { $0.contains("内容位置已失效") })
        app.scrollViews.firstMatch.swipeUp()
        showMenu(app)
        capture(app, "连续回填-新版本正文与安装门禁")
    }

    func testSettingsSearchPrecisionCancelAndLargeText() {
        let app = launch(); defer { app.terminate() }
        settings(app)
        number("fontSize", "30", app: app)
        number("paperPixels", "2097152", app: app)
        number("maximumRequests", "3", app: app)
        search("maximumRequests", app: app)
        capture(app, "完整设置-搜索连续补屏预算")
        app.buttons["settings-cancel"].tap()
        settings(app); search("fontSize", app: app)
        XCTAssertTrue(settingText("fontSize", app: app).contains("20"))
        number("fontSize", "30", app: app)
        choose("appearance", "dark", app: app)
        apply(app)
        app.buttons["reader-hide-menu"].tap()
        capture(app, "深色大字正文")
        showMenu(app); settings(app)
        search("coverCorner", app: app)
        capture(app, "完整设置-深色数字参数")
        app.buttons["settings-cancel"].tap()
    }

    /// 无参数；翻页面板可直接切换手感并进入完整阅读设置。无返回值。
    func testModeSheetCarriesPageTurnFeelAndAllSettings() {
        let app = launch(); defer { app.terminate() }
        modePicker(app)
        XCTAssertTrue(app.switches["mode-animated"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["mode-tap-turns"].exists)
        XCTAssertTrue(app.switches["mode-pan"].exists)
        app.switches["mode-tap-turns"].tap()
        app.buttons["mode-all-settings"].tap()
        XCTAssertTrue(app.tables["reader-settings"].waitForExistence(timeout: 5))
        capture(app, "翻页面板-手感开关与全部设置入口")
    }

    /// 无参数；类型里的“系统仿真”应用后打开系统 pageCurl 基准。无返回值。
    func testModeTypeSystemCurlOpensSystemBaseline() {
        let app = launch(); defer { app.terminate() }
        modePicker(app)
        let button = app.buttons["mode-type-systemCurl"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<6 where !button.isHittable { app.scrollViews["reader-mode-picker"].swipeUp() }
        XCTAssertTrue(button.isHittable, "系统仿真类型应可选择")
        button.tap()
        app.buttons["mode-apply"].tap()
        XCTAssertTrue(app.staticTexts["system-curl-position"].waitForExistence(timeout: 8))
        capture(app, "类型-系统仿真基准")
    }

    /// 无参数；反向半程松手与正向同样不应掉帧。无返回值。
    func testMidwayReleaseFramePacingBothDirections() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        action("帧率诊断（翻页时观察）", button: "reader-debug", app: app)
        let canvas = app.otherElements["fullscreen-reader-canvas"]
        func dragAndReport(_ name: String, from: CGVector, to: CGVector) {
            let start = canvas.coordinate(withNormalizedOffset: from)
            let end = canvas.coordinate(withNormalizedOffset: to)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            wait { (app.staticTexts["reader-frame-monitor"].label).contains("avg") }
            print("FRAMEPACING \(name) -> \(app.staticTexts["reader-frame-monitor"].label)")
        }
        // 反向：自左向右拖到一半松手
        dragAndReport("previous", from: CGVector(dx: 0.06, dy: 0.5), to: CGVector(dx: 0.40, dy: 0.5))
        // 正向：自右向左拖到一半松手
        dragAndReport("next", from: CGVector(dx: 0.94, dy: 0.5), to: CGVector(dx: 0.60, dy: 0.5))
    }

    func testAnimationDiagnosticOverlayAndLogCopy() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        action("帧率诊断（翻页时观察）", button: "reader-debug", app: app)
        let monitor = app.staticTexts["reader-frame-monitor"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        XCTAssertTrue(monitor.label.contains("屏幕"))
        XCTAssertTrue(monitor.label.contains("申请"))
        app.otherElements["fullscreen-reader-canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.6)).tap()
        wait { monitor.label.contains("finished") && monitor.label.contains("completed") }
        XCTAssertTrue(monitor.label.contains("上一页"))
        XCTAssertTrue(monitor.label.contains("回调"))
        XCTAssertTrue(monitor.label.contains("GPU呈现"))
        XCTAssertTrue(monitor.label.contains("时长"))
        XCTAssertTrue(monitor.label.contains("avg"))
        capture(app, "翻页诊断-真实回调帧率与动画参数")
        action("复制动画诊断日志", button: "reader-debug", app: app)
        XCTAssertTrue(app.staticTexts["reader-notice"].label.contains("已复制"))
        mode("none", axis: "横向", app: app)
        app.otherElements["fullscreen-reader-canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.6)).tap()
        wait { monitor.label.contains("finished") && monitor.label.contains("unanimated") }
        XCTAssertTrue(monitor.label.contains("回调 —FPS"), "不足两个回调不能显示旧值或伪造120FPS")
        XCTAssertTrue(monitor.label.contains("上一页"))
        action("帧率诊断（翻页时观察）", button: "reader-debug", app: app)
        wait { !monitor.exists }
    }

    /// 底部横拖按整页方向往返，斜拉仍可卷角；与几何回归一起覆盖真实手势入口。
    func testBottomHorizontalCurlPanAndDiagonalPickup() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        let canvas = app.otherElements["reader-paged"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        func swipe(_ start: CGVector, _ end: CGVector, expected: Int, title: String) {
            canvas.coordinate(withNormalizedOffset: start).press(forDuration: 0.03,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: .slow, thenHoldForDuration: 0.2)
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == String(expected) }
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            capture(app, title)
        }
        swipe(CGVector(dx: 0.88, dy: 0.92), CGVector(dx: 0.36, dy: 0.915), expected: 1,
              title: "底部整页平翻-向左完成")
        swipe(CGVector(dx: 0.12, dy: 0.92), CGVector(dx: 0.65, dy: 0.925), expected: 0,
              title: "底部整页平翻-向右回翻")
        swipe(CGVector(dx: 0.90, dy: 0.92), CGVector(dx: 0.48, dy: 0.60), expected: 1,
              title: "底部明显斜拉-保留卷角")
    }

    /// 大幅快速回翻覆盖真实长文、连续输入与诊断面板，不以最终页码代替 GPU 阶段回归。
    func testFastPreviousSwipesKeepRespondingWithDiagnostics() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        showMenu(app)
        for _ in 0..<5 { app.buttons["reader-next"].tap() }
        wait { (app.staticTexts["reader-position"].value as? String) == "5" }
        action("帧率诊断（翻页时观察）", button: "reader-debug", app: app)
        let canvas = app.otherElements["reader-paged"]
        let monitor = app.staticTexts["reader-frame-monitor"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        for y in [0.92, 0.5, 0.92] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: y)).press(forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: y - 0.005)),
                withVelocity: .fast, thenHoldForDuration: 0)
        }
        wait { monitor.label.contains("finished") && monitor.label.contains("completed") }
        print("FAST_PREVIOUS_DEMO \(monitor.label)")
        capture(app, "快速回翻-长文三次输入与帧率诊断")
        showMenu(app)
        wait { (app.staticTexts["reader-position"].value as? String) == "2" }
    }

    /// 浅角度回翻也要跟随上下方向，包含低速持握和快速松手。
    func testPreviousShallowAngleFollowsUpAndDown() {
        let app = launch(); defer { app.terminate() }
        mode("curl", axis: "横向", app: app)
        showMenu(app)
        for _ in 0..<4 { app.buttons["reader-next"].tap() }
        wait { (app.staticTexts["reader-position"].value as? String) == "4" }
        app.buttons["reader-hide-menu"].tap()
        wait { !app.buttons["reader-settings-button"].isHittable }
        let canvas = app.otherElements["reader-paged"]
        for (index, endY) in [0.47, 0.63, 0.47].enumerated() {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.55)).press(forDuration: 0.03,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: endY)),
                withVelocity: index == 2 ? .fast : .slow, thenHoldForDuration: index == 2 ? 0 : 0.2)
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == String(3 - index) }
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            capture(app, "上一页角度跟随-\(index)")
        }
    }

    /// 目标页已显露过半时，小位移慢速松手也完成；实际向左／向右均验证。
    func testSmallDragCommitsWhenVisiblePageHasPassedHalf() {
        for rtl in [false, true] {
            let app = launch(); defer { app.terminate() }
            if rtl { settings(app); choose("readingOrder", "rtl", app: app); apply(app) }
            mode("curl", axis: "横向", app: app)
            showMenu(app)
            app.buttons["reader-next"].tap(); app.buttons["reader-next"].tap()
            wait { (app.staticTexts["reader-position"].value as? String) == "2" }
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            let canvas = app.otherElements["reader-paged"]
            func drag(_ start: CGFloat, _ end: CGFloat) {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: rtl ? 1 - start : start, dy: 0.5))
                    .press(forDuration: 0.02,
                        thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: rtl ? 1 - end : end, dy: 0.5)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
            }
            drag(0.25, 0.30)
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == "1" }
            capture(app, "页面已过半-小位移\(rtl ? "向左" : "向右")松手完成")
            app.buttons["reader-hide-menu"].tap()
            wait { !app.buttons["reader-settings-button"].isHittable }
            drag(0.02, 0.06)
            showMenu(app)
            wait { (app.staticTexts["reader-position"].value as? String) == "1" }
            capture(app, "页面未过半-小位移\(rtl ? "向左" : "向右")回弹")
        }
    }
}
