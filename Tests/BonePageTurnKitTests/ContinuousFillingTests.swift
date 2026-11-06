import XCTest
@testable import BonePageTurnKit

final class ContinuousFillingTests: XCTestCase {
    private let presentationID = UUID()
    private func item(_ id: String, _ height: Double, _ state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: .init(sourceID: id, unitID: id), sectionID: "s", extent: height, state: state)
    }
    private func token(_ revision: UInt64) -> ContinuousUpdateToken { .init(presentationID: presentationID, revision: revision) }
    private func demand(_ window: ContinuousWindow, revision: UInt64 = 0) throws -> ContinuousContentDemand {
        try XCTUnwrap(window.contentDemands(at: 0, viewportExtent: 300, token: token(revision)).first)
    }

    func testFourDataUnitsJustFillOneViewportAndStillNeedReadableBuffer() throws {
        let window = try ContinuousWindow(items: (0..<4).map { item(String($0), 75) }, before: .startOfBook, after: .available)
        let coverage = try XCTUnwrap(window.readableCoverage(at: 0, viewportExtent: 300))
        XCTAssertEqual(coverage.visibleReadyExtent, 300)
        XCTAssertTrue(coverage.coversViewport)
        XCTAssertEqual(coverage.contiguousReadyFromTop, 300)
        let next = try demand(window)
        XCTAssertEqual(next.direction, .next)
        XCTAssertEqual(next.target, .edge)
        XCTAssertEqual(next.missingReadyExtent, 300)
        let filled = try ContinuousWindow(items: (0..<8).map { item(String($0), 75) }, before: .startOfBook, after: .available)
        XCTAssertTrue(filled.contentDemands(at: 0, viewportExtent: 300, token: token(1)).isEmpty)
    }

    func testLargePlaceholderIsNotReadableAndInteriorHoleHasPriority() throws {
        let gap = item("hole", 5000, .loading)
        let window = try ContinuousWindow(items: [item("a", 120), gap, item("c", 900)], before: .available, after: .available)
        let coverage = try XCTUnwrap(window.readableCoverage(at: 20, viewportExtent: 300))
        XCTAssertEqual(coverage.visibleReadyExtent, 100)
        XCTAssertEqual(coverage.missingVisibleExtent, 200)
        XCTAssertEqual(coverage.contiguousReadyFromTop, 100)
        let needs = window.contentDemands(at: 20, viewportExtent: 300, token: token(0))
        XCTAssertEqual(needs.count, 1)
        XCTAssertEqual(needs.first?.target, .item(gap.identity))
        XCTAssertEqual(needs.first?.direction, .next)
    }

    func testVisibleReadyHeightSumsBothSidesButContiguousCoverageStopsAtHole() throws {
        let window = try ContinuousWindow(items: [item("a", 100), item("hole", 50, .loading), item("c", 200)])
        let coverage = try XCTUnwrap(window.readableCoverage(at: 0, viewportExtent: 300))
        XCTAssertEqual(coverage.visibleReadyExtent, 250)
        XCTAssertEqual(coverage.contiguousReadyFromTop, 100)
        XCTAssertFalse(coverage.coversViewport)
    }

    func testPreviousGapCanBeRequestedWithoutLosingCurrentReadyRegion() throws {
        let gap = item("hole", 200, .loading)
        let window = try ContinuousWindow(items: [item("a", 100), gap, item("c", 1000)], before: .startOfBook, after: .endOfBook)
        let needs = window.contentDemands(at: 400, viewportExtent: 200, token: token(0))
        XCTAssertEqual(needs.count, 1)
        XCTAssertEqual(needs.first?.direction, .previous)
        XCTAssertEqual(needs.first?.target, .item(gap.identity))
        XCTAssertEqual(needs.first?.coverage.contiguousReadyBefore, 100)
    }

    func testFailedBlockAndConfirmedEndsDoNotAutomaticallyLoop() throws {
        let failed = try ContinuousWindow(items: [item("a", 200, .failed)], before: .startOfBook, after: .available)
        XCTAssertTrue(failed.contentDemands(at: 0, viewportExtent: 300, token: token(0)).isEmpty)
        for end in [ReaderBoundaryState.endOfBook, .latestAvailable, .end, .failed, .loading, .unknown] {
            let window = try ContinuousWindow(items: [item("a", 75)], before: .startOfBook, after: end)
            XCTAssertTrue(window.contentDemands(at: 0, viewportExtent: 300, token: token(0)).isEmpty)
            XCTAssertEqual(window.readableCoverage(at: 0, viewportExtent: 300)?.missingVisibleExtent, 225)
        }
    }

    func testPolicyValidationAndZeroPrefetchOnlyFillsViewport() throws {
        for value in [Double.nan, .infinity, -1, 9] {
            XCTAssertThrowsError(try ContinuousFillPolicy(leadingViewports: value))
            XCTAssertThrowsError(try ContinuousFillPolicy(trailingViewports: value))
        }
        XCTAssertThrowsError(try ContinuousFillPolicy(maximumRequests: 0))
        XCTAssertThrowsError(try ContinuousFillPolicy(maximumNoProgressResults: 0))
        XCTAssertThrowsError(try ContinuousFillPolicy(maximumAddedItems: -1))
        let policy = try ContinuousFillPolicy(leadingViewports: 0, trailingViewports: 0)
        let full = try ContinuousWindow(items: [item("a", 300)], before: .available, after: .available)
        XCTAssertTrue(full.contentDemands(at: 0, viewportExtent: 300, token: token(0), policy: policy).isEmpty)
        XCTAssertNil(full.readableCoverage(at: .nan, viewportExtent: 300))
        XCTAssertNil(full.readableCoverage(at: 0, viewportExtent: 0))
    }

    func testUnchangedWindowCannotBypassNoProgressLimitWithNewRevisions() throws {
        let window = try ContinuousWindow(items: [item("a", 75)], after: .available)
        var fill = ContinuousFillController()
        for revision in UInt64(0)..<2 {
            let need = try demand(window, revision: revision)
            XCTAssertTrue(fill.admit(need, policy: .standard))
            XCTAssertFalse(fill.admit(need, policy: .standard))
            fill.installed(from: window, to: window, token: token(revision), owner: .next,
                           anchor: window.anchor(at: 0, viewportExtent: 300))
        }
        XCTAssertFalse(fill.admit(try demand(window, revision: 2), policy: .standard))
        XCTAssertEqual(fill.takeUnreportedLimit(in: .next), .noReadableProgress)
        XCTAssertNil(fill.takeUnreportedLimit(in: .next))
        fill.reset()
        XCTAssertTrue(fill.admit(try demand(window, revision: 2), policy: .standard))
    }

    func testPlaceholderGrowthDoesNotCountAsReadableProgress() throws {
        var window = try ContinuousWindow(items: [item("a", 75)], after: .available)
        var fill = ContinuousFillController()
        for revision in UInt64(0)..<2 {
            let need = ContinuousContentDemand(direction: .next, target: .edge, token: token(revision),
                                                coverage: try XCTUnwrap(window.readableCoverage(at: 0, viewportExtent: 300)), missingReadyExtent: 525)
            XCTAssertTrue(fill.admit(need, policy: .standard))
            let enlarged = try ContinuousWindow(items: window.items + [item("placeholder-\(revision)", 2000, .loading)], after: .available)
            fill.installed(from: window, to: enlarged, token: token(revision), owner: .next,
                           anchor: window.anchor(at: 0, viewportExtent: 300))
            window = enlarged
        }
        XCTAssertFalse(fill.admit(try demand(window, revision: 2), policy: .standard))
        XCTAssertEqual(fill.limit(in: .next), .noReadableProgress)
    }

    func testRequestAndAddedItemBudgetsStopEvenWhenEveryResponseProgresses() throws {
        for addedBudget in [false, true] {
            let policy = try ContinuousFillPolicy(maximumRequests: addedBudget ? 10 : 2,
                                                  maximumAddedItems: addedBudget ? 2 : 100)
            var fill = ContinuousFillController()
            var window = try ContinuousWindow(items: [item("a", 30)], after: .available)
            for revision in UInt64(0)..<2 {
                XCTAssertTrue(fill.admit(try demand(window, revision: revision), policy: policy))
                let expanded = try ContinuousWindow(items: window.items + [item(String(revision), 30)], after: .available)
                fill.installed(from: window, to: expanded, token: token(revision), owner: .next,
                               anchor: window.anchor(at: 0, viewportExtent: 300))
                window = expanded
            }
            XCTAssertFalse(fill.admit(try demand(window, revision: 2), policy: policy))
            XCTAssertEqual(fill.limit(in: .next), addedBudget ? .addedItemBudget : .requestBudget)
        }
    }

    func testReadyHydrationCountsAsProgressEvenIfEstimatedHeightShrinks() throws {
        let original = try ContinuousWindow(items: [item("a", 500, .loading)], after: .available)
        let ready = try ContinuousWindow(items: [item("a", 75)], after: .available)
        let policy = try ContinuousFillPolicy(maximumNoProgressResults: 1)
        var fill = ContinuousFillController()
        XCTAssertTrue(fill.admit(try demand(original), policy: policy))
        fill.installed(from: original, to: ready, token: token(0), owner: .next,
                       anchor: original.anchor(at: 0, viewportExtent: 300))
        XCTAssertTrue(fill.admit(try demand(ready, revision: 1), policy: policy))
        XCTAssertNil(fill.limit(in: .next))
    }
}
