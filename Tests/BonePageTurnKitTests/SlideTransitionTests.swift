#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 平移使用两个真实子页面；几何断言不依赖截图基线。
@MainActor
final class SlideTransitionTests: XCTestCase {
    /// - Parameter index: 示例页索引。
    /// - Returns: 同一本书中稳定且互不相同的页面身份。
    private func identity(_ index: Int) -> PageItemIdentity {
        .init(sourceID: "slide-test-book", unitID: String(index))
    }

    /// - Parameters: index: 页面索引；info: 随提交一起安装的阅读信息。
    /// - Returns: 可直接辨认正文身份的真实页面。
    private func page(_ index: Int, info: ReaderPageInfo = .init()) -> PageContent {
        let controller = UIViewController()
        let label = UILabel()
        label.text = "真实页面 \(index)"
        label.textAlignment = .center
        label.font = .boldSystemFont(ofSize: 24)
        label.backgroundColor = index.isMultiple(of: 2) ? .systemTeal : .systemOrange
        controller.view = label
        return .init(identity: identity(index), controller: controller, readingInfo: info)
    }

    /// - Parameters: page: 初始内容；effect: 效果；axis: 主轴。
    /// - Returns: 已完成首次布局的分页容器，默认 bounds 原点非零。
    private func pager(_ page: PageContent, effect: PageTurnEffect = .slide,
                       axis: PageTurnAxis = .horizontal) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page,
            configuration: .init(presentation: .paged(effect: effect, axis: axis)))
        layout(reader, bounds: CGRect(x: 17, y: 31, width: 320, height: 480))
        return reader
    }

    /// - Parameters: controller: 待布局容器；bounds: 含原点的完整视口。
    private func layout(_ controller: UIViewController, bounds: CGRect) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: bounds.size)
        controller.view.bounds = bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    /// - Parameter reader: 要运行真实 UIKit 动画的分页容器。
    /// - Returns: 测试结束时需要关闭的窗口。
    private func mount(_ reader: PagedReaderViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 760))
        window.rootViewController = reader
        window.isHidden = false
        layout(reader, bounds: window.bounds)
        return window
    }

    /// - Parameter window: 本测试持有的窗口。
    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// - Parameters: actual: 实际 frame；expected: 预期 frame；file: 调用文件；line: 调用行。
    private func assertFrame(_ actual: CGRect, _ expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
    }

    /// - Parameters: events: 完整事件序列；from: 原页；to: 目标页；direction: 逻辑方向；completed: 是否提交。
    private func assertSettlement(_ events: [PageTransitionEvent], from: PageItemIdentity,
                                  to: PageItemIdentity, direction: PageTurnDirection, completed: Bool) {
        guard case .willBegin(let transaction) = events.first else {
            return XCTFail("缺少翻页开始事件")
        }
        XCTAssertEqual(transaction.from, from)
        XCTAssertEqual(transaction.to, to)
        XCTAssertEqual(transaction.direction, direction)
        let expected: [PageTransitionEvent] = completed
            ? [.willBegin(transaction), .didCommit(transaction), .didSettle(transaction, completed: true)]
            : [.willBegin(transaction), .didSettle(transaction, completed: false)]
        XCTAssertEqual(events, expected, "同一事务只能提交、收尾各一次")
    }

    /// - Parameters: view: 实际页面层级；name: 附件名称。截图仅用于人工观察，不作为通过条件。
    private func attachScreenshot(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// - Parameter axis: 被检验的主轴；同时覆盖 next、previous、半程和进度钳制。
    private func verifyGeometry(axis: PageTurnAxis) throws {
        for direction in [PageTurnDirection.next, .previous] {
            let original = page(4)
            let incoming = page(direction == .next ? 5 : 3)
            let reader = try pager(original, axis: axis)
            defer { reader.invalidate() }
            reader.pageProvider = { requestedIdentity, requestedDirection in
                XCTAssertEqual(requestedIdentity, original.identity)
                XCTAssertEqual(requestedDirection, direction)
                return .page(incoming)
            }
            XCTAssertTrue(try reader.beginInteractiveTurn(direction))
            let bounds = reader.view.bounds
            let extent = axis == .horizontal ? bounds.width : bounds.height
            let sign: CGFloat = direction == .next ? -1 : 1
            let samples: [(displacement: CGFloat, progress: CGFloat)] = [(-10, 0), (extent / 2, 0.5), (extent * 2, 1)]
            for sample in samples {
                reader.updateInteractiveTurn(displacement: sample.displacement)
                let outgoingOffset = sign * sample.progress * extent
                let incomingOffset = sign * (sample.progress - 1) * extent
                assertFrame(original.controller.view.frame, bounds.offsetBy(
                    dx: axis == .horizontal ? outgoingOffset : 0,
                    dy: axis == .vertical ? outgoingOffset : 0))
                assertFrame(incoming.controller.view.frame, bounds.offsetBy(
                    dx: axis == .horizontal ? incomingOffset : 0,
                    dy: axis == .vertical ? incomingOffset : 0))
                XCTAssertEqual(reader.children.count, 2)
                XCTAssertEqual(reader.view.subviews.count, 2, "不得以快照替换真实页面")
                for controller in [original.controller, incoming.controller] {
                    XCTAssertTrue(controller.parent === reader)
                    XCTAssertTrue(controller.view.superview === reader.view)
                    XCTAssertFalse(controller.view.isHidden)
                    XCTAssertEqual(controller.view.transform, .identity)
                }
                if sample.progress == 0.5 {
                    attachScreenshot(reader.view, name: "平移半程-\(axis)-\(direction)-非零原点")
                }
            }
            reader.cancelTransition()
            assertFrame(original.controller.view.frame, bounds)
            XCTAssertNil(incoming.controller.parent)
            XCTAssertEqual(reader.children.count, 1)
        }
    }

    /// 横向双页移动保留纵向位置和非零 bounds 原点。
    func testHorizontalSlideMovesBothPagesWithNonzeroBoundsOrigin() throws {
        try verifyGeometry(axis: .horizontal)
    }

    /// 纵向双页移动保留横向位置和非零 bounds 原点。
    func testVerticalSlideMovesBothPagesWithNonzeroBoundsOrigin() throws {
        try verifyGeometry(axis: .vertical)
    }

    /// 0.17 半屏距离、500 速度及反向优先规则同时约束内容和事件。
    func testReleaseCommitsContentOnceOrRestoresOriginalOnReversal() throws {
        let releases: [(fraction: CGFloat, velocity: CGFloat, completed: Bool)] = [
            (0.09, 0, true), (0.08, 499, false), (0, 500, true), (0.75, -500, false)
        ]
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for direction in [PageTurnDirection.next, .previous] {
                for release in releases {
                    let original = page(4)
                    let index = direction == .next ? 5 : 3
                    let info = ReaderPageInfo(pagination: .init(book: try .init(current: index + 1, total: .exact(8))),
                                              before: .available, after: .available)
                    let incoming = page(index, info: info)
                    let reader = try pager(original, axis: axis)
                    defer { reader.invalidate() }
                    var events: [PageTransitionEvent] = []
                    reader.pageProvider = { _, _ in .page(incoming) }
                    reader.onTransition = { events.append($0) }
                    XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                    let extent = axis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height
                    reader.updateInteractiveTurn(displacement: extent * release.fraction)
                    reader.endInteractiveTurn(velocity: release.velocity, animated: false)
                    reader.endInteractiveTurn(velocity: 700, animated: false)
                    reader.cancelTransition()
                    let expected = release.completed ? incoming : original
                    let detached = release.completed ? original : incoming
                    XCTAssertEqual(reader.currentPage.identity, expected.identity)
                    XCTAssertTrue(reader.currentPage.controller === expected.controller)
                    XCTAssertEqual((reader.currentPage.controller.view as? UILabel)?.text,
                                   "真实页面 \(expected.identity.unitID)")
                    XCTAssertTrue(expected.controller.parent === reader)
                    XCTAssertNil(detached.controller.parent)
                    XCTAssertNil(detached.controller.view.superview)
                    XCTAssertEqual(reader.children.count, 1)
                    XCTAssertFalse(reader.isTransitioning)
                    assertFrame(expected.controller.view.frame, reader.view.bounds)
                    if release.completed {
                        XCTAssertEqual(reader.currentPage.readingInfo, info)
                        XCTAssertEqual(reader.readingStatus?.pagination, info.pagination)
                    }
                    assertSettlement(events, from: original.identity, to: incoming.identity,
                                     direction: direction, completed: release.completed)
                }
            }
        }
    }

    /// 使用窗口中的真实动画，提交必须等到收尾完成。
    func testAnimatedSlideCommitsOnlyAfterAnimationFinishes() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled || !UIView.areAnimationsEnabled,
                      "系统减少动态效果或全局禁用动画时，无法检验实际动画时序")
        let original = page(0)
        let incoming = page(1)
        let reader = try pager(original)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let finished = expectation(description: "真实平移动画完成")
        var events: [PageTransitionEvent] = []
        reader.pageProvider = { _, _ in .page(incoming) }
        reader.onTransition = { event in
            events.append(event)
            if case .didSettle(_, completed: true) = event { finished.fulfill() }
        }
        XCTAssertTrue(try reader.turn(.next, animated: true))
        XCTAssertTrue(reader.isTransitioning)
        XCTAssertTrue(reader.currentPage.controller === original.controller)
        XCTAssertEqual(reader.children.count, 2)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(reader.currentPage.controller === incoming.controller)
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertNil(original.controller.parent)
        XCTAssertEqual(reader.children.count, 1)
        assertFrame(incoming.controller.view.frame, reader.view.bounds)
        assertSettlement(events, from: original.identity, to: incoming.identity, direction: .next, completed: true)
    }

    /// 失效会取消动画；越过原动画截止时间也不能产生迟到提交。
    func testInvalidatedAnimationCannotCommitLate() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled || !UIView.areAnimationsEnabled,
                      "系统减少动态效果或全局禁用动画时，没有可取消的在途动画")
        let original = page(1)
        let incoming = page(0)
        let reader = try pager(original, axis: .vertical)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var events: [PageTransitionEvent] = []
        reader.pageProvider = { _, _ in .page(incoming) }
        reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.turn(.previous, animated: true))
        XCTAssertTrue(reader.isTransitioning)
        reader.invalidate()
        let eventsAtInvalidation = events
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(events, eventsAtInvalidation)
        assertSettlement(events, from: original.identity, to: incoming.identity, direction: .previous, completed: false)
        XCTAssertFalse(reader.isActive)
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertTrue(reader.currentPage.controller === original.controller)
        XCTAssertNil(incoming.controller.parent)
        XCTAssertEqual(reader.children.count, 1)
        assertFrame(original.controller.view.frame, reader.view.bounds)
        XCTAssertThrowsError(try reader.turn(.next)) { XCTAssertEqual($0 as? PageTurnError, .inactive) }
    }

    /// 快速重入不能重复请求邻页，也不能漏页或留下额外 child。
    func testRapidTurnsRejectReentryAndKeepExactlyOneSettledChild() throws {
        let reader = try pager(page(0))
        defer { reader.invalidate() }
        var requested: [Int] = []
        var events: [PageTransitionEvent] = []
        reader.pageProvider = { [weak self] identity, direction in
            guard let self, let index = Int(identity.unitID) else { return .failed }
            let target = index + (direction == .next ? 1 : -1)
            requested.append(target)
            return .page(self.page(target))
        }
        reader.onTransition = { events.append($0) }
        for index in 1...12 {
            let original = reader.currentPage
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            XCTAssertThrowsError(try reader.turn(.next, animated: false)) {
                XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
            }
            XCTAssertThrowsError(try reader.beginInteractiveTurn(.previous)) {
                XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
            }
            reader.updateInteractiveTurn(displacement: reader.view.bounds.width / 2)
            reader.endInteractiveTurn(velocity: 0, animated: false)
            XCTAssertEqual(reader.currentPage.identity, identity(index))
            XCTAssertEqual((reader.currentPage.controller.view as? UILabel)?.text, "真实页面 \(index)")
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertNil(original.controller.parent)
            assertSettlement(Array(events.suffix(3)), from: original.identity, to: identity(index),
                             direction: .next, completed: true)
        }
        XCTAssertEqual(requested, Array(1...12))
        XCTAssertEqual(events.count, 36)
    }

    /// 尺寸变化取消半程事务，恢复原页后可以按新视口继续翻页。
    func testResizeCancelsSlideAndNextTurnUsesNewViewport() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let original = page(0)
            let incoming = page(1)
            let reader = try pager(original, axis: axis)
            defer { reader.invalidate() }
            var events: [PageTransitionEvent] = []
            reader.pageProvider = { _, _ in .page(incoming) }
            reader.onTransition = { events.append($0) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            let extent = axis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height
            reader.updateInteractiveTurn(displacement: extent / 2)
            let newBounds = CGRect(x: -11, y: 9, width: 410, height: 350)
            layout(reader, bounds: newBounds)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertTrue(reader.currentPage.controller === original.controller)
            XCTAssertNil(incoming.controller.parent)
            XCTAssertEqual(reader.children.count, 1)
            assertFrame(original.controller.view.frame, newBounds)
            assertSettlement(events, from: original.identity, to: incoming.identity, direction: .next, completed: false)
            XCTAssertTrue(try reader.turn(.next, animated: false))
            assertFrame(incoming.controller.view.frame, newBounds)
            XCTAssertEqual(reader.children.count, 1)
        }
    }

    /// none 隐藏目标页、cover 只移动一页，不能被统一替换为双页平移。
    func testNoneAndCoverRetainTheirDifferentGeometry() throws {
        let modes: [(PageTurnEffect, PageTurnAxis)] = [
            (.none, .horizontal), (.none, .vertical), (.cover, .horizontal), (.slide, .horizontal)
        ]
        for (effect, axis) in modes {
            for direction in [PageTurnDirection.next, .previous] {
                let original = page(4)
                let incoming = page(direction == .next ? 5 : 3)
                let reader = try pager(original, effect: effect, axis: axis)
                defer { reader.invalidate() }
                let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
                layout(reader, bounds: bounds)
                reader.pageProvider = { _, _ in .page(incoming) }
                XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                reader.updateInteractiveTurn(displacement: (axis == .horizontal ? bounds.width : bounds.height) / 2)
                let outgoingX: CGFloat = effect == .none ? 0
                    : (direction == .next ? -160 : (effect == .slide ? 160 : 0))
                let incomingX: CGFloat = effect == .none ? 0
                    : (direction == .previous ? -160 : (effect == .slide ? 160 : 0))
                assertFrame(original.controller.view.frame, bounds.offsetBy(dx: outgoingX, dy: 0))
                assertFrame(incoming.controller.view.frame, bounds.offsetBy(dx: incomingX, dy: 0))
                XCTAssertFalse(original.controller.view.isHidden)
                XCTAssertEqual(incoming.controller.view.isHidden, effect == .none)
            }
        }
    }

    /// 两轴点击都按主轴和 bounds 原点判定，另一轴落在边缘也不会改变意图。
    func testSlideTapsFollowConfiguredAxisWithNonzeroBoundsOrigin() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let reader = try pager(page(4), axis: axis)
            defer { reader.invalidate() }
            reader.tapConfiguration = try ReaderTapConfiguration()
            var directions: [PageTurnDirection] = []
            var centers: [CGPoint] = []
            reader.pageProvider = { [weak self] identity, direction in
                guard let self, let index = Int(identity.unitID) else { return .failed }
                directions.append(direction)
                return .page(self.page(index + (direction == .next ? 1 : -1)))
            }
            reader.onCenterTap = { centers.append($0) }
            let bounds = reader.view.bounds
            let next = CGPoint(x: bounds.minX + bounds.width * (axis == .horizontal ? 0.9 : 0.1),
                               y: bounds.minY + bounds.height * (axis == .vertical ? 0.9 : 0.1))
            let previous = CGPoint(x: bounds.minX + bounds.width * (axis == .horizontal ? 0.1 : 0.9),
                                   y: bounds.minY + bounds.height * (axis == .vertical ? 0.1 : 0.9))
            let center = CGPoint(x: bounds.minX + bounds.width * (axis == .horizontal ? 0.5 : 0.95),
                                 y: bounds.minY + bounds.height * (axis == .vertical ? 0.5 : 0.95))
            XCTAssertTrue(try reader.handleTap(at: next, animated: false))
            XCTAssertEqual(reader.currentPage.identity, identity(5))
            XCTAssertTrue(try reader.handleTap(at: previous, animated: false))
            XCTAssertEqual(reader.currentPage.identity, identity(4))
            XCTAssertTrue(try reader.handleTap(at: center, animated: false))
            XCTAssertEqual(directions, [.next, .previous])
            XCTAssertEqual(centers, [center])
            XCTAssertEqual(reader.children.count, 1)
        }
    }

    /// 两页在半程中完成异步富文本和插图；可选文本及正文身份一直属于原真实视图。
    func testAsyncStyledPagesFinishRenderingDuringSlideWithoutIdentityMixup() async throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            var originalPlan = AsyncStyledRenderPlan()
            originalPlan.title = "原页正文"
            originalPlan.textDelay = 10_000_000
            originalPlan.imageDelay = 30_000_000
            var incomingPlan = AsyncStyledRenderPlan()
            incomingPlan.title = "邻页正文"
            incomingPlan.textDelay = 20_000_000
            incomingPlan.imageDelay = 50_000_000
            let original = AsyncStyledPageController(identity: identity(40), plan: originalPlan)
            let incoming = AsyncStyledPageController(identity: identity(41), plan: incomingPlan)
            let reader = try pager(.init(identity: original.identity, controller: original), axis: axis)
            let window = mount(reader)
            defer {
                original.onEvent = nil
                incoming.onEvent = nil
                reader.invalidate()
                close(window)
            }
            let rendered = expectation(description: "\(axis) 半程中的两页正文和插图完成")
            rendered.expectedFulfillmentCount = 4
            var arrivals: [AsyncStyledRenderEvent] = []
            let observe: (AsyncStyledRenderEvent) -> Void = { [weak reader] event in
                guard event.result == .applied else { return XCTFail("在途真实页面不应丢弃渲染") }
                XCTAssertTrue(reader?.isTransitioning == true)
                arrivals.append(event)
                rendered.fulfill()
            }
            original.onEvent = observe
            incoming.onEvent = observe
            reader.pageProvider = { _, _ in .page(.init(identity: incoming.identity, controller: incoming)) }
            let originalTextView = original.content.textView
            let incomingTextView = incoming.content.textView
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            let extent = axis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height
            reader.updateInteractiveTurn(displacement: extent / 2)
            await fulfillment(of: [rendered], timeout: 3)
            XCTAssertTrue(reader.isTransitioning)
            XCTAssertTrue(original.view === original.content)
            XCTAssertTrue(incoming.view === incoming.content)
            XCTAssertTrue(original.content.textView === originalTextView)
            XCTAssertTrue(incoming.content.textView === incomingTextView)
            for controller in [original, incoming] {
                XCTAssertTrue(controller.parent === reader)
                XCTAssertTrue(controller.content.textView.isDescendant(of: reader.view))
                XCTAssertTrue(controller.content.textView.isSelectable)
                XCTAssertFalse(controller.content.textView.isEditable)
                XCTAssertFalse(controller.view.isHidden)
                XCTAssertTrue(controller.content.isFullyRendered)
                XCTAssertEqual(controller.content.renderedIdentity, controller.identity)
                XCTAssertNotNil(controller.content.imageView.image)
                XCTAssertEqual(arrivals.filter { $0.identity == controller.identity }.count, 2)
            }
            let originalText = try XCTUnwrap(originalTextView.attributedText)
            let incomingText = try XCTUnwrap(incomingTextView.attributedText)
            XCTAssertTrue(originalText.string.contains("原页正文 · 40"))
            XCTAssertFalse(originalText.string.contains("邻页正文"))
            XCTAssertTrue(incomingText.string.contains("邻页正文 · 41"))
            XCTAssertFalse(incomingText.string.contains("原页正文"))
            if incomingText.length > 0 {
                let heading = try XCTUnwrap(incomingText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
                XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitBold))
            }
            let bounds = reader.view.bounds
            assertFrame(original.view.frame, bounds.offsetBy(
                dx: axis == .horizontal ? -extent / 2 : 0, dy: axis == .vertical ? -extent / 2 : 0))
            assertFrame(incoming.view.frame, bounds.offsetBy(
                dx: axis == .horizontal ? extent / 2 : 0, dy: axis == .vertical ? extent / 2 : 0))
            let selected = NSRange(location: 0, length: 4)
            incomingTextView.selectedRange = selected
            attachScreenshot(reader.view, name: "真实异步富文本-\(axis)-平移半程")
            reader.endInteractiveTurn(velocity: 0, animated: false)
            XCTAssertTrue(reader.currentPage.controller === incoming)
            XCTAssertTrue(incoming.content.textView === incomingTextView)
            XCTAssertEqual(incomingTextView.selectedRange, selected)
            XCTAssertTrue(incomingTextView.isSelectable)
            XCTAssertNil(original.parent)
            XCTAssertEqual(reader.children.count, 1)
        }
    }
}
#endif
