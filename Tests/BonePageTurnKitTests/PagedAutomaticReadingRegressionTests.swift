#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class PagedAutomaticReadingRegressionTests: XCTestCase {
    private final class CancellingPage: UIViewController {
        weak var reader: PagedReaderViewController?
        override func viewDidLoad() { super.viewDidLoad(); reader?.cancelTransition() }
    }
    private func page(_ id: String, controller: UIViewController? = nil) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: id), controller: controller ?? UIViewController())
    }
    private func mount(_ reader: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader
        window.isHidden = false
        reader.loadViewIfNeeded()
        reader.view.frame = window.bounds
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }

    func testMountCancellationRestoresRunningStateAndActualClockImmediately() throws {
        let reader = try PagedReaderViewController(page: page("a"), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let candidate = CancellingPage()
        candidate.reader = reader
        reader.pageProvider = { [self] _, _ in .page(page("b", controller: candidate)) }
        var events: [PageTransitionEvent] = []
        reader.onTransition = { events.append($0) }
        try reader.startAutomaticReading(interval: 100)
        XCTAssertTrue(reader.isAutomaticClockRunning)
        XCTAssertFalse(try reader.beginInteractiveTurn(.next))
        // 不调用 advance 或额外布局，以免掩盖挂载退出后缺失的状态刷新。
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertTrue(reader.isAutomaticClockRunning)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        XCTAssertNil(candidate.parent)
        XCTAssertNil(candidate.viewIfLoaded?.superview)
        XCTAssertEqual(events.count, 2)
        guard case .didSettle(_, completed: false) = events.last else { return XCTFail("应只结束一次取消事务") }
    }

    func testProviderTemporarySuspensionDoesNotBecomeFalseContentFailure() throws {
        let reader = try PagedReaderViewController(page: page("a"), configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var queries = 0
        var unavailable = 0
        reader.onUnavailable = { _, _ in unavailable += 1 }
        reader.pageProvider = { [weak reader, self] _, _ in
            queries += 1
            if queries == 1 { reader?.setSuspended(true, reason: "render") }
            return .page(page("b"))
        }
        try reader.startAutomaticReading(interval: 0.1, animated: false)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        reader.setSuspended(false, reason: "render")
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.advanceAutomaticReading(elapsed: 0.016)
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(reader.currentPage.identity.unitID, "b")
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertEqual(unavailable, 0)
    }
}
#endif
