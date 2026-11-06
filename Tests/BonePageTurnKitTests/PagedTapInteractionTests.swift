import Foundation
import XCTest
@testable import BonePageTurnKit

final class ReaderTapConfigurationTests: XCTestCase {
    /// 非有限、越界和逆序边界必须使用公开配置错误拒绝。
    func testInvalidRegionsAreRejected() {
        let invalid: [(Double, Double)] = [
            (.nan, 0.8), (0.2, .nan), (.infinity, 1), (0, .infinity),
            (-.infinity, 1), (0, -.infinity), (-0.1, 0.8), (0.2, 1.1),
            (0.8, 0.2), (1.1, 1.1), (-0.2, -0.1)
        ]
        for (previousEnd, nextStart) in invalid {
            XCTAssertThrowsError(try ReaderTapConfiguration(previousEnd: previousEnd, nextStart: nextStart)) {
                XCTAssertEqual($0 as? ReaderTapConfigurationError, .invalidRegions)
            }
        }
    }

    /// 分区交界属于右侧区域；空边缘配置仍把归一化端点 1 交给下一页。
    func testBoundariesEmptyRegionsAndIgnoredFractions() throws {
        let configuration = try ReaderTapConfiguration()
        XCTAssertEqual(configuration, try ReaderTapConfiguration(previousEnd: 1.0 / 3, nextStart: 2.0 / 3))
        XCTAssertEqual(configuration.action(at: 0), .previous)
        XCTAssertEqual(configuration.action(at: configuration.previousEnd.nextDown), .previous)
        XCTAssertEqual(configuration.action(at: configuration.previousEnd), .center)
        XCTAssertEqual(configuration.action(at: configuration.nextStart.nextDown), .center)
        XCTAssertEqual(configuration.action(at: configuration.nextStart), .next)
        XCTAssertEqual(configuration.action(at: 1), .next)
        for fraction in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            XCTAssertEqual(configuration.action(at: fraction), .ignored)
        }
        let noEdges = try ReaderTapConfiguration(previousEnd: 0, nextStart: 1)
        XCTAssertEqual(noEdges.action(at: 0), .center)
        XCTAssertEqual(noEdges.action(at: 1.nextDown), .center)
        XCTAssertEqual(noEdges.action(at: 1), .next)
        let noCenter = try ReaderTapConfiguration(previousEnd: 0.5, nextStart: 0.5)
        XCTAssertEqual(noCenter.action(at: 0.5.nextDown), .previous)
        XCTAssertEqual(noCenter.action(at: 0.5), .next)
        XCTAssertEqual(try ReaderTapConfiguration(previousEnd: 0, nextStart: 0).action(at: 0), .next)
        XCTAssertEqual(try ReaderTapConfiguration(previousEnd: 1, nextStart: 1).action(at: 0), .previous)
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class PagedTapInteractionTests: XCTestCase {
    private final class MountingPage: UIViewController {
        var onMount: (() -> Void)?

        /// - Parameter parent: 正在挂载的父容器；仅挂载阶段执行测试回调。
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent != nil { onMount?() }
        }
    }

    /// - Parameter id: 测试页面身份。
    /// - Returns: 尚未挂载的新页面。
    private func page(_ id: String) -> PageContent {
        .init(identity: .init(sourceID: "source", unitID: id), controller: UIViewController())
    }

    /// - Parameter reader: 使用固定尺寸布局的阅读器。
    private func layout(_ reader: PagedReaderViewController) {
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
    }

