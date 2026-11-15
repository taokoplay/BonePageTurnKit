#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 空白／极短内容页（只有页脚）上半程松手，收尾必须照常落定，不能停在半翻等帧。
@MainActor
final class ShortPageReleaseTests: XCTestCase {
    /// - Parameters:
    ///   - heights: 当前页与目标页的正文高度；0 表示只有页脚。
    ///   - direction: 翻页方向。
    /// - Returns: 真实窗口中的容器。
    private func makeReader(heights: (CGFloat, CGFloat), direction: PageTurnDirection) throws
        -> PagedReaderViewController {
        func leaf(_ height: CGFloat, color: UIColor, name: String) -> PageContent {
            let controller = UIViewController()
            controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: max(1, height)))
            controller.view.backgroundColor = color
            let label = UILabel(frame: CGRect(x: 12, y: 0, width: 296, height: 18))
            label.text = name
            controller.view.addSubview(label)
            return PageContent(identity: .init(sourceID: "short-page", unitID: name), controller: controller)
        }
        let current = leaf(heights.0, color: .white, name: "current")
        let target = leaf(heights.1, color: .systemTeal, name: "target")
        let reader = try PagedReaderViewController(page: current,
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { _, _ in .page(target) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader
        window.makeKeyAndVisible()
        addTeardownBlock { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return reader
    }

    /// 无参数；相邻两笔翻页只抓三张页面位图：第二笔复用第一笔的目标页。无返回值。
    func testConsecutiveTurnsReuseCachedSnapshot() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "复用例需要开启动画")
        func leaf(_ name: String) -> PageContent {
            let controller = UIViewController()
            controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            controller.view.backgroundColor = .white
            return PageContent(identity: .init(sourceID: "cache", unitID: name), controller: controller)
        }
        let pages = ["0", "1", "2"].map(leaf)
        let reader = try PagedReaderViewController(page: pages[0],
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        var next = 1
        reader.pageProvider = { _, _ in defer { next += 1 }; return .page(pages[min(next, pages.count - 1)]) }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.layoutIfNeeded()
        func spin() {
            let deadline = Date().addingTimeInterval(3)
            while reader.isTransitioning, Date() < deadline {
                reader.advancePaperAnimation(elapsed: 0.05)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }
        XCTAssertTrue(try reader.turn(.next)); spin()
        XCTAssertEqual(reader.paperSnapshotCaptureCount, 2, "第一笔必须抓取当前页与目标页")
        XCTAssertTrue(try reader.turn(.next)); spin()
        XCTAssertTrue(reader.lastPaperSnapshotReused, "第二笔应命中快照缓存")
        XCTAssertEqual(reader.paperSnapshotCaptureCount, 3, "第二笔应复用上一笔的目标页，只抓一张")
    }

    /// 无参数；原生视图不再提交新帧时，收尾门禁必须在 0.2 秒后改为标量驱动。无返回值。
    func testReleaseGateFallsBackWhenNativeStopsSubmitting() {
        var gate = PaperReleaseFrameGate(waitsForGPU: true, submittedFrameCount: 3)
        var advanced: [TimeInterval] = []
        for _ in 0..<20 {
            if let step = gate.step(elapsed: 1.0 / 60.0, submittedFrameCount: 3, framesExhausted: true) { advanced.append(step) }
        }
        XCTAssertFalse(advanced.isEmpty, "原生停止提交后不能永久等待")
        XCTAssertLessThanOrEqual(advanced[0], PaperCornerDragFollower.maximumFrameStep)
        // 兜底之后必须持续可推进，不能只放行一帧再卡住。
        let after = (0..<5).compactMap { _ in gate.step(elapsed: 1.0 / 60.0, submittedFrameCount: 3, framesExhausted: true) }
        XCTAssertEqual(after.count, 5)
    }

    /// 无参数；只有页脚高的页面松手后，收尾应在有限帧内落定而不是停住。无返回值。
    func testReleaseOnFooterOnlyPageStillSettles() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "收尾需要开启动画")
        for direction in [PageTurnDirection.next, .previous] {
            for heights in [(CGFloat(18), CGFloat(18)), (CGFloat(18), CGFloat(400))] {
                let reader = try makeReader(heights: heights, direction: direction)
                let start = direction == .next ? CGPoint(x: 300, y: 9) : CGPoint(x: 20, y: 9)
                XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: start),
                              "\(direction) 应能开始卷页（高度 \(heights)）")
                reader.updateInteractiveTurn(displacement: 0.45 * 2 * 320 * (direction == .next ? -1 : 1))
                reader.endInteractiveTurn(velocity: 0)
                XCTAssertTrue(reader.isTransitioning)
                // 逐帧推进 + 让主队列处理原生提交；超时未落定即为冻结。
                let deadline = Date().addingTimeInterval(3)
                while reader.isTransitioning, Date() < deadline {
                    reader.advancePaperAnimation(elapsed: 0.05)
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                }
                XCTAssertFalse(reader.isTransitioning, "\(direction) 高度 \(heights) 的收尾冻结在半翻")
            }
        }
    }
}
#endif
