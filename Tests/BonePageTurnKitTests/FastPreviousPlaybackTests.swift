#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 快速原生回翻要从实际显示姿态继续，不能只检查逻辑进度和最终页码。
@MainActor
final class FastPreviousPlaybackTests: XCTestCase {
    private final class PanSample: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .possible
        var sampleTranslation = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint {
            CGPoint(x: 20 + sampleTranslation.x, y: 474 + sampleTranslation.y)
        }
        override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: 2_400, y: -40) }
    }

    private func page(_ index: Int) -> PageContent {
        let controller = UIViewController()
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        controller.view.backgroundColor = index.isMultiple(of: 2) ? .white : .systemTeal
        let text = UILabel(frame: CGRect(x: 18, y: 35, width: 284, height: 350))
        text.numberOfLines = 0
        text.text = String(repeating: "第 \(index) 页 · 快速回翻仍需连续显示纸面\n", count: 10)
        controller.view.addSubview(text)
        return .init(identity: .init(sourceID: "fast-previous", unitID: String(index)), controller: controller)
    }

    private func fixture() throws -> (PagedReaderViewController, UIWindow) {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let reader = try PagedReaderViewController(page: page(6), configuration: .init(
            presentation: .paged(effect: .curl, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.animationDiagnosticsEnabled = true
        reader.pageProvider = { [self] identity, _ in .page(page((Int(identity.unitID) ?? 6) - 1)) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader; window.makeKeyAndVisible()
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return (reader, window)
    }

    private func flick(_ reader: PagedReaderViewController) {
        let pan = PanSample()
        for (state, translation) in [(UIGestureRecognizer.State.began, CGPoint(x: 12, y: -1)),
                                     (.changed, CGPoint(x: 270, y: -6)), (.ended, CGPoint(x: 280, y: -6))] {
            pan.sampleState = state; pan.sampleTranslation = translation
            reader.perform(NSSelectorFromString("handlePan:"), with: pan)
        }
    }

    func testFastPreviousBeforeFirstSubmissionStartsFromUnshownPaper() throws {
        let (reader, window) = try fixture()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        flick(reader)
        let paper = try XCTUnwrap(reader.activePaperView)
        XCTAssertEqual(paper.nativeCornerSubmittedFrameCount, 0)
        let input = try XCTUnwrap(paper.cornerDrag)
        let folding = try XCTUnwrap(input.foldingPresentation(direction: .previous,
            size: reader.view.bounds.size, spread: false))
        XCTAssertEqual(folding.progress, 1, accuracy: 1e-6,
                       "GPU 尚未显示拖动时，应从原来的完全折出姿态收尾，不能从手指终点跳起")
        XCTAssertTrue(input.prefersFlatTurn)
        XCTAssertGreaterThanOrEqual(reader.animationDiagnostic?.duration ?? 0, 0.3)
    }

    func testRapidPreviousQueueShowsEveryVisiblePhaseAndKeepsRunLoopResponsive() async throws {
        let (reader, window) = try fixture()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        var committed: [String] = []
        reader.onTransition = { if case .didCommit(let transition) = $0 { committed.append(transition.to.unitID) } }
        var heartbeatCount = 0
        var lastHeartbeat = CACurrentMediaTime()
        var maximumGap: TimeInterval = 0
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                maximumGap = max(maximumGap, now - lastHeartbeat)
                lastHeartbeat = now
                heartbeatCount += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        flick(reader); flick(reader); flick(reader)
        var phases: [UUID: [CGFloat]] = [:]
        var submissions: [UUID: Int] = [:]
        for _ in 0..<600 {
            if let id = reader.activeTransitionID, let paper = reader.activePaperView,
               let shown = paper.submittedCornerDrag,
               let fold = shown.foldingPresentation(direction: .previous, size: reader.view.bounds.size, spread: false),
               paper.nativeCornerSubmittedFrameCount > (submissions[id] ?? 0) {
                phases[id, default: []].append(1 - fold.progress)
                submissions[id] = paper.nativeCornerSubmittedFrameCount
            }
            if !reader.isTransitioning { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertEqual(committed, ["5", "4", "3"])
        let turns = reader.recentAnimationDiagnostics.filter { $0.event == .began }.map(\.transitionID)
        XCTAssertEqual(turns.count, 3)
        for id in turns {
            let samples = try XCTUnwrap(phases[id])
            XCTAssertGreaterThan(samples.count, 5)
            XCTAssertLessThan(samples.first ?? 1, 0.2, "缺少手势侧展开的起翻阶段")
            XCTAssertTrue(samples.contains { (0.35...0.65).contains($0) }, "缺少半翻阶段")
            XCTAssertGreaterThan(samples.last ?? 0, 0.8, "缺少完整落页阶段")
        }
        XCTAssertGreaterThan(heartbeatCount, 10, "动画期间主线程必须继续处理事件")
        XCTAssertEqual(reader.paperSnapshotCaptureCount, 4, "连续回翻应复用上一笔快照，不能重复抓取当前页")
        print("FAST_PREVIOUS_HEARTBEAT count=\(heartbeatCount) maxGapMS=\(maximumGap * 1_000)")
    }
}
#endif
