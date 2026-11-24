import UIKit
import BonePageTurnKit

@MainActor
extension FullScreenReaderDemoViewController {
    /// 准备完整新场景后才移除旧场景；返回明确错误供设置页保持草稿。
    /// - Parameters: value: 新配置；sourcePage: 指定源页；unitIndex: 指定当前样本展示单元。
    /// - Returns: nil 表示已安装，错误字符串表示原页面仍保留。
    func install(_ value: FullScreenDemoSettings, sourcePage: Int? = nil, unitIndex: Int? = nil) -> String? {
        guard !installing else { return "页面正在准备，请稍后再试" }
        guard scene?.exitToken == nil else { return "请先取消或确认当前退出事务" }
        if let error = value.validationMessage() { return error }
        installing = true
        defer { installing = false }
        let old = scene
        let oldUnit = old.flatMap { $0.factory.units.indices.contains($0.focusedUnit) ? $0.factory.units[$0.focusedUnit] : nil }
        let oldFraction: Double = {
            guard let reader = old?.continuous, let anchor = reader.visibleAnchor,
                  let item = reader.window.item(withID: anchor.identity.unitID) else { return 0 }
            return anchor.offsetInItem / item.extent
        }()
        let source = sourcePage ?? oldUnit?.sourceIndex ?? 0
        let point = oldUnit?.slice.map { CGPoint(x: $0.normalizedRect.midX, y: $0.normalizedRect.midY) }
        layoutVersion &+= 1
        let factory = FullScreenDemoContentFactory(settings: value, layoutVersion: layoutVersion)
        guard factory.count > 0 else { return "没有可展示的内容" }
        let focus = min(max(0, unitIndex ?? factory.index(forSourcePage: source, point: point)), factory.count - 1)
        var candidate: FullScreenDemoScene?
        do {
            let layout = try effectiveLayout(for: value)
            let surface: ReaderSurfaceViewController?
            let container: PageTurnViewController?
            if layout == .single {
                surface = try ReaderSurfaceViewController(metrics: value.surfaceMetrics, motion: value.sdkMotion,
                    decorations: decorations(factory: factory), viewportPolicy: viewportPolicy(for: value),
                    backgroundColor: FullScreenDemoContentFactory.paperColor)
                container = nil
            } else {
                surface = nil; container = PageTurnViewController()
                container?.adaptiveLayoutPolicy = viewportPolicy(for: value)
            }
            let next = FullScreenDemoScene(settings: value, factory: factory, layout: layout, surface: surface, container: container, focus: focus)
            candidate = next
            addChild(next.root)
            next.root.view.frame = readerMount.bounds
            next.root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            next.root.view.backgroundColor = FullScreenDemoContentFactory.paperColor
            readerMount.insertSubview(next.root.view, at: 0)
            next.root.didMove(toParent: self)
            next.root.view.setNeedsLayout(); next.root.view.layoutIfNeeded()
            if let surface {
                guard let geometry = surface.layout, geometry.bodyFrame.width > 8, geometry.bodyFrame.height > 8 else {
                    throw ReaderSurfaceError.invalidBounds
                }
                next.bodyWidth = geometry.bodyFrame.width
                if value.effect == "continuous" {
                    next.lower = max(0, focus - 1); next.upper = min(factory.count, focus + max(2, value.loadBatch))
                    let window = try window(for: next)
                    let target = try windowItem(window, index: focus)
                    let offset = min(target.extent - 0.001, max(0, target.extent * oldFraction))
                    let continuous = try surface.showContinuous(window: window, provider: next,
                        anchor: .init(identity: target.identity, offsetInItem: offset), fillPolicy: value.fillPolicy())
                    continuous.view.accessibilityIdentifier = "reader-continuous"
                } else {
                    _ = try surface.showPaged(page: factory.page(at: focus), configuration: value.pageConfiguration(layout: .single))
                }
            } else if let container {
                let spread = try ReaderSpreadLayout(pageCount: factory.count, firstPageIsCover: value.firstPageIsCover)
                let group = try spread.spreadIndex(containingPage: focus)
                _ = try container.showPaged(page: spreadPage(for: next, group: group), configuration: value.pageConfiguration(layout: .spread))
            }
            next.root.view.layoutIfNeeded()
            if let paged = next.paged { configure(paged: paged, scene: next) }
            configureCallbacks(for: next)
            scene = next; settings = value
            old?.invalidate()
            if let old { old.root.willMove(toParent: nil); old.root.view.removeFromSuperview(); old.root.removeFromParent() }
            applyAppearance(); installCanvasTap(); applyInteractionControls()
            updateStatus(); updateRevealButton()
            frameMonitor.bind(next.paged)
            next.root.view.accessibilityValue = "\(value.effect)|\(value.axis)|\(layout == .spread ? "spread" : "single")"
            DispatchQueue.main.async { [weak self, weak next] in
                guard let self, let next, self.scene === next else { return }
                self.syncAutomatic()
                if let continuous = next.continuous { try? continuous.resumeContentFilling() }
            }
            return nil
        } catch {
            if let candidate {
                candidate.invalidate(); candidate.root.willMove(toParent: nil)
                candidate.root.view.removeFromSuperview(); candidate.root.removeFromParent()
            }
            return "无法应用这组设置：\(error)"
        }
    }

