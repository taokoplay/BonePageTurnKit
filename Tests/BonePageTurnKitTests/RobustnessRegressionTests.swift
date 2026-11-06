#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class RobustnessRegressionTests: XCTestCase {
    private final class Page: UIViewController {
        var onLoad: (() -> Void)?
        var onRemoval: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); onLoad?() }
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent == nil { onRemoval?() }
        }
    }
    private func content(_ id: String, controller: UIViewController? = nil) -> PageContent {
        .init(identity: .init(sourceID: "source", unitID: id), controller: controller ?? UIViewController())
    }
    private func layout(_ controller: UIViewController) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func pager(_ page: PageContent) throws -> PagedReaderViewController {
        try PagedReaderViewController(page: page, configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
    }

    func testEndingInteractionInsideWillBeginCannotSkipMounting() throws {
        let reader = try pager(content("a"))
        layout(reader)
        let target = content("b")
        reader.pageProvider = { _, _ in .page(target) }
        reader.onTransition = { [weak reader] event in
            guard case .willBegin = event else { return }
            reader?.updateInteractiveTurn(displacement: 320)
            reader?.endInteractiveTurn(velocity: 1000, animated: false)
        }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        XCTAssertTrue(reader.isTransitioning)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertTrue(target.controller.parent === reader)
        reader.endInteractiveTurn(velocity: 1000, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertTrue(reader.currentPage.controller.parent === reader)
        XCTAssertEqual(reader.children.count, 1)
    }

    func testInitialPageLoadRejectsNestedTurn() throws {
        let initial = Page()
        let reader = try pager(content("a", controller: initial))
        let target = content("b")
        reader.pageProvider = { _, _ in .page(target) }
        var nestedError: PageTurnError?
        initial.onLoad = { [weak reader] in
            do { _ = try reader?.turn(.next, animated: false) }
            catch { nestedError = error as? PageTurnError }
        }
        layout(reader)
        XCTAssertEqual(nestedError, .interactionInProgress)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertTrue(initial.parent === reader)
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertEqual(reader.view.subviews.count, 1)
    }

    func testUnavailableCallbackCannotRecursivelyRetry() throws {
        let reader = try pager(content("a"))
        layout(reader)
        reader.pageProvider = { _, _ in .waiting }
        var nestedError: PageTurnError?
        var calls = 0
        reader.onUnavailable = { [weak reader] _, _ in
            calls += 1
            guard calls == 1 else { return }
            do { _ = try reader?.turn(.next) }
            catch { nestedError = error as? PageTurnError }
        }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(nestedError, .interactionInProgress)
    }

    func testRemovalInvalidationStillDeliversOneTerminalPair() throws {
        let old = Page()
        let reader = try pager(content("a", controller: old))
        layout(reader)
        old.onRemoval = { [weak reader] in reader?.invalidate() }
        let target = content("b")
        reader.pageProvider = { _, _ in .page(target) }
        var events: [PageTransitionEvent] = []
        reader.onTransition = { events.append($0) }
        XCTAssertTrue(try reader.turn(.next, animated: false))
        XCTAssertEqual(events.count, 3)
        guard case .willBegin(let transaction) = events.first else { return XCTFail("开始事务缺失") }
        XCTAssertEqual(events.last, .didSettle(transaction, completed: true))
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertFalse(reader.isActive)
    }

    func testInvalidatedCandidatePreservesExistingMode() throws {
        let root = PageTurnViewController()
        layout(root)
        let configuration = PageTurnConfiguration(presentation: .paged(effect: .none, axis: .horizontal))
        let old = try root.showPaged(page: content("a"), configuration: configuration)
        let incoming = Page()
        XCTAssertThrowsError(try root.showPaged(page: content("b", controller: incoming), configuration: configuration) { candidate in
            incoming.onLoad = { [weak candidate] in candidate?.invalidate() }
        }) { XCTAssertEqual($0 as? PageTurnError, .inactive) }
        XCTAssertTrue(root.pagedReader === old)
        XCTAssertTrue(old.isActive)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertTrue(old.parent === root)
    }

    func testRootInvalidationDuringPreparationDoesNotResurrectCandidate() throws {
        let root = PageTurnViewController()
        layout(root)
        XCTAssertThrowsError(try root.showPaged(page: content("a"), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal))) { _ in
            root.invalidate()
        }) { XCTAssertEqual($0 as? PageTurnError, .inactive) }
        XCTAssertNil(root.pagedReader)
        XCTAssertTrue(root.children.isEmpty)
    }
}
#endif
