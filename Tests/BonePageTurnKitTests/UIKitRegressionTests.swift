#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class UIKitRegressionTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        var reader: ContinuousReaderViewController?
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private final class HookPage: UIViewController {
        var onLoad: (() -> Void)?
        var onWillMove: (() -> Void)?
        var onDidMove: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); onLoad?() }
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent != nil { onWillMove?() }
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil { onDidMove?() }
        }
    }
    private func identity(_ id: String = "a") -> PageItemIdentity { .init(sourceID: "source", unitID: id) }
    private func window() throws -> ContinuousWindow {
        try ContinuousWindow(items: [.init(identity: identity(), sectionID: "s", extent: 1000)])
    }
    private func layout(_ reader: UIViewController, width: CGFloat = 320, height: CGFloat = 300) {
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
    }

    func testCancellationDuringEachChildLifecycleLeavesNoOrphanOrReorderedEvents() throws {
        for phase in 0..<3 {
            let reader = try PagedReaderViewController(page: .init(identity: identity(), controller: UIViewController()),
                                                      configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
            layout(reader)
            let child = HookPage()
            let cancel: () -> Void = { [weak reader] in reader?.cancelTransition() }
            if phase == 0 { child.onLoad = cancel }
            if phase == 1 { child.onWillMove = cancel }
            if phase == 2 { child.onDidMove = cancel }
            reader.pageProvider = { [self] _, _ in .page(.init(identity: identity("b"), controller: child)) }
            var events: [PageTransitionEvent] = []
            reader.onTransition = { events.append($0) }
            XCTAssertFalse(try reader.beginInteractiveTurn(.previous), "phase=\(phase)")
            XCTAssertNil(child.parent)
            XCTAssertNil(child.viewIfLoaded?.superview)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertEqual(reader.view.subviews.count, 1)
            XCTAssertEqual(reader.currentPage.identity.unitID, "a")
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertEqual(events.count, 2)
            guard case .willBegin(let transition) = events.first else { return XCTFail("开始事件必须先于取消") }
            XCTAssertEqual(events.last, .didSettle(transition, completed: false))
        }
    }

    func testInvalidationFromChildViewLoadCannotMountCancelledPage() throws {
        let reader = try PagedReaderViewController(page: .init(identity: identity(), controller: UIViewController()),
                                                  configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(reader)
        let child = HookPage()
        child.onLoad = { [weak reader] in reader?.invalidate() }
        reader.pageProvider = { [self] _, _ in .page(.init(identity: identity("b"), controller: child)) }
        XCTAssertFalse(try reader.beginInteractiveTurn(.previous))
        XCTAssertFalse(reader.isActive)
        XCTAssertNil(child.parent)
        XCTAssertNil(child.view.superview)
        XCTAssertEqual(reader.children.count, 1)
    }

    func testNestedCancellationDoesNotUnlockEventDeliveryForAnotherTurn() throws {
        let reader = try PagedReaderViewController(page: .init(identity: identity(), controller: UIViewController()),
                                                  configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        layout(reader)
        reader.pageProvider = { [self] _, _ in .page(.init(identity: identity("b"), controller: UIViewController())) }
        var rejected = false
        reader.onTransition = { [weak reader] event in
            guard let reader, case .willBegin = event else { return }
            reader.cancelTransition()
            do { _ = try reader.turn(.next) }
            catch { rejected = (error as? PageTurnError) == .interactionInProgress }
        }
        XCTAssertFalse(try reader.beginInteractiveTurn(.next))
        XCTAssertTrue(rejected)
        XCTAssertEqual(reader.children.count, 1)
    }

    func testResizeInvalidatesOldWindowRequestButRepeatedLayoutDoesNot() throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: window(), provider: provider)
        layout(reader)
        let old = reader.updateToken
        layout(reader, width: 640)
        let resized = reader.updateToken
        XCTAssertNotEqual(old, resized)
        layout(reader, width: 640)
        XCTAssertEqual(reader.updateToken, resized)
        XCTAssertThrowsError(try reader.apply(window(), expectedToken: old)) { XCTAssertEqual($0 as? PageTurnError, .staleWindow) }
        try reader.apply(window(), expectedToken: resized)
    }

    func testNonzeroViewportAnchorCanBeAppliedAndRestoredBeforeFirstLayout() throws {
        for useRestore in [false, true] {
            let provider = Provider()
            let anchor = ContinuousAnchor(identity: identity(), offsetInItem: 500, viewportOffset: 60)
            let reader = try ContinuousReaderViewController(window: window(), provider: provider, anchor: anchor)
            if useRestore { try reader.restore(anchor, expectedToken: reader.updateToken) }
            else { try reader.apply(window(), expectedToken: reader.updateToken) }
            layout(reader)
            XCTAssertEqual(reader.scrollView.contentOffset.y, 440, accuracy: 0.01)
            XCTAssertNotNil(reader.visibleAnchor)
        }
    }

    func testLatestExplicitAnchorSupersedesUnresolvedInitialTargetAcrossResize() throws {
        for useRestore in [false, true] {
            let provider = Provider()
            let initial = ContinuousAnchor(identity: identity(), offsetInItem: 500, viewportOffset: 400)
            let reader = try ContinuousReaderViewController(window: window(), provider: provider, anchor: initial)
            var failures = 0
            var stableCount = 0
            reader.onAnchorRestorationFailure = { _ in failures += 1 }
            reader.onStableAnchor = { _ in stableCount += 1 }
            layout(reader)
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(stableCount, 0)
            XCTAssertNil(reader.visibleAnchor)
            let latest = ContinuousAnchor(identity: identity(), offsetInItem: 200)
            if useRestore { try reader.restore(latest, expectedToken: reader.updateToken) }
            else { try reader.apply(window(), expectedToken: reader.updateToken, anchor: latest) }
            layout(reader, height: 500)
            XCTAssertEqual(reader.scrollView.contentOffset.y, 200, accuracy: 0.01)
            XCTAssertEqual(reader.visibleAnchor, latest)
        }
    }

    func testHostOwningReaderIsNotRetainedByContentProviderReference() throws {
        var owner: Provider? = Provider()
        let weakOwner = WeakObject(owner)
        owner?.reader = try ContinuousReaderViewController(window: window(), provider: XCTUnwrap(owner))
        let weakReader = WeakObject(owner?.reader)
        layout(try XCTUnwrap(owner?.reader))
        owner = nil
        XCTAssertNil(weakOwner.value)
        XCTAssertNil(weakReader.value)
    }
}
#endif
