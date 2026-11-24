#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 点击翻页延迟分解：同步准备（邻页挂载／快照／纹理）与首帧等待各占多少。只打印，不设阈值。
@MainActor
final class TapLatencyBreakdownTests: XCTestCase {
    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        child.view.backgroundColor = index % 2 == 0 ? .systemBackground : .secondarySystemBackground
        // 贴近真实正文：满页文字标签，让渲染层有实际内容。
        let text = UILabel(frame: child.view.bounds.insetBy(dx: 24, dy: 60))
        text.numberOfLines = 0
        text.font = .systemFont(ofSize: 20)
        text.text = String(repeating: "正文测样，用于快照渲染延迟测量。\n", count: 40)
        child.view.addSubview(text)
        return .init(identity: .init(sourceID: "tap-latency", unitID: String(index)), controller: child)
    }

    func testMeasureTapToFirstFrameBreakdown() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let reader = try PagedReaderViewController(page: Self.page(2),
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal),
                paper: PaperRenderingOptions(maximumSnapshotPixels: 4_194_304, stripCount: 128)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.animationDiagnosticsEnabled = true
        reader.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            let next = current + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            return .page(Self.page(next))
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()

        // 第一击：包含当前页 + 目标页两次快照与纹理上传。
        var start = CACurrentMediaTime()
        XCTAssertTrue(try reader.turn(.next))
        let syncFirst = CACurrentMediaTime() - start
        var firstFrame: TimeInterval = 0
        var paper = reader.activePaperView
        for _ in 0..<300 {
            if let paper, paper.nativeCornerSubmittedFrameCount > 0 { firstFrame = CACurrentMediaTime() - start; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let preparationFirst = reader.animationDiagnostic?.preparationDuration ?? 0
        print("LATENCY_FIRST syncTurn=\(Int(syncFirst * 1000))ms firstNativeFrame=\(Int(firstFrame * 1000))ms preparation=\(Int(preparationFirst * 1000))ms")
        // 等待落定，测第二击（当前页快照应命中缓存，只捕获目标页）。
        while reader.isTransitioning { try await Task.sleep(nanoseconds: 5_000_000) }
        start = CACurrentMediaTime()
        XCTAssertTrue(try reader.turn(.next))
        let syncSecond = CACurrentMediaTime() - start
        paper = reader.activePaperView
        for _ in 0..<300 {
            if let paper, paper.nativeCornerSubmittedFrameCount > 0 { firstFrame = CACurrentMediaTime() - start; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let preparationSecond = reader.recentAnimationDiagnostics.last { $0.event == .releaseStarted }?.preparationDuration ?? 0
        print("LATENCY_SECOND syncTurn=\(Int(syncSecond * 1000))ms firstNativeFrame=\(Int(firstFrame * 1000))ms preparation=\(Int(preparationSecond * 1000))ms snapshots=\(reader.paperSnapshotCaptureCount) textureUploads=\(reader.paperTextureUploadCount)")
        while reader.isTransitioning { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}
#endif
