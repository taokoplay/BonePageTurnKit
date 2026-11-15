#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class PaperSmoothnessRegressionTests: XCTestCase {
    private func page(_ id: Int) -> PageContent {
        let controller = UIViewController()
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        controller.view.backgroundColor = id.isMultiple(of: 2) ? .white : .systemTeal
        let text = UILabel(frame: CGRect(x: 18, y: 30, width: 280, height: 400))
        text.numberOfLines = 0; text.text = String(repeating: "第 \(id) 页 · 相同纸面与连续收尾\n", count: 10)
        controller.view.addSubview(text)
        return .init(identity: .init(sourceID: "smooth-regression", unitID: String(id)), controller: controller)
    }

    private func reader(currentView: UIView? = nil) throws -> PagedReaderViewController {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let initial = page(0)
        if let currentView { initial.controller.view = currentView }
        let reader = try PagedReaderViewController(page: initial, configuration: .init(
            presentation: .paged(effect: .curl, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { [self] identity, _ in .page(page((Int(identity.unitID) ?? 0) + 1)) }
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return reader
    }

    private func settle(_ reader: PagedReaderViewController) {
        for _ in 0..<10 where reader.isTransitioning { reader.advancePaperAnimation(elapsed: 0.1) }
        XCTAssertFalse(reader.isTransitioning)
    }

    func testTextureReuseKeepsBothDirectionsPixelIdenticalAndRejectsDifferentImage() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let options = PaperRenderingOptions(maximumSnapshotPixels: 262_144, stripCount: 64)
        for initialDirection in [PageTurnDirection.next, .previous] {
            let a = page(0).controller.view!, b = page(1).controller.view!, c = page(2).controller.view!
            let first = try PaperTransitionView(currentView: a, targetView: b, effect: .curl,
                direction: initialDirection, spine: .minimum, options: options, cornerDriven: true)
            let image = try XCTUnwrap(first.targetSnapshot)
            let texture = try XCTUnwrap(first.targetTextureSnapshot)
            XCTAssertEqual(first.textureUploadCount, 2)
            first.invalidateResources()
            for direction in [PageTurnDirection.next, .previous] {
                let cached = try PaperTransitionView(currentView: b, targetView: c, effect: .curl,
                    direction: direction, spine: .minimum, options: options, cornerDriven: true,
                    cachedCurrent: image, cachedCurrentTexture: texture)
                let uploaded = try PaperTransitionView(currentView: b, targetView: c, effect: .curl,
                    direction: direction, spine: .minimum, options: options, cornerDriven: true, cachedCurrent: image)
                defer { cached.invalidateResources(); uploaded.invalidateResources() }
                XCTAssertEqual(cached.textureUploadCount, 1)
                XCTAssertEqual(uploaded.textureUploadCount, 2)
                let seed = try XCTUnwrap(PaperCornerDrag(size: b.bounds.size, axis: .horizontal, spread: false,
                    inwardSign: direction == .next ? -1 : 1,
                    origin: CGPoint(x: direction == .next ? 300 : 20, y: 460)))
                for x: CGFloat in [80, 160, 240] {
                    let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: x, y: 390), direction: direction))
                    cached.update(progress: drag.gestureProgress, cornerDrag: drag)
                    uploaded.update(progress: drag.gestureProgress, cornerDrag: drag)
                    XCTAssertEqual(try XCTUnwrap(cached.cornerGPUImage()).pngData(),
                        try XCTUnwrap(uploaded.cornerGPUImage()).pngData())
                }
            }
            let mismatch = try PaperTransitionView(currentView: c, targetView: b, effect: .curl,
                direction: .next, spine: .minimum, options: options, cornerDriven: true, cachedCurrentTexture: texture)
            XCTAssertEqual(mismatch.textureUploadCount, 2, "不能把别张图的纹理套到当前页")
            mismatch.invalidateResources()
        }
    }

    func testReaderReusesOneTextureAndMemoryWarningClearsRebuildableCache() throws {
        let reader = try reader(); defer { reader.invalidate() }
        reader.usesDisplayLinkForPaperAnimation = false
        XCTAssertTrue(try reader.turn(.next)); settle(reader)
        XCTAssertEqual(reader.paperTextureUploadCount, 2)
        XCTAssertTrue(reader.hasCachedPaperSnapshot)
        XCTAssertTrue(try reader.turn(.next)); settle(reader)
        XCTAssertTrue(reader.lastPaperSnapshotReused)
        XCTAssertEqual(reader.paperSnapshotCaptureCount, 3)
        XCTAssertEqual(reader.paperTextureUploadCount, 3, "第二笔只上传新的目标页")
        reader.didReceiveMemoryWarning()
        XCTAssertFalse(reader.hasCachedPaperSnapshot)
        XCTAssertTrue(try reader.turn(.next)); settle(reader)
        XCTAssertFalse(reader.lastPaperSnapshotReused)
        XCTAssertEqual(reader.paperTextureUploadCount, 5)
        reader.invalidate()
        XCTAssertFalse(reader.hasCachedPaperSnapshot)
    }

    func testAppearanceChangeRejectsSnapshotAndTextureCache() throws {
        let reader = try reader(); defer { reader.invalidate() }
        reader.usesDisplayLinkForPaperAnimation = false
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        reader.overrideUserInterfaceStyle = .light
        XCTAssertEqual(reader.currentPage.controller.view.traitCollection.userInterfaceStyle, .light)
        XCTAssertTrue(try reader.turn(.next)); settle(reader)
        XCTAssertEqual(reader.paperTextureUploadCount, 2)
        reader.overrideUserInterfaceStyle = .dark
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        XCTAssertEqual(reader.currentPage.controller.view.traitCollection.userInterfaceStyle, .dark)
        XCTAssertTrue(try reader.turn(.next)); settle(reader)
        XCTAssertFalse(reader.lastPaperSnapshotReused)
        XCTAssertEqual(reader.paperSnapshotCaptureCount, 4)
        XCTAssertEqual(reader.paperTextureUploadCount, 4)
    }

    func testSameIdentityReplacementDiscardsOldPaperPixels() throws {
        try assertChangedContentIsRecaptured { reader in
            let replacement = self.page(1)
            replacement.controller.view.backgroundColor = .magenta
            _ = try reader.replaceCurrentPage(replacement, expectedBinding: reader.currentPageBinding)
        }
    }

    func testEmbeddedLayoutInvalidationDiscardsOldPaperPixels() throws {
        try assertChangedContentIsRecaptured { reader in
            reader.currentPage.controller.view.backgroundColor = .magenta
            reader.invalidateEmbeddedContentLayout()
        }
    }

    func testViewportRoundTripDiscardsOldPaperPixels() throws {
        try assertChangedContentIsRecaptured { reader in
            reader.currentPage.controller.view.backgroundColor = .magenta
            for size in [CGSize(width: 340, height: 500), CGSize(width: 320, height: 480)] {
                reader.view.frame.size = size
                reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            }
        }
    }

    private func assertChangedContentIsRecaptured(
        after change: (PagedReaderViewController) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let reader = try reader(); defer { reader.invalidate() }
        reader.usesDisplayLinkForPaperAnimation = false
        XCTAssertTrue(try reader.turn(.next), file: file, line: line); settle(reader)
        XCTAssertTrue(reader.hasCachedPaperSnapshot, file: file, line: line)
        try change(reader)
        let origin = CGPoint(x: 300, y: 240), point = CGPoint(x: 200, y: 220)
        let reference = try PaperTransitionView(currentView: reader.currentPage.controller.view,
            targetView: page(2).controller.view, effect: .curl, direction: .next, spine: .minimum,
            options: .init(maximumSnapshotPixels: 262_144, stripCount: 64), cornerDriven: true)
        defer { reference.invalidateResources() }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: origin), file: file, line: line)
        reader.updateInteractiveTurn(to: point)
        XCTAssertFalse(reader.lastPaperSnapshotReused, "正文改变后应重新捕获", file: file, line: line)
        let actual = try XCTUnwrap(reader.activePaperView, file: file, line: line)
        let seed = try XCTUnwrap(PaperCornerDrag(size: reader.view.bounds.size, axis: .horizontal,
            spread: false, inwardSign: -1, origin: origin), file: file, line: line)
        let drag = try XCTUnwrap(seed.moved(to: point, direction: .next), file: file, line: line)
        reference.update(progress: drag.gestureProgress, cornerDrag: drag)
        XCTAssertEqual(try XCTUnwrap(actual.cornerGPUImage()).pngData(),
            try XCTUnwrap(reference.cornerGPUImage()).pngData(),
            "翻页中的实际像素应来自更新后的正文", file: file, line: line)
    }

    func testNativePoseUpdatesDoNotRewriteUnchangedRealPages() throws {
        final class ObservedView: UIView {
            var frames = 0, visibility = 0
            override var frame: CGRect { didSet { frames += 1 } }
            override var isHidden: Bool { didSet { visibility += 1 } }
        }
        let root = ObservedView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        root.backgroundColor = .white
        let reader = try reader(currentView: root); defer { reader.invalidate() }
        reader.usesDisplayLinkForPaperAnimation = false
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 300, y: 240)))
        root.frames = 0; root.visibility = 0
        for x in stride(from: CGFloat(290), through: 160, by: -10) {
            reader.updateInteractiveTurn(to: CGPoint(x: x, y: 240))
        }
        XCTAssertEqual(root.frames, 0)
        XCTAssertEqual(root.visibility, 0)
        reader.cancelTransition()
        XCTAssertFalse(root.isHidden)
    }

    func testNativeReleaseSharesRenderClockAndSubmitsMostRefreshes() async throws {
        let reader = try reader(); reader.animationDiagnosticsEnabled = true
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        let observer = ReaderDisplayLink()
        defer { observer.stop(); reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        var ticks = 0
        observer.onTick = { [weak reader] _ in if reader?.isTransitioning == true { ticks += 1 } }
        // 第一笔预热，第二笔测完整 Reader 的原生收尾，而非直接驱动独立纸面。
        for index in 0..<2 {
            ticks = 0
            observer.start(maximumFramesPerSecond: window.screen.maximumFramesPerSecond)
            XCTAssertTrue(try reader.turn(.next))
            XCTAssertTrue(reader.isPaperClockRunning)
            XCTAssertTrue(try XCTUnwrap(reader.activePaperView).isNativeReleaseClockRunning)
            for _ in 0..<500 {
                if !reader.isTransitioning { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            observer.stop()
            XCTAssertFalse(reader.isTransitioning)
            let diagnostic = try XCTUnwrap(reader.recentAnimationDiagnostics.last { $0.event == .finished })
            if index == 1 {
                XCTAssertGreaterThan(ticks, 5)
                XCTAssertGreaterThan(Double(diagnostic.gpuSubmissionCount) / Double(max(1, ticks)), 0.7,
                    "正常绘制负载下不能因两只时钟相位固定隔帧提交")
            }
            XCTAssertFalse(reader.isPaperClockRunning)
        }
    }
}
#endif
