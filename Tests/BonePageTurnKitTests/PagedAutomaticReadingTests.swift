#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class PagedAutomaticReadingTests: XCTestCase {
    private func page(_ number: Int, after: ReaderBoundaryState = .available) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: String(number)), controller: UIViewController(), readingInfo: .init(after: after))
    }
    private func reader(effect: PageTurnEffect = .none, after: ReaderBoundaryState = .available) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page(0, after: after), configuration: .init(presentation: .paged(effect: effect, axis: .horizontal)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { [self] identity, direction in
            let number = (Int(identity.unitID) ?? 0) + (direction == .next ? 1 : -1)
            return .page(page(number))
        }
        return reader
    }
    private func mount(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
    private func advance(_ reader: PagedReaderViewController, steps: Int, elapsed: Double = 0.1) {
        for _ in 0..<steps { reader.advanceAutomaticReading(elapsed: elapsed) }
    }

    func testIntervalMakesExactlyOneTransactionAndDoesNotCountAnimationTime() async throws {
        let reader = try reader(effect: .slide)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var commits = 0
        let settled = expectation(description: "真实平移动画完成")
        reader.onTransition = { event in
            if case .didCommit = event { commits += 1 }
            if case .didSettle(_, completed: true) = event { settled.fulfill() }
        }
        try reader.startAutomaticReading(interval: 0.5, animated: true)
        advance(reader, steps: 4)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        XCTAssertEqual(reader.automaticReadingProgress, 0.8, accuracy: 0.001)
        reader.advanceAutomaticReading(elapsed: 0.1)
        if reader.isTransitioning {
            XCTAssertEqual(reader.automaticReadingState, .turning)
            advance(reader, steps: 100)
            XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        XCTAssertEqual(reader.automaticReadingState, .running)
    }

    func testWaitingQueriesOnlyOnceAndExplicitReadinessResumesWithoutPolling() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var calls = 0
        reader.pageProvider = { _, _ in calls += 1; return .waiting }
        try reader.startAutomaticReading(interval: 0.2, animated: false)
        advance(reader, steps: 50)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reader.automaticReadingState, .waiting(.loading))
        let token = reader.contentRequestToken
        reader.pageProvider = { [self] _, _ in calls += 1; return .page(page(1)) }
        try reader.notifyContentAvailable(expectedToken: token)
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.016)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        XCTAssertEqual(reader.automaticReadingProgress, 0)
    }

    func testUserPauseSurvivesReadinessAndTemporarySuspensions() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        reader.pageProvider = { _, _ in .waiting }
        try reader.startAutomaticReading(interval: 0.1, animated: false)
        reader.advanceAutomaticReading(elapsed: 0.1)
        let token = reader.contentRequestToken
        reader.pauseAutomaticReading()
        reader.setSuspended(true, reason: "menu")
        reader.setSuspended(true, reason: "selection")
        reader.pageProvider = { [self] _, _ in .page(page(1)) }
        try reader.notifyContentAvailable(expectedToken: token)
        reader.setSuspended(false, reason: "menu")
        reader.setSuspended(false, reason: "selection")
        advance(reader, steps: 50)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.016)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
    }

    func testPauseKeepsElapsedAndStopClearsItWithoutInventingAnotherTurn() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading(interval: 1, animated: false)
        advance(reader, steps: 4)
        reader.pauseAutomaticReading()
        advance(reader, steps: 50)
        XCTAssertEqual(reader.automaticReadingProgress, 0.4, accuracy: 0.001)
        try reader.resumeAutomaticReading()
        advance(reader, steps: 5)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        advance(reader, steps: 3)
        reader.stopAutomaticReading()
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        try reader.resumeAutomaticReading()
        advance(reader, steps: 50)
        XCTAssertEqual(reader.automaticReadingState, .stopped)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
    }

    func testManualTurnAndCancellationRestartCurrentPageDwell() throws {
        let reader = try reader(effect: .slide)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading(interval: 1, animated: false)
        advance(reader, steps: 9)
        XCTAssertTrue(try reader.turn(.next, animated: false))
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        advance(reader, steps: 9)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous))
        XCTAssertEqual(reader.automaticReadingState, .turning)
        advance(reader, steps: 50)
        reader.cancelTransition()
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
    }

    func testOnlyConfirmedBookEndFinishesAfterDwellWhileOtherBoundariesWait() throws {
        for boundary in [ReaderBoundaryState.endOfBook, .latestAvailable, .failed, .end, .unknown, .endOfSection("chapter")] {
            let reader = try reader(after: boundary)
            let window = mount(reader)
            defer { reader.invalidate(); close(window) }
            var queries = 0
            reader.pageProvider = { _, _ in queries += 1; return .boundary(boundary) }
            try reader.startAutomaticReading(interval: 0.2, animated: false)
            XCTAssertEqual(reader.automaticReadingState, .running)
            reader.advanceAutomaticReading(elapsed: 0.1)
            XCTAssertEqual(reader.automaticReadingState, .running)
            advance(reader, steps: 30)
            XCTAssertEqual(reader.automaticReadingState, boundary == .endOfBook ? .finished(.endOfBook) : .waiting(boundary))
            XCTAssertEqual(queries, boundary == .endOfBook ? 0 : 1)
            XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        }
    }

    func testNewPageRejectsStaleContentTokenWhileMetadataUpdateKeepsReadinessContext() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        reader.pageProvider = { _, _ in .waiting }
        try reader.startAutomaticReading(interval: 0.1, animated: false)
        reader.advanceAutomaticReading(elapsed: 0.1)
        let token = reader.contentRequestToken
        try reader.updateReadingInfo(.init(after: .available), expectedToken: reader.metadataToken)
        XCTAssertEqual(reader.contentRequestToken, token)
        reader.pageProvider = { [self] _, _ in .page(page(1)) }
        try reader.notifyContentAvailable(expectedToken: token)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertThrowsError(try reader.notifyContentAvailable(expectedToken: token)) { XCTAssertEqual($0 as? PageTurnError, .staleWindow) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
    }

    func testSecondUnavailableQuerySupersedesFirstReadinessToken() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        reader.pageProvider = { _, _ in .waiting }
        XCTAssertFalse(try reader.turn(.next))
        let first = reader.contentRequestToken
        XCTAssertFalse(try reader.turn(.next))
        let second = reader.contentRequestToken
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try reader.notifyContentAvailable(expectedToken: first))
        XCTAssertNoThrow(try reader.notifyContentAvailable(expectedToken: second))
    }

    func testBackgroundAndOffscreenTimeIsNotCaughtUpAndResizeNeedsNewReadyToken() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading(interval: 1, animated: false)
        advance(reader, steps: 3)
        reader.setAutomaticApplicationActive(false)
        advance(reader, steps: 100, elapsed: 100)
        reader.setAutomaticApplicationActive(true)
        XCTAssertEqual(reader.automaticReadingProgress, 0.3, accuracy: 0.001)
        reader.viewWillDisappear(false)
        advance(reader, steps: 100)
        reader.viewDidAppear(false)
        XCTAssertEqual(reader.automaticReadingProgress, 0.3, accuracy: 0.001)
        let old = reader.contentRequestToken
        reader.view.frame.size.width = 500
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        XCTAssertEqual(reader.automaticReadingState, .waiting(.loading))
        XCTAssertThrowsError(try reader.notifyContentAvailable(expectedToken: old))
        try reader.notifyContentAvailable(expectedToken: reader.contentRequestToken)
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        reader.advanceAutomaticReading(elapsed: 100)
        XCTAssertEqual(reader.automaticReadingProgress, 0.1, accuracy: 0.001)
    }

    func testInvalidIntervalsAreAtomicAndMalformedProviderPausesInsteadOfLooping() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        try reader.startAutomaticReading(interval: 1, animated: false)
        for value in [Double.nan, .infinity, 0, 0.05, 3601] {
            XCTAssertThrowsError(try reader.startAutomaticReading(interval: value))
            XCTAssertEqual(reader.automaticReadingInterval, 1)
            XCTAssertEqual(reader.automaticReadingState, .running)
        }
        var calls = 0
        reader.pageProvider = { [weak reader] _, _ in
            calls += 1
            guard let reader else { return .failed }
            return .page(reader.currentPage)
        }
        advance(reader, steps: 100)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reader.automaticReadingState, .waiting(.failed))
    }

    func testAutomaticStateAndMetadataCallbacksCanPauseWithoutReentry() throws {
        let reader = try reader()
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var blockedTurn = false
        reader.onAutomaticReadingStateChange = { [weak reader] state in
            guard let reader, state == .running else { return }
            do { _ = try reader.turn(.next, animated: false) }
            catch { blockedTurn = error as? PageTurnError == .interactionInProgress }
            reader.pauseAutomaticReading()
        }
        try reader.startAutomaticReading(interval: 1)
        XCTAssertTrue(blockedTurn)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.onAutomaticReadingStateChange = nil
        try reader.startAutomaticReading(interval: 1)
        reader.onReadingStatus = { [weak reader] _ in reader?.pauseAutomaticReading() }
        try reader.updateReadingInfo(.init(after: .latestAvailable), expectedToken: reader.metadataToken)
        XCTAssertEqual(reader.automaticReadingState, .paused)
    }

    func testExitCancellationResumesCountdownButFinalExitPreventsLatePageAdvance() throws {
        let root = PageTurnViewController()
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        let reader = try root.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .slide, axis: .vertical)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.view.layoutIfNeeded()
        reader.viewDidAppear(false)
        reader.pageProvider = { [self] _, _ in .page(page(1)) }
        try reader.startAutomaticReading(interval: 1, animated: false)
        advance(reader, steps: 4)
        let exit = root.beginExit()
        advance(reader, steps: 100)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertTrue(root.cancelExit(exit))
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertEqual(reader.automaticReadingProgress, 0.4, accuracy: 0.001)
        XCTAssertTrue(root.finishExit(root.beginExit()))
        advance(reader, steps: 100)
        XCTAssertFalse(reader.isActive)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
    }

    func testActualClockAdvancesAndInvalidationReleasesRenderer() async throws {
        var reader: PagedReaderViewController? = try reader()
        let probe = WeakObject(reader)
        let window = mount(try XCTUnwrap(reader))
        let finished = expectation(description: "真实分页计时器完成一次翻页")
        reader?.usesDisplayLinkForAutomaticReading = true
        reader?.onTransition = { [weak reader] event in
            if case .didCommit = event { reader?.pauseAutomaticReading(); finished.fulfill() }
        }
        try reader?.startAutomaticReading(interval: 0.15, animated: false)
        XCTAssertTrue(reader?.isAutomaticClockRunning == true)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(reader?.currentPage.identity.unitID, "1")
        XCTAssertFalse(reader?.isAutomaticClockRunning == true)
        autoreleasepool { reader?.invalidate(); close(window); reader = nil }
        let cleanup = expectation(description: "UIKit 完成释放")
        DispatchQueue.main.async { cleanup.fulfill() }
        await fulfillment(of: [cleanup], timeout: 2)
        XCTAssertNil(probe.value)
    }
}
#endif
