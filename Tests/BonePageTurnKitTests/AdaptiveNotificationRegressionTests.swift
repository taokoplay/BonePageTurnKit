#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class AdaptiveNotificationRegressionTests: XCTestCase {
    private func page(_ name: String) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: name), controller: UIViewController())
    }
    private func root() throws -> PageTurnViewController {
        let root = PageTurnViewController()
        root.loadViewIfNeeded()
        let view = try XCTUnwrap(root.view as? ReaderViewportView)
        view.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        view.environmentOverride = .init(bounds: view.bounds, widthClass: .regular)
        let reader = try root.showPaged(page: page("a"), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        reader.pageProvider = { [self] _, _ in .page(page("b")) }
        root.adaptiveLayoutPolicy = .init()
        return root
    }
    private func drain() async {
        let ready = expectation(description: "队列落定")
        DispatchQueue.main.async { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
    }

    func testReturningToPublishedLayoutClearsCoalescedSuspension() async throws {
        let root = try root()
        defer { root.invalidate() }
        var notices = 0
        root.onAdaptiveLayoutChange = { _ in notices += 1 }
        await drain()
        XCTAssertEqual(notices, 1)
        root.adaptiveLayoutPolicy = .init(prefersSpread: false)
        root.adaptiveLayoutPolicy = .init(prefersSpread: true)
        await drain()
        XCTAssertEqual(notices, 1)
        XCTAssertTrue(try XCTUnwrap(root.pagedReader).turn(.next, animated: false))
    }

    func testInvalidPolicyInsideCallbackRetainsFailureSuspension() async throws {
        let root = try root()
        defer { root.invalidate() }
        root.onAdaptiveLayoutChange = { [weak root] _ in root?.adaptiveLayoutPolicy = .init(minimumPageWidth: 0) }
        await drain()
        await drain()
        let reader = try XCTUnwrap(root.pagedReader)
        XCTAssertThrowsError(try reader.turn(.next, animated: false)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
        root.onAdaptiveLayoutChange = nil
        root.adaptiveLayoutPolicy = .init()
        await drain()
        XCTAssertTrue(try reader.turn(.next, animated: false))
    }

    func testInvalidationDoesNotReuseFailureCacheWithoutPausingNewReader() async throws {
        let root = try root()
        await drain()
        root.adaptiveLayoutPolicy = .init(minimumPageWidth: 0)
        await drain()
        root.invalidate()
        let fresh = try root.showPaged(page: page("c"), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        defer { root.invalidate() }
        fresh.pageProvider = { [self] _, _ in .page(page("d")) }
        XCTAssertThrowsError(try fresh.turn(.next, animated: false)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
        root.adaptiveLayoutPolicy = .init()
        await drain()
        XCTAssertTrue(try fresh.turn(.next, animated: false))
    }

    func testCorrectedPolicyDropsQueuedObsoleteError() async throws {
        let root = try root()
        defer { root.invalidate() }
        await drain()
        var errors = 0
        root.onAdaptiveLayoutError = { _ in errors += 1 }
        root.adaptiveLayoutPolicy = .init(minimumPageWidth: 0)
        root.adaptiveLayoutPolicy = .init()
        await drain()
        XCTAssertEqual(errors, 0)
        XCTAssertTrue(try XCTUnwrap(root.pagedReader).turn(.next, animated: false))
    }
}
#endif
