#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ContinuousFillingRegressionTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func item(_ id: String, _ height: Double, _ state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: height, state: state)
    }
    private func window(_ count: Int) throws -> ContinuousWindow {
        try ContinuousWindow(items: (0..<count).map { item(String($0), 75) }, before: .startOfBook, after: .available)
    }
    private func layout(_ reader: UIViewController) {
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
    }

    func testRealMovementAccumulatesAcrossWindowInstallsAndSameSizeLayout() async throws {
        let provider = Provider()
        let policy = try ContinuousFillPolicy(maximumRequests: 2)
        let reader = try ContinuousReaderViewController(window: window(4), provider: provider, fillPolicy: policy)
        defer { reader.invalidate() }
        var requests = 0
        var installed = expectation(description: "第一批补足")
        reader.onFillLimitReached = { _, limit in XCTFail("实际移动满一屏后不应停在旧预算：\(limit)") }
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            requests += 1
            do {
                let count = requests == 1 ? 8 : (requests == 2 ? 10 : 14)
                let ticket = try reader.beginLoading(.next, token: demand.token, target: demand.target, cancel: {}) { outcome in
                    if case .installed = outcome { installed.fulfill() }
                }
                try reader.submit(self.window(count), for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [installed], timeout: 2)
        installed = expectation(description: "移动半屏后的第二批")
        reader.scrollView.contentOffset.y = 150
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(requests, 2)
        layout(reader)
        installed = expectation(description: "累计一屏后重新允许需求")
        reader.scrollView.contentOffset.y = 300
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(requests, 3)
        XCTAssertNil(reader.fillLimit(in: .next))
        XCTAssertEqual(reader.scrollView.contentOffset.y, 300)
    }

    func testOnePlaceholderIsDeduplicatedAcrossDirectionsUntilTaskEnds() throws {
        let provider = Provider()
        let gap = item("hole", 100, .loading)
        let current = item("c", 1000)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item("a", 100), gap, current]),
                                                        provider: provider, anchor: .init(identity: current.identity, offsetInItem: 100))
        defer { reader.invalidate() }
        var demands: [ContinuousContentDemand] = []
        var tickets: [ContinuousLoadTicket] = []
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            demands.append(demand)
            do { tickets.append(try reader.beginLoading(demand.direction, token: demand.token, cancel: {}, completion: { _ in })) }
            catch { XCTFail("\(error)") }
        }
        layout(reader)
        XCTAssertEqual(demands.map(\.direction), [.previous])
        XCTAssertEqual(demands.first?.target, .item(gap.identity))
        reader.scrollView.contentOffset.y = 150
        XCTAssertEqual(demands.count, 1)
        XCTAssertThrowsError(try reader.beginLoading(.next, token: reader.updateToken, target: .item(gap.identity), cancel: {}, completion: { _ in })) {
            XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
        }
        reader.cancelLoading(try XCTUnwrap(tickets.first))
        reader.scrollViewDidScroll(reader.scrollView)
        XCTAssertEqual(demands.map(\.direction), [.previous, .next])
        XCTAssertEqual(demands.last?.target, .item(gap.identity))
    }

    func testZeroPrefetchStillRequestsPreviousToFillShortTerminalViewport() throws {
        let policy = try ContinuousFillPolicy(leadingViewports: 0, trailingViewports: 0)
        let window = try ContinuousWindow(items: [item("tail", 75)], before: .available, after: .endOfBook)
        let token = ContinuousUpdateToken(presentationID: UUID(), revision: 0)
        let demands = window.contentDemands(at: 0, viewportExtent: 300, token: token, policy: policy)
        XCTAssertEqual(demands.count, 1)
        XCTAssertEqual(demands.first?.direction, .previous)
        XCTAssertEqual(demands.first?.target, .edge)
        XCTAssertEqual(demands.first?.missingReadyExtent, 225)
    }

    func testContentTargetDedupDoesNotBlockIndependentEdgeRequests() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = ContinuousUpdateToken(presentationID: UUID(), revision: 0)
        let previous = try coordinator.begin(direction: .previous, token: token, target: .edge, cancel: {}, completion: { _ in })
        let next = try coordinator.begin(direction: .next, token: token, target: .edge, cancel: {}, completion: { _ in })
        XCTAssertEqual(coordinator.activeCount, 2)
        coordinator.finish(previous, outcome: .cancelled)
        coordinator.finish(next, outcome: .cancelled)
        let target = ContinuousLoadTarget.item(item("hole", 100, .loading).identity)
        _ = try coordinator.begin(direction: .previous, token: token, target: target, cancel: {}, completion: { _ in })
        XCTAssertThrowsError(try coordinator.begin(direction: .next, token: token, target: target, cancel: {}, completion: { _ in }))
        XCTAssertEqual(coordinator.activeCount, 1)
        coordinator.invalidate()
    }

    func testPrependCompensationDoesNotMasqueradeAsOneScreenOfUserMovement() async throws {
        let provider = Provider()
        let current = item("current", 800)
        let initial = try ContinuousWindow(items: [current], after: .available)
        let policy = try ContinuousFillPolicy(maximumRequests: 2, maximumNoProgressResults: 10)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider, fillPolicy: policy)
        defer { reader.invalidate() }
        let paused = expectation(description: "两次后达到请求预算")
        var requests = 0
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            requests += 1
            do {
                let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}, completion: { _ in })
                try reader.submit(initial, for: ticket)
            } catch { XCTFail("\(error)") }
        }
        reader.onFillLimitReached = { _, limit in XCTAssertEqual(limit, .requestBudget); paused.fulfill() }
        layout(reader)
        try reader.restore(.init(identity: current.identity, offsetInItem: 400), expectedToken: reader.updateToken)
        await fulfillment(of: [paused], timeout: 2)
        try reader.apply(ContinuousWindow(items: [item("prefix", 600), current], after: .available), expectedToken: reader.updateToken)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 1000)
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 400)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(reader.fillLimit(in: .next), .requestBudget)
    }
}
#endif