    /// - Parameters: window: 已准备窗口；index: 展示单元。返回有效项，否则抛出锚点错误。
    private func windowItem(_ window: ContinuousWindow, index: Int) throws -> ContinuousItem {
        guard let item = window.item(withID: String(index)) else { throw PageTurnError.anchorUnavailable }
        return item
    }

    /// 以真实窗口判断单双页；强制双页和 SDK 自适应建议是两个独立选择。
    private func effectiveLayout(for value: FullScreenDemoSettings) throws -> ReaderPageLayout {
        if value.pageLayout == "spread" { return .spread }
        if value.pageLayout != "adaptive" { return .single }
        var environment = ReaderViewportEnvironment.capture(from: view)
        if !value.safeArea {
            environment = .init(bounds: environment.bounds, widthClass: environment.widthClass)
        }
        let policy = ReaderAdaptiveLayoutPolicy(prefersSpread: value.prefersSpread,
            minimumPageWidth: CGFloat(value.minimumPageWidth), minimumPageHeight: CGFloat(value.minimumPageHeight),
            spreadGap: CGFloat(value.spreadGap), horizontalSafeArea: viewportPolicy(for: value)?.horizontalSafeArea ?? .system)
        return try policy.layout(for: environment).pageLayout
    }

    /// 全屏窗口不随工具栏改变；策略仅控制可读内容如何避开硬件和安全区。
    private func viewportPolicy(for value: FullScreenDemoSettings) -> ReaderAdaptiveLayoutPolicy? {
        guard value.safeArea else { return nil }
        var horizontal = ReaderHorizontalSafeAreaPolicy.system
        #if compiler(>=6.4)
        if #available(iOS 27.1, *), value.reservedRegions { horizontal = .reservedRegions }
        #endif
        return .init(prefersSpread: false, minimumPageWidth: CGFloat(value.minimumPageWidth), minimumPageHeight: CGFloat(value.minimumPageHeight),
                     spreadGap: CGFloat(value.spreadGap), horizontalSafeArea: horizontal)
    }

