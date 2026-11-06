#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderScrollHandoffTests: XCTestCase {
    func testPinchKeepsAutomaticReadingPausedAfterPanCancellation() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.reader.viewDidAppear(false)
        try item.reader.startAutomaticReading(interval: 1, animated: false)
        XCTAssertTrue(item.scroll.alwaysBounceHorizontal)
        begin(item)
        item.handoff.processPinch(state: .began)
        item.handoff.processPan(state: .cancelled, translation: .zero, velocity: .zero)
        XCTAssertEqual(item.reader.automaticReadingState, .paused)
        item.handoff.processPinch(state: .ended)
        XCTAssertEqual(item.reader.automaticReadingState, .running)
        item.handoff.invalidate()
        XCTAssertFalse(item.scroll.alwaysBounceHorizontal)
    }

    private struct Fixture {
        let reader: PagedReaderViewController
        let scroll: UIScrollView
        let handoff: ReaderScrollHandoff
    }

    private func fixture(effect: PageTurnEffect = .none, axis: PageTurnAxis = .horizontal,
                         order: ReaderReadingOrder = .leftToRight, policy: ReaderScrollHandoffPolicy = .standard) throws -> Fixture {
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        let child = UIViewController()
        child.view = scroll
        let reader = try PagedReaderViewController(page: .init(identity: .init(sourceID: "book", unitID: "a"), controller: child),
            configuration: .init(presentation: .paged(effect: effect, axis: axis), readingOrder: order))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.usesDisplayLinkForPaperAnimation = false
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        scroll.contentSize = CGSize(width: 1000, height: 1500)
        let handoff = try reader.registerScrollableContent(scroll, policy: policy)
        reader.pageProvider = { _, _ in
            .page(.init(identity: .init(sourceID: "book", unitID: "b"), controller: UIViewController()))
        }
        return Fixture(reader: reader, scroll: scroll, handoff: handoff)
    }

    private func begin(_ item: Fixture) { item.handoff.processPan(state: .began, translation: .zero, velocity: .zero) }
    private func move(_ item: Fixture, x: CGFloat = 0, y: CGFloat = 0, touches: Int = 1) {
        item.handoff.processPan(state: .changed, translation: CGPoint(x: x, y: y), velocity: .zero, touches: touches)
    }
    private func end(_ item: Fixture, x: CGFloat = 0, y: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0) {
        item.handoff.processPan(state: .ended, translation: CGPoint(x: x, y: y), velocity: CGPoint(x: vx, y: vy), touches: 0)
    }

    func testInteriorScrollingConsumesDistanceBeforeEdgeHandoff() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.scroll.contentOffset.x = 100
        begin(item)
        move(item, x: -400)
        XCTAssertFalse(item.reader.isTransitioning)
        move(item, x: -590) // 到末端 580 point 后仅多拖 10，未达到 18 point 门槛。
        XCTAssertFalse(item.reader.isTransitioning)
        move(item, x: -618)
        XCTAssertTrue(item.handoff.isHandingOff)
        XCTAssertEqual(item.scroll.contentOffset.x, 680)
        XCTAssertFalse(item.scroll.bounces)
        end(item, x: -618) // 真正翻页位移只有 20，不含前面已经被内容消耗的距离。
        XCTAssertEqual(item.reader.currentPage.identity.unitID, "a")
        XCTAssertTrue(item.scroll.bounces)
    }

    func testBothAxesAndRTLMapPhysicalEdgesToLogicalNext() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let item = try fixture(axis: axis, order: order)
                defer { item.reader.invalidate() }
                let forward: CGFloat = axis == .horizontal && order == .rightToLeft ? 1 : -1
                if forward < 0 { item.scroll.contentOffset = axis == .horizontal ? CGPoint(x: 680, y: 0) : CGPoint(x: 0, y: 1020) }
                var requested: [PageTurnDirection] = []
                item.reader.pageProvider = { _, direction in
                    requested.append(direction)
                    return .page(.init(identity: .init(sourceID: "book", unitID: "b"), controller: UIViewController()))
                }
                begin(item)
                move(item, x: axis == .horizontal ? forward * 150 : 0, y: axis == .vertical ? forward * 150 : 0)
                end(item, x: axis == .horizontal ? forward * 150 : 0, y: axis == .vertical ? forward * 150 : 0)
                XCTAssertEqual(requested, [.next])
                XCTAssertEqual(item.reader.currentPage.identity.unitID, "b")
                XCTAssertFalse(item.handoff.isActive)
                XCTAssertTrue(item.scroll.bounces)
            }
        }
    }

    func testFastReverseCancelsAndRestoresOriginalScrollProperties() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.scroll.contentOffset.x = 680
        item.scroll.bounces = false
        begin(item); move(item, x: -200); end(item, x: -200, vx: 900)
        XCTAssertEqual(item.reader.currentPage.identity.unitID, "a")
        XCTAssertFalse(item.scroll.bounces)
        XCTAssertTrue(item.handoff.isActive)
    }

    func testPaperHandoffKeepsOriginalPanViewVisibleBelowSnapshot() throws {
        let item = try fixture(effect: .curl)
        defer { item.reader.invalidate() }
        item.scroll.contentOffset.x = 680
        begin(item); move(item, x: -160)
        XCTAssertTrue(item.handoff.isHandingOff)
        XCTAssertFalse(item.scroll.isHidden, "隐藏原视图会被 UIKit 取消现有 pan")
        XCTAssertEqual(item.reader.activePaperView?.hasResources, true)
        end(item, x: -160)
        for _ in 0..<10 { item.reader.advancePaperAnimation(elapsed: 0.1) }
        XCTAssertEqual(item.reader.currentPage.identity.unitID, "b")
        XCTAssertNil(item.reader.activePaperView)
        XCTAssertTrue(item.scroll.bounces)
    }

    func testPinchMultipleTouchesAndLifecycleCancelHandoff() throws {
        for interruption in 0..<5 {
            let item = try fixture(effect: .arch)
            defer { item.reader.invalidate() }
            item.scroll.contentOffset.x = 680
            begin(item); move(item, x: -160)
            switch interruption {
            case 0: item.handoff.processPinch(state: .began)
            case 1: move(item, x: -180, touches: 2)
            case 2: item.reader.setSuspended(true, reason: "selection")
            case 3:
                item.reader.view.frame.size.width = 400
                item.reader.view.setNeedsLayout(); item.reader.view.layoutIfNeeded()
            default: item.reader.invalidate()
            }
            XCTAssertFalse(item.reader.isTransitioning)
            XCTAssertFalse(item.handoff.isHandingOff)
            XCTAssertTrue(item.scroll.bounces)
            XCTAssertEqual(item.reader.currentPage.identity.unitID, "a")
            move(item, x: -300)
            XCTAssertFalse(item.reader.isTransitioning)
        }
    }

    func testAutomaticReadingPausesForNestedPanAndQueuedReplacementWaits() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.reader.viewDidAppear(false)
        try item.reader.startAutomaticReading(interval: 1, animated: false)
        begin(item)
        XCTAssertEqual(item.reader.automaticReadingState, .paused)
        XCTAssertThrowsError(try item.reader.turn(.next))
        var results: [PageReplacementOutcome] = []
        let replacement = PageContent(identity: .init(sourceID: "book", unitID: "a", contentVersion: 1), controller: UIViewController())
        _ = try item.reader.submitCurrentPage(replacement, expectedBinding: item.reader.currentPageBinding) { results.append($0) }
        item.reader.installPendingCurrentPageIfIdle()
        XCTAssertTrue(results.isEmpty)
        end(item)
        item.reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(results, [.installed(item.reader.currentPageBinding)])
        XCTAssertEqual(item.reader.automaticReadingState, .running)
        XCTAssertEqual(item.reader.automaticReadingProgress, 0)
        XCTAssertFalse(item.handoff.isActive)
    }

    func testUnavailableNeighborIsRequestedOnlyOncePerGesture() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.scroll.contentOffset.x = 680
        var calls = 0
        item.reader.pageProvider = { _, _ in calls += 1; return .waiting }
        begin(item)
        for index in 1...20 { move(item, x: CGFloat(-index * 30)) }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(item.reader.isTransitioning)
        XCTAssertTrue(item.scroll.bounces)
        end(item, x: -600)
        begin(item); move(item, x: -60)
        XCTAssertEqual(calls, 2)
    }

    func testCrossAxisDominanceAndForeignScrollCannotStartTurn() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.scroll.contentOffset.x = 680
        begin(item); move(item, x: -80, y: 200)
        XCTAssertFalse(item.reader.isTransitioning)
        item.handoff.cancelInteraction()
        let foreign = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let registration = try item.reader.registerScrollableContent(foreign)
        registration.processPan(state: .began, translation: .zero, velocity: .zero)
        registration.processPan(state: .changed, translation: CGPoint(x: -200, y: 0), velocity: .zero)
        XCTAssertFalse(item.reader.isTransitioning)
    }

    func testInsetBoundaryAndNoScrollableExtentStillHonorThreshold() throws {
        let item = try fixture()
        defer { item.reader.invalidate() }
        item.scroll.contentSize = CGSize(width: 300, height: 400)
        item.scroll.contentInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        item.scroll.contentOffset.x = -12
        begin(item); move(item, x: -17)
        XCTAssertFalse(item.reader.isTransitioning)
        move(item, x: -80); end(item, x: -80)
        XCTAssertEqual(item.reader.currentPage.identity.unitID, "b")
    }

    func testRegistrationIsIdempotentAndDoesNotRetainReaderOrDelegate() throws {
        let weakReader = WeakObject<PagedReaderViewController>(nil)
        var registration: ReaderScrollHandoff?
        var retainedScroll: UIScrollView?
        try autoreleasepool {
            let item = try fixture()
            weakReader.value = item.reader
            retainedScroll = item.scroll
            registration = item.handoff
            XCTAssertTrue(try item.reader.registerScrollableContent(item.scroll) === item.handoff)
            XCTAssertThrowsError(try item.reader.registerScrollableContent(UIScrollView(), policy: .init(threshold: .nan)))
            item.reader.invalidate()
            XCTAssertFalse(item.handoff.isActive)
            XCTAssertNil(item.scroll.delegate)
        }
        XCTAssertNil(weakReader.value)
        XCTAssertNotNil(retainedScroll)
        registration?.invalidate()
    }
}
#endif
