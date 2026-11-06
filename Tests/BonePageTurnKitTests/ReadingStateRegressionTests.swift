#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReadingStateRegressionTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        var onUnbind: (() -> Void)?
        var onBind: (() -> Void)?
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) { onBind?() }
        func unbind(_ view: UIView, binding: PageViewBinding) { onUnbind?() }
    }
    private func item(_ id: String = "a", height: Double = 1000, state: ContinuousContentState = .ready,
                      unit: ReaderCountingUnit = .layoutPage) throws -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: height, state: state,
              pagination: .init(book: try .init(current: 1, total: .exact(10), unit: unit)))
    }
    private func layout(_ controller: UIViewController, width: CGFloat = 320) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func page(_ number: Int) throws -> PageContent {
        .init(identity: .init(sourceID: "s", unitID: String(number)), controller: UIViewController(),
              readingInfo: .init(pagination: .init(book: try .init(current: number, total: .exact(2))), after: .available))
    }

    func testCancellationFromUnbindCannotRewriteCommittedInstallationOutcome() throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item(state: .loading)]), provider: provider)
        layout(reader)
        var results: [ContinuousLoadOutcome] = []
        var cancels = 0
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: { cancels += 1 }, completion: { results.append($0) })
        provider.onUnbind = { [weak reader] in reader?.cancelLoading(ticket) }
        try reader.submit(ContinuousWindow(items: [item()]), for: ticket)
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(reader.window.items[0].state, .ready)
        XCTAssertEqual(results, [.installed(reader.updateToken)])
        XCTAssertEqual(cancels, 0)
    }

    func testReadingStatusInvalidationOrModeSwitchCannotSwallowCommittedTransition() throws {
        for switchMode in [false, true] {
            let root = PageTurnViewController()
            layout(root)
            let reader = try root.showPaged(page: page(1), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
            layout(reader)
            let target = try page(2)
            reader.pageProvider = { _, _ in .page(target) }
            var events: [PageTransitionEvent] = []
            reader.onTransition = { events.append($0) }
            let provider = Provider()
            let newWindow = try ContinuousWindow(items: [item()])
            reader.onReadingStatus = { [weak reader, weak root] status in
                guard status.pagination.book?.current == 2 else { return }
                if switchMode {
                    do { try root?.showContinuous(window: newWindow, provider: provider) }
                    catch { XCTFail("\(error)") }
                } else { reader?.invalidate() }
            }
            XCTAssertTrue(try reader.turn(.next, animated: false))
            XCTAssertEqual(events.count, 3)
            guard case .willBegin(let transaction) = events.first else { return XCTFail("缺少开始") }
            XCTAssertEqual(events[1], .didCommit(transaction))
            XCTAssertEqual(events[2], .didSettle(transaction, completed: true))
            XCTAssertFalse(reader.isActive)
        }
    }

    func testTerminalCallbackCannotNavigateAndConsumeUndeliverableEdgeDemand() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item()], after: .available)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        layout(reader)
        let anchor = ContinuousAnchor(identity: initial.items[0].identity, offsetInItem: 650)
        var restorationError: PageTurnError?
        var demands = 0
        reader.onEdgeApproach = { [weak reader] direction, token in
            guard let reader else { return }
            do {
                _ = try reader.beginLoading(direction, token: token, cancel: {}, completion: { _ in })
                demands += 1
            } catch { XCTFail("边缘不能被无效登记消耗：\(error)") }
        }
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}) { [weak reader] _ in
            guard let reader else { return }
            do { try reader.restore(anchor, expectedToken: reader.updateToken) }
            catch { restorationError = error as? PageTurnError }
        }
        reader.cancelLoading(ticket)
        XCTAssertEqual(restorationError, .interactionInProgress)
        XCTAssertEqual(demands, 0)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        try reader.restore(anchor, expectedToken: reader.updateToken)
        XCTAssertEqual(demands, 1)
        reader.invalidate()
    }

    func testResolvedNeighborStaysAvailableWhenPageTurnIsCancelled() throws {
        for availability in [PageAvailability.waiting, .failed] {
            let reader = try PagedReaderViewController(page: page(1), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
            layout(reader)
            reader.pageProvider = { _, _ in availability }
            XCTAssertFalse(try reader.turn(.next))
            XCTAssertNotEqual(reader.readingStatus?.after, .available)
            let target = try page(2)
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            reader.cancelTransition()
            XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 1)
            XCTAssertEqual(reader.readingStatus?.after, .available)
        }
    }

    func testContinuousResizeInvalidatesLayoutCountsButPreservesSourcePageCounts() throws {
        for unit in [ReaderCountingUnit.layoutPage, .sourcePage] {
            let provider = Provider()
            let window = try ContinuousWindow(items: [item(unit: unit)])
            let reader = try ContinuousReaderViewController(window: window, provider: provider)
            layout(reader)
            XCTAssertNotNil(reader.readingStatus?.pagination.book)
            layout(reader, width: 640)
            if unit == .layoutPage { XCTAssertNil(reader.readingStatus?.pagination.book) }
            else { XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 1) }
            try reader.apply(window, expectedToken: reader.updateToken)
            XCTAssertNotNil(reader.readingStatus?.pagination.book)
        }
    }

    func testShortChapterChainConfirmsInstallationBeforeStartingNextLoad() async throws {
        let provider = Provider()
        let first = try item("a", height: 100)
        let second = try item("b", height: 100)
        let third = try item("c", height: 800)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [first], after: .available), provider: provider)
        let settled = expectation(description: "两个短章安装均正确确认")
        settled.expectedFulfillmentCount = 2
        var results: [ContinuousLoadOutcome] = []
        var demands = 0
        reader.onEdgeApproach = { [weak reader] direction, token in
            guard let reader else { return }
            demands += 1
            do {
                let next = try ContinuousWindow(items: demands == 1 ? [first, second] : [first, second, third],
                                                after: demands == 1 ? .available : .endOfBook)
                let ticket = try reader.beginLoading(direction, token: token, cancel: {}, completion: { result in
                    results.append(result)
                    if case .installed = result { settled.fulfill() }
                })
                try reader.submit(next, for: ticket)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(reader.window.items.count, 3)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "a")
    }

    func testInvalidationDuringReservedInstallationTerminatesExactlyOnce() throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item(state: .loading)]), provider: provider)
        layout(reader)
        var results: [ContinuousLoadOutcome] = []
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}, completion: { results.append($0) })
        provider.onBind = { [weak reader] in reader?.invalidate() }
        try reader.submit(ContinuousWindow(items: [item()]), for: ticket)
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(results, [.invalidated])
        XCTAssertFalse(reader.isActive)
        XCTAssertEqual(reader.mountedContentViewCount, 0)
    }
}
#endif