    /// - Parameter factory: 本场景的内容来源；每次工厂创建独立装饰视图。
    private func decorations(factory: FullScreenDemoContentFactory) -> ReaderSurfaceDecorations {
        ReaderSurfaceDecorations(makeHeader: { context in
            let label = UILabel(); label.font = .preferredFont(forTextStyle: .caption1); label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel; label.textAlignment = .center
            label.text = FullScreenDemoContentFactory.articleTitle; label.accessibilityIdentifier = "reader-header"
            return label
        }, makeFooter: { _ in
            let label = UILabel(); label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabel; label.textAlignment = .center; label.accessibilityIdentifier = "reader-footer"
            return label
        }, makeBackground: { _ in factory.makeBackground() }, update: { views, context in
            let index = Int(context.identity?.unitID ?? "") ?? 0
            (views.header as? UILabel)?.text = factory.units.indices.contains(index) ? factory.units[index].title : FullScreenDemoContentFactory.articleTitle
            let total: String
            switch context.readingInfo.pagination.book?.total {
            case .exact(let count): total = String(count)
            case .estimated(let count): total = "约\(count)"
            default: total = "—"
            }
            let current = context.readingInfo.pagination.book?.current.map(String.init) ?? "—"
            (views.footer as? UILabel)?.text = "\(current) / \(total)"
        })
    }

    /// 真正的双页仍直接交给 SDK；每一侧以单页 Surface 组合装饰，内层驱动保持暂停。
    /// - Parameters: scene: 当前场景；group: 双页组号；override: 原位回填的新工厂。
    func spreadPage(for scene: FullScreenDemoScene, group: Int, override: FullScreenDemoContentFactory? = nil) throws -> PageContent {
        let factory = override ?? scene.factory, settings = scene.settings
        let grouping = try ReaderSpreadLayout(pageCount: factory.count, firstPageIsCover: settings.firstPageIsCover)
        let indices = try grouping.spread(at: group)
        let viewport = scene.container?.adaptiveLayout?.contentFrame ?? scene.root.view.bounds
        let horizontal = settings.axis == "horizontal"
        let gap = CGFloat(settings.spreadGap)
        let size = horizontal ? CGSize(width: (viewport.width - gap) / 2, height: viewport.height)
                              : CGSize(width: viewport.width, height: (viewport.height - gap) / 2)
        guard size.width > 8, size.height > 8 else { throw PageTurnError.invalidPageLayout }
        func side(_ index: Int) throws -> PageContent {
            let surface = try ReaderSurfaceViewController(metrics: settings.surfaceMetrics, motion: .wholePage,
                decorations: decorations(factory: factory), viewportPolicy: nil, backgroundColor: FullScreenDemoContentFactory.paperColor)
            surface.view.frame = CGRect(origin: .zero, size: size); surface.view.layoutIfNeeded()
            let body = try factory.page(at: index)
            _ = try surface.showPaged(page: body, configuration: .init(presentation: .paged(effect: .none, axis: .horizontal)))
            surface.setSuspended(true, reason: "spread-parent-owns-input")
            return .init(identity: body.identity, controller: surface, readingInfo: body.readingInfo)
        }
        let first = try indices.first.map(side), second = try indices.second.map(side)
        let spread = try PageSpreadViewController(first: first, second: second, axis: settings.sdkAxis,
                                                  readingOrder: settings.sdkOrder, gutter: gap)
        spread.view.backgroundColor = FullScreenDemoContentFactory.paperColor
        spread.view.accessibilityIdentifier = "reader-spread"
        let firstIndex = indices.first ?? indices.second ?? 0
        let unit = factory.units[firstIndex]
        let reading = try factory.readingInfo(at: firstIndex)
        return .init(identity: .init(sourceID: unit.identity.sourceID, unitID: "group-\(group)", contentVersion: unit.identity.contentVersion,
                                    layoutVersion: unit.identity.layoutVersion), controller: spread,
                     readingInfo: .init(pagination: reading.pagination, before: group == 0 ? .startOfBook : .available,
                                        after: group == grouping.spreadCount - 1 ? finalBoundary(settings) : .available))
    }

