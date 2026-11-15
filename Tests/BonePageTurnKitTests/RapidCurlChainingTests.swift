#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 连续翻页不等待收尾时钟；以真实控制器、快照及事务验证接管顺序。
@MainActor
final class RapidCurlChainingTests: XCTestCase {
    private final class PanSample: UIPanGestureRecognizer {
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: -600, y: -300) }
    }

    private final class ReentrantView: UIView {
        var onFrame: (() -> Void)?
        var onHidden: (() -> Void)?
        override var frame: CGRect {
            didSet { let callback = onFrame; onFrame = nil; callback?() }
        }
        override var isHidden: Bool {
            didSet { let callback = onHidden; onHidden = nil; callback?() }
        }
    }

    /// - Parameters: index: 独立页面号；layout: 单双页；axis: 翻页轴；order: 阅读方向。
    /// - Returns: 每次请求均创建新控制器的真实页面。
    private func page(_ index: Int, layout: ReaderPageLayout = .single, axis: PageTurnAxis = .horizontal,
                      order: ReaderReadingOrder = .leftToRight) throws -> PageContent {
        func leaf(_ name: String) -> PageContent {
            let child = UIViewController()
            child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            child.view.backgroundColor = index % 2 == 0 ? .systemYellow : .systemTeal
            let label = UILabel(frame: CGRect(x: 20, y: 30, width: 260, height: 120))
            label.numberOfLines = 0; label.text = "连续翻页 \(name)\n正文 ABC 012"
            child.view.addSubview(label)
            return .init(identity: .init(sourceID: "rapid-curl", unitID: name), controller: child)
        }
        if layout == .spread {
            let spread = try PageSpreadViewController(first: leaf("\(index)-a"), second: leaf("\(index)-b"),
                axis: axis, readingOrder: order)
            return .init(identity: .init(sourceID: "rapid-curl", unitID: String(index)), controller: spread)
        }
        return leaf(String(index))
    }

    /// - Parameters: initial: 初始页码；layout: 布局；axis: 翻页轴；order: 阅读方向；effect: 分页效果。
    /// - Returns: 收尾只由测试显式推进的真实分页容器。
    private func reader(initial: Int = 2, layout: ReaderPageLayout = .single, axis: PageTurnAxis = .horizontal,
                        order: ReaderReadingOrder = .leftToRight, effect: PageTurnEffect = .curl) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "连续收尾测试需要开启翻页动画")
        let value = try PagedReaderViewController(page: page(initial, layout: layout, axis: axis, order: order),
            configuration: .init(presentation: .paged(effect: effect, axis: axis),
                paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64), layout: layout, readingOrder: order))
        value.usesDisplayLinkForPaperAnimation = false; value.usesDisplayLinkForAutomaticReading = false
        value.loadViewIfNeeded(); value.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        return value
    }

    /// - Parameters: reader: 容器；layout: 布局；axis: 轴；order: 阅读方向；requests: 每次实际查询的源页与方向。
    /// - Returns: 无返回值，安装有明确边界的独立邻页供给。
    private func supply(_ reader: PagedReaderViewController, layout: ReaderPageLayout = .single,
                        axis: PageTurnAxis = .horizontal, order: ReaderReadingOrder = .leftToRight,
                        requests: @escaping (Int, PageTurnDirection) -> Void = { _, _ in }) {
        reader.pageProvider = { [weak self] identity, direction in
            guard let self, let index = Int(identity.unitID) else { return .failed }
            requests(index, direction)
            let next = index + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            do { return .page(try self.page(next, layout: layout, axis: axis, order: order)) }
            catch { XCTFail("邻页构造失败：\(error)"); return .failed }
        }
    }

    /// - Parameters: reader: 容器；axis: 轴；order: 阅读方向；direction: 本次逻辑方向。
    /// - Returns: 页中实际起点与能触发翻页的终点。
    private func points(_ reader: PagedReaderViewController, axis: PageTurnAxis = .horizontal,
                        order: ReaderReadingOrder = .leftToRight, direction: PageTurnDirection = .next) -> (CGPoint, CGPoint) {
        let forward: CGFloat = axis == .horizontal && order == .rightToLeft ? 1 : -1
        let sign = direction == .next ? forward : -forward
        let bounds = reader.view.bounds
        let primary = axis == .horizontal ? bounds.width : bounds.height
        let cross = axis == .horizontal ? bounds.height : bounds.width
        let a = CGPoint(x: sign < 0 ? primary * 0.92 : primary * 0.08, y: cross * 0.5)
        let b = CGPoint(x: a.x + sign * primary * 0.55, y: a.y + primary * 0.08)
        return axis == .horizontal ? (a, b) : (CGPoint(x: a.y, y: a.x), CGPoint(x: b.y, y: b.x))
    }

    /// - Parameter reader: 已松手容器。
    /// - Returns: 无返回值，过期额外 tick 也不能重复提交。
    private func finish(_ reader: PagedReaderViewController) {
        for _ in 0..<60 { reader.advancePaperAnimation(elapsed: 0.1) }
    }

    /// - Parameter events: 实际事件。
    /// - Returns: 每个事务的一次开始、可选提交和一次落定必须紧邻且唯一。
    private func assertTerminals(_ events: [PageTransitionEvent], results: [Bool],
                                 file: StaticString = #filePath, line: UInt = #line) {
        var offset = 0
        for completed in results {
            guard offset < events.count, case .willBegin(let transition) = events[offset] else {
                return XCTFail("缺少独立事务开始", file: file, line: line)
            }
            let expected: [PageTransitionEvent] = completed
                ? [.willBegin(transition), .didCommit(transition), .didSettle(transition, completed: true)]
                : [.willBegin(transition), .didSettle(transition, completed: false)]
            XCTAssertEqual(Array(events.dropFirst(offset).prefix(expected.count)), expected, file: file, line: line)
            offset += expected.count
        }
        XCTAssertEqual(offset, events.count, file: file, line: line)
    }

    /// 无参数；不推进一帧收尾就开始下一次触点翻页，两轴、单双页、RTL、反向与取消结果均正确。无返回值。
    func testNewPointTurnTakesOverUnadvancedSettlement() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for layout in [ReaderPageLayout.single, .spread] {
                for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                    for completed in [false, true] {
                        for reverse in [false, true] {
                            let reader = try reader(layout: layout, axis: axis, order: order)
                            defer { reader.invalidate() }
                            var requested: [Int] = []; var events: [PageTransitionEvent] = []
                            supply(reader, layout: layout, axis: axis, order: order, requests: { index, _ in requested.append(index) })
                            reader.onTransition = { events.append($0) }
                            let (a, b) = points(reader, axis: axis, order: order)
                            XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: a))
                            reader.updateInteractiveTurn(to: b)
                            let oldPaper = try XCTUnwrap(reader.activePaperView)
                            reader.endInteractiveTurn(velocity: completed ? 900 : -900)
                            XCTAssertTrue(reader.isTransitioning); XCTAssertEqual(reader.currentPage.identity.unitID, "2")
                            let direction: PageTurnDirection = reverse ? .previous : .next
                            let (nextA, nextB) = points(reader, axis: axis, order: order, direction: direction)
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: nextA))
                            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "3" : "2")
                            XCTAssertEqual(requested, [2, completed ? 3 : 2])
                            XCTAssertFalse(oldPaper.hasResources); XCTAssertNil(oldPaper.superview)
                            XCTAssertTrue(reader.activePaperView !== oldPaper); XCTAssertEqual(reader.children.count, 2)
                            XCTAssertEqual(events.count, completed ? 4 : 3)
                            reader.updateInteractiveTurn(to: nextB); reader.endInteractiveTurn(velocity: 900)
                            finish(reader)
                            XCTAssertEqual(reader.currentPage.identity.unitID, String((completed ? 3 : 2) + (reverse ? -1 : 1)))
                            assertTerminals(events, results: [completed, true])
                            XCTAssertEqual(reader.children.count, 1); XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                            XCTAssertFalse(reader.isTransitioning); XCTAssertNil(reader.activePaperView)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；连续点击依序完成，低层标量接管保持即时；反向请求使用实际落定的新身份。无返回值。
    func testRapidTurnAndTapRequestsNeverLoseInputs() throws {
        for input in 0..<3 {
            let reader = try reader(); defer { reader.invalidate() }
            reader.tapConfiguration = try ReaderTapConfiguration(previousEnd: 0.3, nextStart: 0.7)
            var queried: [Int] = []; var events: [PageTransitionEvent] = []
            supply(reader, requests: { index, _ in queried.append(index) }); reader.onTransition = { events.append($0) }
            for direction in [PageTurnDirection.next, .next, .next, .previous, .previous] {
                if input == 0 { XCTAssertTrue(try reader.turn(direction)) }
                else if input == 1 {
                    XCTAssertTrue(try reader.beginInteractiveTurn(direction)); reader.updateInteractiveTurn(displacement: 160)
                    reader.endInteractiveTurn(velocity: 900)
                } else {
                    XCTAssertTrue(try reader.handleTap(at: CGPoint(x: direction == .next ? 300 : 20, y: 240)))
                }
                XCTAssertTrue(reader.isTransitioning); XCTAssertEqual(reader.children.count, 2)
            }
            finish(reader)
            XCTAssertEqual(queried, [2, 3, 4, 5, 4]); XCTAssertEqual(reader.currentPage.identity.unitID, "3")
            assertTerminals(events, results: Array(repeating: true, count: 5))
            XCTAssertEqual(reader.children.count, 1); XCTAssertNil(reader.activePaperView)
        }
    }

    /// 无参数；原生 pan 的识别门禁在松手后立即放行，判断本身不提交旧页，宿主拒绝继续有效。无返回值。
    func testNativePanGateAdmitsSettlementAndPreservesHostVeto() throws {
        let reader = try reader(); defer { reader.invalidate() }; supply(reader)
        let (a, b) = points(reader); XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: a))
        reader.updateInteractiveTurn(to: b)
        let pan = PanSample(); XCTAssertFalse(reader.gestureRecognizerShouldBegin(pan))
        let old = reader.activeTransitionID; reader.endInteractiveTurn(velocity: 900)
        XCTAssertTrue(reader.gestureRecognizerShouldBegin(pan))
        XCTAssertEqual(reader.activeTransitionID, old); XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        reader.shouldBeginPan = { _ in false }; XCTAssertFalse(reader.gestureRecognizerShouldBegin(pan))
        XCTAssertEqual(reader.activeTransitionID, old)
        reader.setSuspended(true, reason: "宿主门禁"); XCTAssertFalse(reader.gestureRecognizerShouldBegin(pan))
        XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: a))
        XCTAssertEqual(reader.currentPage.identity.unitID, "2")
    }

    /// 无参数；非法坐标、宿主拒绝和中心点击不能顺便结束旧页，尚未松手仍拒绝第二个事务。无返回值。
    func testUnacceptedInputsDoNotConsumeSettlement() throws {
        let reader = try reader(); defer { reader.invalidate() }; supply(reader)
        reader.tapConfiguration = try ReaderTapConfiguration(previousEnd: 0.3, nextStart: 0.7)
        let (a, b) = points(reader); XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: a))
        reader.updateInteractiveTurn(to: b)
        let old = reader.activeTransitionID; let paper = try XCTUnwrap(reader.activePaperView)
        XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: a))
        reader.endInteractiveTurn(velocity: 900)
        XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: CGPoint(x: -1, y: 20)))
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 400, y: 20)))
        var centers = 0; reader.onCenterTap = { _ in centers += 1 }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 160, y: 240))); XCTAssertEqual(centers, 1)
        reader.shouldHandleTap = { _ in false }
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 300, y: 240)))
        XCTAssertEqual(reader.activeTransitionID, old); XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        XCTAssertTrue(paper.hasResources)
        finish(reader); XCTAssertEqual(reader.currentPage.identity.unitID, "3")
    }

    /// 无参数；快速翻到供给边界时只落定旧页，下一次无内容请求不创建伪事务。无返回值。
    func testBoundaryRequestSettlesPreviousPageOnly() throws {
        let reader = try reader(initial: 7); defer { reader.invalidate() }; supply(reader)
        var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.currentPage.identity.unitID, "7")
        finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "8"); XCTAssertFalse(reader.isTransitioning)
        assertTerminals(events, results: [true]); XCTAssertEqual(reader.children.count, 1)
        XCTAssertNil(reader.activePaperView)
    }

    /// 无参数；落定回调中的重入仍被拒绝；宿主暂停或失效后不得继续请求新页。无返回值。
    func testCallbacksCannotReenterAndCanStopChainedTurn() throws {
        for invalidates in [false, true] {
            let reader = try reader(); defer { reader.invalidate() }
            var requests = 0; supply(reader, requests: { _, _ in requests += 1 })
            reader.onTransition = { [weak reader] event in
                guard let reader else { return }
                switch event {
                case .didCommit:
                    do { _ = try reader.turn(.next); XCTFail("同步落定回调不能重入翻页") }
                    catch { XCTAssertEqual(error as? PageTurnError, .interactionInProgress) }
                case .didSettle:
                    if invalidates { reader.invalidate() } else { reader.setSuspended(true, reason: "落定暂停") }
                case .willBegin: break
                }
            }
            XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.next))
            finish(reader)
            XCTAssertThrowsError(try reader.turn(.next)) {
                XCTAssertEqual($0 as? PageTurnError, invalidates ? .inactive : .interactionInProgress)
            }
            XCTAssertEqual(requests, 1); XCTAssertEqual(reader.currentPage.identity.unitID, "3")
            XCTAssertFalse(reader.isTransitioning); XCTAssertNil(reader.activePaperView)
        }
    }

    /// 无参数；上一事务落定回调改变 bounds 后，新触点重新计算材料坐标和画布，不能沿用旧尺寸。无返回值。
    func testNewPointUsesViewportAfterOldSettleCallback() throws {
        let reader = try reader(); defer { reader.invalidate() }; supply(reader)
        XCTAssertTrue(try reader.turn(.next))
        reader.onTransition = { [weak reader] event in
            guard case .didSettle = event, let reader else { return }
            reader.view.bounds = CGRect(x: 7, y: 13, width: 400, height: 600)
        }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 290, y: 40)))
        let drag = try XCTUnwrap(reader.activePaperView?.cornerDrag)
        XCTAssertEqual(drag.page.size, CGSize(width: 400, height: 600))
        XCTAssertEqual(drag.origin, CGPoint(x: 283, y: 27))
        reader.cancelTransition()
    }

    /// 无参数；旧收尾最后一帧的宿主视图回调开始新翻页时，旧布局与时钟不能改写新事务。无返回值。
    func testLastReleaseFrameCannotClearReentrantNewTurn() throws {
        /// - Parameter paper: 已捕获的真实纸面。返回软件路径实际首帧 PNG，用于检出旧布局污染。
        func frameData(_ paper: PaperTransitionView) -> Data? {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: paper.bounds.size, format: format).image { _ in paper.draw(paper.bounds) }.pngData()
        }
        for hiddenCallback in [false, true] {
            let reader = try reader(); defer { reader.invalidate() }
            let hook = ReentrantView(); hook.backgroundColor = .systemTeal
            let first = try page(3), second = try page(4)
            first.controller.view = hook
            reader.pageProvider = { identity, _ in identity.unitID == "2" ? .page(first) : .page(second) }
            var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
            XCTAssertTrue(try reader.turn(.next))
            for _ in 0..<3 { reader.advancePaperAnimation(elapsed: 0.1) }
            let old = reader.activeTransitionID
            var expectedFrame: Data?
            let callback = { [weak reader] in
                guard let reader else { return }
                do {
                    let accepted = try reader.beginInteractiveTurn(.next); XCTAssertTrue(accepted)
                    reader.updateInteractiveTurn(displacement: 160); reader.endInteractiveTurn(velocity: 900)
                    if let paper = reader.activePaperView { expectedFrame = frameData(paper) }
                } catch { XCTFail("末帧回调应能衔接下一页：\(error)") }
            }
            if hiddenCallback { hook.onHidden = callback } else { hook.onFrame = callback }
            reader.advancePaperAnimation(elapsed: 0.1)
            XCTAssertNotEqual(reader.activeTransitionID, old)
            XCTAssertTrue(reader.isTransitioning); XCTAssertEqual(reader.currentPage.identity.unitID, "3")
            let expectedImage = try XCTUnwrap(expectedFrame)
            let newPaper = try XCTUnwrap(reader.activePaperView)
            XCTAssertEqual(frameData(newPaper), expectedImage, "旧帧不能覆盖新页的首帧")
            XCTAssertTrue(hook.isHidden, "新纸面覆盖期间真实当前页须保持隐藏")
            finish(reader)
            XCTAssertEqual(reader.currentPage.identity.unitID, "4", "新收尾仍必须有有效时钟状态")
            XCTAssertFalse(reader.isTransitioning)
            assertTerminals(events, results: [true, true])
        }
    }

    /// 无参数；连续按钮和分区轻点只记录后续意图，不能提前提交或替换尚未播放完的纸面。无返回值。
    func testRapidDiscreteInputsKeepCurrentAnimationUntilItCompletes() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for usesTap in [false, true] {
                let reader = try reader(axis: axis); defer { reader.invalidate() }
                reader.tapConfiguration = try ReaderTapConfiguration(previousEnd: 0.3, nextStart: 0.7)
                var queried: [Int] = []; var events: [PageTransitionEvent] = []
                supply(reader, axis: axis, requests: { index, _ in queried.append(index) })
                reader.onTransition = { events.append($0) }
                XCTAssertTrue(try reader.turn(.next))
                let firstID = reader.activeTransitionID
                let firstPaper = try XCTUnwrap(reader.activePaperView)
                for direction in [PageTurnDirection.next, .previous] {
                    if usesTap {
                        let primary: CGFloat = direction == .next ? 0.92 : 0.08
                        let point = axis == .horizontal ? CGPoint(x: 320 * primary, y: 240)
                            : CGPoint(x: 160, y: 480 * primary)
                        XCTAssertTrue(try reader.handleTap(at: point))
                    } else { XCTAssertTrue(try reader.turn(direction)) }
                    XCTAssertEqual(reader.activeTransitionID, firstID, "快速点击不能截断正在显示的动画")
                    XCTAssertTrue(reader.activePaperView === firstPaper)
                    XCTAssertTrue(firstPaper.hasResources)
                    XCTAssertEqual(reader.currentPage.identity.unitID, "2")
                    XCTAssertEqual(queried, [2], "后续页面应在上一页完整落定后才查询")
                    XCTAssertEqual(events.count, 1, "连点期间不能提前交付终态")
                }
                for _ in 0..<20 { reader.advancePaperAnimation(elapsed: 0.1) }
                XCTAssertEqual(reader.currentPage.identity.unitID, "3")
                XCTAssertEqual(queried, [2, 3, 4])
                assertTerminals(events, results: [true, true, true])
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertEqual(reader.children.count, 1)
            }
        }
    }

    /// 无参数；队列到达书尾后仍按顺序处理相反方向，不创建边界伪事务。无返回值。
    func testQueuedBoundaryStillAllowsLaterReverseClick() throws {
        let reader = try reader(initial: 7); defer { reader.invalidate() }
        var queried: [Int] = []; var events: [PageTransitionEvent] = []; var unavailable = 0
        supply(reader, requests: { index, _ in queried.append(index) })
        reader.onTransition = { events.append($0) }; reader.onUnavailable = { _, _ in unavailable += 1 }
        for direction in [PageTurnDirection.next, .next, .next, .previous] { XCTAssertTrue(try reader.turn(direction)) }
        XCTAssertEqual(queried, [7]); XCTAssertEqual(reader.currentPage.identity.unitID, "7")
        finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "7")
        XCTAssertEqual(queried, [7, 8, 8, 8]); XCTAssertEqual(unavailable, 2)
        assertTerminals(events, results: [true, true]); XCTAssertFalse(reader.isTransitioning)
    }

    /// 无参数；取消、暂停、退出、退后台及尺寸变化均清理待执行点击，不得在恢复后突然翻页。无返回值。
    func testQueuedClicksAreClearedByLifecycleCancellation() throws {
        for interruption in 0..<5 {
            let reader = try reader(); defer { reader.invalidate() }
            var queried: [Int] = []; var events: [PageTransitionEvent] = []
            supply(reader, requests: { index, _ in queried.append(index) }); reader.onTransition = { events.append($0) }
            XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.previous))
            switch interruption {
            case 0: reader.cancelTransition()
            case 1: reader.setSuspended(true, reason: "测试暂停")
            case 2: reader.invalidate()
            case 3: reader.setAutomaticApplicationActive(false)
            default:
                reader.view.bounds.size.width = 400; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            }
            if reader.isActive { reader.setSuspended(false, reason: "测试暂停"); reader.setAutomaticApplicationActive(true) }
            finish(reader)
            XCTAssertEqual(queried, [2]); XCTAssertEqual(reader.currentPage.identity.unitID, "2")
            XCTAssertFalse(reader.isTransitioning); XCTAssertNil(reader.activePaperView)
            assertTerminals(events, results: [false])
        }
    }

    /// 无参数；真实拖动可接管当前收尾，并取消积压轻点，避免松手后继续执行过时点击。无返回值。
    func testNewDragTakesOwnershipAndDropsQueuedClicks() throws {
        let reader = try reader(); defer { reader.invalidate() }
        var queried: [Int] = []; var events: [PageTransitionEvent] = []
        supply(reader, requests: { index, _ in queried.append(index) }); reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.next))
        let (a, b) = points(reader, direction: .previous)
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: a))
        XCTAssertEqual(queried, [2, 3])
        reader.updateInteractiveTurn(to: b); reader.endInteractiveTurn(velocity: 900); finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "2"); XCTAssertEqual(queried, [2, 3])
        assertTerminals(events, results: [true, true])
    }

    /// 无参数；积压有固定上限，超过上限明确返回不接受，不能强制跳完当前动画或提前查询更多页面。无返回值。
    func testClickBacklogIsBoundedWithoutDiscardingAcceptedAnimation() throws {
        let reader = try reader(); defer { reader.invalidate() }
        var queried: [Int] = []; supply(reader, requests: { index, _ in queried.append(index) })
        XCTAssertTrue(try reader.turn(.next)); let original = reader.activeTransitionID
        for _ in 0..<32 { XCTAssertTrue(try reader.turn(.next)) }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(reader.activeTransitionID, original); XCTAssertEqual(queried, [2])
        reader.cancelTransition(); finish(reader)
        XCTAssertEqual(queried, [2]); XCTAssertEqual(reader.currentPage.identity.unitID, "2")
    }

    /// 无参数；真实窗口中的连续点击每笔都使用 Metal，提交多个不同姿态，再按正确页码交付唯一终态。无返回值。
    func testEveryRapidClickPresentsItsOwnIntermediateNativeFrames() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let reader = try reader(axis: axis, order: order)
                reader.usesDisplayLinkForPaperAnimation = true
                supply(reader, axis: axis, order: order)
                var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                window.rootViewController = reader; window.makeKeyAndVisible()
                defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
                reader.view.frame = window.bounds; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                XCTAssertTrue(try reader.turn(.next)); let first = reader.activeTransitionID
                XCTAssertNotNil(reader.activePaperView?.cornerDrag)
                XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.previous))
                XCTAssertEqual(reader.activeTransitionID, first)
                var submitted: [UUID: Int] = [:]; var poses: [UUID: Set<CGFloat>] = [:]
                for _ in 0..<800 {
                    if let id = reader.activeTransitionID, let paper = reader.activePaperView {
                        XCTAssertTrue(paper.usesMetalCornerRendering)
                        XCTAssertEqual(paper.softwareCornerDrawCount, 0)
                        submitted[id] = max(submitted[id] ?? 0, paper.nativeCornerSubmittedFrameCount)
                        if let shown = paper.submittedCornerDrag {
                            let primary = axis == .horizontal ? shown.gripPosition.x : shown.gripPosition.y
                            poses[id, default: []].insert(primary)
                        }
                    }
                    if !reader.isTransitioning { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertFalse(reader.isTransitioning); XCTAssertFalse(reader.isPaperClockRunning)
                XCTAssertEqual(reader.currentPage.identity.unitID, "3")
                XCTAssertEqual(reader.children.count, 1); XCTAssertNil(reader.activePaperView)
                let transitions = events.compactMap { event -> UUID? in
                    if case .willBegin(let transition) = event { return transition.id }; return nil
                }
                XCTAssertEqual(transitions.count, 3)
                for id in transitions {
                    XCTAssertGreaterThan(submitted[id] ?? 0, 3, "每次点击都应提交多个原生中间帧")
                    XCTAssertGreaterThan(poses[id]?.count ?? 0, 3, "不能只提交重复的平面终页")
                }
                assertTerminals(events, results: [true, true, true])
                print("RAPID_TAP_NATIVE axis=\(axis) order=\(order) submissions=\(transitions.map { submitted[$0] ?? 0 }) poses=\(transitions.map { poses[$0]?.count ?? 0 })")
            }
        }
    }

    /// 无参数；排队执行失败的回调中暂停／停止自动阅读，公开状态与时钟必须同步更新。无返回值。
    func testQueuedFailureCallbackImmediatelyUpdatesAutomaticPauseAndStop() throws {
        for stops in [false, true] {
            let reader = try reader(); defer { reader.invalidate() }
            reader.usesDisplayLinkForAutomaticReading = true
            reader.viewDidAppear(false)
            try reader.startAutomaticReading(interval: 5)
            XCTAssertEqual(reader.automaticReadingState, .running)
            var requests = 0, failures = 0
            reader.pageProvider = { [weak reader, weak self] _, _ in
                guard let reader, let self else { return .failed }
                requests += 1
                // 第二次请求返回已挂载的当前页，强制进入排队执行的抛错路径。
                if requests > 1 { return .page(reader.currentPage) }
                do { return .page(try self.page(3)) }
                catch { XCTFail("页面构造失败：\(error)"); return .failed }
            }
            reader.onUnavailable = { [weak reader] _, availability in
                guard let reader else { return }
                guard case .failed = availability else { return XCTFail("应报告排队执行失败") }
                failures += 1
                if stops { reader.stopAutomaticReading() } else { reader.pauseAutomaticReading() }
            }
            XCTAssertTrue(try reader.turn(.next)); XCTAssertTrue(try reader.turn(.next))
            finish(reader)
            XCTAssertEqual(requests, 2); XCTAssertEqual(failures, 1)
            XCTAssertEqual(reader.currentPage.identity.unitID, "3")
            XCTAssertEqual(reader.automaticReadingState, stops ? .stopped : .paused)
            XCTAssertFalse(reader.isAutomaticClockRunning, "回调要求暂停后不能等待下一次 tick 才停钟")
            XCTAssertFalse(reader.isTransitioning)
        }
    }

    /// 无参数；拖动未松手仍拒绝第二个事务，收尾动画期间则排队并在落定后执行。无返回值。
    func testOtherEffectsQueueDuringSettlementButRejectDuringDrag() throws {
        for effect in [PageTurnEffect.arch, .slide, .cover] {
            let reader = try reader(effect: effect); defer { reader.invalidate() }; supply(reader)
            XCTAssertTrue(try reader.beginInteractiveTurn(.next)); reader.updateInteractiveTurn(displacement: 160)
            XCTAssertThrowsError(try reader.turn(.next)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
            reader.endInteractiveTurn(velocity: 900)
            // 收尾动画仍在播放：这里接受并排队，不立刻改写当前页，也不被丢弃。
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity.unitID, "2")
            // 取消应连同排队意图一起清理，不能偷偷多翻一页。
            reader.cancelTransition()
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        }
    }
}
#endif
