import XCTest
@testable import BonePageTurnKit

final class ReaderStatusTests: XCTestCase {
    func testUnknownAndEstimatedTotalsDoNotClaimLastPage() throws {
        XCTAssertFalse(try ReaderPageMetrics(current: 7).isLast)
        XCTAssertFalse(try ReaderPageMetrics(current: 7, total: .estimated(7)).isLast)
        XCTAssertFalse(try ReaderPageMetrics(current: 9, total: .estimated(7)).isLast)
        XCTAssertTrue(try ReaderPageMetrics(current: 7, total: .exact(7)).isLast)
    }

    func testSinglePageIsFirstAndLastButNotAutomaticallyFinishedBook() throws {
        let pages = try ReaderPageMetrics(current: 1, total: .exact(1))
        XCTAssertTrue(pages.isFirst)
        XCTAssertTrue(pages.isLast)
        let status = ReaderStatus(presentationID: UUID(), identity: .init(sourceID: "s", unitID: "u"),
                                  info: .init(pagination: .init(book: pages), before: .startOfBook, after: .latestAvailable))
        XCTAssertTrue(status.isAtBookStart)
        XCTAssertTrue(status.hasReachedLatestAvailable)
        XCTAssertFalse(status.hasReachedBookEnd)
    }

    func testUnknownEmptyAndInvalidPageCounts() throws {
        XCTAssertNil(try ReaderPageMetrics(current: nil, total: .exact(0)).current)
        XCTAssertFalse(try ReaderPageMetrics(current: nil, total: .exact(0)).isLast)
        XCTAssertThrowsError(try ReaderPageMetrics(current: 0))
        XCTAssertThrowsError(try ReaderPageMetrics(current: -1))
        XCTAssertThrowsError(try ReaderPageMetrics(current: 1, total: .exact(0)))
        XCTAssertThrowsError(try ReaderPageMetrics(current: 4, total: .exact(3)))
        XCTAssertThrowsError(try ReaderPageMetrics(current: nil, total: .estimated(-1)))
        XCTAssertThrowsError(try ReaderSectionPagination(sectionID: "", pages: .init(current: 1)))
    }

    func testSectionLastPageDoesNotImplyBookEnd() throws {
        let pagination = ReaderPagination(book: try .init(current: 20, total: .unknown),
                                          section: try .init(sectionID: "chapter-2", pages: .init(current: 6, total: .exact(6))))
        let status = ReaderStatus(presentationID: UUID(), identity: .init(sourceID: "s", unitID: "u"),
                                  info: .init(pagination: pagination, after: .endOfSection("chapter-2")))
        XCTAssertTrue(try XCTUnwrap(status.pagination.section).pages.isLast)
        XCTAssertFalse(status.hasReachedBookEnd)
        XCTAssertFalse(status.hasReachedLatestAvailable)
    }

    func testContinuousTopPositionAndReachedBottomHaveIndependentMeaning() throws {
        let first = ContinuousItem(identity: .init(sourceID: "s", unitID: "1"), sectionID: "c", extent: 600,
                                   pagination: .init(book: try .init(current: 1, total: .exact(2), unit: .sourcePage)))
        let last = ContinuousItem(identity: .init(sourceID: "s", unitID: "2"), sectionID: "c", extent: 150,
                                  pagination: .init(book: try .init(current: 2, total: .exact(2), unit: .sourcePage)))
        let window = try ContinuousWindow(items: [first, last], before: .startOfBook, after: .endOfBook)
        let id = UUID()
        let notAtBottom = try XCTUnwrap(window.readingStatus(at: 400, viewportExtent: 300, presentationID: id))
        XCTAssertEqual(notAtBottom.pagination.book?.current, 1)
        XCTAssertFalse(notAtBottom.hasReachedBookEnd)
        let atBottom = try XCTUnwrap(window.readingStatus(at: 450, viewportExtent: 300, presentationID: id))
        XCTAssertEqual(atBottom.pagination.book?.current, 1)
        XCTAssertTrue(atBottom.hasReachedBookEnd)
        XCTAssertFalse(try XCTUnwrap(atBottom.pagination.book).isLast)
        XCTAssertFalse(try XCTUnwrap(window.readingStatus(at: 490, viewportExtent: 300, presentationID: id)).hasReachedBookEnd)
    }

    func testWindowSizeAndPlaceholderCannotBecomeTotalOrBookEnd() throws {
        let placeholder = ContinuousItem(identity: .init(sourceID: "s", unitID: "u"), sectionID: "c", extent: 100,
                                         state: .loading, pagination: .init(book: try .init(current: 100, total: .exact(100))))
        let window = try ContinuousWindow(items: [placeholder], after: .endOfBook)
        let status = try XCTUnwrap(window.readingStatus(at: 0, viewportExtent: 300, presentationID: UUID()))
        XCTAssertNil(status.pagination.book)
        XCTAssertEqual(status.after, .loading)
        XCTAssertFalse(status.hasReachedBookEnd)
        let ready = ContinuousItem(identity: placeholder.identity, sectionID: "c", extent: 100)
        let suppliedEnd = try ContinuousWindow(items: [ready])
        let suppliedStatus = try XCTUnwrap(suppliedEnd.readingStatus(at: 0, viewportExtent: 300, presentationID: UUID()))
        XCTAssertNil(suppliedStatus.pagination.book)
        XCTAssertFalse(suppliedStatus.hasReachedBookEnd)
        XCTAssertFalse(suppliedStatus.hasReachedLatestAvailable)
    }
}
