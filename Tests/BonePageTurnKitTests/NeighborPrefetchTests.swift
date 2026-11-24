#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 空闲邻页预取：落定后后台完成快照与纹理，点击翻页零捕获零上传直接复用。
@MainActor
final class NeighborPrefetchTests: XCTestCase {
    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        child.view.backgroundColor = index % 2 == 0 ? .systemBackground : .secondarySystemBackground
        return .init(identity: .init(sourceID: "neighbor-prefetch", unitID: String(index)), controller: child)
    }

    private func makeReader(prefetch: Bool) throws -> PagedReaderViewController {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let value = try PagedReaderViewController(page: Self.page(2),
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal),
                paper: PaperRenderingOptions(maximumSnapshotPixels: 4_194_304, stripCount: 128)))
        value.usesDisplayLinkForAutomaticReading = false
        value.prefetchNeighborSnapshots = prefetch
        value.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            let next = current + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            return .page(Self.page(next))
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = value; window.makeKeyAndVisible()
        value.view.frame = window.bounds
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        return value
    }

    /// - Parameters: reader: 已落定容器；timeout: 最长等待秒数。
    /// - Returns: 无返回值；真实推进主队列让空闲预取执行。
    private func pumpUntilIdlePrefetch(_ reader: PagedReaderViewController, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while reader.neighborPrefetchCountForTesting < 1, Date() < deadline {
            // 显式确认主队列被排空：预取块经 DispatchQueue.main.async 投递。
            var drained = false
            DispatchQueue.main.async { drained = true }
            while !drained, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// 无参数；开启预取后落定即填充邻页快照，点击翻页零捕获零上传并正常落定。无返回值。
    func testPrefetchFeedsTurnWithoutCaptureOrUpload() async throws {
        let reader = try makeReader(prefetch: true)
        let window = reader.view.window
        XCTAssertNotNil(window)
        defer { reader.invalidate(); window?.isHidden = true }
        let uploadsBeforeFirstTurn = reader.paperTextureUploadCount
        XCTAssertTrue(try reader.turn(.next))
        let uploadsAfterFirstTurn = reader.paperTextureUploadCount
        XCTAssertGreaterThanOrEqual(uploadsAfterFirstTurn, uploadsBeforeFirstTurn)
        while reader.isTransitioning { try await Task.sleep(nanoseconds: 5_000_000) }
        pumpUntilIdlePrefetch(reader)
        XCTAssertGreaterThanOrEqual(reader.neighborPrefetchCountForTesting, 1, "落定后应预取邻页快照")
        let capturesBefore = reader.paperSnapshotCaptureCount
        let uploadsBefore = reader.paperTextureUploadCount
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.paperSnapshotCaptureCount - capturesBefore, 0,
                       "命中预取与当前页缓存后不应再捕获")
        XCTAssertEqual(reader.paperTextureUploadCount - uploadsBefore, 0,
                       "命中预取与当前页纹理缓存后不应再上传")
        while reader.isTransitioning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
    }

    /// 无参数；默认关闭时不预取，保持既有 provider 调用时机。无返回值。
    func testPrefetchDisabledByDefault() async throws {
        let reader = try makeReader(prefetch: false)
        let window = reader.view.window
        defer { reader.invalidate(); window?.isHidden = true }
        XCTAssertTrue(try reader.turn(.next))
        while reader.isTransitioning { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reader.neighborPrefetchCountForTesting, 0, "默认关闭时不预取")
    }
}
#endif
