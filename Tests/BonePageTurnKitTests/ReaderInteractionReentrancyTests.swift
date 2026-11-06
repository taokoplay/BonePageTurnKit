#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderInteractionReentrancyTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func item(_ id: String) -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: 500)
    }
    private func mount(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }

    func testFinishingExitFromBookEndCallbackSavesBeforeInvalidationExactlyOnce() async throws {
        let root = PageTurnViewController()
        let provider = Provider()
        let reader = try root.showContinuous(window: ContinuousWindow(items: [item("a")], after: .endOfBook), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        try reader.restore(.init(identity: item("a").identity, offsetInItem: 195), expectedToken: reader.updateToken)
        var saves: [ContinuousAnchor] = []
        let finalized = expectation(description: "通知事务结束后确认退出")
        reader.onStableAnchor = { anchor in
            XCTAssertTrue(reader.isActive)
            saves.append(anchor)
        }
        root.onExitFinalized = { _ in
            XCTAssertFalse(reader.isActive)
            XCTAssertEqual(saves.count, 1)
            finalized.fulfill()
        }
        reader.onAutomaticReadingStateChange = { [weak root] state in
            guard case .finished(.endOfBook) = state, let root else { return }
            XCTAssertTrue(root.finishExit(root.beginExit()))
        }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.advanceAutomaticReading(elapsed: 0.1)
        await fulfillment(of: [finalized], timeout: 2)
        XCTAssertEqual(saves.first?.offsetInItem, 200)
        XCTAssertFalse(root.isExitInProgress)
    }

    func testResumingInsideAutomaticStateCallbackDoesNotRejectPreparedWindow() async throws {
        let provider = Provider()
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item("a")], after: .available), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading()
        let installed = expectation(description: "回调结束后继续安装")
        var results: [ContinuousLoadOutcome] = []
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}) { result in
            results.append(result)
            if case .installed = result { installed.fulfill() }
        }
        try reader.submit(ContinuousWindow(items: [item("a"), item("b")], after: .endOfBook), for: ticket)
        reader.onAutomaticReadingStateChange = { [weak reader] state in
            if state == .paused { reader?.setSuspended(false, reason: "menu") }
        }
        reader.setSuspended(true, reason: "menu")
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(results, [.installed(reader.updateToken)])
        XCTAssertEqual(reader.window.items.count, 2)
        XCTAssertEqual(reader.automaticReadingState, .running)
    }

    func testReentrantRootResumeCannotLeaveCandidateWithStaleSuspension() throws {
        let root = PageTurnViewController()
        let provider = Provider()
        let initial = try ContinuousWindow(items: [item("a")], after: .available)
        let old = try root.showContinuous(window: initial, provider: provider)
        old.usesDisplayLinkForAutomaticReading = false
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        try old.startAutomaticReading()
        old.onAutomaticReadingStateChange = { [weak root] state in
            if state == .paused { root?.setSuspended(false, reason: "menu") }
        }
        let replacement = try root.showContinuous(window: initial, provider: provider) { candidate in
            candidate.usesDisplayLinkForAutomaticReading = false
            root.setSuspended(true, reason: "menu")
        }
        replacement.view.frame = root.view.bounds
        replacement.view.layoutIfNeeded()
        replacement.viewDidAppear(false)
        try replacement.startAutomaticReading()
        XCTAssertEqual(replacement.automaticReadingState, .running)
        XCTAssertTrue(replacement.scrollView.isScrollEnabled)
    }
}
#endif