    /// - Parameters: axis: 分页轴；effect: 已实现的分页效果。
    /// - Returns: 已布局、开启默认点击分区且能提供不同身份邻页的阅读器。
    private func makeReader(axis: PageTurnAxis = .horizontal, effect: PageTurnEffect = .none) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page("initial"),
                                                   configuration: .init(presentation: .paged(effect: effect, axis: axis)))
        reader.tapConfiguration = try ReaderTapConfiguration()
        layout(reader)
        var sequence = 0
        reader.pageProvider = { [unowned self] _, _ in
            sequence += 1
            return .page(self.page("page-\(sequence)"))
        }
        return reader
    }

    /// - Parameters: reader: 当前忙碌的阅读器；file: 断言来源文件；line: 断言来源行。
    private func assertBusy(_ reader: PagedReaderViewController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try reader.handleTap(at: CGPoint(x: 150, y: 300), animated: false), file: file, line: line) {
            XCTAssertEqual($0 as? PageTurnError, .interactionInProgress, file: file, line: line)
        }
        XCTAssertThrowsError(try reader.turn(.next, animated: false), file: file, line: line) {
            XCTAssertEqual($0 as? PageTurnError, .interactionInProgress, file: file, line: line)
        }
    }

    /// 横纵无动画模式使用自身轴，非零 bounds 原点和最大边界也正确映射。
    func testNoneMapsHorizontalAndVerticalTapsIncludingBoundsEdges() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let reader = try makeReader(axis: axis)
            reader.view.bounds.origin = CGPoint(x: 20, y: 40)
            var directions: [PageTurnDirection] = []
            reader.pageProvider = { [unowned self] _, direction in
                directions.append(direction)
                return .page(self.page("page-\(directions.count)"))
            }
            let previous = axis == .horizontal ? CGPoint(x: 20, y: 640) : CGPoint(x: 320, y: 40)
            let next = axis == .horizontal ? CGPoint(x: 320, y: 40) : CGPoint(x: 20, y: 640)
            XCTAssertTrue(try reader.handleTap(at: previous, animated: false))
            XCTAssertTrue(try reader.handleTap(at: next, animated: false))
            XCTAssertEqual(directions, [.previous, .next])
            XCTAssertEqual(reader.currentPage.identity.unitID, "page-2")
            XCTAssertEqual(reader.children.count, 1)
            reader.invalidate()
        }
    }

    /// 中心点击只通知位置，不请求邻页或派发翻页事务。
    func testCenterNotifiesWithoutTurning() throws {
        let reader = try makeReader()
        let original = reader.currentPage.identity
        var centers: [CGPoint] = []
        reader.onCenterTap = { centers.append($0) }
        reader.pageProvider = { _, _ in XCTFail("中心点击不应请求页面"); return .end }
        reader.onTransition = { _ in XCTFail("中心点击不应创建事务") }
        let point = CGPoint(x: 150, y: 300)
        XCTAssertTrue(try reader.handleTap(at: point))
        XCTAssertEqual(centers, [point])
        XCTAssertEqual(reader.currentPage.identity, original)
        XCTAssertFalse(reader.isTransitioning)
        reader.invalidate()
    }

    /// 默认关闭分区，不调用宿主；配置变化即时更新真实点击识别器。
    func testNilConfigurationPreservesPanOnlyBehavior() throws {
        let reader = try PagedReaderViewController(page: page("initial"),
                                                   configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        layout(reader)
        let tap = try XCTUnwrap(reader.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        let pan = try XCTUnwrap(reader.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        reader.shouldHandleTap = { _ in XCTFail("关闭分区不应请求命中仲裁"); return true }
        XCTAssertNil(reader.tapConfiguration)
        XCTAssertFalse(tap.isEnabled)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 280, y: 300)))
        reader.tapConfiguration = try ReaderTapConfiguration()
        XCTAssertTrue(tap.isEnabled)
        reader.tapConfiguration = nil
        XCTAssertFalse(tap.isEnabled)
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 150, y: 300)))
        reader.invalidate()
    }

    /// 宿主可以通过真实视图命中消费图片点击，无须伪造 UITouch。
    func testHostImageHitTestingCanVetoTap() throws {
        let reader = try makeReader()
        let image = UIImageView(frame: CGRect(x: 250, y: 10, width: 50, height: 100))
        image.isUserInteractionEnabled = true
        reader.currentPage.controller.view.addSubview(image)
        var hits = 0
        reader.shouldHandleTap = { [unowned reader] point in
            hits += 1
            return reader.view.hitTest(point, with: nil) !== image
        }
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 280, y: 50), animated: false))
        XCTAssertEqual(reader.currentPage.identity.unitID, "initial")
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false))
        XCTAssertEqual(hits, 2)
        XCTAssertEqual(reader.currentPage.identity.unitID, "page-1")
        reader.invalidate()
    }

    /// 状态、中心、宿主仲裁、供给、事务及初次挂载回调均拒绝点击与翻页重入。
    func testCallbacksRejectTapAndTurnReentry() throws {
        let reader = try makeReader()
        var rejected = 0
        let reject: () -> Void = { [unowned reader, unowned self] in
            self.assertBusy(reader)
            rejected += 1
        }
        reader.onReadingStatus = { _ in reject() }
        try reader.updateReadingInfo(.init(after: .end), expectedToken: reader.metadataToken)
        XCTAssertEqual(rejected, 1)
        reader.onReadingStatus = nil
        reader.onCenterTap = { _ in reject() }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 150, y: 300), animated: false))
        XCTAssertEqual(rejected, 2)
        reader.onCenterTap = nil
        reader.shouldHandleTap = { _ in reject(); return false }
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false))
        XCTAssertEqual(rejected, 3)
        reader.shouldHandleTap = nil
        reader.pageProvider = { [unowned self] _, _ in reject(); return .page(self.page("next")) }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false))
        XCTAssertEqual(rejected, 4)
        reader.pageProvider = { [unowned self] _, _ in .page(self.page("previous")) }
        reader.onTransition = { _ in reject() }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 10, y: 300), animated: false))
        XCTAssertEqual(rejected, 7)
        reader.invalidate()

        let child = MountingPage()
        let mountingReader = try PagedReaderViewController(
            page: .init(identity: .init(sourceID: "source", unitID: "mounting"), controller: child),
            configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        mountingReader.tapConfiguration = try ReaderTapConfiguration()
        child.onMount = { [unowned mountingReader, unowned self] in
            self.assertBusy(mountingReader)
            rejected += 1
        }
        layout(mountingReader)
        XCTAssertEqual(rejected, 8)
        mountingReader.invalidate()
    }

    /// 命中仲裁允许宿主同步暂停或退出，但返回后不能继续翻页。
    func testHostVetoCallbackRevalidatesSuspensionAndInvalidation() throws {
        for invalidates in [false, true] {
            let reader = try makeReader()
            reader.shouldHandleTap = { [unowned reader] _ in
                if invalidates { reader.invalidate() }
                else { reader.setSuspended(true, reason: "image") }
                return true
            }
            XCTAssertThrowsError(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false)) {
                XCTAssertEqual($0 as? PageTurnError, invalidates ? .inactive : .interactionInProgress)
            }
            XCTAssertEqual(reader.currentPage.identity.unitID, "initial")
            XCTAssertFalse(reader.isTransitioning)
            reader.invalidate()
        }
    }

    /// 交互事务和覆盖动画期间不接受新点击；失效时取消旧事务。
    func testPendingTurnAndCoverAnimationRejectAdditionalTaps() throws {
        let reader = try makeReader(effect: .cover)
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        assertBusy(reader)
        reader.cancelTransition()
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: true))
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity.unitID, "page-2")
        } else {
            XCTAssertTrue(reader.isTransitioning)
            assertBusy(reader)
            reader.invalidate()
            XCTAssertEqual(reader.currentPage.identity.unitID, "initial")
        }
        reader.invalidate()
        XCTAssertFalse(reader.isTransitioning)
    }

    /// 暂停原因叠加，完全解除后恢复点击；失效会清空闭包并永久禁用手势。
    func testMultipleSuspensionsAndInvalidationControlTapAvailability() throws {
        let reader = try makeReader()
        let tap = try XCTUnwrap(reader.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        reader.setSuspended(true, reason: "selection")
        reader.setSuspended(true, reason: "menu")
        reader.setSuspended(false, reason: "menu")
        XCTAssertFalse(tap.isEnabled)
        assertBusy(reader)
        XCTAssertEqual(reader.currentPage.identity.unitID, "initial")
        reader.setSuspended(false, reason: "selection")
        XCTAssertTrue(tap.isEnabled)
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false))
        reader.shouldHandleTap = { _ in true }
        reader.onCenterTap = { _ in }
        reader.invalidate()
        XCTAssertNil(reader.shouldHandleTap)
        XCTAssertNil(reader.onCenterTap)
        XCTAssertFalse(tap.isEnabled)
        reader.setSuspended(false, reason: "menu")
        reader.tapConfiguration = try ReaderTapConfiguration()
        XCTAssertFalse(tap.isEnabled)
        XCTAssertThrowsError(try reader.handleTap(at: CGPoint(x: 280, y: 300), animated: false)) {
            XCTAssertEqual($0 as? PageTurnError, .inactive)
        }
        XCTAssertEqual(reader.currentPage.identity.unitID, "page-1")
    }

    /// 非有限、越界或零尺寸位置均不调用宿主，也不请求邻页。
    func testInvalidPointsAndEmptyBoundsAreIgnored() throws {
        let reader = try makeReader()
        reader.shouldHandleTap = { _ in XCTFail("无效位置不应请求命中仲裁"); return true }
        reader.pageProvider = { _, _ in XCTFail("无效位置不应请求邻页"); return .end }
        let points: [CGPoint] = [
            .init(x: CGFloat.nan, y: 300), .init(x: 150, y: CGFloat.nan),
            .init(x: CGFloat.infinity, y: 300), .init(x: 150, y: -CGFloat.infinity),
            .init(x: -1, y: 300), .init(x: 301, y: 300), .init(x: 150, y: -1), .init(x: 150, y: 601)
        ]
        for point in points { XCTAssertFalse(try reader.handleTap(at: point, animated: false)) }
        reader.view.bounds.size = .zero
        XCTAssertFalse(try reader.handleTap(at: .zero, animated: false))
        XCTAssertEqual(reader.currentPage.identity.unitID, "initial")
        reader.invalidate()
    }

    /// 检查真实识别器上的 UIKit 代理规则：tap 等待 pan，且不使用 pan 的速度仲裁。
    func testRealTapRecognizerWaitsForPanAndUsesItsOwnBeginRule() throws {
        let reader = try makeReader()
        let tap = try XCTUnwrap(reader.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        let pan = try XCTUnwrap(reader.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        XCTAssertTrue(tap.delegate === reader)
        XCTAssertTrue(pan.delegate === reader)
        reader.shouldBeginPan = { _ in XCTFail("tap 不应进入 pan 仲裁"); return false }
        XCTAssertEqual(tap.delegate?.gestureRecognizerShouldBegin?(tap), true)
        XCTAssertEqual(tap.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: pan), true)
        XCTAssertEqual(pan.delegate?.gestureRecognizer?(pan, shouldRequireFailureOf: tap), false)
        XCTAssertEqual(pan.delegate?.gestureRecognizerShouldBegin?(pan), false)
        reader.setSuspended(true, reason: "selection")
        XCTAssertEqual(tap.delegate?.gestureRecognizerShouldBegin?(tap), false)
        reader.setSuspended(false, reason: "selection")
        var centers = 0
        reader.onCenterTap = { _ in centers += 1 }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 150, y: 300), animated: false))
        XCTAssertEqual(centers, 1)
        reader.invalidate()
    }
}
#endif
