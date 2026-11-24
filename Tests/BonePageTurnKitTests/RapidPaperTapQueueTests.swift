#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 快速连点仿真／拱页时，收尾期间的点击必须按序累积并在上一笔落定后继续翻页，而不是被丢弃。
@MainActor
final class RapidPaperTapQueueTests: XCTestCase {
    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index % 2 == 0 ? .systemYellow : .systemTeal
        let label = UILabel(frame: CGRect(x: 20, y: 30, width: 260, height: 120))
        label.numberOfLines = 0; label.text = "快速连点 \(index)"
        child.view.addSubview(label)
        return .init(identity: .init(sourceID: "rapid-paper-tap", unitID: String(index)), controller: child)
    }

    /// - Parameters: effect: 纸张效果；initial: 初始页号。
    /// - Returns: 关闭原生时钟、由测试显式推进收尾的真实分页容器。
    private func reader(effect: PageTurnEffect, initial: Int = 2) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "连点排队测试需要开启翻页动画")
        let value = try PagedReaderViewController(page: Self.page(initial),
            configuration: .init(presentation: .paged(effect: effect, axis: .horizontal),
                paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        value.usesDisplayLinkForPaperAnimation = false; value.usesDisplayLinkForAutomaticReading = false
        value.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            let next = current + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            return .page(Self.page(next))
        }
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        return value
    }

    /// - Parameter reader: 已松手容器。
    /// - Returns: 无返回值；过期额外 tick 也不会重复提交。
    private func finish(_ reader: PagedReaderViewController) {
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
    }

    /// 无参数；仿真与拱页连点三次后必须依次翻三页，每一笔都有独立的开始、提交与落定。无返回值。
    func testRapidPaperTapsQueueAllTurnsInOrder() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let reader = try reader(effect: effect)
            defer { reader.invalidate() }
            var committed: [Int] = []
            var events: [PageTransitionEvent] = []
            reader.onTransition = { event in
                events.append(event)
                if case .didCommit(let transition) = event, let to = Int(transition.to.unitID) { committed.append(to) }
            }
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity.unitID, "2", "连点期间不能提前提交")
            finish(reader)
            XCTAssertEqual(reader.currentPage.identity.unitID, "5", "\(effect) 连点三次应翻三页")
            XCTAssertEqual(committed, [3, 4, 5])
            XCTAssertEqual(events.filter { if case .willBegin = $0 { return true }; return false }.count, 3)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertNil(reader.activePaperView)
        }
    }

    /// 无参数；分区轻点走同一条排队路径：收尾期间连点两侧区域同样累积为后续翻页。无返回值。
    func testRapidSideTapsQueueDuringPaperSettlement() throws {
        let reader = try reader(effect: .curl)
        defer { reader.invalidate() }
        reader.tapConfiguration = try ReaderTapConfiguration()
        let nextPoint = CGPoint(x: reader.view.bounds.maxX - 8, y: reader.view.bounds.midY)
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.handleTap(at: nextPoint))
        XCTAssertTrue(try reader.handleTap(at: nextPoint))
        XCTAssertEqual(reader.currentPage.identity.unitID, "2")
        finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "5", "一笔翻页加两次侧边轻点应各翻一页")
    }

    /// 无参数；快速连点时纸张收尾按手速压到 0.8 倍（约 288ms），队列排空后恢复原速，且每一笔都保留完整阶段。无返回值。
    func testFastTapsShortenPaperReleaseButKeepPhases() throws {
        let reader = try reader(effect: .curl)
        defer { reader.invalidate() }
        reader.smoothedTurnInterval = 0.30
        XCTAssertEqual(reader.transitionDurationScale, 1, accuracy: 0.001)
        XCTAssertTrue(try reader.turn(.next))
        // 模拟最快手速：第二次意图让平滑间隔低于 0.10 秒。
        reader.smoothedTurnInterval = 0.10
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.transitionDurationScale, 0.8, accuracy: 0.001, "快速连点时纸张收尾应压缩到 0.8 倍")
        var frames: [CGFloat] = []
        let id = try XCTUnwrap(reader.activeTransitionID)
        for _ in 0..<200 {
            guard reader.activeTransitionID == id, let paper = reader.activePaperView else { break }
            frames.append(paper.progress)
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
        XCTAssertGreaterThanOrEqual(frames.count, 16, "压缩后仍要保留至少约 1/4 秒的播放")
        XCTAssertTrue(frames.contains { (0.1...0.3).contains($0) }, "缺少起翻阶段")
        XCTAssertTrue(frames.contains { (0.4...0.65).contains($0) }, "缺少中段卷曲")
        XCTAssertTrue(frames.contains { $0 >= 0.9 }, "缺少落页阶段")
        finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
        reader.smoothedTurnInterval = nil
        XCTAssertEqual(reader.transitionDurationScale, 1, accuracy: 0.001, "停手后恢复原速")
    }

    /// 无参数；开启接管后快速连点立即衔接：上一笔推到终点落定，新一笔即刻起播。无返回值。
    func testHandoverStacksRapidPaperTapsLikeSystemCurl() throws {
        let reader = try reader(effect: .curl)
        defer { reader.invalidate() }
        reader.handsOverActiveTransitionOnNewIntent = true
        var committed: [Int] = []
        reader.onTransition = { event in
            if case .didCommit(let transition) = event, let to = Int(transition.to.unitID) { committed.append(to) }
        }
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(committed, [3], "第二笔接管时第一笔立即落定")
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
        XCTAssertTrue(reader.isTransitioning)
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(committed, [3, 4])
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
        finish(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "5")
        XCTAssertEqual(committed, [3, 4, 5])
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertNil(reader.activePaperView)
    }

    /// 无参数；开启衔接后旧收尾层转为幽灵：从旧姿态连续推进、完整播完后自动移除，新动画不受影响。无返回值。
    func testGhostReleaseFinishesNaturallyAboveNewTurn() throws {
        let reader = try reader(effect: .curl)
        defer { reader.invalidate() }
        reader.handsOverActiveTransitionOnNewIntent = true
        XCTAssertTrue(try reader.turn(.next))
        let firstPaper = try XCTUnwrap(reader.activePaperView)
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.ghostReleaseCount, 1, "接管时应保留旧收尾层为幽灵")
        XCTAssertTrue(reader.activePaperView !== firstPaper)
        XCTAssertTrue(firstPaper.hasResources, "幽灵层必须继续持有资源播放")
        XCTAssertTrue(firstPaper.superview === reader.view, "幽灵层仍挂在画布上")
        var lastProgress = firstPaper.progress
        for _ in 0..<120 {
            reader.advanceGhostReleases(elapsed: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(firstPaper.progress, lastProgress, "幽灵层必须从旧姿态连续推进")
            lastProgress = firstPaper.progress
            if reader.ghostReleaseCount == 0 { break }
        }
        XCTAssertEqual(reader.ghostReleaseCount, 0, "幽灵层播完后应自动移除")
        XCTAssertNil(firstPaper.superview)
        XCTAssertFalse(firstPaper.hasResources)
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
        XCTAssertNil(reader.activePaperView)
    }

    /// 无参数；取消等中断会连同幽灵层一起清理，不留悬挂视图。无返回值。
    func testGhostReleaseTeardownOnCancel() throws {
        let reader = try reader(effect: .curl)
        defer { reader.invalidate() }
        reader.handsOverActiveTransitionOnNewIntent = true
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.ghostReleaseCount, 1)
        reader.cancelTransition()
        XCTAssertEqual(reader.ghostReleaseCount, 0)
        XCTAssertNil(reader.activePaperView)
        XCTAssertFalse(reader.isTransitioning)
    }
}
#endif
