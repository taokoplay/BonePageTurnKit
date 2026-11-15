#if canImport(UIKit)
import UIKit
import Testing
@testable import BonePageTurnKit

@Suite(.serialized)
@MainActor
struct AnimationDiagnosticTests {
    private func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = .systemTeal
        return .init(identity: .init(sourceID: "diagnostic-test", unitID: String(index)), controller: child)
    }

    private func reader(enabled: Bool = true, effect: PageTurnEffect = .curl) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page(0), configuration: .init(
            presentation: .paged(effect: effect, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.animationDiagnosticsEnabled = enabled
        reader.pageProvider = { identity, _ in
            .page(page((Int(identity.unitID) ?? 0) + 1))
        }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return reader
    }

    private func finish(_ reader: PagedReaderViewController) {
        for _ in 0..<180 where reader.isTransitioning {
            reader.advancePaperAnimation(elapsed: 1.0 / 60.0)
        }
    }

    @Test(arguments: [60, 120])
    func syntheticRefreshRatesAreMeasuredRatherThanAssumed(_ rate: Int) {
        let summary = ReaderFrameRateSummary(intervals: Array(repeating: 1 / Double(rate), count: 30),
                                            targetFramesPerSecond: rate)
        #expect(abs((summary.framesPerSecond ?? 0) - Double(rate)) < 0.001)
        #expect(summary.overBudgetCount == 0)
        #expect(summary.estimatedMissedFrames == 0)
        #expect(abs((summary.averageMilliseconds ?? 0) - 1_000 / Double(rate)) < 0.001)
    }

    @Test
    func highRefreshBudgetDetectsOneMissedFrame() {
        let interval = 1.0 / 120.0
        let summary = ReaderFrameRateSummary(intervals: [interval, interval, interval * 2, interval],
                                            targetFramesPerSecond: 120)
        #expect(summary.overBudgetCount == 1)
        #expect(summary.estimatedMissedFrames == 1)
        #expect(abs((summary.maximumMilliseconds ?? 0) - 1_000 / 60) < 0.001)
        let empty = ReaderFrameRateSummary(intervals: [.nan, .infinity, -1, 0], targetFramesPerSecond: 120)
        #expect(empty.framesPerSecond == nil, "无采样不能显示成120FPS")
        #expect(empty.sampleCount == 0)
    }

    @Test
    func diagnosticsAreOptInAndPreservePlayback() throws {
        let reader = try reader(enabled: false)
        defer { reader.invalidate() }
        let accepted = try reader.turn(.next)
        #expect(accepted)
        finish(reader)
        #expect(reader.currentPage.identity.unitID == "1")
        #expect(reader.recentAnimationDiagnostics.isEmpty)
        reader.animationDiagnosticsEnabled = true
        let second = try reader.turn(.next)
        #expect(second)
        finish(reader)
        #expect(reader.currentPage.identity.unitID == "2")
        #expect(reader.animationDiagnostic?.endReason == .completed)
    }

    @Test
    func queuedPlaybackRetainsTimingAndTerminalParameters() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader()
        defer { reader.invalidate() }
        let first = try reader.turn(.next)
        let second = try reader.turn(.next)
        #expect(first && second)
        #expect(reader.recentAnimationDiagnostics.contains { $0.event == .queued && $0.queueDepth == 1 })
        finish(reader)
        let records = reader.recentAnimationDiagnostics
        let releases = records.filter { $0.event == .releaseStarted }
        let terminals = records.filter { $0.event == .finished }
        #expect(releases.count == 2)
        #expect(terminals.count == 2)
        #expect(terminals.map(\.transitionID) == releases.map(\.transitionID))
        for record in terminals {
            #expect(record.endReason == .completed)
            #expect(record.progress == 1)
            #expect((record.duration ?? 0) >= 0.28)
            #expect(record.curve == "systemEaseInOut")
            #expect(record.updateCount > 3)
            #expect(record.preparationDuration != nil)
            #expect(record.logLine.contains("reason=completed"))
            #expect(record.logLine.contains("duration="))
            #if targetEnvironment(simulator)
            #expect(record.gpuPresentationCount == nil)
            #expect(record.gpuPresentedFramesPerSecond == nil, "模拟器不伪造真机GPU呈现FPS")
            #endif
        }
        #expect(records.count <= 180)
    }

    @Test
    func earlyTerminationReportsItsActualCause() throws {
        for reason in [PageTurnAnimationDiagnostic.EndReason.suspended, .invalidated, .viewportChanged, .memoryWarning] {
            let reader = try reader()
            defer { reader.invalidate() }
            let accepted = try reader.beginInteractiveTurn(.next)
            #expect(accepted)
            reader.updateInteractiveTurn(displacement: 80)
            switch reason {
            case .suspended: reader.setSuspended(true, reason: "test")
            case .invalidated: reader.invalidate()
            case .viewportChanged:
                reader.view.bounds.size.width = 360
                reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            case .memoryWarning: reader.didReceiveMemoryWarning()
            default: break
            }
            let terminal = try #require(reader.recentAnimationDiagnostics.last { $0.event == .finished })
            #expect(terminal.endReason == reason)
            #expect(terminal.progress < 1, "提前消失的进度不能伪装为完整翻页")
            #expect(!reader.isTransitioning)
        }
    }

    @Test
    func wholeTurnTotalsRetainEarlySpikesBeyondTheLiveWindow() {
        var totals = ReaderFrameRateTotals(targetFramesPerSecond: 120)
        totals.record(0.05)
        for _ in 0..<500 { totals.record(1.0 / 120) }
        for invalid in [Double.nan, .infinity, -1, 0] { totals.record(invalid) }
        #expect(totals.sampleCount == 501)
        #expect(totals.overBudgetCount == 1)
        #expect(totals.estimatedMissedFrames == 5)
        #expect(abs((totals.maximumMilliseconds ?? 0) - 50) < 0.001)
        #expect((totals.framesPerSecond ?? 120) < 120)
    }

    @Test
    func scrollHandoffPreservesLifecycleCancellationCause() throws {
        for reason in [PageTurnAnimationDiagnostic.EndReason.suspended, .offscreen,
                       .applicationInactive, .viewportChanged, .invalidated] {
            let reader = try reader()
            defer { reader.invalidate() }
            let scroll = UIScrollView(frame: reader.currentPage.controller.view.bounds)
            scroll.contentSize = scroll.bounds.size
            reader.currentPage.controller.view.addSubview(scroll)
            let handoff = try reader.registerScrollableContent(scroll)
            handoff.processPan(state: .began, translation: .zero, velocity: .zero)
            handoff.processPan(state: .changed, translation: CGPoint(x: -150, y: 0), velocity: .zero)
            #expect(handoff.isHandingOff)
            switch reason {
            case .suspended: reader.setSuspended(true, reason: "diagnostic-test")
            case .offscreen:
                reader.beginAppearanceTransition(false, animated: false); reader.endAppearanceTransition()
            case .applicationInactive: reader.setAutomaticApplicationActive(false)
            case .viewportChanged:
                reader.view.bounds.size.width = 360
                reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            case .invalidated: reader.invalidate()
            default: break
            }
            let terminals = reader.recentAnimationDiagnostics.filter { $0.event == .finished }
            #expect(terminals.count == 1)
            #expect(terminals.last?.endReason == reason)
            #expect(!handoff.isHandingOff)
            #expect(scroll.bounces)
        }
    }

    @Test(arguments: [PageTurnEffect.slide, .cover])
    func propertyAnimatorCompletionRetainsFinalElapsedTime(_ effect: PageTurnEffect) async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader(effect: effect)
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        #expect(try reader.turn(.next))
        for _ in 0..<100 where reader.isTransitioning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let terminal = try #require(reader.animationDiagnostic)
        #expect(terminal.event == .finished)
        #expect(terminal.endReason == .completed)
        let duration = try #require(terminal.duration)
        #expect(duration > 0)
        #expect(abs((terminal.animationElapsed ?? 0) - duration) < 0.001)
    }

    @Test
    func propertyAnimatorCancellationRetainsElapsedTime() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let reader = try reader(effect: .slide)
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        #expect(try reader.turn(.next))
        try await Task.sleep(nanoseconds: 60_000_000)
        reader.cancelTransition()
        let terminal = try #require(reader.animationDiagnostic)
        #expect(terminal.endReason == .cancelled)
        #expect((terminal.animationElapsed ?? 0) > 0)
        #expect((terminal.animationElapsed ?? 1) < (terminal.duration ?? 0))
        #expect(terminal.progress > 0 && terminal.progress < 1)
    }

    @Test
    func metalPresentationCollectionRollsAndRejectsOldEpochs() throws {
        guard PaperCornerMetalRenderer.isSupported else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.cgImage)
        let renderer = try PaperCornerMetalRenderer(current: image, target: image,
            size: CGSize(width: 320, height: 480), axis: .horizontal, spread: false,
            strips: 64, paperColor: .white)
        defer { renderer.invalidate() }
        renderer.collectsPresentationMetrics = true
        let oldEpoch = renderer.presentationCollectionID
        for index in 0..<700 {
            renderer.recordPresentedTime(10 + Double(index) / 120, collectionID: oldEpoch)
        }
        #expect(renderer.presentedFrameCount == 700)
        #expect(renderer.presentedTimes.count == 512)
        #expect(abs((renderer.presentedTimes.last ?? 0) - (10 + 699.0 / 120)) < 0.001)
        let drag = try #require(PaperCornerDrag(size: CGSize(width: 320, height: 480),
            axis: .horizontal, spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        _ = try renderer.snapshot(drag)
        #expect(renderer.diagnosticSubmissionCount == 1)
        renderer.collectsPresentationMetrics = false
        renderer.recordPresentedTime(99, collectionID: oldEpoch)
        renderer.collectsPresentationMetrics = true
        renderer.recordPresentedTime(100, collectionID: oldEpoch)
        #expect(renderer.presentedFrameCount == 0)
        #expect(renderer.presentedTimes.isEmpty)
        #expect(renderer.diagnosticSubmissionCount == 0)
        let epoch = renderer.presentationCollectionID
        renderer.recordPresentedTime(110, collectionID: epoch)
        renderer.recordPresentedTime(110 + 1.0 / 120, collectionID: epoch)
        #expect(renderer.presentedFrameCount == 2)
        let first = try #require(renderer.presentedTimes.first)
        let last = try #require(renderer.presentedTimes.last)
        #expect(abs(last - first - 1.0 / 120) < 0.001)
    }
}
#endif
