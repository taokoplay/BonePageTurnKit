#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderSurfaceExitTests: XCTestCase {
    private final class Provider: ContinuousContentProvider {
        var onUnbind: (() -> Void)?
        func makeContentView(reuseIdentifier: String) -> UIView { UIView() }
        func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {}
        func unbind(_ view: UIView, binding: PageViewBinding) { onUnbind?() }
    }

    /// - Returns: 已布局的外壳；不引入安全区或装饰尺寸差异。
    private func makeSurface() throws -> ReaderSurfaceViewController {
        let surface = try ReaderSurfaceViewController(viewportPolicy: nil)
        surface.loadViewIfNeeded()
        surface.view.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        surface.view.setNeedsLayout()
        surface.view.layoutIfNeeded()
        return surface
    }

    /// - Parameters: id: 正文身份；version: 原位替换版本。
    /// - Returns: 未挂载的正文页。
    private func page(_ id: String = "a", version: UInt64 = 0) -> PageContent {
        .init(identity: .init(sourceID: "book", unitID: id, contentVersion: version),
              controller: UIViewController(), readingInfo: .init(after: .available))
    }

    /// - Parameter state: 正文准备状态。
    /// - Returns: 可滚动且尚未到全书末尾的窗口。
    private func content(_ state: ContinuousContentState = .ready) throws -> ContinuousWindow {
        try ContinuousWindow(items: [.init(identity: .init(sourceID: "book", unitID: "a"),
                                           sectionID: "chapter", extent: 2000, state: state)], after: .available)
    }

    /// - Parameter surface: 接收分页的外壳。
    /// - Returns: 使用手动时钟、支持相邻页的 renderer。
    private func showPaged(_ surface: ReaderSurfaceViewController) throws -> PagedReaderViewController {
        surface.pageProvider = { _, _, _ in
            .page(.init(identity: .init(sourceID: "book", unitID: "b"), controller: UIViewController()))
        }
        let reader = try surface.showPaged(page: page(), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return reader
    }

    /// - Parameter surface: 接收真实可见生命周期的外壳。
    /// - Returns: 由用例持有并关闭的窗口。
    private func mount(_ surface: ReaderSurfaceViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        window.rootViewController = surface
        window.isHidden = false
        surface.view.frame = window.bounds
        surface.view.setNeedsLayout()
        surface.view.layoutIfNeeded()
        return window
    }

    /// - Parameter window: 用例窗口；解除可见性与根控制器，不返回值。
    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// 无参数和返回值；等待此前排入主队列的退出及布局动作。
    private func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// - Parameter surface: 已完成退出的外壳；检查所有宿主回调清理，不返回值。
    private func assertCallbacksCleared(_ surface: ReaderSurfaceViewController) {
        XCTAssertNil(surface.onExitFinalized)
        XCTAssertNil(surface.onLayoutChange)
        XCTAssertNil(surface.onLayoutError)
        XCTAssertNil(surface.pageProvider)
        XCTAssertNil(surface.onTransition)
        XCTAssertNil(surface.onReadingStatus)
        XCTAssertNil(surface.onUnavailable)
        XCTAssertNil(surface.onPageReplacement)
        XCTAssertNil(surface.onContentError)
    }

    func testPagedCancelPreservesOtherReasonsAndUserPause() throws {
        let surface = try makeSurface()
        let reader = try showPaged(surface)
        let window = mount(surface)
        defer { surface.invalidate(); close(window) }
        try reader.startAutomaticReading()
        XCTAssertEqual(reader.automaticReadingState, .running)
        var transitions: [PageTransitionEvent] = []
        surface.onTransition = { transitions.append($0) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        let token = try surface.beginExit()
        XCTAssertEqual(try surface.beginExit(), token)
        XCTAssertTrue(surface.isExitInProgress)
        XCTAssertTrue(surface.isActive)
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertEqual(reader.currentPage.identity.unitID, "a")
        guard case .willBegin(let transaction) = transitions.first else { return XCTFail("缺少翻页开始事件") }
        XCTAssertEqual(transitions, [.willBegin(transaction), .didSettle(transaction, completed: false)])
        XCTAssertEqual(reader.automaticReadingState, .paused)
        surface.setSuspended(true, reason: "menu")
        surface.setSuspended(true, reason: "selection")
        XCTAssertTrue(surface.cancelExit(token))
        XCTAssertFalse(surface.cancelExit(token))
        XCTAssertFalse(surface.isExitInProgress)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        surface.setSuspended(false, reason: "menu")
        XCTAssertEqual(reader.automaticReadingState, .paused)
        surface.setSuspended(false, reason: "selection")
        XCTAssertEqual(reader.automaticReadingState, .running)
        reader.pauseAutomaticReading()
        XCTAssertTrue(surface.cancelExit(try surface.beginExit()))
        XCTAssertEqual(reader.automaticReadingState, .paused)
    }

    func testContinuousCancelPreservesOtherReasonsAndUserPause() throws {
        let surface = try makeSurface()
        let provider = Provider()
        let reader = try surface.showContinuous(window: content(), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(surface)
        defer { surface.invalidate(); close(window) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        reader.advanceAutomaticReading(elapsed: 0.1)
        let offset = reader.scrollView.contentOffset.y
        let token = try surface.beginExit()
        XCTAssertEqual(try surface.beginExit(), token)
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertFalse(reader.scrollView.isScrollEnabled)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(reader.scrollView.contentOffset.y, offset)
        surface.setSuspended(true, reason: "menu")
        surface.setSuspended(true, reason: "selection")
        XCTAssertTrue(surface.cancelExit(token))
        surface.setSuspended(false, reason: "menu")
        XCTAssertEqual(reader.automaticReadingState, .paused)
        XCTAssertFalse(reader.scrollView.isScrollEnabled)
        surface.setSuspended(false, reason: "selection")
        XCTAssertEqual(reader.automaticReadingState, .running)
        XCTAssertTrue(reader.scrollView.isScrollEnabled)
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertGreaterThan(reader.scrollView.contentOffset.y, offset)
        reader.pauseAutomaticReading()
        XCTAssertTrue(surface.cancelExit(try surface.beginExit()))
        XCTAssertEqual(reader.automaticReadingState, .paused)
    }

    func testOldAndForeignTokensCannotFinishCurrentTransaction() throws {
        let first = try makeSurface()
        let second = try makeSurface()
        let reader = try showPaged(first)
        let otherReader = try showPaged(second)
        defer { first.invalidate(); second.invalidate() }
        let old = try first.beginExit()
        XCTAssertTrue(first.cancelExit(old))
        let current = try first.beginExit()
        let foreign = try second.beginExit()
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(first.cancelExit(old))
        XCTAssertFalse(first.finishExit(old))
        XCTAssertFalse(first.cancelExit(foreign))
        XCTAssertFalse(first.finishExit(foreign))
        XCTAssertFalse(second.finishExit(current))
        XCTAssertFalse(second.cancelExit(current))
        XCTAssertEqual(try first.beginExit(), current)
        var completed: [ReaderExitToken] = []
        first.onExitFinalized = { completed.append($0) }
        XCTAssertTrue(first.finishExit(current))
        XCTAssertEqual(completed, [current])
        XCTAssertFalse(first.finishExit(current))
        XCTAssertFalse(first.cancelExit(current))
        XCTAssertFalse(first.isActive)
        XCTAssertFalse(first.isExitInProgress)
        XCTAssertFalse(reader.isActive)
        XCTAssertThrowsError(try first.beginExit()) { XCTAssertEqual($0 as? ReaderSurfaceError, .inactive) }
        XCTAssertTrue(second.isActive)
        XCTAssertTrue(otherReader.isActive)
        XCTAssertTrue(second.cancelExit(foreign))
    }

    func testPagedFinalizationClearsCallbacksBeforeNotifyingAndCannotReenter() throws {
        let surface = try makeSurface()
        let reader = try showPaged(surface)
        surface.onLayoutChange = { _ in }
        surface.onLayoutError = { _ in }
        surface.onTransition = { _ in }
        surface.onReadingStatus = { _ in }
        surface.onUnavailable = { _, _ in }
        surface.onPageReplacement = { _ in }
        surface.onContentError = { _ in }
        let token = try surface.beginExit()
        var finalized = 0
        surface.onExitFinalized = { [weak surface, self] completed in
            guard let surface else { return XCTFail("完成时外壳应仍存活") }
            finalized += 1
            XCTAssertEqual(completed, token)
            XCTAssertFalse(surface.isActive)
            XCTAssertFalse(surface.isExitInProgress)
            XCTAssertFalse(reader.isActive)
            assertCallbacksCleared(surface)
            XCTAssertFalse(surface.finishExit(completed))
            XCTAssertFalse(surface.cancelExit(completed))
            do { _ = try surface.beginExit(); XCTFail("失效外壳不能开始退出") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
            do { _ = try surface.showPaged(page: page(), configuration: reader.configuration); XCTFail("失效外壳不能安装页面") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
            surface.invalidate()
        }
        XCTAssertTrue(surface.finishExit(token))
        XCTAssertEqual(finalized, 1)
        XCTAssertFalse(surface.finishExit(token))
    }

    func testContinuousNotificationExitSavesBeforeInvalidationAndFinalizesOnce() async throws {
        let surface = try makeSurface()
        let provider = Provider()
        let reader = try surface.showContinuous(window: content(), provider: provider)
        reader.usesDisplayLinkForAutomaticReading = false
        let window = mount(surface)
        defer { surface.invalidate(); close(window) }
        try reader.startAutomaticReading(pointsPerSecond: 100)
        var token: ReaderExitToken?
        var events: [String] = []
        var saves: [ContinuousAnchor] = []
        reader.onStableAnchor = { [weak surface, weak reader] anchor in
            guard let surface, let reader, let token else { return XCTFail("缺少退出上下文") }
            XCTAssertTrue(surface.isActive)
            XCTAssertTrue(surface.isExitInProgress)
            XCTAssertTrue(reader.isActive)
            XCTAssertEqual(try? surface.beginExit(), token)
            XCTAssertFalse(surface.cancelExit(token))
            XCTAssertFalse(surface.finishExit(token))
            saves.append(anchor)
            events.append("saved")
        }
        surface.onExitFinalized = { [weak surface, weak reader, self] completed in
            guard let surface, let reader else { return XCTFail("完成前生命周期被提前释放") }
            XCTAssertEqual(completed, token)
            XCTAssertFalse(surface.isActive)
            XCTAssertFalse(surface.isExitInProgress)
            XCTAssertFalse(reader.isActive)
            XCTAssertNil(reader.onStableAnchor)
            assertCallbacksCleared(surface)
            XCTAssertEqual(saves.count, 1)
            events.append("finalized")
        }
        reader.onVisibleAnchor = { [weak surface, weak reader] anchor in
            guard anchor.offsetInItem > 0, token == nil, let surface, let reader else { return }
            do {
                let exit = try surface.beginExit()
                token = exit
                XCTAssertTrue(surface.finishExit(exit))
                XCTAssertTrue(surface.isActive)
                XCTAssertTrue(reader.isActive)
                XCTAssertTrue(surface.isExitInProgress)
                XCTAssertFalse(surface.finishExit(exit))
                events.append("accepted")
            } catch { XCTFail("退出请求失败：\(error)") }
        }
        reader.advanceAutomaticReading(elapsed: 0.1)
        XCTAssertEqual(events, ["accepted"])
        XCTAssertTrue(surface.isActive)
        await drain()
        XCTAssertEqual(events, ["accepted", "saved", "finalized"])
        XCTAssertEqual(saves.first?.offsetInItem, 10)
        let exit = try XCTUnwrap(token)
        XCTAssertFalse(surface.finishExit(exit))
        await drain()
        XCTAssertEqual(events, ["accepted", "saved", "finalized"])
    }

    func testCancelCallbackCannotCreateOrCompleteAnotherTransaction() throws {
        let surface = try makeSurface()
        let provider = Provider()
        let reader = try surface.showContinuous(window: content(), provider: provider)
        defer { surface.invalidate() }
        let token = try surface.beginExit()
        var callbacks = 0
        reader.onInteractionIdle = { [weak surface] in
            guard let surface else { return }
            callbacks += 1
            do { _ = try surface.beginExit(); XCTFail("取消回调不能开始另一笔退出") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .interactionInProgress) }
            XCTAssertFalse(surface.finishExit(token))
            XCTAssertFalse(surface.cancelExit(token))
            do { try surface.updateMetrics(.init(headerHeight: 20)); XCTFail("取消回调不能修改布局") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .interactionInProgress) }
        }
        XCTAssertTrue(surface.cancelExit(token))
        XCTAssertEqual(callbacks, 1)
        reader.onInteractionIdle = nil
        let next = try surface.beginExit()
        XCTAssertNotEqual(next, token)
        XCTAssertFalse(surface.finishExit(token))
        XCTAssertEqual(try surface.beginExit(), next)
        XCTAssertTrue(surface.finishExit(next))
        XCTAssertFalse(surface.isActive)
    }

    func testCancelCallbackInvalidationCannotReactivateSurface() throws {
        let surface = try makeSurface()
        let reader = try showPaged(surface)
        let window = mount(surface)
        defer { surface.invalidate(); close(window) }
        try reader.startAutomaticReading()
        let token = try surface.beginExit()
        var resumed = 0
        surface.onExitFinalized = { _ in XCTFail("手动失效不能报告确认退出") }
        reader.onAutomaticReadingStateChange = { [weak surface] state in
            guard state == .running, let surface else { return }
            resumed += 1
            surface.invalidate()
            do { _ = try surface.beginExit(); XCTFail("失效外壳不能开始退出") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
            XCTAssertFalse(surface.cancelExit(token))
            XCTAssertFalse(surface.finishExit(token))
        }
        XCTAssertTrue(surface.cancelExit(token))
        XCTAssertEqual(resumed, 1)
        XCTAssertFalse(surface.isActive)
        XCTAssertFalse(surface.isExitInProgress)
        XCTAssertFalse(reader.isActive)
        assertCallbacksCleared(surface)
    }

    func testBeginCallbackInvalidationDoesNotReturnUsableToken() throws {
        let surface = try makeSurface()
        let reader = try showPaged(surface)
        let window = mount(surface)
        defer { surface.invalidate(); close(window) }
        try reader.startAutomaticReading()
        reader.onAutomaticReadingStateChange = { [weak surface] state in
            if state == .paused { surface?.invalidate() }
        }
        do { _ = try surface.beginExit(); XCTFail("失效外壳不能开始退出") }
        catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
        XCTAssertFalse(surface.isActive)
        XCTAssertFalse(surface.isExitInProgress)
        XCTAssertFalse(reader.isActive)
    }

    func testRendererTeardownCannotStartNewExitAndManualInvalidationWins() throws {
        for invalidateDuringTeardown in [false, true] {
            let surface = try makeSurface()
            let provider = Provider()
            let reader = try surface.showContinuous(window: content(), provider: provider)
            defer { surface.invalidate() }
            let token = try surface.beginExit()
            var unbound = 0
            var finalized = 0
            surface.onExitFinalized = { _ in finalized += 1 }
            provider.onUnbind = { [weak surface] in
                guard let surface else { return }
                unbound += 1
                // 此时底层已清掉自己的令牌，但外壳必须维持正在完成的那笔退出。
                XCTAssertTrue(surface.isActive)
                XCTAssertTrue(surface.isExitInProgress)
                XCTAssertEqual(try? surface.beginExit(), token)
                XCTAssertFalse(surface.cancelExit(token))
                XCTAssertFalse(surface.finishExit(token))
                do { try surface.updateViewportPolicy(nil); XCTFail("清理期间不能修改布局") }
                catch { XCTAssertEqual(error as? ReaderSurfaceError, .interactionInProgress) }
                if invalidateDuringTeardown { surface.invalidate() }
            }
            XCTAssertTrue(surface.finishExit(token))
            XCTAssertEqual(unbound, 1)
            XCTAssertEqual(finalized, invalidateDuringTeardown ? 0 : 1)
            XCTAssertFalse(surface.isActive)
            XCTAssertFalse(surface.isExitInProgress)
            XCTAssertFalse(reader.isActive)
            assertCallbacksCleared(surface)
        }
    }

    func testInvalidationInsideFinalSaveSuppressesFinalizedCallback() throws {
        let surface = try makeSurface()
        let provider = Provider()
        let reader = try surface.showContinuous(window: content(), provider: provider)
        reader.scrollView.contentOffset.y = 80
        let token = try surface.beginExit()
        var saves = 0
        surface.onExitFinalized = { _ in XCTFail("保存回调中的手动失效应覆盖最终完成") }
        reader.onStableAnchor = { [weak surface, weak reader] _ in
            guard let surface, let reader else { return XCTFail("保存前不能释放") }
            saves += 1
            XCTAssertTrue(surface.isActive)
            XCTAssertTrue(reader.isActive)
            surface.invalidate()
            XCTAssertFalse(surface.finishExit(token))
            do { _ = try surface.beginExit(); XCTFail("失效外壳不能开始退出") }
            catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
        }
        XCTAssertTrue(surface.finishExit(token))
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(surface.isActive)
        XCTAssertFalse(reader.isActive)
        assertCallbacksCleared(surface)
    }

    func testExitRejectsAllSurfaceMutationsForBothRenderers() throws {
        for useContinuous in [false, true] {
            let surface = try makeSurface()
            let paged = try showPaged(surface)
            let binding = paged.currentPageBinding
            let provider = Provider()
            if useContinuous { _ = try surface.showContinuous(window: content(), provider: provider) }
            defer { surface.invalidate() }
            let token = try surface.beginExit()
            let previousLayout = surface.layout
            let previousMetrics = surface.metrics
            let candidate = page("a", version: 1)
            let configuration = PageTurnConfiguration(presentation: .paged(effect: .slide, axis: .horizontal))
            let operations: [() throws -> Void] = [
                { _ = try surface.showPaged(page: candidate, configuration: configuration) },
                { _ = try surface.showContinuous(window: self.content(), provider: provider) },
                { _ = try surface.replaceCurrentPage(candidate, expectedBinding: binding) },
                { _ = try surface.submitCurrentPage(candidate, expectedBinding: binding) { _ in XCTFail("拒绝提交不能产生票据终态") } },
                { try surface.updateMetrics(.init(headerHeight: 40)) },
                { try surface.updateViewportPolicy(.init(prefersSpread: false)) }
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? ReaderSurfaceError, .interactionInProgress) }
            }
            XCTAssertNil(candidate.controller.parent)
            XCTAssertEqual(surface.layout, previousLayout)
            XCTAssertEqual(surface.metrics, previousMetrics)
            XCTAssertNil(surface.viewportPolicy)
            XCTAssertTrue(surface.cancelExit(token))
            try surface.updateMetrics(.init(headerHeight: 20))
            XCTAssertEqual(surface.metrics.headerHeight, 20)
        }
    }

    func testLayoutNotificationResumesAfterCancelAndIsDroppedAfterFinish() async throws {
        let surface = try makeSurface()
        _ = try showPaged(surface)
        var layouts: [ReaderSurfaceLayout] = []
        surface.onLayoutChange = { layouts.append($0) }
        let token = try surface.beginExit()
        await drain()
        XCTAssertTrue(layouts.isEmpty)
        XCTAssertTrue(surface.cancelExit(token))
        await drain()
        XCTAssertEqual(layouts, [try XCTUnwrap(surface.layout)])
        try surface.updateMetrics(.init(headerHeight: 20))
        XCTAssertTrue(surface.finishExit(try surface.beginExit()))
        await drain()
        XCTAssertEqual(layouts.count, 1)
        assertCallbacksCleared(surface)
    }

    func testManualInvalidationOverridesQueuedFinalizationAndReleasesSurface() async throws {
        let provider = Provider()
        weak var weakSurface: ReaderSurfaceViewController?
        weak var weakReader: ContinuousReaderViewController?
        var saves = 0
        var finalizations = 0
        var accepted = false
        try autoreleasepool {
            let surface = try makeSurface()
            let reader = try surface.showContinuous(window: content(), provider: provider)
            weakSurface = surface
            weakReader = reader
            reader.onStableAnchor = { _ in saves += 1 }
            surface.onExitFinalized = { _ in finalizations += 1 }
            reader.onVisibleAnchor = { [weak surface] _ in
                guard !accepted, let surface else { return }
                do {
                    let token = try surface.beginExit()
                    accepted = surface.finishExit(token)
                    XCTAssertTrue(surface.isActive)
                    surface.invalidate()
                    XCTAssertFalse(surface.isActive)
                    XCTAssertFalse(surface.isExitInProgress)
                    do { _ = try surface.beginExit(); XCTFail("失效外壳不能开始退出") }
                    catch { XCTAssertEqual(error as? ReaderSurfaceError, .inactive) }
                    XCTAssertFalse(surface.finishExit(token))
                } catch { XCTFail("退出请求失败：\(error)") }
            }
            reader.scrollView.contentOffset.y = 80
            reader.scrollViewDidScroll(reader.scrollView)
            XCTAssertTrue(accepted)
            assertCallbacksCleared(surface)
        }
        XCTAssertNil(weakSurface, "手动失效须解除等待完成时的强引用")
        await drain()
        XCTAssertNil(weakReader)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(finalizations, 0)
        withExtendedLifetime(provider) {}
    }

    func testQueuedExitRetainsSurfaceAndRendererUntilSaveAndThenReleasesBoth() async throws {
        let provider = Provider()
        weak var weakSurface: ReaderSurfaceViewController?
        weak var weakReader: ContinuousReaderViewController?
        var events: [String] = []
        var accepted = false
        try autoreleasepool {
            let surface = try makeSurface()
            let reader = try surface.showContinuous(window: content(), provider: provider)
            weakSurface = surface
            weakReader = reader
            reader.onStableAnchor = { [weak surface, weak reader] _ in
                XCTAssertEqual(surface?.isActive, true)
                XCTAssertEqual(surface?.isExitInProgress, true)
                XCTAssertEqual(reader?.isActive, true)
                events.append("saved")
            }
            surface.onExitFinalized = { [weak surface, weak reader] _ in
                XCTAssertEqual(surface?.isActive, false)
                XCTAssertEqual(reader?.isActive, false)
                events.append("finalized")
            }
            reader.onVisibleAnchor = { [weak surface] _ in
                guard !accepted, let surface else { return }
                do { accepted = surface.finishExit(try surface.beginExit()) }
                catch { XCTFail("退出请求失败：\(error)") }
            }
            reader.scrollView.contentOffset.y = 80
            reader.scrollViewDidScroll(reader.scrollView)
            XCTAssertTrue(accepted)
        }
        XCTAssertNotNil(weakSurface)
        XCTAssertNotNil(weakReader)
        XCTAssertTrue(events.isEmpty)
        await drain()
        XCTAssertEqual(events, ["saved", "finalized"])
        XCTAssertNil(weakSurface)
        XCTAssertNil(weakReader)
        withExtendedLifetime(provider) {}
    }

    func testUnreadyContinuousPositionDoesNotInventFinalSave() throws {
        let surface = try makeSurface()
        let provider = Provider()
        let reader = try surface.showContinuous(window: content(.loading), provider: provider)
        var finalizations = 0
        reader.onStableAnchor = { _ in XCTFail("加载占位不能生成可保存位置") }
        surface.onExitFinalized = { _ in finalizations += 1 }
        XCTAssertTrue(surface.finishExit(try surface.beginExit()))
        XCTAssertEqual(finalizations, 1)
        XCTAssertFalse(surface.isActive)
        XCTAssertFalse(reader.isActive)
    }
}
#endif
