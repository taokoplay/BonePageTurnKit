#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class PageReplacementTests: XCTestCase {
    private final class HookPage: UIViewController {
        var onLoad: (() -> Void)?
        var onAttach: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); onLoad?() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); if parent != nil { onAttach?() } }
    }
    private final class Payload { var callbacks = 0 }
    private func page(_ id: String = "a", version: UInt64 = 0, source: String = "chapter", controller: UIViewController? = nil) -> PageContent {
        .init(identity: .init(sourceID: source, unitID: id, contentVersion: version, layoutVersion: version),
              controller: controller ?? UIViewController(), readingInfo: .init(after: .available))
    }
    private func reader() throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: page(), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return reader
    }

    func testAtomicReplacementKeepsRendererAndPublishesOnlyReplacementEvent() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        let presentation = reader.presentationID
        let oldController = reader.currentPage.controller
        let oldBinding = reader.currentPageBinding
        let oldMetadata = reader.metadataToken
        let oldContentRequest = reader.contentRequestToken
        var replacements: [PageReplacement] = []
        reader.onPageReplacement = { replacements.append($0) }
        reader.onTransition = { _ in XCTFail("原位替换不能冒充翻页") }
        let replacement = page("a-reflowed", version: 1)
        let installed = try reader.replaceCurrentPage(replacement, expectedBinding: oldBinding)
        XCTAssertEqual(reader.presentationID, presentation)
        XCTAssertEqual(reader.currentPage.identity, replacement.identity)
        XCTAssertEqual(reader.currentPageBinding, installed)
        XCTAssertNil(oldController.parent)
        XCTAssertTrue(replacement.controller.parent === reader)
        XCTAssertFalse(replacement.controller.view.isHidden)
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.previousBinding, oldBinding)
        XCTAssertEqual(replacements.first?.installedBinding, installed)
        XCTAssertNotEqual(oldMetadata, reader.metadataToken)
        XCTAssertNotEqual(oldContentRequest, reader.contentRequestToken)
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 2), expectedBinding: oldBinding))
    }

    func testNeighborQueryAndMetadataDoNotInvalidateCurrentPageBinding() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        let binding = reader.currentPageBinding
        reader.pageProvider = { _, _ in .waiting }
        XCTAssertFalse(try reader.turn(.next))
        try reader.updateReadingInfo(.init(after: .loading), expectedToken: reader.metadataToken)
        XCTAssertEqual(reader.currentPageBinding, binding)
        _ = try reader.replaceCurrentPage(page(version: 1), expectedBinding: binding)
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 1)
    }

    func testInvalidReplacementPreservesPageAndBinding() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        _ = try reader.replaceCurrentPage(page(version: 2), expectedBinding: reader.currentPageBinding)
        let binding = reader.currentPageBinding
        let current = reader.currentPage.controller
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 1), expectedBinding: binding))
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 3, source: "other"), expectedBinding: binding))
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 3, controller: current), expectedBinding: binding))
        let occupied = UIViewController()
        let other = UIViewController()
        other.addChild(occupied)
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 3, controller: occupied), expectedBinding: binding))
        XCTAssertEqual(reader.currentPageBinding, binding)
        XCTAssertTrue(reader.currentPage.controller === current)
        XCTAssertEqual(reader.children.count, 1)
        occupied.removeFromParent()
    }

    func testTransitionCancellationInstallsQueuedCurrentPageButCommitRejectsOldPage() throws {
        for commits in [false, true] {
            let reader = try reader()
            defer { reader.invalidate() }
            let binding = reader.currentPageBinding
            reader.pageProvider = { [self] _, _ in .page(page("b")) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            var results: [PageReplacementOutcome] = []
            _ = try reader.submitCurrentPage(page(version: 1), expectedBinding: binding) { results.append($0) }
            reader.installPendingCurrentPageIfIdle()
            XCTAssertTrue(results.isEmpty)
            if commits { reader.endInteractiveTurn(velocity: 900, animated: false) }
            else { reader.cancelTransition() }
            reader.installPendingCurrentPageIfIdle()
            XCTAssertEqual(results.count, 1)
            if commits {
                XCTAssertEqual(results, [.rejected(.staleWindow)])
                XCTAssertEqual(reader.currentPage.identity.unitID, "b")
            } else {
                XCTAssertEqual(results, [.installed(reader.currentPageBinding)])
                XCTAssertEqual(reader.currentPage.identity.contentVersion, 1)
            }
        }
    }

    func testLatestQueueSupersedesOldAndCancellationHasOneTerminal() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.setSuspended(true, reason: "selection")
        var first: [PageReplacementOutcome] = []
        var second: [PageReplacementOutcome] = []
        let old = try reader.submitCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding) { first.append($0) }
        _ = try reader.submitCurrentPage(page(version: 2), expectedBinding: reader.currentPageBinding) { second.append($0) }
        XCTAssertEqual(first, [.superseded])
        XCTAssertFalse(reader.cancelPageReplacement(old))
        reader.setSuspended(false, reason: "selection")
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(second, [.installed(reader.currentPageBinding)])
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 2)
        var last: [PageReplacementOutcome] = []
        let ticket = try reader.submitCurrentPage(page(version: 3), expectedBinding: reader.currentPageBinding) { last.append($0) }
        XCTAssertTrue(reader.cancelPageReplacement(ticket))
        XCTAssertFalse(reader.cancelPageReplacement(ticket))
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(last, [.cancelled])
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 2)
    }

    func testMultiplePauseReasonsDelayWithoutLosingAcceptedReplacement() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.setSuspended(true, reason: "selection")
        reader.setSuspended(true, reason: "menu")
        var outcomes: [PageReplacementOutcome] = []
        _ = try reader.submitCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding) { outcomes.append($0) }
        reader.setSuspended(false, reason: "menu")
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 0)
        reader.setSuspended(false, reason: "selection")
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(outcomes, [.installed(reader.currentPageBinding)])
    }

    func testResizeRejectsQueuedOldLayoutInsteadOfInstallingWrongPage() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        var outcomes: [PageReplacementOutcome] = []
        _ = try reader.submitCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding) { outcomes.append($0) }
        reader.view.frame.size.width = 500
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(outcomes, [.rejected(.staleWindow)])
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 0)
    }

    func testCandidateInvalidationBeforeCommitKeepsOriginalIdentity() throws {
        let reader = try reader()
        let old = reader.currentPage.controller
        let candidate = HookPage()
        candidate.onLoad = { [weak reader] in reader?.invalidate() }
        var outcomes: [PageReplacementOutcome] = []
        _ = try reader.submitCurrentPage(page(version: 1, controller: candidate), expectedBinding: reader.currentPageBinding) { outcomes.append($0) }
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(outcomes, [.invalidated])
        XCTAssertTrue(reader.currentPage.controller === old)
        XCTAssertNil(candidate.parent)
        XCTAssertNil(candidate.viewIfLoaded?.superview)
    }

    func testCandidateSuspensionDuringContainmentDoesNotPartiallyCommit() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        let old = reader.currentPage.controller
        let candidate = HookPage()
        candidate.onAttach = { [weak reader] in reader?.setSuspended(true, reason: "menu") }
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(version: 1, controller: candidate), expectedBinding: reader.currentPageBinding)) {
            XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
        }
        XCTAssertTrue(reader.currentPage.controller === old)
        XCTAssertFalse(old.view.isHidden)
        XCTAssertNil(candidate.parent)
        XCTAssertEqual(reader.children.count, 1)
    }

    func testInvalidationAfterCommitCannotRewriteInstalledOutcome() throws {
        let reader = try reader()
        reader.onPageReplacement = { [weak reader] _ in reader?.invalidate() }
        var outcomes: [PageReplacementOutcome] = []
        _ = try reader.submitCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding) { outcomes.append($0) }
        reader.installPendingCurrentPageIfIdle()
        XCTAssertEqual(outcomes, [.installed(reader.currentPageBinding)])
        XCTAssertEqual(reader.currentPage.identity.contentVersion, 1)
        XCTAssertFalse(reader.isActive)
    }

    func testReplacementResetsDwellAndPreservesUserPlaybackIntent() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        reader.usesDisplayLinkForAutomaticReading = false
        reader.viewDidAppear(false)
        try reader.startAutomaticReading(interval: 1, animated: false)
        for _ in 0..<4 { reader.advanceAutomaticReading(elapsed: 0.1) }
        _ = try reader.replaceCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding)
        XCTAssertEqual(reader.automaticReadingProgress, 0)
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.pauseAutomaticReading()
        _ = try reader.replaceCurrentPage(page(version: 2), expectedBinding: reader.currentPageBinding)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        reader.stopAutomaticReading()
        _ = try reader.replaceCurrentPage(page(version: 3), expectedBinding: reader.currentPageBinding)
        XCTAssertEqual(reader.automaticReadingState, .stopped)
    }

    func testQueueInvalidationReleasesCapturedPayloadAndBlocksTerminalReentry() throws {
        let reader = try reader()
        let probe = WeakObject<Payload>(nil)
        var outcomes: [PageReplacementOutcome] = []
        try autoreleasepool {
            let payload = Payload()
            probe.value = payload
            _ = try reader.submitCurrentPage(page(version: 1), expectedBinding: reader.currentPageBinding) { [weak reader] result in
                payload.callbacks += 1
                outcomes.append(result)
                guard let reader else { return }
                do { _ = try reader.submitCurrentPage(self.page(version: 2), expectedBinding: reader.currentPageBinding) { _ in }; XCTFail("不能在失效结果中重入") }
                catch { XCTAssertEqual(error as? PageTurnError, .inactive) }
            }
        }
        XCTAssertNotNil(probe.value)
        reader.invalidate()
        reader.invalidate()
        XCTAssertEqual(outcomes, [.invalidated])
        XCTAssertNil(probe.value)
    }
}
#endif
