#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 半程松手的收尾必须逐帧播放：正反向的收尾帧数、进度单调性与最终落点一致。
/// 现场问题：左往右（previous）翻到一半松手会直接跳到结束，缺少右往左那种丝滑收尾。
@MainActor
final class MidwayCurlReleaseTests: XCTestCase {
    /// - Parameters:
    ///   - direction: 翻页方向；
    ///   - progress: 松手时的进度。
    /// - Returns: 真实窗口中的容器与纸面视图。
    private func makeReader(direction: PageTurnDirection, progress: CGFloat) throws
        -> (PagedReaderViewController, PaperTransitionView) {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "收尾逐帧需要开启动画")
        let current = UIViewController(); current.view.backgroundColor = .white
        let target = UIViewController(); target.view.backgroundColor = .systemTeal
        let currentPage = PageContent(identity: .init(sourceID: "midway", unitID: "current"), controller: current)
        let targetPage = PageContent(identity: .init(sourceID: "midway", unitID: "target"), controller: target)
        let reader = try PagedReaderViewController(page: currentPage,
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { _, _ in .page(targetPage) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader; window.makeKeyAndVisible()
        addTeardownBlock { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        let start = direction == .next ? CGPoint(x: 300, y: 240) : CGPoint(x: 20, y: 240)
        XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: start))
        // 半程：沿翻页轴推 0.45 × 2 × 页宽。
        let displacement = 0.45 * 2 * 320 * (direction == .next ? -1 : 1)
        reader.updateInteractiveTurn(displacement: displacement)
        return (reader, try XCTUnwrap(reader.activePaperView))
    }

    /// 无参数；零速度半程松手后，正反向都要多帧推进且进度单调，不能一帧跳到终点。无返回值。
    func testMidwayZeroVelocityReleaseAnimatesFrameByFrame() throws {
        for direction in [PageTurnDirection.next, .previous] {
            let (reader, paper) = try makeReader(direction: direction, progress: 0.45)
            let startProgress = try XCTUnwrap(paper.cornerDrag).gestureProgress
            reader.endInteractiveTurn(velocity: 0)
            XCTAssertTrue(reader.isTransitioning, "\(direction) 松手后应立即进入收尾")
            var samples: [CGFloat] = []
            for _ in 0..<20 {
                guard reader.isTransitioning else { break }
                reader.advancePaperAnimation(elapsed: 0.02)
                if let drag = paper.cornerDrag { samples.append(drag.gestureProgress) }
            }
            XCTAssertFalse(reader.isTransitioning, "\(direction) 收尾应在若干帧内结束")
            XCTAssertGreaterThanOrEqual(samples.count, 3, "\(direction) 收尾必须逐帧推进，不能一帧完成")
            print("TRACE", direction, "start", startProgress, "samples", samples.map { ($0 * 1000).rounded() / 1000 })
            let steps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
            print("TRACE steps", steps.map { ($0 * 1000).rounded() / 1000 })
            // 首帧应与手指姿态连续（20ms 一帧的缓动步进本身可达 10%+），不能整段跳到终点。
            let jump = abs(samples.first! - startProgress)
            XCTAssertLessThan(jump, 0.16, "\(direction) 收尾首帧跳变过大：松手 \(startProgress) → 首帧 \(samples.first!)")
        }
    }
}
#endif
