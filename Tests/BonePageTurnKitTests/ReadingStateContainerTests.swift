#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReadingStateContainerTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func identity(_ id: String) -> PageItemIdentity { .init(sourceID: id, unitID: id) }
    private func info(_ number: Int, total: Int, after: ReaderBoundaryState = .available) throws -> ReaderPageInfo {
        .init(pagination: .init(book: try .init(current: number, total: .exact(total))),
              before: number == 1 ? .startOfBook : .available, after: after)
    }
    private func page(_ number: Int, total: Int, after: ReaderBoundaryState = .available) throws -> PageContent {
        .init(identity: identity(String(number)), controller: UIViewController(), readingInfo: try info(number, total: total, after: after))
    }
    private func item(_ id: String, _ height: Double = 500) -> ContinuousItem {
        .init(identity: identity(id), sectionID: "s", extent: height)
    }
    private func layout(_ controller: UIViewController, width: CGFloat = 320) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func pager() throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page(1, total: 2), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(reader)
        return reader
    }

    func testPageNumberCommitsOnlyAfterSuccessfulTurnAndLatestIsNotBookEnd() throws {
        let reader = try pager()
        var pages: [Int] = []
        reader.onReadingStatus = { if let page = $0.pagination.book?.current { pages.append(page) } }
        let next = try page(2, total: 2, after: .latestAvailable)
        reader.pageProvider = { _, _ in .page(next) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 200)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 1)
        reader.cancelTransition()
        XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 1)
        XCTAssertTrue(pages.isEmpty)
        XCTAssertTrue(try reader.turn(.next, animated: false))
        XCTAssertEqual(pages, [2])
        XCTAssertEqual(reader.readingStatus?.hasReachedLatestAvailable, true)
        XCTAssertEqual(reader.readingStatus?.hasReachedBookEnd, false)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.isLast, true)
    }

    func testUnavailableStatesDoNotCommitAndAbsentProviderIsNotEndOfBook() throws {
        let reader = try pager()
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(reader.readingStatus?.after, .loading)
        reader.pageProvider = { _, _ in .failed }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(reader.readingStatus?.after, .failed)
        reader.pageProvider = { _, _ in .boundary(.endOfBook) }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(reader.readingStatus?.hasReachedBookEnd, true)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 1)
    }

    func testMetadataUpdateRejectsOldTokenAndResizeClearsOldPagination() throws {
        let reader = try pager()
        let old = reader.metadataToken
        try reader.updateReadingInfo(info(1, total: 20), expectedToken: old)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.total, .exact(20))
        XCTAssertThrowsError(try reader.updateReadingInfo(info(1, total: 2), expectedToken: old))
        let beforeResize = reader.metadataToken
        layout(reader, width: 640)
        XCTAssertNil(reader.readingStatus?.pagination.book)
        XCTAssertThrowsError(try reader.updateReadingInfo(info(1, total: 2), expectedToken: beforeResize))
        try reader.updateReadingInfo(info(1, total: 10), expectedToken: reader.metadataToken)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.total, .exact(10))
    }

    func testAppendingToLatestChangesTotalAndRemovesLatestStateWithoutMovingPage() throws {
        let reader = try PagedReaderViewController(page: page(2, total: 2, after: .latestAvailable), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        layout(reader)
        let controller = reader.currentPage.controller
        try reader.updateReadingInfo(info(2, total: 3), expectedToken: reader.metadataToken)
        XCTAssertTrue(reader.currentPage.controller === controller)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.current, 2)
        XCTAssertEqual(reader.readingStatus?.pagination.book?.total, .exact(3))
        XCTAssertEqual(reader.readingStatus?.hasReachedLatestAvailable, false)
    }

    func testDeferredWindowUsesAnchorAtInstallationAndConfirmsExactlyOnce() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a"), item("b"), item("c")], after: .available)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        layout(reader)
        var outcomes: [ContinuousLoadOutcome] = []
        var cancelled = 0
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: { cancelled += 1 }, completion: { outcomes.append($0) })
        reader.setSuspended(true, reason: "selection")
        try reader.submit(ContinuousWindow(items: [item("prefix", 200)] + initial.items), for: ticket)
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(reader.window, initial)
        // 模拟等待期间用户位置改变；安装时不能回到提交时的 a 顶部。
        reader.scrollView.contentOffset.y = 640
        reader.setSuspended(false, reason: "selection")
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "b")
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 140)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 840)
        XCTAssertEqual(outcomes, [.installed(reader.updateToken)])
        XCTAssertEqual(cancelled, 0)
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertThrowsError(try reader.submit(initial, for: ticket))
    }

    func testQueuedResultCannotUndoExplicitNavigationOrResize() throws {
        for resize in [false, true] {
            let provider = Provider()
            let initial = try ContinuousWindow(items: [item("a"), item("b")])
            let reader = try ContinuousReaderViewController(window: initial, provider: provider)
            layout(reader)
            var outcomes: [ContinuousLoadOutcome] = []
            var cancels = 0
            let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: { cancels += 1 }, completion: { outcomes.append($0) })
            try reader.submit(ContinuousWindow(items: initial.items + [item("c")]), for: ticket)
            if resize { layout(reader, width: 640) }
            else { try reader.restore(.init(identity: identity("b"), offsetInItem: 20), expectedToken: reader.updateToken) }
            reader.installPendingUpdateIfIdle()
            XCTAssertEqual(reader.window, initial)
            XCTAssertEqual(outcomes, [.superseded])
            XCTAssertEqual(cancels, 1)
        }
    }

    func testInstallFailureTerminatesOwnershipAndPreservesWindow() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a"), item("b")])
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        layout(reader)
        var outcomes: [ContinuousLoadOutcome] = []
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}, completion: { outcomes.append($0) })
        try reader.submit(ContinuousWindow(items: [item("b")]), for: ticket)
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(outcomes, [.rejected(.anchorUnavailable)])
        XCTAssertEqual(reader.window, initial)
        _ = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}, completion: { _ in })
        reader.invalidate()
    }

    func testSynchronousEdgeResultInstallsAfterCallbackNotInsideIt() async throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a", 200)], after: .available)
        let replacement = try ContinuousWindow(items: [item("a", 200), item("b", 600)], after: .latestAvailable)
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        let installed = expectation(description: "同步边界结果在下一主线程事务安装")
        reader.onEdgeApproach = { [weak reader] direction, token in
            guard let reader else { return }
            do {
                let ticket = try reader.beginLoading(direction, token: token, cancel: {}, completion: { outcome in
                    if case .installed = outcome { installed.fulfill() }
                })
                try reader.submit(replacement, for: ticket)
                XCTAssertEqual(reader.window, initial)
            } catch { XCTFail("\(error)") }
        }
        layout(reader)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(reader.window, replacement)
        XCTAssertEqual(reader.readingStatus?.hasReachedLatestAvailable, false)
        reader.scrollView.contentOffset.y = 500
        XCTAssertEqual(reader.readingStatus?.hasReachedLatestAvailable, true)
        reader.invalidate()
    }

    func testInvalidationCancelsPendingLoadAndRejectsLateSubmission() throws {
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a")])
        let reader = try ContinuousReaderViewController(window: initial, provider: provider)
        layout(reader)
        var results: [ContinuousLoadOutcome] = []
        var cancels = 0
        let ticket = try reader.beginLoading(.previous, token: reader.updateToken, cancel: { cancels += 1 }, completion: { results.append($0) })
        reader.setSuspended(true, reason: "menu")
        try reader.submit(initial, for: ticket)
        reader.invalidate()
        reader.invalidate()
        XCTAssertEqual(results, [.invalidated])
        XCTAssertEqual(cancels, 1)
        XCTAssertThrowsError(try reader.submit(initial, for: ticket))
        XCTAssertNil(reader.readingStatus)
    }
}
#endif