    /// 连接同一套 provider、事务、自动状态与真实滚动内容。
    private func configure(paged: PagedReaderViewController, scene: FullScreenDemoScene) {
        paged.view.backgroundColor = .clear; paged.view.accessibilityIdentifier = "reader-paged"
        paged.tapConfiguration = try? ReaderTapConfiguration(previousEnd: scene.settings.tapTurns ? scene.settings.previousEnd : 0,
                                                             nextStart: scene.settings.tapTurns ? scene.settings.nextStart : 1)
        // 连点时新一笔立刻起播（平移／覆盖）；仿真与拱页仍需重建纸面快照，改为排队＋加速。
        paged.handsOverActiveTransitionOnNewIntent = true
        // 左滑（上一页）带细微斜向折痕（参考主流阅读 App 的轻微弧度），折叠仍自由跟手；
        // 右滑（下一页）点击带系统卷页式的斜向卷曲，拖动仍自由跟手不斜。
        paged.previousTurnSlant = 0.05
        paged.nextTurnSlant = 0.05
        // 空闲预取邻页快照：点击翻页几乎零准备延迟。
        paged.prefetchNeighborSnapshots = true
        paged.shouldHandleTap = { [weak self, weak scene, weak paged] point in
            guard let self, let scene, let paged, self.scene === scene, scene.settings.tapsEnabled else { return false }
            // 处理方在触点开始时固定；宿主先开始翻页后，快照覆盖层会改变当前命中树。
            if self.canvasTapOwner == .host { return false }
            // SDK 已在按下时接管的轻点，即使抬手时正文恢复，也继续由 SDK 处理。
            if self.canvasTapOwner == .unassigned {
                var hit = paged.view.hitTest(point, with: nil)
                while let candidate = hit, candidate !== paged.view {
                    if candidate is UITextView { return false }
                    hit = candidate.superview
                }
            }
            if scene.layout == .spread, let spread = paged.currentPage.controller as? PageSpreadViewController {
                for page in spread.pages where page.controller.view.convert(page.controller.view.bounds, to: paged.view).contains(point) {
                    if let index = Int(page.identity.unitID) { scene.focusedUnit = index }
                }
            }
            if self.controlsVisible { self.setControlsVisible(false); return false }
            if !scene.settings.animated, scene.settings.tapTurns, let tap = paged.tapConfiguration {
                let bounds = paged.view.bounds
                let fraction = scene.settings.axis == "horizontal" ? (point.x - bounds.minX) / bounds.width : (point.y - bounds.minY) / bounds.height
                var action = tap.action(at: Double(fraction))
                if scene.settings.axis == "horizontal", scene.settings.readingOrder == "rtl" {
                    if action == .next { action = .previous } else if action == .previous { action = .next }
                }
                if action == .next || action == .previous {
                    let direction: PageTurnDirection = action == .next ? .next : .previous
                    let binding = paged.currentPageBinding
                    DispatchQueue.main.async { [weak self, weak paged, weak scene] in
                        guard let self, let paged, self.scene === scene, paged.currentPageBinding == binding else { return }
                        _ = try? paged.turn(direction, animated: false)
                    }
                    return false
                }
            }
            return true
        }
        paged.onCenterTap = { [weak self] _ in self?.setControlsVisible(true) }
        paged.shouldBeginPan = { [weak self, weak scene] _ in
            guard let self, let scene else { return false }
            return self.scene === scene && scene.settings.panEnabled && scene.exitToken == nil
        }
        paged.onAutomaticReadingStateChange = { [weak self, weak scene] _ in
            guard let self, self.scene === scene else { return }; self.updateStatus()
        }
        paged.onAutomaticReadingProgress = { [weak self, weak scene] progress in
            guard let self, self.scene === scene else { return }
            self.automaticProgress.progress = Float(progress)
        }
        let provider: (PageItemIdentity, PageTurnDirection) -> PageAvailability = { [weak self, weak scene, weak paged] identity, direction in
            guard let self, let scene, let paged, self.scene === scene else { return .failed }
            if scene.settings.simulateFailure && !scene.ignoreFailure { return .failed }
            if direction == .next && scene.blockedNext { return .waiting }
            do {
                let value: PageContent
                if scene.layout == .spread {
                    let current = Int(identity.unitID.replacingOccurrences(of: "group-", with: "")) ?? 0
                    let next = current + (direction == .next ? 1 : -1)
                    let grouping = try ReaderSpreadLayout(pageCount: scene.factory.count, firstPageIsCover: scene.settings.firstPageIsCover)
                    guard next >= 0, next < grouping.spreadCount else { return .boundary(next < 0 ? .startOfBook : self.finalBoundary(scene.settings)) }
                    value = try self.spreadPage(for: scene, group: next)
                } else {
                    let next = (Int(identity.unitID) ?? 0) + (direction == .next ? 1 : -1)
                    guard next >= 0, next < scene.factory.count else { return .boundary(next < 0 ? .startOfBook : self.finalBoundary(scene.settings)) }
                    value = try scene.factory.page(at: next)
                }
                self.registerContent(in: value.controller, for: paged, scene: scene)
                return .page(value)
            } catch { scene.lastEvent = "内容准备失败：\(error)"; return .failed }
        }
        let transition: (PageTransitionEvent) -> Void = { [weak self, weak scene, weak paged] event in
            guard let self, let scene, let paged, self.scene === scene else { return }
            switch event {
            case .willBegin: scene.lastEvent = "翻页开始"
            case .didCommit:
                if scene.layout == .spread {
                    scene.focusedUnit = paged.visiblePageIdentities.compactMap { Int($0.unitID) }.first ?? scene.focusedUnit
                } else { scene.focusedUnit = Int(paged.currentPage.identity.unitID) ?? scene.focusedUnit }
                scene.lastEvent = "翻页已提交"; self.savePosition()
            case .didSettle(_, let completed): scene.lastEvent = completed ? "翻页完成" : "翻页已取消"
            }
            self.updateStatus()
        }
        let unavailable: (PageTurnDirection, PageAvailability) -> Void = { [weak self, weak scene, weak paged] direction, availability in
            guard let self, let scene, let paged, self.scene === scene else { return }
            if case .waiting = availability { self.wakePagedAfterDelay(scene, reader: paged) }
            else { scene.lastEvent = "供给边界：\(availability)"; self.showNotice(direction == .previous ? "已经到达前向边界" : "当前内容不可继续，可在调试中重试") }
            self.updateStatus()
        }
        if let surface = scene.surface {
            surface.pageProvider = { identity, direction, _ in provider(identity, direction) }
            surface.onTransition = transition; surface.onUnavailable = unavailable
            surface.onReadingStatus = { [weak self, weak scene] _ in if self?.scene === scene { self?.updateStatus() } }
            surface.onPageReplacement = { [weak self, weak scene] _ in
                scene?.lastEvent = "当前页已原位替换"; if self?.scene === scene { self?.updateStatus() }
            }
        } else {
            paged.pageProvider = provider; paged.onTransition = transition; paged.onUnavailable = unavailable
            paged.onReadingStatus = { [weak self, weak scene] _ in if self?.scene === scene { self?.updateStatus() } }
            paged.onPageReplacement = { [weak self, weak scene] _ in
                scene?.lastEvent = "当前页已原位替换"; if self?.scene === scene { self?.updateStatus() }
            }
        }
        registerContent(in: paged.currentPage.controller, for: paged, scene: scene)
    }

