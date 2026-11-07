#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderSurfaceRegressionTests: XCTestCase {
    private final class MovingHook: UIView {
        var onInsert: (() -> Void)?
        override func willMove(toSuperview newSuperview: UIView?) {
            super.willMove(toSuperview: newSuperview)
            guard newSuperview != nil, let action = onInsert else { return }
            onInsert = nil
            action()
        }
    }

    private func body(_ version: UInt64 = 0) -> PageContent {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return .init(identity: .init(sourceID: "book", unitID: "a", contentVersion: version), controller: controller)
    }

    private func surface(motion: ReaderSurfaceMotion = .wholePage,
                         decorations: ReaderSurfaceDecorations = .init()) throws -> ReaderSurfaceViewController {
        let surface = try ReaderSurfaceViewController(metrics: .init(headerHeight: 20, footerHeight: 20),
            motion: motion, decorations: decorations, viewportPolicy: nil)
        surface.loadViewIfNeeded()
        surface.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        surface.view.setNeedsLayout(); surface.view.layoutIfNeeded()
        return surface
    }

    func testQueuedReplacementUsesLatestPositionsWhenBodyAndRendererSizesStayEqual() throws {
        let surface = try surface(decorations: .init(makeHeader: { _ in UILabel() }, makeFooter: { _ in UILabel() }))
        defer { surface.invalidate() }
        let paged = try surface.showPaged(page: body(), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
        paged.view.setNeedsLayout(); paged.view.layoutIfNeeded()
        let binding = paged.currentPageBinding
        let oldBody = try XCTUnwrap(surface.layout?.bodyFrame)
        var outcomes: [PageReplacementOutcome] = []
        _ = try surface.submitCurrentPage(body(1), expectedBinding: binding) { outcomes.append($0) }
        try surface.updateMetrics(.init(headerHeight: 40, footerHeight: 0))
        XCTAssertEqual(oldBody.size, surface.layout?.bodyFrame.size)
        XCTAssertEqual(binding, paged.currentPageBinding)
        var notificationChecked = false
        surface.onPageReplacement = { [weak surface] _ in
            guard let surface, let layout = surface.layout, let realBody = surface.currentBodyController?.view else { return }
            XCTAssertEqual(realBody.convert(realBody.bounds, to: surface.view), layout.bodyFrame)
            XCTAssertEqual(surface.headerView?.frame.height, 40)
            XCTAssertEqual(surface.footerView?.isHidden, true)
            notificationChecked = true
        }
        paged.installPendingCurrentPageIfIdle()
        XCTAssertTrue(notificationChecked)
        XCTAssertEqual(outcomes, [.installed(paged.currentPageBinding)])
        let realBody = try XCTUnwrap(surface.currentBodyController?.view)
        XCTAssertEqual(realBody.convert(realBody.bounds, to: surface.view), surface.layout?.bodyFrame)
    }

    func testDecorationTakenDuringAnotherInsertionIsNotStolenBack() throws {
        for motion in [ReaderSurfaceMotion.contentOnly, .contentAndChrome] {
            let header = MovingHook()
            let footer = UIView()
            let externalOwner = UIView()
            header.onInsert = { externalOwner.addSubview(footer) }
            let surface = try surface(motion: motion, decorations: .init(makeHeader: { _ in header }, makeFooter: { _ in footer }))
            defer { surface.invalidate() }
            let page = body()
            XCTAssertThrowsError(try surface.showPaged(page: page, configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))) {
                XCTAssertEqual($0 as? ReaderSurfaceError, .invalidDecoration)
            }
            XCTAssertTrue(footer.superview === externalOwner)
            XCTAssertNil(header.superview)
            XCTAssertNil(page.controller.parent)
            XCTAssertNil(page.controller.view.superview)
        }
    }

    func testCurvedPaperDoesNotReportHiddenFlatPageAsActualAnimationGeometry() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let surface = try surface()
            defer { surface.invalidate() }
            let paged = try surface.showPaged(page: body(), configuration: .init(presentation: .paged(effect: effect, axis: .horizontal)))
            surface.pageProvider = { _, _, _ in .page(.init(identity: .init(sourceID: "book", unitID: "b"), controller: UIViewController())) }
            XCTAssertTrue(try paged.beginInteractiveTurn(.next))
            paged.updateInteractiveTurn(displacement: 160)
            XCTAssertNotNil(surface.layout)
            XCTAssertNil(surface.currentPageFrames())
            paged.cancelTransition()
            XCTAssertEqual(surface.currentPageFrames(), surface.layout)
        }
    }

    func testInitialStatusAndDecorationsArePublishedOnlyOncePerPresentation() throws {
        var updates = 0
        let surface = try surface(motion: .contentOnly, decorations: .init(update: { _, _ in updates += 1 }))
        defer { surface.invalidate() }
        var statuses: [ReaderStatus] = []
        surface.onReadingStatus = { statuses.append($0) }
        _ = try surface.showPaged(page: body(), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(statuses.count, 1)
        _ = try surface.showPaged(page: body(), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
        XCTAssertEqual(updates, 2)
        XCTAssertEqual(statuses.count, 2)
        XCTAssertNotEqual(statuses.first?.presentationID, statuses.last?.presentationID)
    }

    func testSurfaceRootCannotBeReturnedAsItsOwnDecoration() throws {
        var reference: ReaderSurfaceViewController?
        let surface = try surface(motion: .contentOnly, decorations: .init(makeHeader: { _ in reference?.view ?? UIView() }))
        reference = surface
        defer { surface.invalidate(); reference = nil }
        XCTAssertThrowsError(try surface.showPaged(page: body(), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))) {
            XCTAssertEqual($0 as? ReaderSurfaceError, .invalidDecoration)
        }
        XCTAssertNil(surface.view.superview)
        XCTAssertNil(surface.pagedReader)
    }
}
#endif
