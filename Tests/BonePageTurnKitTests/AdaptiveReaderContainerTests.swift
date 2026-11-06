#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class AdaptiveReaderContainerTests: XCTestCase {
    private func environment(width: CGFloat = 951, height: CGFloat = 669,
                             widthClass: ReaderViewportWidthClass = .regular,
                             regions: [ReaderReservedRegion] = []) -> ReaderViewportEnvironment {
        .init(bounds: CGRect(x: 0, y: 0, width: width, height: height),
              safeAreaInsets: .init(top: 8, left: 12, bottom: 10, right: 84), widthClass: widthClass, regions: regions)
    }

    private func page(_ index: Int) -> PageContent {
        let content = UIViewController()
        content.view.backgroundColor = .systemBackground
        return .init(identity: .init(sourceID: "book", unitID: "source-\(index)"), controller: content)
    }

    private func fixture() throws -> (PageTurnViewController, ReaderViewportView) {
        let root = PageTurnViewController()
        root.loadViewIfNeeded()
        let viewport = try XCTUnwrap(root.view as? ReaderViewportView)
        viewport.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        viewport.environmentOverride = environment()
        viewport.refreshEnvironment()
        return (root, viewport)
    }

    private func drain() async {
        let done = expectation(description: "布局通知完成")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }

    func testAdaptivePolicyIsOptInAndUsesAllFourInsets() async throws {
        let (root, _) = try fixture()
        defer { root.invalidate() }
        let paged = try root.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        XCTAssertEqual(paged.view.frame, root.view.bounds)
        var notices: [ReaderAdaptiveLayout] = []
        root.onAdaptiveLayoutChange = { notices.append($0) }
        root.adaptiveLayoutPolicy = .init()
        await drain()
        let layout = try XCTUnwrap(root.adaptiveLayout)
        XCTAssertEqual(layout.contentFrame.minX, 12)
        XCTAssertEqual(layout.contentFrame.maxX, 867)
        XCTAssertEqual(layout.contentFrame.minY, 8)
        XCTAssertEqual(layout.contentFrame.maxY, 659)
        XCTAssertEqual(paged.view.frame, layout.contentFrame)
        XCTAssertEqual(notices, [layout])
        root.adaptiveLayoutPolicy = nil
        XCTAssertEqual(paged.view.frame, root.view.bounds)
    }

    func testSameSizeFoldChangeCancelsPaperAndInvalidatesOldContentBinding() async throws {
        let (root, viewport) = try fixture()
        defer { root.invalidate() }
        root.adaptiveLayoutPolicy = .init()
        let paged = try root.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
        paged.pageProvider = { [self] _, _ in .page(page(1)) }
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        paged.view.setNeedsLayout(); paged.view.layoutIfNeeded()
        await drain()
        let oldBinding = paged.currentPageBinding
        var settles: [Bool] = []
        paged.onTransition = { if case .didSettle(_, let complete) = $0 { settles.append(complete) } }
        XCTAssertTrue(try paged.beginInteractiveTurn(.next))
        let paper = try XCTUnwrap(paged.activePaperView)
        viewport.environmentOverride = environment(regions: [.init(kind: .division, frame: CGRect(x: 460, y: 0, width: 30, height: 669))])
        viewport.refreshEnvironment()
        paged.view.setNeedsLayout(); paged.view.layoutIfNeeded()
        XCTAssertEqual(settles, [false])
        XCTAssertFalse(paper.hasResources)
        XCTAssertEqual(paged.currentPage.identity.unitID, "source-0")
        XCTAssertNotEqual(oldBinding, paged.currentPageBinding)
        await drain()
        XCTAssertTrue(try paged.turn(.next, animated: false))
    }

    func testRapidEnvironmentChangesDeliverOnlyLatestPreparedLayout() async throws {
        let (root, viewport) = try fixture()
        defer { root.invalidate() }
        var notices: [ReaderAdaptiveLayout] = []
        root.onAdaptiveLayoutChange = { notices.append($0) }
        root.adaptiveLayoutPolicy = .init()
        viewport.environmentOverride = environment(width: 466, height: 678, widthClass: .compact)
        viewport.refreshEnvironment()
        let tabletop = environment(width: 669, height: 951, regions: [.init(kind: .division, frame: CGRect(x: 0, y: 460, width: 669, height: 30))])
        viewport.environmentOverride = tabletop
        viewport.refreshEnvironment()
        await drain()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first, try ReaderAdaptiveLayoutPolicy().layout(for: tabletop))
        XCTAssertEqual(notices.first?.pageLayout, .single)
        XCTAssertNotNil(notices.first?.auxiliaryFrame)
    }

    func testInvalidPolicyReportsOnceAndRecoveryToSameLayoutUnpausesReader() async throws {
        let (root, _) = try fixture()
        defer { root.invalidate() }
        root.adaptiveLayoutPolicy = .init()
        let paged = try root.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        paged.pageProvider = { [self] _, _ in .page(page(1)) }
        await drain()
        var errors = 0
        root.onAdaptiveLayoutError = { _ in errors += 1 }
        root.adaptiveLayoutPolicy = .init(minimumPageWidth: .nan)
        await drain()
        XCTAssertEqual(errors, 1)
        XCTAssertThrowsError(try paged.turn(.next, animated: false))
        root.adaptiveLayoutPolicy = .init()
        await drain()
        XCTAssertTrue(try paged.turn(.next, animated: false))
    }

    func testExitDefersAdaptiveNotificationAndInvalidationDropsOldQueue() async throws {
        let (root, viewport) = try fixture()
        _ = try root.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        root.adaptiveLayoutPolicy = .init()
        await drain()
        var notices = 0
        root.onAdaptiveLayoutChange = { _ in notices += 1 }
        let exit = root.beginExit()
        viewport.environmentOverride = environment(width: 466, height: 678, widthClass: .compact)
        viewport.refreshEnvironment()
        await drain()
        XCTAssertEqual(notices, 0)
        XCTAssertTrue(root.cancelExit(exit))
        await drain()
        XCTAssertEqual(notices, 1)
        viewport.environmentOverride = environment()
        viewport.refreshEnvironment()
        root.invalidate()
        root.onAdaptiveLayoutChange = { _ in XCTFail("失效后不可重新通知") }
        await drain()
    }

    func testHostRebuildPreservesSourceAnchorOnSecondSideAcrossOpenAndClose() async throws {
        let (root, viewport) = try fixture()
        defer { root.invalidate() }
        let anchor = 4
        var renderers: [PagedReaderViewController] = []
        root.onAdaptiveLayoutChange = { [weak root, self] layout in
            guard let root else { return }
            do {
                let content: PageContent
                if layout.pageLayout == .spread {
                    let book = try ReaderSpreadLayout(pageCount: 12)
                    let indices = try book.spread(at: book.spreadIndex(containingPage: anchor))
                    let spread = try PageSpreadViewController(first: indices.first.map(page), second: indices.second.map(page),
                        axis: layout.axis, gutter: layout.spreadGap)
                    content = .init(identity: .init(sourceID: "book", unitID: "spread"), controller: spread)
                } else { content = page(anchor) }
                renderers.append(try root.showPaged(page: content, configuration: .init(presentation: .paged(effect: .none, axis: layout.axis), layout: layout.pageLayout)))
            } catch { XCTFail("主队列布局通知应该能安全重建：\(error)") }
        }
        root.adaptiveLayoutPolicy = .init()
        await drain()
        XCTAssertEqual(root.pagedReader?.visiblePageIdentities.map(\.unitID), ["source-3", "source-4"])
        viewport.environmentOverride = environment(width: 466, height: 678, widthClass: .compact)
        viewport.refreshEnvironment()
        await drain()
        XCTAssertEqual(root.pagedReader?.visiblePageIdentities.map(\.unitID), ["source-4"])
        XCTAssertEqual(renderers.count, 2)
        XCTAssertFalse(renderers[0].isActive)
        XCTAssertTrue(renderers[1].isActive)
    }

    func testSpreadGutterKeepsBothPagesOutsideCenterOnBothAxesAndOrders() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let first = page(0)
                let second = page(1)
                let spread = try PageSpreadViewController(first: first, second: second, axis: axis, readingOrder: order, gutter: 30)
                spread.loadViewIfNeeded()
                spread.view.bounds = CGRect(x: 17, y: 23, width: 600, height: 500)
                spread.view.setNeedsLayout(); spread.view.layoutIfNeeded()
                let fold = axis == .horizontal ? CGRect(x: 302, y: 23, width: 30, height: 500) : CGRect(x: 17, y: 258, width: 600, height: 30)
                for content in [first, second] {
                    XCTAssertFalse(content.controller.view.frame.intersects(fold))
                    XCTAssertTrue(spread.view.bounds.contains(content.controller.view.frame))
                }
                XCTAssertEqual(first.controller.view.frame.size, second.controller.view.frame.size)
            }
        }
        XCTAssertThrowsError(try PageSpreadViewController(first: page(0), second: nil, gutter: -.infinity))
    }

    func testPaperSnapshotUsesViewDisplayScaleInsteadOfMainScreen() throws {
        let host = UIViewController()
        let current = UIViewController()
        host.addChild(current)
        if #available(iOS 17.0, *) { current.traitOverrides.displayScale = 2 }
        else { host.setOverrideTraitCollection(UITraitCollection(displayScale: 2), forChild: current) }
        host.view.addSubview(current.view)
        current.didMove(toParent: host)
        current.view.frame = CGRect(x: 0, y: 0, width: 80, height: 120)
        let target = UIView(frame: current.view.bounds)
        XCTAssertEqual(current.view.traitCollection.displayScale, 2)
        let paper = try PaperTransitionView(currentView: current.view, targetView: target, effect: .curl,
            direction: .next, spine: .minimum, options: .standard)
        XCTAssertEqual(paper.contentScaleFactor, 2)
        XCTAssertEqual(paper.snapshotPixelCount, 2 * 160 * 240)
        paper.invalidateResources()
    }
}
#endif