    /// 注册文字内滚或图片缩放，使用配置中的边缘交接策略；默认登记不能覆盖自定义参数。
    func registerContent(in controller: UIViewController, for reader: PagedReaderViewController, scene: FullScreenDemoScene) {
        let policy = ReaderScrollHandoffPolicy(threshold: scene.settings.handoffThreshold, allowsPagingWhileZoomed: scene.settings.allowPagingWhileZoomed)
        var visited = Set<ObjectIdentifier>()
        func scan(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled, visited.insert(ObjectIdentifier(scroll)).inserted {
                if let registration = try? reader.registerScrollableContent(scroll, policy: policy) {
                    if !scene.settings.panEnabled { registration.invalidate() }
                    else if registration.policy != policy {
                        registration.invalidate(); _ = try? reader.registerScrollableContent(scroll, policy: policy)
                    }
                }
            }
            if let doubleTap = view.gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer }).first(where: { $0.numberOfTapsRequired == 2 }) {
                reader.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.forEach { $0.require(toFail: doubleTap) }
                tapRecognizer?.require(toFail: doubleTap)
            }
            view.subviews.forEach(scan)
        }
        scan(controller.view)
    }

    /// 连续的真实需求、稳定锚点及外壳尺寸回调。
    private func configureCallbacks(for scene: FullScreenDemoScene) {
        scene.surface?.onLayoutChange = { [weak self, weak scene] layout in
            guard let self, let scene, self.scene === scene else { return }
            if scene.continuous != nil, abs(scene.bodyWidth - layout.bodyFrame.width) > 0.5 { self.scheduleRebuild() }
            else if let paged = scene.paged { try? paged.notifyContentAvailable(expectedToken: paged.contentRequestToken) }
        }
        scene.surface?.onLayoutError = { [weak self] error in self?.showNotice("布局错误：\(error)") }
        scene.container?.onAdaptiveLayoutChange = { [weak self, weak scene] _ in
            guard let self, self.scene === scene else { return }
            if !self.installing { self.scheduleRebuildIfLayoutChanged(scene) }
        }
        guard let reader = scene.continuous else { return }
        reader.view.backgroundColor = .clear
        reader.onVisibleAnchor = { [weak self, weak scene] anchor in
            guard let self, let scene, self.scene === scene else { return }
            scene.focusedUnit = Int(anchor.identity.unitID) ?? scene.focusedUnit; self.updateStatus()
        }
        reader.onStableAnchor = { [weak self, weak scene] _ in if self?.scene === scene { self?.savePosition() } }
        scene.surface?.onReadingStatus = { [weak self, weak scene] _ in if self?.scene === scene { self?.updateStatus() } }
        reader.onContentDemand = { [weak self, weak scene] demand in
            guard let self, let scene, self.scene === scene else { return }; self.fulfill(demand, scene: scene)
        }
        reader.onFillLimitReached = { [weak self, weak scene] _, limit in
            scene?.lastEvent = "补屏限额：\(limit)"; if self?.scene === scene { self?.showNotice("已达到补屏预算，可在调试中重新补屏") }
        }
        reader.onAutomaticReadingStateChange = { [weak self, weak scene] _ in if self?.scene === scene { self?.updateStatus() } }
        reader.shouldBeginPan = { [weak self, weak scene] _ in
            guard let self, let scene else { return false }; return self.scene === scene && scene.settings.panEnabled && scene.exitToken == nil
        }
        reader.shouldHandleTap = { [weak scene, weak reader] context in
            guard scene?.settings.tapsEnabled == true, let reader else { return false }
            // TextKit 的轻点由宿主处理，避免它与 SDK 点击同时切换两次菜单。
            var hit = reader.view.hitTest(context.point, with: nil)
            while let candidate = hit, candidate !== reader.view {
                if candidate is UITextView { return false }
                hit = candidate.superview
            }
            return true
        }
        reader.onTap = { [weak self] _ in guard let self else { return }; self.setControlsVisible(!self.controlsVisible) }
    }

    private func scheduleRebuildIfLayoutChanged(_ scene: FullScreenDemoScene?) {
        guard let scene, settings.pageLayout == "adaptive", let next = try? effectiveLayout(for: settings), next != scene.layout else { return }
        scheduleRebuild()
    }

    /// 外壳外缘也可以轻点显示菜单；正文内的点击交给 SDK 自己处理。
    func installCanvasTap() {
        canvasTapOwner = .unassigned
        if let tapRecognizer { readerMount.removeGestureRecognizer(tapRecognizer) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false
        readerMount.addGestureRecognizer(tap); tapRecognizer = tap
        func scan(_ view: UIView) {
            if let scroll = view as? UIScrollView { tap.require(toFail: scroll.panGestureRecognizer) }
            view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.filter { $0.numberOfTapsRequired == 2 }.forEach { tap.require(toFail: $0) }
            view.subviews.forEach(scan)
        }
        if let root = scene?.root.view { scan(root) }
    }

    func applyInteractionControls() {
        guard let scene else { return }
        if let reader = scene.continuous {
            reader.setSuspended(!settings.userScrollEnabled, targets: .userScrolling, reason: "demo-user-scroll")
            reader.setSuspended(!settings.tapsEnabled, targets: .taps, reason: "demo-taps")
            reader.setSuspended(settings.pauseAutomatic, targets: .automaticReading, reason: "demo-auto-pause")
            reader.setSuspended(settings.deferInstallation, targets: .contentInstallation, reason: "demo-install")
        }
    }

    /// 唯一自动驱动；菜单/设置临时暂停，用户主动暂停由宿主意图单独保存。
    func syncAutomatic() {
        guard !installing, let scene, scene.exitToken == nil else { return }
        let mode = scene.settings.automaticMode
        guard mode == "timed" || mode == "scroll" else {
            scene.paged?.stopAutomaticReading(); scene.continuous?.stopAutomaticReading(commitPosition: false)
            scene.automaticStarted = false; updateStatus(); return
        }
        do {
            if automaticIntent == "stopped" {
                scene.paged?.stopAutomaticReading(); scene.continuous?.stopAutomaticReading()
                scene.automaticStarted = false
            } else {
                if !scene.automaticStarted {
                    if let reader = scene.paged { try reader.startAutomaticReading(interval: settings.pageInterval, animated: settings.animated) }
                    if let reader = scene.continuous { try reader.startAutomaticReading(pointsPerSecond: settings.scrollSpeed) }
                    scene.automaticStarted = true
                }
                if controlsVisible || settingsPresented || settings.pauseAutomatic || automaticIntent == "paused" {
                    scene.paged?.pauseAutomaticReading(); scene.continuous?.pauseAutomaticReading()
                } else {
                    try scene.paged?.resumeAutomaticReading(); try scene.continuous?.resumeAutomaticReading()
                }
            }
        } catch { scene.lastEvent = "自动驱动暂不可用：\(error)" }
        updateStatus()
    }

    /// 状态来自 renderer；正文底部页脚与菜单显示使用同一来源。
    func updateStatus() {
        guard let scene else { return }
        let index = min(max(0, scene.focusedUnit), scene.factory.count - 1)
        let total = settings.paginationTotal == "unknown" ? "—" : (settings.paginationTotal == "estimated" ? "约\(scene.factory.count)" : "\(scene.factory.count)")
        pageLabel.text = "\(index + 1) / \(total) · \(scene.layout == .spread ? "双页" : (scene.continuous != nil ? "连续" : "单页"))"
        pageLabel.accessibilityValue = String(index)
        positionSlider.maximumValue = Float(max(1, scene.factory.count - 1))
        if !positionSlider.isTracking { positionSlider.value = Float(index) }
        let state: String
        if let reader = scene.paged {
            switch reader.automaticReadingState {
            case .running: state = "自动翻页中"
            case .turning: state = "翻页中"
            case .paused: state = "已暂停"
            case .waiting: state = "等待内容"
            case .finished: state = "已读完"
            case .stopped: state = settings.automaticMode == "external" ? "外部手势" : modeTitle(settings.effect, axis: settings.axis)
            }
        } else if let reader = scene.continuous {
            switch reader.automaticReadingState {
            case .running: state = "自动滚屏中"
            case .paused: state = "已暂停"
            case .waiting: state = "等待内容"
            case .finished: state = "已读完"
            case .stopped: state = "连续滚动"
            }
        } else { state = "正在准备" }
        stateLabel.text = state
        navigationBar.topItem?.title = scene.factory.units[index].title
    }

    func finalBoundary(_ settings: FullScreenDemoSettings) -> ReaderBoundaryState {
        settings.bookBoundary == "latestAvailable" ? .latestAvailable : (settings.bookBoundary == "unknown" ? .unknown : .endOfBook)
    }

    /// 由宿主合并可用范围再提交完整窗口，SDK负责安装和锚点补偿。
    func window(for scene: FullScreenDemoScene) throws -> ContinuousWindow {
        let before: ReaderBoundaryState = scene.failedDirections.contains(.previous) ? .failed : (scene.lower == 0 ? .startOfBook : .available)
        let after: ReaderBoundaryState = scene.failedDirections.contains(.next) ? .failed : (scene.upper == scene.factory.count ? finalBoundary(scene.settings) : .available)
        let items = try (scene.lower..<scene.upper).flatMap { index in
            try scene.factory.items(in: index..<(index + 1), width: scene.bodyWidth, state: scene.placeholderStates[index] ?? .ready)
        }
        return try ContinuousWindow(items: items, before: before, after: after)
    }

    private func fulfill(_ demand: ContinuousContentDemand, scene: FullScreenDemoScene) {
        guard let reader = scene.continuous else { return }
        let taskID = UUID()
        do {
            let ticket = try reader.beginLoading(demand.direction, token: demand.token, target: demand.target, cancel: { [weak scene] in
                scene?.works.removeValue(forKey: taskID)?.cancel()
            }, completion: { [weak self, weak scene] outcome in
                scene?.works.removeValue(forKey: taskID)
                scene?.tickets.removeValue(forKey: taskID)
                guard let self, let scene, self.scene === scene else { return }
                scene.lastEvent = "窗口结果：\(outcome)"; self.updateStatus()
            })
            let work = DispatchWorkItem { [weak self, weak scene, weak reader] in
                guard let self, let scene, let reader, self.scene === scene, reader.isActive, reader.updateToken == ticket.token else { return }
                if scene.settings.simulateFailure && !scene.ignoreFailure {
                    scene.failedDirections.insert(demand.direction)
                    if case .item(let identity) = demand.target, let index = Int(identity.unitID) { scene.placeholderStates[index] = .failed }
                } else {
                    scene.failedDirections.remove(demand.direction)
                    if case .item(let identity) = demand.target, let index = Int(identity.unitID) { scene.placeholderStates.removeValue(forKey: index) }
                    else if demand.direction == .next { scene.upper = min(scene.factory.count, scene.upper + scene.settings.loadBatch) }
                    else { scene.lower = max(0, scene.lower - scene.settings.loadBatch) }
                }
                do { try reader.submit(self.window(for: scene), for: ticket) }
                catch { reader.rejectLoading(ticket, error: .invalidWindow); scene.lastEvent = "回填失败：\(error)" }
            }
            scene.works[taskID] = work
            scene.tickets[taskID] = ticket
            scene.lastEvent = "请求\(demand.direction == .next ? "后续" : "前置")内容"
            DispatchQueue.main.asyncAfter(deadline: .now() + scene.settings.loadDelay, execute: work)
        } catch { scene.lastEvent = "请求暂不可用：\(error)" }
    }

    private func wakePagedAfterDelay(_ scene: FullScreenDemoScene, reader: PagedReaderViewController) {
        guard scene.works.isEmpty else { return }
        let token = reader.contentRequestToken, taskID = UUID()
        let work = DispatchWorkItem { [weak self, weak scene, weak reader] in
            guard let self, let scene, let reader, self.scene === scene else { return }
            scene.works.removeValue(forKey: taskID)
            guard reader.isActive, reader.contentRequestToken == token else { return }
            scene.blockedNext = false
            do { try reader.notifyContentAvailable(expectedToken: token); scene.lastEvent = "内容已就绪" }
            catch { scene.lastEvent = "旧内容通知被拒绝" }
            self.updateStatus()
        }
        scene.works[taskID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scene.settings.loadDelay, execute: work)
    }
}
