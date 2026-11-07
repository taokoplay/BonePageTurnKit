#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderSurfaceContainerTests: XCTestCase {
    func testSwitchingRendererDeliversOldCancellationBeforeNewState() throws {
        let surface = try surface()
        defer { surface.invalidate() }
        let old = try show(surface)
        var events: [PageTransitionEvent] = []
        surface.onTransition = { events.append($0) }
        XCTAssertTrue(try old.beginInteractiveTurn(.next))
        let provider = Provider()
        let item = ContinuousItem(identity: .init(sourceID: "book", unitID: "c"), sectionID: "chapter", extent: 600)
        _ = try surface.showContinuous(window: ContinuousWindow(items: [item]), provider: provider)
        guard case .willBegin(let transaction) = events.first else { return XCTFail("缺少开始事件") }
        XCTAssertEqual(events, [.willBegin(transaction), .didSettle(transaction, completed: false)])
        XCTAssertFalse(old.isActive)
    }

    private final class Provider: ContinuousContentProvider {
        var views: [String: UIView] = [:]
        func makeContentView(reuseIdentifier: String) -> UIView { UILabel() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
            (view as? UILabel)?.text = item.identity.unitID
            view.backgroundColor = .clear
            views[item.identity.unitID] = view
        }
        func unbind(_ view: UIView, binding: PageViewBinding) { views[binding.identity.unitID] = nil }
    }
    private final class HookPage: UIViewController {
        var onLoad: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); onLoad?() }
    }
    private final class HookView: UIView {
        var onInsert: (() -> Void)?
        override func willMove(toSuperview newSuperview: UIView?) {
            super.willMove(toSuperview: newSuperview)
            guard newSuperview != nil, let action = onInsert else { return }
            onInsert = nil; action()
        }
    }
    private let metrics = ReaderSurfaceMetrics(headerHeight: 32, footerHeight: 24, headerGap: 6, footerGap: 8,
                                               bodyInsets: .init(top: 4, left: 10, bottom: 10, right: 10))

    private func page(_ name: String, version: UInt64 = 0, controller: UIViewController? = nil) -> PageContent {
        let child = controller ?? UIViewController()
        if controller == nil {
            child.view.backgroundColor = .clear
            let title = UILabel(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
            title.text = "正文 \(name)"
            child.view.addSubview(title)
        }
        return .init(identity: .init(sourceID: "book", unitID: name, contentVersion: version, layoutVersion: version),
                     controller: child, readingInfo: .init(after: .available))
    }

    private func decorations() -> ReaderSurfaceDecorations {
        .init(makeHeader: { context in let label = UILabel(); label.text = "页眉 \(context.identity?.unitID ?? "")"; return label },
              makeFooter: { context in let label = UILabel(); label.text = "页脚 \(context.identity?.unitID ?? "")"; return label },
              makeBackground: { _ in
                  let view = UIView(); view.backgroundColor = .systemYellow
                  let stripe = UIView(frame: CGRect(x: 20, y: 0, width: 4, height: 900))
                  stripe.backgroundColor = .systemBlue; view.addSubview(stripe); return view
              }, update: { views, context in
                  (views.header as? UILabel)?.text = "页眉 \(context.identity?.unitID ?? "")"
                  (views.footer as? UILabel)?.text = "页脚 \(context.identity?.unitID ?? "")"
              })
    }

    private func surface(_ motion: ReaderSurfaceMotion = .contentOnly,
                         decorations: ReaderSurfaceDecorations? = nil) throws -> ReaderSurfaceViewController {
        let surface = try ReaderSurfaceViewController(metrics: metrics, motion: motion,
            decorations: decorations ?? self.decorations(), viewportPolicy: nil, backgroundColor: .systemYellow)
        surface.loadViewIfNeeded()
        surface.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        surface.view.setNeedsLayout(); surface.view.layoutIfNeeded()
        return surface
    }

    private func show(_ surface: ReaderSurfaceViewController, axis: PageTurnAxis = .horizontal,
                      effect: PageTurnEffect = .slide) throws -> PagedReaderViewController {
        surface.pageProvider = { [self] _, _, layout in
            XCTAssertGreaterThan(layout.bodyFrame.height, 0)
            return .page(page("b"))
        }
        let paged = try surface.showPaged(page: page("a"), configuration: .init(presentation: .paged(effect: effect, axis: axis)))
        surface.view.layoutIfNeeded(); paged.view.layoutIfNeeded()
        return paged
    }

    private func drain() async {
        let ready = expectation(description: "主队列布局完成")
        DispatchQueue.main.async { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
    }

    func testStableFramesMatchRealBodyAndChromeForAllMotionModes() throws {
        for motion in [ReaderSurfaceMotion.contentOnly, .contentAndChrome, .wholePage] {
            let surface = try surface(motion)
            defer { surface.invalidate() }
            let paged = try show(surface)
            let layout = try XCTUnwrap(surface.layout)
            let body = try XCTUnwrap(surface.currentBodyController?.viewIfLoaded)
            let header = try XCTUnwrap(surface.headerView)
            let footer = try XCTUnwrap(surface.footerView)
            XCTAssertEqual(body.bounds.size, layout.bodyFrame.size)
            XCTAssertEqual(body.convert(body.bounds, to: surface.view), layout.bodyFrame)
            XCTAssertEqual(header.convert(header.bounds, to: surface.view), layout.headerFrame)
            XCTAssertEqual(footer.convert(footer.bounds, to: surface.view), layout.footerFrame)
            XCTAssertEqual(paged.view.convert(paged.view.bounds, to: surface.view), layout.rendererFrame)
            XCTAssertEqual(surface.backgroundView?.convert(surface.backgroundView?.bounds ?? .zero, to: surface.view), layout.backgroundFrame)
            XCTAssertEqual(paged.view.backgroundColor, .clear)
            XCTAssertEqual(surface.currentPageFrames(), layout)
        }
    }

    func testInteractiveSlideMovesOnlyChosenLayersOnBothAxes() throws {
        for motion in [ReaderSurfaceMotion.contentOnly, .contentAndChrome, .wholePage] {
            for axis in [PageTurnAxis.horizontal, .vertical] {
                let surface = try surface(motion)
                defer { surface.invalidate() }
                let paged = try show(surface, axis: axis)
                let before = try XCTUnwrap(surface.layout)
                XCTAssertTrue(try paged.beginInteractiveTurn(.next))
                paged.updateInteractiveTurn(displacement: 80)
                let actual = try XCTUnwrap(surface.currentPageFrames())
                let dx: CGFloat = axis == .horizontal ? -80 : 0
                let dy: CGFloat = axis == .vertical ? -80 : 0
                XCTAssertEqual(actual.bodyFrame, before.bodyFrame.offsetBy(dx: dx, dy: dy))
                XCTAssertEqual(actual.headerFrame, motion == .contentOnly ? before.headerFrame : before.headerFrame?.offsetBy(dx: dx, dy: dy))
                XCTAssertEqual(actual.footerFrame, motion == .contentOnly ? before.footerFrame : before.footerFrame?.offsetBy(dx: dx, dy: dy))
                XCTAssertEqual(actual.backgroundFrame, motion == .wholePage ? before.backgroundFrame.offsetBy(dx: dx, dy: dy) : before.backgroundFrame)
                XCTAssertEqual(surface.layout, before, "排版矩形不应随动画位移改变")
                paged.cancelTransition()
                XCTAssertEqual(surface.currentPageFrames(), before)
            }
        }
    }

    func testFixedHeaderIdentityAndDataStayOnCurrentPageUntilCommit() throws {
        let surface = try surface()
        defer { surface.invalidate() }
        let paged = try show(surface)
        let header = try XCTUnwrap(surface.headerView as? UILabel)
        XCTAssertEqual(header.text, "页眉 a")
        XCTAssertTrue(try paged.beginInteractiveTurn(.next))
        XCTAssertEqual(header.text, "页眉 a")
        paged.cancelTransition()
        XCTAssertEqual(header.text, "页眉 a")
        XCTAssertTrue(try paged.turn(.next, animated: false))
        XCTAssertTrue(surface.headerView === header)
        XCTAssertEqual(header.text, "页眉 b")
    }

    func testWholePageContainsHeaderFooterAndBackgroundDuringPaper() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let surface = try surface(.wholePage)
            defer { surface.invalidate() }
            let paged = try show(surface, effect: effect)
            XCTAssertTrue(try paged.beginInteractiveTurn(.next))
            XCTAssertEqual(paged.activePaperView?.hasResources, true)
            paged.endInteractiveTurn(velocity: 900, animated: false)
            XCTAssertEqual((surface.headerView as? UILabel)?.text, "页眉 b")
            XCTAssertNil(paged.activePaperView)
        }
    }

    func testContinuousViewportContainsOnlyBodyAndChromeDoesNotScroll() throws {
        let surface = try surface()
        defer { surface.invalidate() }
        let provider = Provider()
        let items = (0..<8).map { ContinuousItem(identity: .init(sourceID: "book", unitID: "block-\($0)"), sectionID: "chapter", extent: 150) }
        let continuous = try surface.showContinuous(window: ContinuousWindow(items: items), provider: provider)
        surface.view.setNeedsLayout(); surface.view.layoutIfNeeded()
        continuous.view.setNeedsLayout(); continuous.view.layoutIfNeeded()
        let layout = try XCTUnwrap(surface.layout)
        XCTAssertEqual(continuous.scrollView.bounds.size, layout.bodyFrame.size)
        let header = try XCTUnwrap(surface.headerView)
        let footer = try XCTUnwrap(surface.footerView)
        let background = try XCTUnwrap(surface.backgroundView)
        let frames = [header, footer, background].map { $0.convert($0.bounds, to: surface.view) }
        continuous.scrollView.contentOffset.y = 300
        continuous.scrollViewDidScroll(continuous.scrollView)
        XCTAssertEqual(frames, [header, footer, background].map { $0.convert($0.bounds, to: surface.view) })
        XCTAssertEqual((header as? UILabel)?.text, "页眉 block-2")
        XCTAssertEqual(continuous.window.items.map(\.extent), Array(repeating: 150, count: 8))
        XCTAssertEqual(surface.currentPageFrames(), layout)
    }

    func testGeometryConvertsIntoHostCoordinatesAndSupportsHiddenChrome() throws {
        let surface = try surface(.contentAndChrome)
        defer { surface.invalidate() }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        host.addSubview(surface.view)
        surface.view.frame.origin = CGPoint(x: 35, y: 80)
        _ = try show(surface)
        let own = try XCTUnwrap(surface.layout)
        let converted = try XCTUnwrap(surface.layout(in: host))
        XCTAssertEqual(converted.bodyFrame, own.bodyFrame.offsetBy(dx: 35, dy: 80))
        XCTAssertEqual(converted.headerFrame, own.headerFrame?.offsetBy(dx: 35, dy: 80))
        try surface.updateMetrics(.init())
        surface.view.layoutIfNeeded()
        XCTAssertNil(surface.layout?.headerFrame)
        XCTAssertNil(surface.layout?.footerFrame)
        XCTAssertEqual(surface.headerView?.isHidden, true)
        XCTAssertEqual(surface.footerView?.isHidden, true)
        XCTAssertEqual(surface.currentBodyController?.view.bounds.size, CGSize(width: 320, height: 480))
    }

    func testLayoutNotificationsCoalesceAndPermitPageFactoryAfterLayout() async throws {
        let surface = try surface()
        defer { surface.invalidate() }
        var snapshots: [ReaderSurfaceLayout] = []
        surface.onLayoutChange = { [weak surface, self] layout in
            snapshots.append(layout)
            guard let surface, surface.pagedReader == nil else { return }
            do { _ = try surface.showPaged(page: page("a"), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))) }
            catch { XCTFail("布局回调应可创建页面：\(error)") }
        }
        try surface.updateMetrics(.init(headerHeight: 20, footerHeight: 10))
        try surface.updateMetrics(.init(headerHeight: 44, footerHeight: 22))
        await drain()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first, surface.layout)
        XCTAssertNotNil(surface.currentBodyController)
        let count = snapshots.count
        surface.view.setNeedsLayout(); surface.view.layoutIfNeeded()
        await drain()
        XCTAssertEqual(snapshots.count, count)
    }

    func testChromeResizeCancelsTransitionAndRejectsOldReplacementEvenWithSameOuterSize() throws {
        let surface = try surface(.wholePage)
        defer { surface.invalidate() }
        let paged = try show(surface)
        let oldBinding = paged.currentPageBinding
        let oldSize = paged.view.bounds.size
        XCTAssertTrue(try paged.beginInteractiveTurn(.next))
        var results: [PageReplacementOutcome] = []
        _ = try surface.submitCurrentPage(page("a", version: 1), expectedBinding: oldBinding) { results.append($0) }
        try surface.updateMetrics(.init(headerHeight: 80, footerHeight: 30))
        paged.installPendingCurrentPageIfIdle()
        XCTAssertFalse(paged.isTransitioning)
        XCTAssertEqual(paged.view.bounds.size, oldSize)
        XCTAssertNotEqual(paged.currentPageBinding, oldBinding)
        XCTAssertEqual(results, [.rejected(.staleWindow)])
        XCTAssertEqual(surface.currentBodyController?.view.bounds.size, surface.layout?.bodyFrame.size)
        XCTAssertThrowsError(try surface.replaceCurrentPage(page("a", version: 1), expectedBinding: oldBinding))
    }

    func testOriginalBodyRemainsInteractiveAfterReplacementAndInvalidatedLayoutCallbackIsDropped() async throws {
        let surface = try surface()
        let paged = try show(surface)
        let next = page("a", version: 1)
        var replacements = 0
        surface.onPageReplacement = { _ in replacements += 1 }
        _ = try surface.replaceCurrentPage(next, expectedBinding: paged.currentPageBinding)
        XCTAssertEqual(replacements, 1)
        XCTAssertTrue(surface.currentBodyController === next.controller)
        XCTAssertTrue(next.controller.view.isUserInteractionEnabled)
        surface.onLayoutChange = { _ in XCTFail("退出后不能交付旧布局") }
        surface.invalidate()
        await drain()
        XCTAssertThrowsError(try surface.updateMetrics(.init()))
    }

    func testInvalidAndUnsupportedInputsKeepExistingRenderer() throws {
        let surface = try surface()
        defer { surface.invalidate() }
        let paged = try show(surface)
        let layout = surface.layout
        XCTAssertThrowsError(try surface.updateMetrics(.init(headerHeight: .nan)))
        XCTAssertEqual(surface.layout, layout)
        XCTAssertThrowsError(try surface.showPaged(page: page("c"), configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal))))
        XCTAssertTrue(surface.pagedReader === paged)
        XCTAssertTrue(paged.isActive)
        let occupied = UIViewController(); let owner = UIViewController(); owner.addChild(occupied)
        XCTAssertThrowsError(try surface.showPaged(page: page("c", controller: occupied), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))))
        XCTAssertTrue(surface.pagedReader === paged)
        let moving = try self.surface(.contentAndChrome)
        defer { moving.invalidate() }
        XCTAssertThrowsError(try moving.showContinuous(window: ContinuousWindow(items: []), provider: Provider()))
    }

    func testDuplicateDecorationsAreRejectedAndCandidateDoesNotLoseOwnership() throws {
        let shared = UILabel()
        let decorations = ReaderSurfaceDecorations(makeHeader: { _ in shared }, makeFooter: { _ in shared })
        let surface = try surface(decorations: decorations)
        defer { surface.invalidate() }
        let candidate = page("a")
        XCTAssertThrowsError(try surface.showPaged(page: candidate, configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))))
        XCTAssertNil(candidate.controller.parent)
        XCTAssertNil(shared.superview)
    }

    func testCandidateLoadOrDecorationInsertInvalidationCannotLeaveOrphans() throws {
        for stage in 0..<2 {
            var reference: ReaderSurfaceViewController?
            let header = HookView()
            let surface = try self.surface(decorations: .init(makeHeader: { _ in header }))
            reference = surface
            let candidate = HookPage()
            if stage == 0 { candidate.onLoad = { [weak reference] in reference?.invalidate() } }
            else { header.onInsert = { [weak reference] in reference?.invalidate() } }
            XCTAssertThrowsError(try surface.showPaged(page: page("a", controller: candidate), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))))
            XCTAssertNil(candidate.parent)
            XCTAssertNil(candidate.viewIfLoaded?.superview)
            XCTAssertNil(header.superview)
        }
    }

    func testSurfaceAndDecorationsReleaseWithoutObserverCycle() throws {
        let weakSurface = WeakObject<ReaderSurfaceViewController>(nil)
        let weakHeader = WeakObject<UIView>(nil)
        try autoreleasepool {
            let surface = try surface()
            weakSurface.value = surface
            _ = try show(surface)
            weakHeader.value = surface.headerView
            surface.invalidate()
        }
        XCTAssertNil(weakSurface.value)
        XCTAssertNil(weakHeader.value)
    }
}
#endif
