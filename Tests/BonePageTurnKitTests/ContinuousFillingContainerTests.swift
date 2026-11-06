#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ContinuousFillingContainerTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UILabel() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) { (view as? UILabel)?.text = item.identity.unitID }
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func item(_ id: String, _ height: Double = 75, _ state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: height, state: state)
    }
    private func window(_ count: Int, height: Double = 75, after: ReaderBoundaryState = .available) throws -> ContinuousWindow {
        try ContinuousWindow(items: (0..<count).map { item(String($0), height) }, before: .startOfBook, after: after)
    }
    private func layout(_ reader: UIViewController, width: CGFloat = 320) {
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
    }

    func testFourUnitsEqualOneScreenRequestsAnotherBatchWithoutAdvancingReadingPosition() async throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: window(4), provider: provider)
        defer { reader.invalidate() }
        let installed = expectation(description: "四个单元一屏后继续补入")
        var demands: [ContinuousContentDemand] = []
        var stable: [ContinuousAnchor] = []
        reader.onStableAnchor = { stable.append($0) }
        reader.onEdgeApproach = { _, _ in XCTFail("结构化需求启用时不能再重复通知旧入口") }
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            demands.append(demand)
            XCTAssertEqual(demand.target, .edge)
            XCTAssertEqual(demand.missingReadyExtent, 300)
            do {
                let ticket = try reader.beginLoading(demand.direction, token: demand.token, cancel: {}) { result in
                    if case .installed = result { installed.fulfill() }
                    else { XCTFail("\(result)") }
                }
                try reader.submit(self.window(8), for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(demands.count, 1)
        XCTAssertEqual(reader.window.items.count, 8)
        XCTAssertEqual(reader.readableCoverage?.contiguousReadyFromTop, 600)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "0")
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        XCTAssertEqual(stable.count, 1)
        XCTAssertEqual(stable.first?.identity.unitID, "0")
    }

    func testManyShortBatchesContinueUntilCoverageTargetRatherThanFourItemLimit() async throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: window(4, height: 20), provider: provider)
        defer { reader.invalidate() }
        let installed = expectation(description: "七批短内容补足两屏")
        installed.expectedFulfillmentCount = 7
        var requests = 0
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            requests += 1
            do {
                let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}) { result in
                    if case .installed = result { installed.fulfill() }
                }
                try reader.submit(self.window(reader.window.items.count + 4, height: 20), for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [installed], timeout: 3)
        XCTAssertEqual(requests, 7)
        XCTAssertEqual(reader.window.items.count, 32)
        XCTAssertEqual(reader.window.totalExtent, 640)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "0")
        XCTAssertNil(reader.fillLimit(in: .next))
    }

    func testLargeVisiblePlaceholderRequestsItsIdentityThenContinuesAtEdge() async throws {
        let provider = Provider()
        let placeholder = item("0", 8000, .loading)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [placeholder], after: .endOfBook), provider: provider)
        defer { reader.invalidate() }
        let done = expectation(description: "先补占位再补窗口外")
        done.expectedFulfillmentCount = 2
        var targets: [ContinuousLoadTarget] = []
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            targets.append(demand.target)
            do {
                let ticket = try reader.beginLoading(demand.direction, token: demand.token, cancel: {}) { result in
                    if case .installed = result { done.fulfill() }
                }
                let next = try self.window(targets.count == 1 ? 1 : 8)
                try reader.submit(next, for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        XCTAssertEqual(reader.readableCoverage?.visibleReadyExtent, 0)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(targets, [.item(placeholder.identity), .edge])
        XCTAssertEqual(reader.readableCoverage?.visibleReadyExtent, 300)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "0")
    }

    func testNoProgressResultsPauseOnceWithoutLoopAndExplicitResumeStartsNewCycle() async throws {
        let provider = Provider()
        let initial = try window(1)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        defer { reader.invalidate() }
        let paused = expectation(description: "两次无进展后停止")
        var requests = 0
        var limitCalls = 0
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            requests += 1
            do {
                let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}, completion: { _ in })
                try reader.submit(initial, for: ticket)
            } catch { XCTFail("\(error)") }
        }
        reader.onFillLimitReached = { [weak reader] direction, limit in
            XCTAssertEqual(direction, .next)
            XCTAssertEqual(limit, .noReadableProgress)
            limitCalls += 1
            do { try reader?.resumeContentFilling(); XCTFail("通知中不应重入补屏") }
            catch { XCTAssertEqual(error as? PageTurnError, .interactionInProgress) }
            paused.fulfill()
        }
        layout(reader)
        await fulfillment(of: [paused], timeout: 2)
        for _ in 0..<20 { reader.scrollViewDidScroll(reader.scrollView) }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(limitCalls, 1)
        XCTAssertEqual(reader.fillLimit(in: .next), .noReadableProgress)
        let recovered = expectation(description: "显式重试后成功补足")
        let currentToken = reader.updateToken
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            XCTAssertEqual(demand.token, currentToken)
            do {
                let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}) { result in
                    if case .installed = result { recovered.fulfill() }
                }
                try reader.submit(self.window(8), for: ticket)
            } catch { XCTFail("\(error)") }
        }
        try reader.resumeContentFilling()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertNil(reader.fillLimit(in: .next))
    }

    func testRequestAndItemBudgetsBoundSuccessfulButTinyResponses() async throws {
        for addedBudget in [false, true] {
            let provider = Provider()
            let policy = try ContinuousFillPolicy(maximumRequests: addedBudget ? 20 : 2, maximumAddedItems: addedBudget ? 2 : 100)
            let reader = try ContinuousReaderViewController(window: window(1, height: 20), provider: provider, fillPolicy: policy)
            defer { reader.invalidate() }
            let paused = expectation(description: "有进展也受总预算限制")
            var requests = 0
            reader.onContentDemand = { [weak reader] demand in
                guard let reader else { return }
                requests += 1
                do {
                    let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}, completion: { _ in })
                    try reader.submit(self.window(reader.window.items.count + 1, height: 20), for: ticket)
                } catch { XCTFail("\(error)") }
            }
            reader.onFillLimitReached = { _, limit in
                XCTAssertEqual(limit, addedBudget ? .addedItemBudget : .requestBudget)
                paused.fulfill()
            }
            layout(reader)
            await fulfillment(of: [paused], timeout: 2)
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(reader.window.items.count, 3)
            XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "0")
        }
    }

    func testReadyResponseDeferredBySelectionDoesNotDuplicateRequestsOrLoseAnchor() async throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: window(4), provider: provider)
        defer { reader.invalidate() }
        var ticket: ContinuousLoadTicket?
        var calls = 0
        let installed = expectation(description: "解除选择暂停后安装")
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            calls += 1
            do {
                ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}) { result in
                    if case .installed = result { installed.fulfill() }
                }
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        reader.setSuspended(true, reason: "selection")
        try reader.submit(window(8), for: XCTUnwrap(ticket))
        reader.installPendingUpdateIfIdle()
        for _ in 0..<5 { reader.scrollViewDidScroll(reader.scrollView) }
        XCTAssertEqual(reader.window.items.count, 4)
        XCTAssertEqual(calls, 1)
        reader.setSuspended(false, reason: "selection")
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "0")
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        XCTAssertEqual(calls, 1)
    }

    func testBackwardFillingMaintainsCurrentContentScreenCoordinate() async throws {
        let provider = Provider()
        let current = item("current", 900)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [current], before: .available, after: .endOfBook), provider: provider)
        defer { reader.invalidate() }
        let installed = expectation(description: "向前补屏不换阅读锚点")
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            XCTAssertEqual(demand.direction, .previous)
            do {
                let ticket = try reader.beginLoading(.previous, token: demand.token, cancel: {}) { result in
                    if case .installed = result { installed.fulfill() }
                }
                try reader.submit(ContinuousWindow(items: [self.item("prefix", 400), current], before: .available, after: .endOfBook), for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 400)
        XCTAssertEqual(reader.visibleAnchor?.identity, current.identity)
        XCTAssertEqual(reader.readableCoverage?.contiguousReadyBefore, 400)
    }

    func testConfirmedShortBookAndLatestDoNotRequireFillingRemainingBlankSpace() throws {
        for boundary in [ReaderBoundaryState.endOfBook, .latestAvailable] {
            let provider = Provider()
            let reader = try ContinuousReaderViewController(window: window(1, after: boundary), provider: provider)
            defer { reader.invalidate() }
            reader.onContentDemand = { _ in XCTFail("不能把真实书尾空白当成加载缺口") }
            layout(reader)
            XCTAssertFalse(try XCTUnwrap(reader.readableCoverage).coversViewport)
            XCTAssertEqual(reader.readingStatus?.after, boundary)
        }
    }

    func testResizeAndExplicitNavigationResetBudgetButRepeatedLayoutDoesNot() async throws {
        let provider = Provider()
        let policy = try ContinuousFillPolicy(maximumRequests: 1, maximumNoProgressResults: 10)
        let initial = try window(1)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider, fillPolicy: policy)
        defer { reader.invalidate() }
        var requests = 0
        var blocked = expectation(description: "初始预算")
        reader.onContentDemand = { [weak reader] demand in
            guard let reader else { return }
            requests += 1
            do {
                let ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}, completion: { _ in })
                try reader.submit(initial, for: ticket)
            } catch { XCTFail("\(error)") }
        }
        reader.onFillLimitReached = { _, _ in blocked.fulfill() }
        layout(reader)
        await fulfillment(of: [blocked], timeout: 2)
        layout(reader)
        XCTAssertEqual(requests, 1)
        blocked = expectation(description: "视口变化预算")
        layout(reader, width: 640)
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertEqual(requests, 2)
        blocked = expectation(description: "显式导航预算")
        try reader.restore(.init(identity: initial.items[0].identity, offsetInItem: 0), expectedToken: reader.updateToken)
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertEqual(requests, 3)
    }

    func testSupersededAndLateFillCannotPullBackNewNavigation() throws {
        let provider = Provider()
        let initial = try window(8)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        defer { reader.invalidate() }
        layout(reader)
        var ticket: ContinuousLoadTicket?
        var outcomes: [ContinuousLoadOutcome] = []
        reader.onContentDemand = { [weak reader] demand in
            guard let reader, ticket == nil else { return }
            do { ticket = try reader.beginLoading(.next, token: demand.token, cancel: {}, completion: { outcomes.append($0) }) }
            catch { XCTFail("\(error)") }
        }
        reader.scrollView.contentOffset.y = 100
        let oldTicket = try XCTUnwrap(ticket)
        try reader.restore(.init(identity: initial.items[0].identity, offsetInItem: 0), expectedToken: reader.updateToken)
        XCTAssertEqual(outcomes, [.superseded])
        XCTAssertThrowsError(try reader.submit(window(12), for: oldTicket))
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        XCTAssertEqual(reader.window, initial)
    }
}
#endif
