#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderExitCoordinationTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) {}
    }
    private func content() throws -> ContinuousWindow {
        try ContinuousWindow(items: [.init(identity: .init(sourceID: "a", unitID: "a"), sectionID: "s", extent: 2000)])
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

    func testExitCancellationResumesOnlyWhenOtherSuspensionReasonsAreCleared() throws {
        let root = PageTurnViewController()
        let provider = Provider()
        let continuous = try root.showContinuous(window: content(), provider: provider)
        continuous.usesDisplayLinkForAutomaticReading = false
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        try continuous.startAutomaticReading()
        let exit = root.beginExit()
        XCTAssertEqual(exit, root.beginExit())
        XCTAssertEqual(continuous.automaticReadingState, .paused)
        root.setSuspended(true, reason: "selection")
        XCTAssertTrue(root.cancelExit(exit))
        XCTAssertFalse(root.cancelExit(exit))
        XCTAssertEqual(continuous.automaticReadingState, .paused)
        root.setSuspended(false, reason: "selection")
        XCTAssertEqual(continuous.automaticReadingState, .running)
        continuous.pauseAutomaticReading()
        let nextExit = root.beginExit()
        XCTAssertTrue(root.cancelExit(nextExit))
        XCTAssertEqual(continuous.automaticReadingState, .paused)
    }

    func testConfirmedExitCommitsPositionInvalidatesAndRejectsOldExitToken() throws {
        let root = PageTurnViewController()
        let provider = Provider()
        let reader = try root.showContinuous(window: content(), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.advanceAutomaticReading(elapsed: 0.1)
        var saved: [ContinuousAnchor] = []
        reader.onStableAnchor = { saved.append($0) }
        let exit = root.beginExit()
        XCTAssertThrowsError(try root.showContinuous(window: content(), provider: provider))
        XCTAssertTrue(root.finishExit(exit))
        XCTAssertFalse(reader.isActive)
        XCTAssertFalse(root.finishExit(exit))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.offsetInItem, 10)
        let newReader = try root.showContinuous(window: content(), provider: provider)
        XCTAssertFalse(root.finishExit(exit))
        XCTAssertTrue(newReader.isActive)
    }

    func testRootSuspensionIsInheritedByNewModeUntilMatchingReasonResumes() throws {
        let root = PageTurnViewController()
        let provider = Provider()
        let window = mount(root)
        defer { root.invalidate(); close(window) }
        root.setSuspended(true, reason: "menu")
        let reader = try root.showPaged(page: .init(identity: .init(sourceID: "a", unitID: "a"), controller: UIViewController()),
                                        configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
        XCTAssertThrowsError(try reader.turn(.next)) { XCTAssertEqual($0 as? PageTurnError, .interactionInProgress) }
        let continuous = try root.showContinuous(window: content(), provider: provider)
        continuous.usesDisplayLinkForAutomaticReading = false
        continuous.view.frame = root.view.bounds
        continuous.view.layoutIfNeeded()
        continuous.viewDidAppear(false)
        try continuous.startAutomaticReading()
        XCTAssertEqual(continuous.automaticReadingState, .paused)
        root.setSuspended(false, reason: "menu")
        XCTAssertEqual(continuous.automaticReadingState, .running)
    }

    func testExitTokenBelongsToItsContainerAndFinishCannotReenterNavigation() throws {
        let first = PageTurnViewController()
        let second = PageTurnViewController()
        let token = first.beginExit()
        XCTAssertFalse(second.cancelExit(token))
        XCTAssertFalse(second.finishExit(token))
        XCTAssertTrue(first.cancelExit(token))
        let provider = Provider()
        let continuous = try first.showContinuous(window: content(), provider: provider)
        continuous.usesDisplayLinkForAutomaticReading = false
        let window = mount(first)
        defer { first.invalidate(); close(window) }
        try continuous.startAutomaticReading()
        continuous.advanceAutomaticReading(elapsed: 0.1)
        let exit = first.beginExit()
        var nestedRejected = false
        continuous.onStableAnchor = { _ in
            nestedRejected = !first.cancelExit(exit) && !first.finishExit(exit)
        }
        XCTAssertTrue(first.finishExit(exit))
        XCTAssertTrue(nestedRejected)
    }
}
#endif
