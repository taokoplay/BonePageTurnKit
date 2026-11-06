#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class RobustnessStressTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        var views: [WeakObject<UIView>] = []
        func makeContentView(reuseIdentifier: String) -> UIView {
            let view = UIView()
            views.append(WeakObject(view))
            return view
        }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
        var liveViews: Int { views.filter { $0.value != nil }.count }
    }
    private final class Payload { var calls = 0 }
    private func page(_ number: Int) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: String(number)), controller: UIViewController())
    }
    private func item(_ id: Int, height: Double = 200) -> ContinuousItem {
        .init(identity: .init(sourceID: "book", unitID: String(id)), sectionID: "section", extent: height)
    }
    private func layout(_ controller: UIViewController) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func testThousandImmediateTurnsPerAxisKeepOneChildAndReleaseOldPages() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let reader = try PagedReaderViewController(page: page(0), configuration: .init(presentation: .paged(effect: .none, axis: axis)))
            layout(reader)
            var pages: [WeakObject<UIViewController>] = []
            var commits = 0
            var settles = 0
            reader.pageProvider = { identity, direction in
                guard let current = Int(identity.unitID) else { return .failed }
                let next = current + (direction == .next ? 1 : -1)
                let controller = UIViewController()
                pages.append(WeakObject(controller))
                return .page(.init(identity: .init(sourceID: "book", unitID: String(next)), controller: controller))
            }
            reader.onTransition = {
                if case .didCommit = $0 { commits += 1 }
                if case .didSettle = $0 { settles += 1 }
            }
            for _ in 0..<1000 {
                try autoreleasepool { XCTAssertTrue(try reader.turn(.next, animated: false)) }
            }
            XCTAssertEqual(reader.currentPage.identity.unitID, "1000")
            XCTAssertEqual(commits, 1000)
            XCTAssertEqual(settles, 1000)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertEqual(reader.view.subviews.count, 1)
            XCTAssertEqual(pages.filter { $0.value != nil }.count, 1)
            reader.invalidate()
        }
    }

    func testThreeHundredCommitCancelCyclesAndInvalidGestureNumbersStayConsistent() throws {
        let reader = try PagedReaderViewController(page: page(0), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(reader)
        reader.pageProvider = { [self] identity, _ in .page(page((Int(identity.unitID) ?? 0) + 1)) }
        var commits = 0
        var settles = 0
        reader.onTransition = {
            if case .didCommit = $0 { commits += 1 }
            if case .didSettle = $0 { settles += 1 }
        }
        for index in 0..<300 {
            try autoreleasepool {
                XCTAssertTrue(try reader.beginInteractiveTurn(.next))
                reader.updateInteractiveTurn(displacement: .nan)
                reader.updateInteractiveTurn(displacement: .infinity)
                XCTAssertTrue(reader.currentPage.controller.view.frame.minX.isFinite)
                reader.updateInteractiveTurn(displacement: 200)
                reader.endInteractiveTurn(velocity: index.isMultiple(of: 2) ? 900 : -900, animated: false)
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertEqual(reader.children.count, 1)
            }
        }
        XCTAssertEqual(commits, 150)
        XCTAssertEqual(settles, 300)
        XCTAssertEqual(reader.currentPage.identity.unitID, "150")
    }

    func testTwoHundredBusyRequestsDoNotQueryProviderOrAccumulatePages() throws {
        let reader = try PagedReaderViewController(page: page(0), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(reader)
        var requests = 0
        reader.pageProvider = { [self] _, _ in requests += 1; return .page(page(1)) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        for index in 0..<200 {
            XCTAssertThrowsError(try reader.turn(index.isMultiple(of: 2) ? .next : .previous)) {
                XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
            }
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reader.children.count, 2)
        reader.cancelTransition()
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
    }

    func testTenThousandItemsAndFiveHundredJumpsHaveBoundedLiveViews() throws {
        let provider = Provider()
        let items = (0..<10_000).map { item($0, height: Double(180 + ($0 % 7) * 20)) }
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: items), provider: provider)
        layout(reader)
        for step in 0..<500 {
            let index = (step * 7919) % 9997
            try autoreleasepool {
                try reader.restore(.init(identity: items[index].identity, offsetInItem: 0), expectedToken: reader.updateToken)
                XCTAssertEqual(reader.visibleAnchor?.identity, items[index].identity)
                XCTAssertLessThanOrEqual(reader.mountedContentViewCount, 8)
            }
            XCTAssertLessThanOrEqual(provider.liveViews, reader.mountedContentViewCount + 8)
        }
        autoreleasepool { reader.invalidate() }
        XCTAssertEqual(provider.liveViews, 0)
        XCTAssertEqual(reader.mountedContentViewCount, 0)
    }

    func testMemoryWarningDropsOnlyOffscreenCacheAndPreservesPosition() throws {
        let provider = Provider()
        let items = (0..<20).map { item($0, height: 100) } + [item(20, height: 2000)]
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: items), provider: provider)
        layout(reader)
        try autoreleasepool {
            try reader.restore(.init(identity: items[20].identity, offsetInItem: 10), expectedToken: reader.updateToken)
        }
        let anchor = reader.visibleAnchor
        XCTAssertGreaterThan(provider.liveViews, reader.mountedContentViewCount)
        autoreleasepool { reader.didReceiveMemoryWarning() }
        XCTAssertEqual(provider.liveViews, reader.mountedContentViewCount)
        XCTAssertEqual(reader.visibleAnchor, anchor)
        reader.invalidate()
    }

    func testCancelledAndInvalidatedLoadsReleaseCapturedPayloads() throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item(0, height: 2000)]), provider: provider)
        layout(reader)
        var probes: [WeakObject<Payload>] = []
        for index in 0..<200 {
            try autoreleasepool {
                let payload = Payload()
                probes.append(WeakObject(payload))
                let ticket = try reader.beginLoading(.next, token: reader.updateToken,
                                                     cancel: { payload.calls += 1 }, completion: { _ in payload.calls += 1 })
                if index < 199 { reader.cancelLoading(ticket) }
            }
        }
        XCTAssertEqual(probes.filter { $0.value != nil }.count, 1)
        reader.invalidate()
        XCTAssertTrue(probes.allSatisfy { $0.value == nil })
    }

    func testReleasingAnimatingReaderDoesNotRetainControllersOrRunLateEvents() async throws {
        let probe = WeakObject<PagedReaderViewController>(nil)
        var events = 0
        try autoreleasepool {
            let reader = try PagedReaderViewController(page: page(0), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
            layout(reader)
            reader.pageProvider = { [self] _, _ in .page(page(1)) }
            reader.onTransition = { _ in events += 1 }
            probe.value = reader
            XCTAssertTrue(try reader.turn(.next, animated: true))
            reader.invalidate()
        }
        XCTAssertNil(probe.value)
        let eventCount = events
        let deadline = expectation(description: "越过已取消动画的回调时间")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { deadline.fulfill() }
        await fulfillment(of: [deadline], timeout: 2)
        XCTAssertEqual(events, eventCount)
    }

    func testTwoHundredModeSwitchesReleasePreviousRenderers() throws {
        let root = PageTurnViewController()
        let provider = Provider()
        layout(root)
        let window = try ContinuousWindow(items: [item(0), item(1), item(2)])
        var probes: [WeakObject<UIViewController>] = []
        for index in 0..<200 {
            try autoreleasepool {
                if index.isMultiple(of: 2) {
                    let reader = try root.showPaged(page: page(index), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
                    probes.append(WeakObject(reader))
                } else {
                    let reader = try root.showContinuous(window: window, provider: provider)
                    layout(reader)
                    probes.append(WeakObject(reader))
                }
                XCTAssertEqual(root.children.count, 1)
            }
        }
        XCTAssertEqual(probes.filter { $0.value != nil }.count, 1)
        root.invalidate()
    }
}
#endif
