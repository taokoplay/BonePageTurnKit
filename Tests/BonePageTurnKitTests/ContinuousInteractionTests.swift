#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ContinuousInteractionTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func contents(version: UInt64 = 0) throws -> ContinuousWindow {
        try ContinuousWindow(items: (0..<12).map { index in
            .init(identity: .init(sourceID: "book", unitID: String(index), contentVersion: version),
                  sectionID: "chapter", extent: 200)
        }, before: .startOfBook, after: .endOfBook)
    }
    private func makeReader(_ provider: Provider) throws -> ContinuousReaderViewController {
        let reader = try ContinuousReaderViewController(window: contents(), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        return reader
    }
    private func mount(_ reader: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        window.rootViewController = reader; window.isHidden = false
        reader.view.frame = window.bounds; reader.view.layoutIfNeeded(); reader.viewDidAppear(false)
        return window
    }
    private func close(_ reader: ContinuousReaderViewController, _ window: UIWindow) {
        reader.invalidate(); window.isHidden = true; window.rootViewController = nil
    }

    func testVisibleQueryExcludesPrefetchClipsAndConvertsCoordinates() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        XCTAssertGreaterThan(reader.mountedContentViewCount, reader.visibleContents().count)
        reader.scrollView.contentOffset.y = 150
        let visible = reader.visibleContents()
        XCTAssertEqual(visible.map { $0.item.identity.unitID }, ["0", "1", "2"])
        XCTAssertEqual(visible[0].frame.minY, -150, accuracy: 0.01)
        XCTAssertEqual(visible[0].visibleFrame, CGRect(x: 0, y: 0, width: 320, height: 50))
        XCTAssertEqual(visible[2].visibleFrame.height, 50, accuracy: 0.01)
        let target = UIView(frame: CGRect(x: 20, y: 30, width: 100, height: 100))
        reader.view.addSubview(target)
        let converted = reader.visibleContents(in: target)
        XCTAssertEqual(converted[0].visibleFrame.origin, CGPoint(x: -20, y: -30))
        XCTAssertEqual(reader.visibleContent(at: CGPoint(x: 10, y: 60))?.item.identity.unitID, "1")
        XCTAssertEqual(reader.visibleContent(at: CGPoint(x: 0, y: 30), in: target)?.item.identity.unitID, "1")
        XCTAssertNil(reader.visibleContent(at: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(reader.visibleContent(at: CGPoint(x: 10, y: 301)))
    }

    func testOldBindingCannotQueryReusedOrReboundView() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        let first = try XCTUnwrap(reader.visibleContents().first)
        XCTAssertTrue(reader.contentView(for: first.binding) === first.view)
        let anchor = ContinuousAnchor(identity: reader.window.items[8].identity, offsetInItem: 0)
        try reader.restore(anchor, expectedToken: reader.updateToken)
        XCTAssertNil(reader.contentView(for: first.binding))
        XCTAssertFalse(reader.isCurrent(first.binding))
        let current = try XCTUnwrap(reader.visibleContents().first)
        current.view.removeFromSuperview()
        XCTAssertNil(reader.contentView(for: current.binding))
        XCTAssertFalse(reader.visibleContents().contains { $0.binding == current.binding })
        reader.invalidate()
        XCTAssertTrue(reader.visibleContents().isEmpty)
    }

    func testTapContextConvertsToContentAndCanBeConsumed() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        reader.scrollView.contentOffset.y = 150
        var events: [ContinuousTapContext] = []
        reader.onTap = { events.append($0) }
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 25, y: 60)))
        XCTAssertEqual(events.first?.content?.item.identity.unitID, "1")
        XCTAssertEqual(events.first?.pointInContent, CGPoint(x: 25, y: 10))
        reader.shouldHandleTap = { _ in false }
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 25, y: 60)))
        XCTAssertEqual(events.count, 1)
        reader.shouldHandleTap = nil
        reader.setSuspended(true, targets: .taps, reason: "selection")
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 25, y: 60)))
        XCTAssertTrue(reader.scrollView.isScrollEnabled)
    }

    func testTapVetoMayInvalidateAndCannotSynchronouslyMutateWindow() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        var delivered = false
        reader.onTap = { _ in delivered = true }
        reader.shouldHandleTap = { _ in
            do {
                try reader.restore(.init(identity: reader.window.items[1].identity, offsetInItem: 0), expectedToken: reader.updateToken)
                XCTFail("点击回调内不应允许导航")
            } catch { XCTAssertEqual(error as? PageTurnError, .interactionInProgress) }
            reader.invalidate()
            return true
        }
        XCTAssertFalse(try reader.handleTap(at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(delivered)
    }

    func testPanGatePreservesNativeDelegateAndRechecksSuspension() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        XCTAssertTrue(reader.scrollView.panGestureRecognizer.delegate === reader.scrollView)
        XCTAssertTrue(reader.canBeginUserPan(reader.scrollView.panGestureRecognizer))
        reader.shouldBeginPan = { _ in false }
        XCTAssertFalse(reader.canBeginUserPan(reader.scrollView.panGestureRecognizer))
        reader.shouldBeginPan = { _ in
            reader.setSuspended(true, targets: .userScrolling, reason: "edge")
            return true
        }
        XCTAssertFalse(reader.canBeginUserPan(reader.scrollView.panGestureRecognizer))
        XCTAssertFalse(reader.scrollView.isScrollEnabled)
    }

    func testIndependentPauseTargetsAndReasonsPreserveUserIntent() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.setSuspended(true, targets: [.automaticReading, .taps], reason: "selection")
        XCTAssertTrue(reader.scrollView.isScrollEnabled)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.setSuspended(true, targets: .automaticReading, reason: "menu")
        reader.setSuspended(false, targets: .automaticReading, reason: "selection")
        XCTAssertEqual(reader.suspendedTargets, [.automaticReading, .taps])
        reader.setSuspended(false, targets: .automaticReading, reason: "menu")
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 10)
        reader.pauseAutomaticReading()
        reader.setSuspended(false, reason: "selection")
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertTrue(reader.suspendedTargets.isEmpty)
    }

    func testScrollGateDoesNotPauseAutomaticDriverAndClearsCancelledDrag() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.scrollViewWillBeginDragging(reader.scrollView)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.setSuspended(true, targets: .userScrolling, reason: "host")
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 10)
        XCTAssertFalse(reader.scrollView.isScrollEnabled)
    }

    func testInstallationGateDefersLatestWindowButAllowsScrollAndIdleMutation() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        reader.setSuspended(true, targets: .contentInstallation, reason: "layout")
        XCTAssertTrue(reader.scrollView.isScrollEnabled)
        var installed = false
        let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}, completion: {
            if case .installed = $0 { installed = true }
        })
        let updated = try contents(version: 1)
        let anchor = ContinuousAnchor(identity: updated.items[0].identity, offsetInItem: 0)
        try reader.submit(updated, for: ticket, anchor: anchor)
        reader.installPendingUpdateIfIdle()
        XCTAssertFalse(installed)
        XCTAssertThrowsError(try reader.apply(updated, expectedToken: reader.updateToken, anchor: anchor))
        var idle = 0
        reader.onInteractionIdle = {
            idle += 1
            do { try reader.restore(.init(identity: reader.window.items[1].identity, offsetInItem: 20), expectedToken: reader.updateToken) }
            catch { XCTFail("空闲回调应允许导航：\(error)") }
            reader.setSuspended(false, targets: .contentInstallation, reason: "layout")
        }
        reader.setSuspended(false, targets: .contentInstallation, reason: "layout")
        XCTAssertTrue(installed)
        XCTAssertEqual(idle, 1)
        XCTAssertEqual(reader.visibleAnchor?.identity.unitID, "1")
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 20)
    }

    func testSpeedChangeKeepsPausePositionTokenAndRejectsInvalidInput() throws {
        let provider = Provider(), reader = try makeReader(provider)
        let host = mount(reader); defer { close(reader, host) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.pauseAutomaticReading()
        let token = reader.updateToken, anchor = reader.visibleAnchor
        try reader.updateAutomaticReadingSpeed(pointsPerSecond: 200)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.visibleAnchor, anchor)
        XCTAssertEqual(reader.updateToken, token)
        for speed in [0, -1, .nan, .infinity, 2001] {
            XCTAssertThrowsError(try reader.updateAutomaticReadingSpeed(pointsPerSecond: speed))
            XCTAssertEqual(reader.automaticReadingSpeed, 200)
        }
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem, 30)
    }
}
#endif
