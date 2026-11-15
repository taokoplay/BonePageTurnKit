#if canImport(UIKit)
import UIKit
import Testing
@testable import BonePageTurnKit

/// 检查连翻的实际播放过程，避免只核对最终页码却漏掉动画被压缩或截断。
@MainActor
struct SmoothPaperPlaybackTests {
    private final class PanSample: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .possible
        var sampleTranslation = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 280, y: 240) }
        override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: -800, y: 0) }
    }

    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index.isMultiple(of: 2) ? .systemTeal : .systemGray
        return .init(identity: .init(sourceID: "smooth-paper", unitID: String(index)), controller: child)
    }

    private func reader(effect: PageTurnEffect = .curl) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: Self.page(6), configuration: .init(
            presentation: .paged(effect: effect, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            return .page(Self.page(current + (direction == .next ? 1 : -1)))
        }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return reader
    }

    @Test(arguments: [PageTurnDirection.next, .previous], [PageTurnEffect.curl, .arch])
    func rapidTurnsKeepEveryAnimationPhase(direction: PageTurnDirection, effect: PageTurnEffect) throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader(effect: effect)
        defer { reader.invalidate() }
        var started: [UUID] = []
        var committed: [Int] = []
        var settled: [UUID] = []
        reader.onTransition = { event in
            switch event {
            case .willBegin(let turn): started.append(turn.id)
            case .didCommit(let turn): if let page = Int(turn.to.unitID) { committed.append(page) }
            case .didSettle(let turn, let completed):
                #expect(completed)
                settled.append(turn.id)
            }
        }
        for _ in 0..<4 {
            let accepted = try reader.turn(direction)
            #expect(accepted)
        }
        // 在已有队列时模拟最快输入，检查实际帧序列，而不是只验证时长系数。
        reader.smoothedTurnInterval = 0.01
        var samples: [UUID: [CGFloat]] = [:]
        for _ in 0..<300 {
            guard reader.isTransitioning else { break }
            let id = try #require(reader.activeTransitionID)
            let paper = try #require(reader.activePaperView)
            samples[id, default: []].append(paper.progress)
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
        #expect(!reader.isTransitioning)
        #expect(started.count == 4)
        #expect(settled == started)
        #expect(committed == (1...4).map { 6 + (direction == .next ? $0 : -$0) })
        for id in started {
            let frames = try #require(samples[id])
            // 即使持续连点，每页也要保留至少约 1/4 秒的播放，且经过卷起、半翻、落页阶段。
            #expect(frames.count >= 16, "完整翻页只有 \(frames.count) 帧")
            #expect(frames.contains { (0.1...0.3).contains($0) }, "缺少起翻阶段")
            #expect(frames.contains { (0.4...0.65).contains($0) }, "缺少中段卷曲")
            #expect(frames.contains { $0 >= 0.9 }, "缺少落页阶段")
            let halfway = frames[frames.count / 2]
            #expect((0.4...0.65).contains(halfway), "时间过半时纸面已提前翻完：\(halfway)")
            for (previous, next) in zip(frames, frames.dropFirst()) {
                #expect(next >= previous)
                #expect(next - previous < 0.18, "相邻显示帧跳过了过多纸面运动")
            }
        }
    }

    @Test
    func nativeSwipeDoesNotCutOffActiveCurl() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader()
        defer { reader.invalidate() }
        let accepted = try reader.turn(.next)
        #expect(accepted)
        reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        let id = try #require(reader.activeTransitionID)
        let paper = try #require(reader.activePaperView)
        let progress = paper.progress
        let pan = PanSample()
        pan.sampleState = .began
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
        #expect(reader.activeTransitionID == id, "新滑动不能直接结束上一页的卷曲")
        #expect(reader.activePaperView === paper)
        #expect(reader.currentPage.identity.unitID == "6")
        #expect(paper.progress == progress)
        pan.sampleState = .ended
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
        for _ in 0..<150 where reader.isTransitioning {
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
        #expect(!reader.isTransitioning)
        #expect(reader.currentPage.identity.unitID == "8", "两次输入应分别完成翻页")
    }

    @Test
    func bufferedPanKeepsOwnershipAcrossPageSettlement() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader()
        defer { reader.invalidate() }
        let accepted = try reader.turn(.next)
        #expect(accepted)
        let pan = PanSample()
        pan.sampleState = .began
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
        for _ in 0..<100 {
            if reader.currentPage.identity.unitID == "7" { break }
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
        #expect(reader.currentPage.identity.unitID == "7")
        let queuedID = try #require(reader.activeTransitionID)
        // 第一次动画已结束，手指仍在第二个手势内；取消这个手势不能误取消已接受的下一笔播放。
        pan.sampleState = .cancelled
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
        #expect(reader.activeTransitionID == queuedID)
        for _ in 0..<100 where reader.isTransitioning {
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
        #expect(reader.currentPage.identity.unitID == "8")
    }
}
#endif
