#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 同一主线程事件内开始、短移、松手，确保首个 GPU 画面来不及提交时收尾仍完整。
@MainActor
final class ShortFlickReleaseTests: XCTestCase {
    /// - Parameter id: 独立页面身份。
    /// - Returns: 不包含加载或布局异步行为的真实页面。
    private func page(_ id: String) -> PageContent {
        let controller = UIViewController()
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        controller.view.backgroundColor = id == "current" ? .white : .systemTeal
        return .init(identity: .init(sourceID: "short-flick", unitID: id), controller: controller)
    }

    /// 无参数；GPU 首帧之前的时钟不能把短触收尾隐形跑完，正反向完成与取消均保留事务和资源。无返回值。
    func testReleaseClockWaitsForFirstNativeSubmission() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        for direction in [PageTurnDirection.next, .previous] {
            for completed in [false, true] {
                let reader = try PagedReaderViewController(page: page("current"),
                    configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
                reader.usesDisplayLinkForAutomaticReading = false
                reader.pageProvider = { [weak self] _, _ in
                    guard let self else { return .failed }
                    return .page(self.page("target"))
                }
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                window.rootViewController = reader; window.makeKeyAndVisible()
                defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
                reader.view.frame = window.bounds; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                let origin = CGPoint(x: direction == .next ? 300 : 20, y: 240)
                XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                reader.updateInteractiveTurn(to: CGPoint(x: origin.x + (direction == .next ? -30 : 30), y: 245))
                let paper = try XCTUnwrap(reader.activePaperView)
                XCTAssertEqual(paper.metalSubmittedFrameCount, 0, "同步短触夹具应在 GPU 首次主线程提交前松手")
                reader.endInteractiveTurn(velocity: completed ? 900 : -900)
                let start = paper.cornerDrag
                for _ in 0..<20 { reader.advancePaperAnimation(elapsed: 0.1) }
                XCTAssertTrue(reader.isTransitioning, "没有显示首帧时不能直接结束动画")
                XCTAssertTrue(paper.hasResources)
                XCTAssertEqual(paper.cornerDrag, start, "首帧等待期间不能隐形推进纸面")
                XCTAssertEqual(reader.currentPage.identity.unitID, "current")
            }
        }
    }
    /// 无参数；实际显示路径中的短触完成／取消都必须提交多个中间帧，之后仅交付一次正确终态。无返回值。
    func testShortReleaseShowsIntermediateFramesAndCompletes() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        for direction in [PageTurnDirection.next, .previous] {
            for completed in [false, true] {
                let reader = try PagedReaderViewController(page: page("current"),
                    configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
                reader.usesDisplayLinkForAutomaticReading = false
                let target = page("target"); reader.pageProvider = { _, _ in .page(target) }
                var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                window.rootViewController = reader; window.makeKeyAndVisible()
                defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
                reader.view.frame = window.bounds; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                let origin = CGPoint(x: direction == .next ? 300 : 20, y: 240)
                XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                reader.updateInteractiveTurn(to: CGPoint(x: origin.x + (direction == .next ? -30 : 30), y: 245))
                let paper = try XCTUnwrap(reader.activePaperView)
                XCTAssertEqual(paper.metalSubmittedFrameCount, 0)
                reader.endInteractiveTurn(velocity: completed ? 900 : -900)
                var maximumSubmissions = 0
                for _ in 0..<400 {
                    maximumSubmissions = max(maximumSubmissions, paper.metalSubmittedFrameCount)
                    if !reader.isTransitioning { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertGreaterThan(maximumSubmissions, 3, "短触后应看到实际连续纸面，而非只恢复终页")
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
                XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                XCTAssertEqual(reader.children.count, 1); XCTAssertFalse(paper.hasResources)
                guard case .willBegin(let transition) = events.first else { return XCTFail("缺少开始事务") }
                let expected: [PageTransitionEvent] = completed
                    ? [.willBegin(transition), .didCommit(transition), .didSettle(transition, completed: true)]
                    : [.willBegin(transition), .didSettle(transition, completed: false)]
                XCTAssertEqual(events, expected)
                print("SHORT_FLICK_SUBMISSIONS direction=\(direction) completed=\(completed) max=\(maximumSubmissions)")
            }
        }
    }

}
#endif
