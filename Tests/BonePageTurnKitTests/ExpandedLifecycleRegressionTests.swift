#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ExpandedLifecycleRegressionTests: XCTestCase {
    private final class HookPage: UIViewController {
        var onLoad: (() -> Void)?
        var onAttach: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); onLoad?() }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil { onAttach?() }
        }
    }
    private final class MoveHookView: UIView {
        var onInsert: (() -> Void)?
        override func willMove(toSuperview newSuperview: UIView?) {
            super.willMove(toSuperview: newSuperview)
            if newSuperview != nil, let action = onInsert { onInsert = nil; action() }
        }
    }

    private func page(_ name: String, controller: UIViewController = UIViewController()) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: name), controller: controller)
    }

    private func fixture() throws -> (PagedReaderViewController, UIScrollView, ReaderScrollHandoff) {
        let content = UIViewController()
        let scroll = UIScrollView()
        content.view = scroll
        let reader = try PagedReaderViewController(page: page("a", controller: content), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        reader.usesDisplayLinkForAutomaticReading = false
        scroll.contentSize = CGSize(width: 320, height: 480)
        let handoff = try reader.registerScrollableContent(scroll)
        reader.pageProvider = { [self] _, _ in .page(page("b")) }
        return (reader, scroll, handoff)
    }

    func testUnregisterDuringProviderOrWillBeginCannotStrandPendingPage() throws {
        for insideProvider in [false, true] {
            let (reader, scroll, handoff) = try fixture()
            defer { reader.invalidate() }
            if insideProvider {
                reader.pageProvider = { [self] _, _ in handoff.invalidate(); return .page(page("b")) }
            } else {
                reader.onTransition = { if case .willBegin = $0 { handoff.invalidate() } }
            }
            handoff.processPan(state: .began, translation: .zero, velocity: .zero)
            handoff.processPan(state: .changed, translation: CGPoint(x: -150, y: 0), velocity: .zero)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertFalse(handoff.isActive)
            XCTAssertTrue(scroll.bounces)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertEqual(reader.view.subviews, [scroll])
            XCTAssertEqual(reader.currentPage.identity.unitID, "a")
            reader.onTransition = nil
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            XCTAssertTrue(try reader.turn(.next, animated: false))
        }
    }

    func testExternalCancelImmediatelyReturnsScrollOwnershipEvenWithoutAnotherChange() throws {
        let (reader, scroll, handoff) = try fixture()
        defer { reader.invalidate() }
        handoff.processPan(state: .began, translation: .zero, velocity: .zero)
        handoff.processPan(state: .changed, translation: CGPoint(x: -150, y: 0), velocity: .zero)
        XCTAssertTrue(handoff.isHandingOff)
        reader.cancelTransition()
        XCTAssertFalse(handoff.isHandingOff)
        XCTAssertTrue(scroll.bounces)
        XCTAssertFalse(reader.isTransitioning)
        handoff.processPan(state: .ended, translation: CGPoint(x: -150, y: 0), velocity: .zero, touches: 0)
        XCTAssertFalse(handoff.isHandingOff)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
    }

    func testTwoFingerPanAndPanAfterPinchRetainOccupancyThroughTheirOwnEnd() throws {
        for pinchFirst in [false, true] {
            let (reader, _, handoff) = try fixture()
            defer { reader.invalidate() }
            reader.viewDidAppear(false)
            try reader.startAutomaticReading(interval: 1, animated: false)
            if pinchFirst { handoff.processPinch(state: .began) }
            handoff.processPan(state: .began, translation: .zero, velocity: .zero, touches: 2)
            if pinchFirst { handoff.processPinch(state: .ended) }
            XCTAssertEqual(reader.automaticReadingState, .paused)
            XCTAssertThrowsError(try reader.replaceCurrentPage(page("a"), expectedBinding: reader.currentPageBinding)) {
                XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
            }
            handoff.processPan(state: .changed, translation: CGPoint(x: -150, y: 0), velocity: .zero, touches: 1)
            XCTAssertFalse(reader.isTransitioning)
            handoff.processPan(state: .ended, translation: .zero, velocity: .zero, touches: 0)
            XCTAssertEqual(reader.automaticReadingState, .running)
        }
    }

    func testZoomRejectsContentRemovedDuringContainmentAndCleansPartialView() throws {
        for duringInsertion in [false, true] {
            let child = HookPage()
            if duringInsertion {
                let root = MoveHookView()
                child.view = root
                root.onInsert = { [weak child] in child?.removeFromParent() }
            } else {
                child.onAttach = { [weak child] in
                    child?.view.removeFromSuperview()
                    child?.removeFromParent()
                }
            }
            XCTAssertThrowsError(try ReaderZoomViewController(content: child, contentSize: CGSize(width: 300, height: 400))) {
                XCTAssertEqual($0 as? ReaderZoomError, .invalidContentController)
            }
            XCTAssertNil(child.parent)
            XCTAssertNil(child.viewIfLoaded?.superview)
        }
    }

    func testSpreadRejectsViewTakenAfterConstructionWithoutStealingIt() throws {
        let child = UIViewController()
        let spread = try PageSpreadViewController(first: page("a", controller: child), second: nil)
        let foreign = UIView()
        foreign.addSubview(child.view)
        let content = page("spread", controller: spread)
        XCTAssertThrowsError(try PagedReaderViewController(page: content, configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal), layout: .spread)))
        XCTAssertTrue(child.view.superview === foreign)
        XCTAssertNil(child.parent)
    }

    func testSpreadLoadingCallbackCannotStealForeignViewOrReplaceExistingRenderer() throws {
        let outer = PageTurnViewController()
        let original = try outer.showPaged(page: page("original"), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        defer { outer.invalidate() }
        let child = HookPage()
        let foreign = UIView()
        child.onLoad = { [weak child] in if let child { foreign.addSubview(child.view) } }
        let spread = try PageSpreadViewController(first: page("a", controller: child), second: nil)
        XCTAssertThrowsError(try outer.showPaged(page: page("spread", controller: spread), configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal), layout: .spread)))
        XCTAssertTrue(outer.pagedReader === original)
        XCTAssertTrue(original.isActive)
        XCTAssertTrue(child.view.superview === foreign)
        XCTAssertNil(child.parent)
    }
}
#endif
