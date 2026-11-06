#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class UIKitContainerTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        var bindings: [String: PageViewBinding] = [:]
        var ended: [PageViewBinding] = []
        var created = 0
        func makeContentView(reuseIdentifier: String) -> UIView { created += 1; return UILabel() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
            bindings[item.identity.unitID] = binding
            (view as? UILabel)?.text = item.identity.unitID
        }
        func unbind(_ view: UIView, binding: PageViewBinding) { ended.append(binding) }
    }

    private func identity(_ id: String, version: UInt64 = 0) -> PageItemIdentity {
        PageItemIdentity(sourceID: "source-\(id)", unitID: id, contentVersion: version)
    }
    private func page(_ id: String) -> PageContent {
        PageContent(identity: identity(id), controller: UIViewController())
    }
    private func item(_ id: String, _ height: Double) -> ContinuousItem {
        ContinuousItem(identity: identity(id), sectionID: "section", extent: height)
    }
    private func layout(_ controller: UIViewController, height: CGFloat = 300) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: height)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func pager(effect: PageTurnEffect = .cover, axis: PageTurnAxis = .horizontal) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page("a"), configuration: .init(presentation: .paged(effect: effect, axis: axis)))
        layout(reader)
        reader.pageProvider = { [weak self] _, _ in self.map { .page($0.page("b")) } ?? .end }
        return reader
    }

    func testNoneCommitsOnceAndKeepsRealPageVisible() throws {
        let reader = try pager(effect: .none, axis: .vertical)
        let old = reader.currentPage.controller
        var events: [PageTransitionEvent] = []
        reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertFalse(reader.currentPage.controller.view.isHidden)
        XCTAssertTrue(reader.currentPage.controller.parent === reader)
        XCTAssertNil(old.parent)
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertEqual(events.count, 3)
        guard case .willBegin(let transition) = events[0] else { return XCTFail("缺少开始事件") }
        XCTAssertEqual(events[1], .didCommit(transition))
        XCTAssertEqual(events[2], .didSettle(transition, completed: true))
    }

    func testCoverReversalCancelsAndDoesNotCommit() throws {
        let reader = try pager()
        var events: [PageTransitionEvent] = []
        reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 180)
        XCTAssertEqual(reader.currentPage.controller.view.frame.minX, -180, accuracy: 0.01)
        reader.endInteractiveTurn(velocity: -700, animated: false)
        reader.cancelTransition()
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertEqual(reader.currentPage.controller.view.frame.minX, 0)
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertEqual(events.count, 2)
        guard case .didSettle(_, completed: false) = events.last else { return XCTFail("取消不应提交") }
    }

    func testPreviousCoverAndFastReentry() throws {
        let reader = try pager()
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous))
        XCTAssertThrowsError(try reader.turn(.next)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
        reader.updateInteractiveTurn(displacement: 160)
        let incoming = try XCTUnwrap(reader.children.last)
        XCTAssertEqual(incoming.view.frame.minX, -160, accuracy: 0.01)
        reader.endInteractiveTurn(velocity: 0, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertEqual(reader.currentPage.controller.view.frame.minX, 0)
    }

    func testAnimatedCoverCommitsAndInvalidatedAnimationCannotCommit() async throws {
        let reader = try pager()
        let finished = expectation(description: "覆盖动画完成")
        reader.onTransition = { if case .didSettle(_, completed: true) = $0 { finished.fulfill() } }
        XCTAssertTrue(try reader.turn(.next))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")

        let cancelled = try pager()
        var events: [PageTransitionEvent] = []
        cancelled.onTransition = { events.append($0) }
        XCTAssertTrue(try cancelled.turn(.next))
        cancelled.invalidate()
        let settledCount = events.count
        let tick = expectation(description: "越过旧动画截止时间")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tick.fulfill() }
        await fulfillment(of: [tick], timeout: 2)
        XCTAssertEqual(cancelled.currentPage.identity.unitID, "a")
        XCTAssertEqual(events.count, settledCount)
        XCTAssertEqual(events.count, 2)
        XCTAssertThrowsError(try cancelled.turn(.next))
    }

    func testWaitingDoesNotStartTransition() throws {
        let reader = try pager()
        var eventCount = 0
        var waiting = false
        reader.pageProvider = { _, _ in .waiting }
        reader.onTransition = { _ in eventCount += 1 }
        reader.onUnavailable = { _, state in if case .waiting = state { waiting = true } }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertTrue(waiting)
        XCTAssertEqual(eventCount, 0)
        XCTAssertFalse(reader.isTransitioning)
    }

    func testContinuousPrependAndHeightChangeKeepScreenAnchor() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a", 240), item("b", 650), item("c", 500)])
        let anchor = ContinuousAnchor(identity: identity("b"), offsetInItem: 90)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider, anchor: anchor)
        layout(reader)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 330, accuracy: 0.01)
        let replacement = try ContinuousWindow(items: [item("p", 130), item("a", 400), item("b", 650), item("c", 500)])
        try reader.apply(replacement, expectedToken: reader.updateToken)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 620, accuracy: 0.01)
        XCTAssertEqual(reader.visibleAnchor, anchor)
        let trimmed = try ContinuousWindow(items: [item("b", 650), item("c", 500)])
        try reader.apply(trimmed, expectedToken: reader.updateToken)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 90, accuracy: 0.01)
        XCTAssertEqual(reader.visibleAnchor, anchor)
    }

    func testContinuousReusesViewsAndRejectsOldBinding() throws {
        let provider = Provider()
        let items = (0..<100).map { item(String($0), 180) }
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: items), provider: provider)
        layout(reader)
        let old = try XCTUnwrap(provider.bindings["0"])
        XCTAssertTrue(reader.isCurrent(old))
        try reader.restore(.init(identity: identity("50"), offsetInItem: 40), expectedToken: reader.updateToken)
        XCTAssertFalse(reader.isCurrent(old))
        XCTAssertLessThan(reader.mountedContentViewCount, 8)
        XCTAssertLessThan(provider.created, 10)
        try reader.restore(.init(identity: identity("0"), offsetInItem: 0), expectedToken: reader.updateToken)
        let rebound = try XCTUnwrap(provider.bindings["0"])
        XCTAssertNotEqual(old, rebound)
        XCTAssertTrue(reader.isCurrent(rebound))
        reader.invalidate()
        XCTAssertFalse(reader.isCurrent(rebound))
        XCTAssertEqual(reader.mountedContentViewCount, 0)
    }

    func testWindowFailureIsAtomicAndOldRequestCannotInstall() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a", 500), item("b", 500)])
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        layout(reader)
        let old = reader.updateToken
        let withoutAnchor = try ContinuousWindow(items: [item("b", 500)])
        XCTAssertThrowsError(try reader.apply(withoutAnchor, expectedToken: old))
        XCTAssertEqual(reader.window, initial)
        XCTAssertEqual(reader.updateToken, old)
        try reader.apply(initial, expectedToken: old)
        XCTAssertThrowsError(try reader.apply(initial, expectedToken: old)) {
            XCTAssertEqual($0 as? PageTurnError, .staleWindow)
        }
    }

    func testBounceDoesNotPublishStablePositionAndPauseReasonsCompose() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a", 500), item("b", 500)])
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        var stable: [ContinuousAnchor] = []
        reader.onStableAnchor = { stable.append($0) }
        layout(reader)
        XCTAssertEqual(stable.count, 1)
        reader.scrollView.contentOffset.y = -40
        reader.scrollViewDidEndDragging(reader.scrollView, willDecelerate: false)
        XCTAssertEqual(stable.count, 1)
        reader.setSuspended(true, reason: "selection")
        reader.setSuspended(true, reason: "menu")
        reader.setSuspended(false, reason: "menu")
        XCTAssertFalse(reader.scrollView.isScrollEnabled)
        XCTAssertThrowsError(try reader.apply(initial, expectedToken: reader.updateToken))
        reader.setSuspended(false, reason: "selection")
        XCTAssertTrue(reader.scrollView.isScrollEnabled)
    }

    func testModeSwitchUsesHostAnchorAndInvalidatesPreviousRenderer() throws {
        let root = PageTurnViewController()
        layout(root)
        let old = try root.showPaged(page: page("a"), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(old)
        XCTAssertThrowsError(try root.showPaged(page: page("b"), configuration: .init(presentation: .paged(effect: .cover, axis: .vertical))))
        XCTAssertTrue(root.pagedReader === old)
        XCTAssertTrue(old.isActive)
        let provider = Provider()
        let anchor = ContinuousAnchor(identity: identity("a"), offsetInItem: 120)
        let continuous = try root.showContinuous(window: ContinuousWindow(items: [item("a", 700), item("b", 500)]), provider: provider, anchor: anchor)
        layout(continuous)
        XCTAssertEqual(continuous.visibleAnchor, anchor)
        XCTAssertFalse(old.isActive)
        let binding = try XCTUnwrap(provider.bindings["a"])
        _ = try root.showPaged(page: page("a"), configuration: .init(presentation: .paged(effect: .none, axis: .vertical)))
        XCTAssertFalse(continuous.isCurrent(binding))
        XCTAssertThrowsError(try continuous.apply(continuous.window, expectedToken: continuous.updateToken))
        XCTAssertEqual(root.children.count, 1)
    }

    func testEdgeDemandIsDeduplicatedAndLoadingIsNotStable() throws {
        let provider = Provider()
        let loading = ContinuousItem(identity: identity("a"), sectionID: "s", extent: 200, state: .loading)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [loading], before: .available, after: .available), provider: provider)
        var demands: [PageTurnDirection] = []
        var stableCount = 0
        reader.onEdgeApproach = { direction, _ in demands.append(direction) }
        reader.onStableAnchor = { _ in stableCount += 1 }
        layout(reader)
        reader.scrollViewDidScroll(reader.scrollView)
        XCTAssertEqual(demands, [.previous, .next])
        XCTAssertEqual(stableCount, 0)
    }
}
#endif
