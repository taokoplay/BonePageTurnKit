#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ContinuousAutomaticReadingTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func item(_ id: String, height: Double = 500, state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: height, state: state)
    }
    private func mount(_ reader: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        window.rootViewController = reader
        window.isHidden = false
        reader.loadViewIfNeeded()
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
    private func makeReader(_ provider: Provider, after: ReaderBoundaryState = .available) throws -> ContinuousReaderViewController {
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item("a")], after: after), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        return reader
    }

    func testAdvancementKeepsWindowTokenAndOnlyStopCommitsPosition() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let token = reader.updateToken
        var cancelled = 0
        _ = try reader.beginLoading(.next, token: token, cancel: { cancelled += 1 }, completion: { _ in })
        var commits: [ContinuousAnchor] = []
        reader.onStableAnchor = { commits.append($0) }
        try reader.startAutomaticReading(pointsPerSecond: 30)
        for _ in 0..<100 { reader.advanceAutomaticReading(elapsed: 0.016) }
        XCTAssertEqual(reader.scrollView.contentOffset.y, 48, accuracy: 0.01)
        XCTAssertEqual(reader.updateToken, token)
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(commits.isEmpty)
        reader.stopAutomaticReading()
        XCTAssertEqual(reader.automaticReadingState, .stopped)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.offsetInItem ?? -1, 48, accuracy: 0.01)
        reader.stopAutomaticReading()
        XCTAssertEqual(commits.count, 1)
    }

    func testInvalidSpeedIsAtomicAndLongFrameCannotCatchUpPausedTime() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        for value in [0, -1, Double.nan, .infinity, 2001] {
            XCTAssertThrowsError(try reader.startAutomaticReading(pointsPerSecond: value))
            XCTAssertEqual(reader.automaticReadingSpeed, 100)
            XCTAssertEqual(reader.automaticReadingState, .running)
        }
        reader.advanceAutomaticReading(elapsed: 100)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 10, accuracy: 0.01)
        for elapsed in [0, -1, Double.nan, .infinity] { reader.advanceAutomaticReading(elapsed: elapsed) }
        XCTAssertEqual(reader.scrollView.contentOffset.y, 10, accuracy: 0.01)
    }

    func testLoadingInsideWindowBlocksUntilReadyAndDoesNotChangeRequestToken() throws {
        let provider = Provider()
        let first = item("a")
        let waiting = item("b", state: .loading)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [first, waiting], after: .endOfBook), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.restore(.init(identity: first.identity, offsetInItem: 195), expectedToken: reader.updateToken)
        let token = reader.updateToken
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 200)
        XCTAssertEqual(reader.automaticReadingState, .waiting(.loading))
        XCTAssertEqual(reader.updateToken, token)
        try reader.apply(ContinuousWindow(items: [first, item("b")], after: .endOfBook), expectedToken: token)
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 210)
    }

    func testAvailableBoundaryLoadsOnceThenResumesAfterInstalledResult() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.restore(.init(identity: item("a").identity, offsetInItem: 200), expectedToken: reader.updateToken)
        var requests = 0
        var ticket: ContinuousLoadTicket?
        var outcomes: [ContinuousLoadOutcome] = []
        reader.onEdgeApproach = { [weak reader] direction, token in
            guard let reader, direction == .next else { return }
            requests += 1
            do { ticket = try reader.beginLoading(direction, token: token, cancel: {}, completion: { outcomes.append($0) }) }
            catch { XCTFail("\(error)") }
        }
        try reader.startAutomaticReading()
        XCTAssertEqual(reader.automaticReadingState, .waiting(.available))
        for _ in 0..<20 { reader.advanceAutomaticReading(elapsed: 0.1) }
        XCTAssertEqual(requests, 1)
        try reader.submit(ContinuousWindow(items: [item("a"), item("b")], after: .endOfBook), for: XCTUnwrap(ticket))
        reader.installPendingUpdateIfIdle()
        XCTAssertEqual(outcomes, [.installed(reader.updateToken)])
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertGreaterThan(reader.scrollView.contentOffset.y, 200)
    }

    func testLatestFailureAndWindowEndWaitWhileOnlyConfirmedBookEndFinishes() throws {
        for boundary in [ReaderBoundaryState.latestAvailable, .failed, .end, .unknown, .endOfSection("s"), .endOfBook] {
            let provider = Provider()
            let reader = try makeReader(provider, after: boundary)
            let window = mount(reader)
            defer { reader.invalidate(); close(window) }
            try reader.restore(.init(identity: item("a").identity, offsetInItem: 195), expectedToken: reader.updateToken)
            var stable = 0
            reader.onStableAnchor = { _ in stable += 1 }
            try reader.startAutomaticReading(pointsPerSecond: 100)
            reader.advanceAutomaticReading(elapsed: 0.1)
            XCTAssertEqual(reader.automaticReadingState, boundary == .endOfBook ? .finished(.endOfBook) : .waiting(boundary))
            XCTAssertEqual(stable, boundary == .endOfBook ? 1 : 0)
            try reader.apply(ContinuousWindow(items: [item("a"), item("b")], after: .endOfBook), expectedToken: reader.updateToken)
            XCTAssertEqual(reader.automaticReadingState, boundary == .endOfBook ? .finished(.endOfBook) : .running)
        }
    }

    func testUserPauseSurvivesAppendAndIndependentSuspensionReasons() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading()
        reader.setSuspended(true, reason: "selection")
        reader.setSuspended(true, reason: "menu")
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.setSuspended(false, reason: "menu")
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        reader.pauseAutomaticReading()
        reader.setSuspended(false, reason: "selection")
        try reader.apply(ContinuousWindow(items: [item("a"), item("b")]), expectedToken: reader.updateToken)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.setAutomaticApplicationActive(false)
        reader.setAutomaticApplicationActive(true)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        try reader.resumeAutomaticReading()
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertGreaterThan(reader.scrollView.contentOffset.y, 0)
    }

    func testDraggingAndDecelerationTemporarilyPauseOriginalPlayback() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading()
        reader.scrollViewWillBeginDragging(reader.scrollView)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.scrollViewDidEndDragging(reader.scrollView, willDecelerate: true)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        reader.scrollViewDidEndDecelerating(reader.scrollView)
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertGreaterThan(reader.scrollView.contentOffset.y, 0)
    }

    func testOffscreenAndBackgroundPauseAndRestoreStopsPlayback() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading()
        reader.viewWillDisappear(false)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
        reader.setAutomaticApplicationActive(false)
        reader.viewDidAppear(false)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.setAutomaticApplicationActive(true)
        XCTAssertEqual(reader.automaticReadingState, .running)
        try reader.restore(.init(identity: item("a").identity, offsetInItem: 80), expectedToken: reader.updateToken)
        XCTAssertEqual(reader.automaticReadingState, .stopped)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 80)
    }

    func testStateCallbackCanPauseWithoutOuterStartResurrectingPlayback() throws {
        let provider = Provider()
        let reader = try makeReader(provider)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var states: [ContinuousAutomaticReadingState] = []
        reader.onAutomaticReadingStateChange = { [weak reader] state in
            states.append(state)
            if state == .running { reader?.pauseAutomaticReading() }
        }
        try reader.startAutomaticReading()
        XCTAssertEqual(states, [.running, .paused])
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0)
    }

    func testActualDisplayLinkAdvancesAndStopsWithoutRetainingReader() async throws {
        let provider = Provider()
        var reader: ContinuousReaderViewController? = try makeReader(provider)
        let probe = WeakObject(reader)
        let window = mount(try XCTUnwrap(reader))
        let moved = expectation(description: "真实 CADisplayLink 推进")
        var fulfilled = false
        reader?.usesDisplayLinkForAutomaticReading = true
        reader?.onVisibleAnchor = { anchor in
            if !fulfilled, anchor.offsetInItem >= 6 { fulfilled = true; moved.fulfill() }
        }
        try reader?.startAutomaticReading(pointsPerSecond: 120)
        XCTAssertTrue(reader?.isAutomaticClockRunning == true)
        await fulfillment(of: [moved], timeout: 3)
        reader?.pauseAutomaticReading()
        XCTAssertFalse(reader?.isAutomaticClockRunning == true)
        autoreleasepool {
            reader?.invalidate()
            close(window)
            reader = nil
        }
        let cleanup = expectation(description: "UIKit 在下一轮主线程完成窗口清理")
        DispatchQueue.main.async { cleanup.fulfill() }
        await fulfillment(of: [cleanup], timeout: 2)
        XCTAssertNil(probe.value)
    }
    func testFractionalSpeedIsConsistentAtSixtyAndOneHundredTwentyFrames() throws {
        for frames in [60, 120] {
            let provider = Provider()
            let reader = try makeReader(provider)
            let window = mount(reader)
            defer { reader.invalidate(); close(window) }
            try reader.startAutomaticReading(pointsPerSecond: 25)
            for _ in 0..<(frames * 4) { reader.advanceAutomaticReading(elapsed: 1 / Double(frames)) }
            XCTAssertEqual(reader.scrollView.contentOffset.y, 100, accuracy: 0.34)
        }
    }

    func testActiveDisplayLinkHasNoOwnerRetentionCycle() {
        let probe = WeakObject<ReaderDisplayLink>(nil)
        autoreleasepool {
            let clock = ReaderDisplayLink()
            clock.onTick = { _ in }
            clock.start()
            XCTAssertTrue(clock.isRunning)
            probe.value = clock
        }
        XCTAssertNil(probe.value)
    }
}
#endif
