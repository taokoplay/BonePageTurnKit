#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class PaperTurnContainerTests: XCTestCase {
    private final class MoveHookView: UIView {
        var onInsert: (() -> Void)?
        override func willMove(toSuperview newSuperview: UIView?) {
            super.willMove(toSuperview: newSuperview)
            guard newSuperview != nil, let action = onInsert else { return }
            onInsert = nil
            action()
        }
    }

    /// UIKit 尚未完成 addSubview 时取消不能留下已无父控制器的目标根视图。
    func testSuperviewCallbackCancellationRemovesOrphanTarget() throws {
        for operation in 0..<3 {
            let reader = try reader()
            defer { reader.invalidate() }
            let original = reader.currentPage.controller
            let target = UIViewController()
            let targetView = MoveHookView()
            target.view = targetView
            targetView.onInsert = { [weak reader] in
                if operation == 0 { reader?.cancelTransition() } else { reader?.invalidate() }
            }
            let content = page(operation == 2 ? "a" : "b", version: 1, controller: target)
            if operation == 2 {
                XCTAssertThrowsError(try reader.replaceCurrentPage(content, expectedBinding: reader.currentPageBinding)) {
                    XCTAssertEqual($0 as? PageTurnError, .inactive)
                }
            } else {
                reader.pageProvider = { _, _ in .page(content) }
                XCTAssertFalse(try reader.beginInteractiveTurn(.next))
            }
            XCTAssertTrue(reader.currentPage.controller === original)
            XCTAssertNil(target.parent)
            XCTAssertNil(targetView.superview)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertEqual(reader.view.subviews, [original.view])
            XCTAssertNil(reader.activePaperView)
        }
    }

    private final class HookPage: UIViewController {
        var onLayout: (() -> Void)?
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
    }
    private final class PanFixture: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .possible
        var sampleTranslation = CGPoint.zero
        var sampleVelocity = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        // 此 fixture 验证页中滑动方向；角落抓取由独立二维测试覆盖。
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 160, y: 240) }
        override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
        override func velocity(in view: UIView?) -> CGPoint { sampleVelocity }
    }

    /// - Parameters: id: 展示单元；version: 内容与布局版本；controller: 可选的真实页面。
    /// - Returns: 同一源下的新页面。
    private func page(_ id: String, version: UInt64 = 0, controller: UIViewController? = nil) -> PageContent {
        let child = controller ?? UIViewController()
        if controller == nil {
            child.view.backgroundColor = id == "a" ? .systemYellow : .systemTeal
            let label = UILabel(frame: CGRect(x: 24, y: 40, width: 220, height: 100))
            label.text = "真实页面 \(id) · \(version)"
            label.numberOfLines = 0
            child.view.addSubview(label)
        }
        return .init(identity: .init(sourceID: "book", unitID: id, contentVersion: version, layoutVersion: version), controller: child)
    }

    /// - Parameters: effect: 纸张效果；spine: 书脊；initial: 可选初始页面。
    /// - Returns: 已布局且由测试驱动时钟的容器。
    private func reader(_ effect: PageTurnEffect = .curl, spine: PageSpinePlacement = .minimum,
                        initial: PageContent? = nil) throws -> PagedReaderViewController {
        let result = try PagedReaderViewController(page: initial ?? page("a"), configuration: .init(
            presentation: .paged(effect: effect, axis: .horizontal), spine: spine,
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        result.usesDisplayLinkForPaperAnimation = false
        result.usesDisplayLinkForAutomaticReading = false
        result.loadViewIfNeeded()
        result.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        result.view.setNeedsLayout()
        result.view.layoutIfNeeded()
        return result
    }

    /// - Parameter reader: 正在收尾的容器；最多推进一秒，真实每帧入口仍限制为 0.1 秒。
    private func finishAnimation(_ reader: PagedReaderViewController) {
        for _ in 0..<10 { reader.advancePaperAnimation(elapsed: 0.1) }
    }

    /// - Parameter view: 纸张视图；返回真实 draw 的位图用于比较冻结快照。
    private func raster(_ view: PaperTransitionView) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in view.draw(view.bounds) }.pngData()
    }

    /// 两效果、两书脊、双方向均保持真实 containment，成功及反向取消各只有一次终态。
    func testPaperMatrixCommitsAndCancelsWithUniqueTerminals() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            for spine in [PageSpinePlacement.minimum, .maximum] {
                for direction in [PageTurnDirection.next, .previous] {
                    for completed in [false, true] {
                        let reader = try reader(effect, spine: spine)
                        defer { reader.invalidate() }
                        let old = reader.currentPage.controller
                        let target = page("b")
                        reader.pageProvider = { _, requested in XCTAssertEqual(requested, direction); return .page(target) }
                        var events: [PageTransitionEvent] = []
                        reader.onTransition = { events.append($0) }
                        XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                        let paper = try XCTUnwrap(reader.activePaperView)
                        XCTAssertTrue(paper.hasResources)
                        XCTAssertLessThanOrEqual(paper.snapshotPixelCount, 262_144)
                        XCTAssertEqual(reader.children.count, 2)
                        XCTAssertTrue(old.view.isHidden)
                        XCTAssertTrue(target.controller.view.isHidden)
                        reader.updateInteractiveTurn(displacement: 160)
                        reader.endInteractiveTurn(velocity: completed ? 0 : -900)
                        XCTAssertTrue(reader.isTransitioning)
                        finishAnimation(reader)
                        guard case .willBegin(let transaction) = events.first else { return XCTFail("缺少事务开始") }
                        let expected: [PageTransitionEvent] = completed
                            ? [.willBegin(transaction), .didCommit(transaction), .didSettle(transaction, completed: true)]
                            : [.willBegin(transaction), .didSettle(transaction, completed: false)]
                        XCTAssertEqual(events, expected)
                        XCTAssertTrue(reader.currentPage.controller === (completed ? target.controller : old))
                        XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                        XCTAssertEqual(reader.children.count, 1)
                        XCTAssertNil(reader.activePaperView)
                        XCTAssertFalse(paper.hasResources)
                        XCTAssertEqual(paper.snapshotPixelCount, 0)
                        XCTAssertFalse(reader.isPaperClockRunning)
                    }
                }
            }
        }
    }

    /// 真实 CADisplayLink 收尾，不靠测试手工推进；时钟和曲面在成功后立即释放。
    func testActualPaperDisplayLinkSettlesBothEffects() async throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let reader = try reader(effect)
            reader.usesDisplayLinkForPaperAnimation = true
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = reader
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
            let finished = expectation(description: "\(effect) 实际收尾")
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            reader.onTransition = { event in if case .didSettle(_, true) = event { finished.fulfill() } }
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(reader.isPaperClockRunning)
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertEqual(reader.currentPage.identity.unitID, "b")
            XCTAssertFalse(reader.isPaperClockRunning)
            XCTAssertNil(reader.activePaperView)
        }
    }

    /// 右书脊镜像点击和 pan 的几何方向，逻辑 next 仍由宿主提供下一页。
    func testMaximumSpineMapsTapAndPanWithoutReversingContentOrder() throws {
        for spine in [PageSpinePlacement.minimum, .maximum] {
            let reader = try reader(.curl, spine: spine)
            defer { reader.invalidate() }
            reader.tapConfiguration = try ReaderTapConfiguration()
            var requested: [PageTurnDirection] = []
            reader.pageProvider = { [self] _, direction in requested.append(direction); return .page(page("b")) }
            XCTAssertTrue(try reader.handleTap(at: CGPoint(x: spine == .maximum ? 10 : 310, y: 100), animated: false))
            XCTAssertEqual(requested, [.next])
            reader.pageProvider = { [self] _, direction in requested.append(direction); return .page(page("c")) }
            let pan = PanFixture()
            let sign: CGFloat = spine == .maximum ? 1 : -1
            pan.sampleVelocity = CGPoint(x: sign * 800, y: 0)
            pan.sampleState = .began
            reader.perform(NSSelectorFromString("handlePan:"), with: pan)
            pan.sampleState = .changed
            pan.sampleTranslation = CGPoint(x: sign * 160, y: 0)
            reader.perform(NSSelectorFromString("handlePan:"), with: pan)
            pan.sampleState = .ended
            reader.perform(NSSelectorFromString("handlePan:"), with: pan)
            finishAnimation(reader)
            XCTAssertEqual(requested, [.next, .next])
            XCTAssertEqual(reader.currentPage.identity.unitID, "c")
        }
    }

    /// 不播放动画时没有快照与曲面，即时操作仍使用同一翻页事务。
    func testUnanimatedPaperTurnKeepsOnlyRealTargetView() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let reader = try reader(effect)
            defer { reader.invalidate() }
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            XCTAssertTrue(try reader.turn(.next, animated: false))
            XCTAssertNil(reader.activePaperView)
            XCTAssertFalse(reader.isPaperClockRunning)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertFalse(reader.currentPage.controller.view.isHidden)
        }
    }

    /// 非零容器 bounds 不偏移稳定视图或纸面；收尾后的真实页面完整覆盖视口。
    func testNonzeroContainerBoundsAndReleaseThreshold() throws {
        let reader = try reader(.arch)
        defer { reader.invalidate() }
        reader.view.bounds.origin = CGPoint(x: 17, y: 23)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        reader.pageProvider = { [self] _, _ in .page(page("b")) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        XCTAssertEqual(reader.activePaperView?.frame, reader.view.bounds)
        reader.updateInteractiveTurn(displacement: reader.view.bounds.width * 0.16)
        reader.endInteractiveTurn(velocity: 0, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: reader.view.bounds.width * 0.18)
        reader.endInteractiveTurn(velocity: 0, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertEqual(reader.currentPage.controller.view.frame, reader.view.bounds)
    }

    /// 捕获中目标布局无效时明确报错，清理事务后仍是原真实页面。
    func testCaptureFailureCancelsWithoutFallbackOrOrphanPage() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        let target = HookPage()
        target.onLayout = { [weak target] in target?.view.bounds.size.height = 0 }
        reader.pageProvider = { [self] _, _ in .page(page("b", controller: target)) }
        var settles: [Bool] = []
        reader.onTransition = { if case .didSettle(_, let completed) = $0 { settles.append(completed) } }
        XCTAssertThrowsError(try reader.beginInteractiveTurn(.next)) { XCTAssertEqual($0 as? PageTurnError, .snapshotUnavailable) }
        XCTAssertEqual(settles, [false])
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertFalse(reader.currentPage.controller.view.isHidden)
        XCTAssertNil(target.parent)
        XCTAssertNil(reader.activePaperView)
    }

    /// UIKit layout 回调取消／退出时不会安装已失效的快照。
    func testCaptureLayoutReentryCannotInstallAbandonedOverlay() throws {
        for invalidates in [false, true] {
            let current = HookPage()
            let reader = try reader(initial: page("a", controller: current))
            defer { reader.invalidate() }
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            var settles = 0
            reader.onTransition = { if case .didSettle = $0 { settles += 1 } }
            current.onLayout = { [weak reader] in
                if invalidates { reader?.invalidate() } else { reader?.cancelTransition() }
            }
            XCTAssertFalse(try reader.beginInteractiveTurn(.next))
            XCTAssertEqual(settles, 1)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertNil(reader.activePaperView)
            XCTAssertFalse(current.view.isHidden)
            XCTAssertEqual(reader.children.count, 1)
        }
    }

    /// resize、内存告警、暂停、离场、后台和退出都取消在途纸张并释放原图及条带。
    func testLifecycleInterruptionsReleasePaperAndRestoreCurrentPage() throws {
        for interruption in 0..<6 {
            let reader = try reader(.arch)
            defer { reader.invalidate() }
            reader.usesDisplayLinkForPaperAnimation = true
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            var settles: [Bool] = []
            reader.onTransition = { if case .didSettle(_, let completed) = $0 { settles.append(completed) } }
            XCTAssertTrue(try reader.turn(.next))
            let paper = try XCTUnwrap(reader.activePaperView)
            switch interruption {
            case 0:
                reader.view.frame.size.width = 450
                reader.view.setNeedsLayout()
                reader.view.layoutIfNeeded()
            case 1: reader.didReceiveMemoryWarning()
            case 2: reader.setSuspended(true, reason: "selection")
            case 3: reader.viewWillDisappear(false)
            case 4: reader.setAutomaticApplicationActive(false)
            default: reader.invalidate()
            }
            finishAnimation(reader)
            XCTAssertEqual(settles, [false])
            XCTAssertFalse(reader.isPaperClockRunning)
            XCTAssertNil(reader.activePaperView)
            XCTAssertFalse(paper.hasResources)
            XCTAssertEqual(reader.currentPage.identity.unitID, "a")
            XCTAssertFalse(reader.currentPage.controller.view.isHidden)
        }
    }

    /// 纸张期间的当前页回填等待终态；取消可安装，切页成功后必须拒绝旧绑定。
    func testReplacementDuringPaperUsesSettledBinding() throws {
        for completed in [false, true] {
            let reader = try reader()
            defer { reader.invalidate() }
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            var outcomes: [PageReplacementOutcome] = []
            _ = try reader.submitCurrentPage(page("a", version: 1), expectedBinding: reader.currentPageBinding) { outcomes.append($0) }
            reader.endInteractiveTurn(velocity: completed ? 800 : -800)
            reader.installPendingCurrentPageIfIdle()
            XCTAssertTrue(outcomes.isEmpty)
            finishAnimation(reader)
            reader.installPendingCurrentPageIfIdle()
            XCTAssertEqual(outcomes, completed ? [.rejected(.staleWindow)] : [.installed(reader.currentPageBinding)])
            XCTAssertNil(reader.activePaperView)
        }
    }

    /// 自动驱动不把纸张动画耗时计入目标页，明确全书末尾后正常结束。
    func testAutomaticReadingUsesPaperTransactionAndResetsDwell() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let reader = try reader(effect)
            defer { reader.invalidate() }
            reader.viewDidAppear(false)
            let target = page("b")
            reader.pageProvider = { _, _ in .page(.init(identity: target.identity, controller: target.controller, readingInfo: .init(after: .endOfBook))) }
            try reader.startAutomaticReading(interval: 0.1)
            reader.advanceAutomaticReading(elapsed: 0.1)
            XCTAssertEqual(reader.automaticReadingState, .turning)
            XCTAssertNotNil(reader.activePaperView)
            for _ in 0..<10 { reader.advanceAutomaticReading(elapsed: 0.1) }
            XCTAssertEqual(reader.currentPage.identity.unitID, "a")
            finishAnimation(reader)
            XCTAssertEqual(reader.automaticReadingState, .running)
            XCTAssertEqual(reader.automaticReadingProgress, 0)
            reader.advanceAutomaticReading(elapsed: 0.1)
            XCTAssertEqual(reader.automaticReadingState, .finished(.endOfBook))
        }
    }

    /// 异步正文和图片在动画期间完成时快照保持不变，落定恢复同一真实可选文本视图。
    func testAsyncContentUpdatesBehindFrozenPaperThenAppearsOnRealPage() async throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let a = PageItemIdentity(sourceID: "book", unitID: "a")
            let b = PageItemIdentity(sourceID: "book", unitID: "b")
            var plan = AsyncStyledRenderPlan()
            plan.textDelay = 20_000_000
            plan.imageDelay = 60_000_000
            let current = AsyncStyledPageController(identity: a, plan: plan)
            let target = AsyncStyledPageController(identity: b, plan: plan)
            let rendered = expectation(description: "\(effect) 两页异步内容")
            rendered.expectedFulfillmentCount = 4
            let observe: (AsyncStyledRenderEvent) -> Void = { if $0.result == .applied { rendered.fulfill() } }
            current.onEvent = observe
            target.onEvent = observe
            let reader = try reader(effect, initial: .init(identity: a, controller: current))
            defer { current.onEvent = nil; target.onEvent = nil; reader.invalidate() }
            reader.pageProvider = { _, _ in .page(.init(identity: b, controller: target)) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            reader.updateInteractiveTurn(displacement: 160)
            let paper = try XCTUnwrap(reader.activePaperView)
            let before = try XCTUnwrap(raster(paper))
            await fulfillment(of: [rendered], timeout: 3)
            XCTAssertEqual(raster(paper), before)
            XCTAssertTrue(target.content.isFullyRendered)
            XCTAssertTrue(target.view.isHidden)
            reader.endInteractiveTurn(velocity: 0, animated: false)
            XCTAssertFalse(target.view.isHidden)
            XCTAssertTrue(reader.currentPage.controller === target)
            XCTAssertTrue(target.content.textView.isSelectable)
            XCTAssertNotNil(target.content.imageView.image)
            XCTAssertFalse(paper.hasResources)
        }
    }

    /// 多次成功／取消不会累积纸张视图；活动时钟也不反向保活整个容器。
    func testRepeatedPaperTransitionsReleaseOverlaysAndReader() throws {
        let weakReader = WeakObject<PagedReaderViewController>(nil)
        try autoreleasepool {
            let reader = try reader()
            weakReader.value = reader
            for index in 0..<120 {
                try autoreleasepool {
                    let target = page("page-\(index)")
                    reader.pageProvider = { _, _ in .page(target) }
                    XCTAssertTrue(try reader.beginInteractiveTurn(.next))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    reader.updateInteractiveTurn(displacement: 180)
                    reader.endInteractiveTurn(velocity: index.isMultiple(of: 2) ? 800 : -800, animated: false)
                    XCTAssertFalse(paper.hasResources)
                    XCTAssertEqual(reader.children.count, 1)
                    XCTAssertEqual(reader.view.subviews.count, 1)
                }
            }
            reader.usesDisplayLinkForPaperAnimation = true
            reader.pageProvider = { [self] _, _ in .page(page("last")) }
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(reader.isPaperClockRunning)
        }
        XCTAssertNil(weakReader.value)
    }
}
#endif
