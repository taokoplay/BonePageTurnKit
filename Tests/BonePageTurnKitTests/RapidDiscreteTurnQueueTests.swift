#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 过渡中的连续轻点／拖动只排队，不丢弃；每笔仍是独立事务，动画资源始终只有一份。
@MainActor
final class RapidDiscreteTurnQueueTests: XCTestCase {
    /// - Parameters: index: 独立页面号；layout: 单双页。
    /// - Returns: 每次请求都创建新控制器的真实页面。
    private func page(_ index: Int, layout: ReaderPageLayout = .single) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index % 2 == 0 ? .systemYellow : .systemTeal
        let label = UILabel(frame: CGRect(x: 20, y: 30, width: 260, height: 120))
        label.numberOfLines = 0; label.text = "连续翻页 \(index)"
        child.view.addSubview(label)
        let content = PageContent(identity: .init(sourceID: "rapid-queue", unitID: String(index)), controller: child)
        guard layout == .spread else { return content }
        let second = UIViewController()
        second.view = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 480))
        let spread = try? PageSpreadViewController(first: content, second: .init(
            identity: .init(sourceID: "rapid-queue", unitID: "\(index)-b"), controller: second),
            axis: .horizontal, readingOrder: .leftToRight)
        guard let spread else { return content }
        return PageContent(identity: .init(sourceID: "rapid-queue", unitID: String(index)), controller: spread)
    }

    /// - Parameters: initial: 初始页号；effect: 翻页效果；layout: 布局。
    /// - Returns: 装载了 0…8 真实邻页的已布局容器。
    private func reader(initial: Int = 2, effect: PageTurnEffect = .slide,
                        layout: ReaderPageLayout = .single) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "连续翻页排队需要开启翻页动画")
        let value = try PagedReaderViewController(page: page(initial, layout: layout),
            configuration: .init(presentation: .paged(effect: effect, axis: .horizontal),
                paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64),
                layout: layout, readingOrder: .leftToRight))
        value.usesDisplayLinkForPaperAnimation = false
        value.pageProvider = { [weak self] identity, direction in
            guard let self, let index = Int(identity.unitID) else { return .failed }
            let next = index + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            return .page(self.page(next, layout: layout))
        }
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        return value
    }

    /// - Parameters: reader: 容器；condition: 结束条件；timeout: 最长等待秒数。
    /// - Returns: 无返回值；真实推进主队列让动画与排队事务依次落定。
    private func spin(_ reader: PagedReaderViewController, until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// 无参数；同一动画期间的连续轻点意图全部落定，顺序与笔数均不丢失。无返回值。
    func testRapidTurnsQueueDuringAnimationAndDrainInOrder() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        var committed: [Int] = []
        reader.onTransition = { event in
            if case .didCommit(let transition) = event, let to = Int(transition.to.unitID) { committed.append(to) }
        }
        XCTAssertTrue(try reader.turn(.next))
        // 上一笔仍在播放：这里以前抛 interactionInProgress，现在应接受并排队。
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(reader.isTransitioning)
        spin(reader) { !reader.isTransitioning && reader.currentPage.identity.unitID == "5" }
        XCTAssertEqual(reader.currentPage.identity.unitID, "5")
        XCTAssertEqual(committed, [3, 4, 5])
    }

    /// 无参数；排队上限为 32 笔，超出明确拒绝且不影响已接受的意图。无返回值。
    func testQueueRespectsMaximumAndKeepsAcceptedIntent() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        XCTAssertTrue(try reader.turn(.next))
        for _ in 0..<32 { XCTAssertTrue(try reader.turn(.next)) }
        XCTAssertFalse(try reader.turn(.next))
        reader.cancelTransition()
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        // 取消后队列已清空，新的翻页立即执行而不是先消费旧意图。
        XCTAssertTrue(try reader.turn(.next))
        spin(reader) { !reader.isTransitioning && reader.currentPage.identity.unitID == "3" }
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
    }

    /// 无参数；过渡中中央轻点不排队也不翻页，避免菜单点击混入翻页序列。无返回值。
    func testCenterTapDuringTransitionIsIgnored() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.tapConfiguration = try ReaderTapConfiguration()
        var centers = 0
        reader.onCenterTap = { _ in centers += 1 }
        XCTAssertTrue(try reader.turn(.next))
        let center = CGPoint(x: reader.view.bounds.midX, y: reader.view.bounds.midY)
        // 中央区不参与排队：沿用原门禁，过渡中明确拒绝而不是被静默消费。
        XCTAssertThrowsError(try reader.handleTap(at: center)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
        XCTAssertEqual(centers, 0)
        spin(reader) { !reader.isTransitioning }
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
    }

    /// 无参数；两侧轻点在过渡中累积为后排意图，最终停在两次之后的页面。无返回值。
    func testSideTapQueuesNextTurn() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.tapConfiguration = try ReaderTapConfiguration()
        let bounds = reader.view.bounds
        let nextPoint = CGPoint(x: bounds.maxX - 8, y: bounds.midY)
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.handleTap(at: nextPoint))
        spin(reader) { !reader.isTransitioning && reader.currentPage.identity.unitID == "4" }
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
    }

    /// 无参数；手速越快收尾倍率越小，间隔恢复到 0.30 秒以上回到原速。无返回值。
    func testPacingScaleFollowsSmoothedInterval() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        XCTAssertEqual(reader.transitionDurationScale, 1, accuracy: 0.001)
        for (interval, expected) in [(0.10, 0.4), (0.20, 0.7), (0.30, 1.0), (2.0, 1.0)] {
            reader.smoothedTurnInterval = interval
            XCTAssertEqual(reader.transitionDurationScale, CGFloat(expected), accuracy: 0.001,
                           "间隔 \(interval) 秒的收尾倍率")
        }
        // 非有限值必须回到原速，不能把动画压成 0。
        reader.smoothedTurnInterval = .nan
        XCTAssertEqual(reader.transitionDurationScale, 1, accuracy: 0.001)
    }

    /// 无参数；连续两笔意图让收尾倍率立即变小，长时间无输入后恢复。无返回值。
    func testRapidIntentsShortenTransitionAndRecoverAfterPause() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertNotNil(reader.smoothedTurnInterval)
        XCTAssertLessThan(reader.transitionDurationScale, 1)
        // 间隔超过 2 秒视为新手势：下一次意图重置平滑值，动画回到原速。
        reader.smoothedTurnInterval = nil
        XCTAssertEqual(reader.transitionDurationScale, 1, accuracy: 0.001)
    }

    /// 无参数；关闭接管时纸张按队列完整播放；开启后仿真／拱页与轻量效果一样立即衔接。无返回值。
    func testPaperEffectHandOverFollowsHostSwitch() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            for handsOver in [false, true] {
                let reader = try reader(effect: effect)
                defer { reader.invalidate() }
                reader.handsOverActiveTransitionOnNewIntent = handsOver
                var commits = 0
                reader.onTransition = { if case .didCommit = $0 { commits += 1 } }
                XCTAssertTrue(try reader.turn(.previous))
                XCTAssertTrue(try reader.turn(.previous))
                XCTAssertTrue(reader.isTransitioning)
                if handsOver {
                    // 接管：第一笔推到终点落定，第二笔立即起播。
                    XCTAssertEqual(reader.currentPage.identity.unitID, "1")
                    XCTAssertEqual(commits, 1)
                } else {
                    // 队列：上一笔完整播放，页未提交，意图按序等待。
                    XCTAssertEqual(reader.currentPage.identity.unitID, "2")
                    XCTAssertEqual(commits, 0)
                }
                reader.cancelTransition()
                XCTAssertFalse(reader.isTransitioning)
            }
        }
    }

    /// 无参数；开启接管后新一笔立即起播，无需等上一段动画播完。无返回值。
    func testHandoffStartsNextTurnImmediately() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.handsOverActiveTransitionOnNewIntent = true
        var commits: [Int] = []
        reader.onTransition = { event in
            if case .didCommit(let transition) = event, let to = Int(transition.to.unitID) { commits.append(to) }
        }
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.turn(.next))
        // 接管：第一笔直接落定，第二笔在同一主队列周期起播，动画不重叠但也没有等待。
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
        XCTAssertTrue(reader.isTransitioning)
        XCTAssertEqual(commits, [3])
        spin(reader) { !reader.isTransitioning && reader.currentPage.identity.unitID == "4" }
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
        XCTAssertEqual(commits, [3, 4])
    }

    /// 无参数；接管沿用动画既定目标，回弹中的取消动画不会被误提交。无返回值。
    func testHandoffRespectsCancelTarget() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.handsOverActiveTransitionOnNewIntent = true
        var commits = 0
        reader.onTransition = { if case .didCommit = $0 { commits += 1 } }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 40)
        reader.endInteractiveTurn(velocity: -900)
        XCTAssertTrue(reader.isTransitioning)
        XCTAssertTrue(try reader.turn(.next))
        // 回弹动画目标是取消：接管必须先把这一笔退回原页，再开始用户要的下一页。
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        spin(reader) { !reader.isTransitioning }
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
        XCTAssertEqual(commits, 1)
    }
}
#endif
