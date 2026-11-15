#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class AutomaticReadingProgressTests: XCTestCase {
    private func page(_ index: Int) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: String(index)), controller: UIViewController())
    }
    private func makeReader() throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page(0), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { identity, _ in
            .page(.init(identity: .init(sourceID: "book", unitID: String((Int(identity.unitID) ?? 0) + 1)), controller: UIViewController()))
        }
        return reader
    }
    private func mount(_ reader: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        window.rootViewController = reader; window.isHidden = false
        reader.view.frame = window.bounds; reader.view.layoutIfNeeded(); reader.viewDidAppear(false)
        return window
    }
    private func close(_ reader: PagedReaderViewController, _ window: UIWindow) {
        reader.invalidate(); window.isHidden = true; window.rootViewController = nil
    }
    func testProgressCallbackAndSpeedChangePreserveFractionAndPause() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var progress: [Double] = []
        reader.onAutomaticReadingProgress = { progress.append($0) }
        XCTAssertEqual(progress, [0])
        try reader.startAutomaticReading(interval: 1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(progress, [0, 0.1])
        reader.pauseAutomaticReading()
        let binding = reader.currentPageBinding
        try reader.updateAutomaticReadingInterval(2)
        XCTAssertEqual(reader.automaticReadingProgress, 0.1, accuracy: 0.0001)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.currentPageBinding, binding)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(progress, [0, 0.1])
        for value in [0, -1, Double.nan, .infinity, 3601] {
            XCTAssertThrowsError(try reader.updateAutomaticReadingInterval(value))
            XCTAssertEqual(reader.automaticReadingInterval, 2)
        }
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.automaticReadingProgress, 0.15, accuracy: 0.0001)
        XCTAssertEqual(progress.last ?? -1, 0.15, accuracy: 0.0001)
    }
    func testPauseFromProgressAtOnePreventsAutomaticTurnUntilResume() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        reader.onAutomaticReadingProgress = { value in if value == 1 { reader.pauseAutomaticReading() } }
        try reader.startAutomaticReading(interval: 0.1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.onAutomaticReadingProgress = nil
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        XCTAssertEqual(reader.automaticReadingProgress, 0)
    }
    func testProgressNotificationRejectsNavigationAndInvalidationStopsDelivery() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var received = 0
        reader.onAutomaticReadingProgress = { value in
            received += 1
            do { _ = try reader.turn(.next); XCTFail("进度通知内不能同步翻页") }
            catch { XCTAssertEqual(error as? PageTurnError, .interactionInProgress) }
            if value > 0 { reader.invalidate() }
        }
        try reader.startAutomaticReading(interval: 0.1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertFalse(reader.isActive)
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        XCTAssertEqual(received, 2)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(received, 2)
    }
    func testManualCommitCancelAndStopPublishResetAfterTerminalEvent() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var events: [String] = []
        reader.onAutomaticReadingProgress = { events.append("progress:\($0)") }
        reader.onTransition = { if case .didSettle = $0 { events.append("settled") } }
        try reader.startAutomaticReading(interval: 1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.cancelTransition()
        XCTAssertEqual(Array(events.suffix(2)), ["settled", "progress:0.0"])
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.stopAutomaticReading()
        XCTAssertEqual(events.last, "progress:0.0")
        let count = events.count
        reader.stopAutomaticReading()
        XCTAssertEqual(events.count, count)
    }
    func testLayoutAndReplacementResetPublishedProgressWhilePaused() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var values: [Double] = []
        reader.onAutomaticReadingProgress = { values.append($0) }
        try reader.startAutomaticReading(interval: 1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.pauseAutomaticReading()
        reader.view.bounds.size.width -= 20
        reader.viewDidLayoutSubviews()
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        try reader.notifyContentAvailable(expectedToken: reader.contentRequestToken)
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.pauseAutomaticReading()
        let replacement = PageContent(identity: .init(sourceID: "book", unitID: "0", contentVersion: 1), controller: UIViewController())
        _ = try reader.replaceCurrentPage(replacement, expectedBinding: reader.currentPageBinding)
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        try reader.resumeAutomaticReading()
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.pauseAutomaticReading()
        reader.invalidateEmbeddedContentLayout()
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(values.filter { $0 == 0 }.count, 4)
    }

    func testUnavailableManualTurnPublishesResetAndRemainsWaiting() throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var values: [Double] = []
        reader.onAutomaticReadingProgress = { values.append($0) }
        try reader.startAutomaticReading(interval: 1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        reader.pageProvider = { _, _ in .waiting }
        XCTAssertFalse(try reader.turn(.next))
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(reader.automaticReadingState, .waiting(.loading))
    }

    func testProgressCallbackCanStopAndReplaceObserverWithoutStaleDelivery() async throws {
        let reader = try makeReader(), window = mount(reader)
        defer { close(reader, window) }
        var values: [Double] = []
        reader.onAutomaticReadingProgress = { value in
            values.append(value)
            if value > 0 { reader.stopAutomaticReading() }
        }
        try reader.startAutomaticReading(interval: 0.1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(values, [0, 1, 0])
        XCTAssertEqual(reader.currentPage.identity.unitID, "0")
        XCTAssertEqual(reader.automaticReadingState, .stopped)
        var replacement: [Double] = []
        reader.onAutomaticReadingProgress = { value in
            if value > 0 { reader.onAutomaticReadingProgress = { replacement.append($0) } }
        }
        try reader.startAutomaticReading(interval: 1)
        reader.advanceAutomaticReading(elapsed: 0.1)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(replacement, [0.1])
    }
}
#endif
