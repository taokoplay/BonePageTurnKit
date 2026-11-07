#if canImport(UIKit)
import UIKit

/// 阅读页面外壳：全幅背景、固定／随动页眉页脚及独立正文视口。正文解析和业务装饰仍由宿主提供。
@MainActor
public final class ReaderSurfaceViewController: UIViewController {
    public let motion: ReaderSurfaceMotion
    public private(set) var metrics: ReaderSurfaceMetrics
    public private(set) var viewportPolicy: ReaderAdaptiveLayoutPolicy?
    public private(set) var layout: ReaderSurfaceLayout?
    public private(set) var layoutRevision: UInt64 = 0
    public private(set) var isActive = true
    public var pagedReader: PagedReaderViewController? { container.pagedReader }
    public var continuousReader: ContinuousReaderViewController? { container.continuousReader }
    public var currentBodyController: UIViewController? { currentPage?.bodyPage.controller }
    public var headerView: UIView? { motion == .contentOnly ? fixedViews.header : currentPage?.decorations.header }
    public var footerView: UIView? { motion == .contentOnly ? fixedViews.footer : currentPage?.decorations.footer }
    public var backgroundView: UIView? { motion == .wholePage ? currentPage?.decorations.background : fixedViews.background }
    /// 布局在主队列合并后通知，单位为 point，坐标系是 surface.view；不是每帧动画位置。
    public var onLayoutChange: ((ReaderSurfaceLayout) -> Void)? {
        didSet { lastPublishedLayout = nil; scheduleLayoutNotification() }
    }
    public var onLayoutError: ((Error) -> Void)?
    /// 供给未挂载的正文控制器；layout.bodyFrame.size 是本次正文排版尺寸，不再重复扣页眉页脚。
    public var pageProvider: ((PageItemIdentity, PageTurnDirection, ReaderSurfaceLayout) -> PageAvailability)?
    public var onTransition: ((PageTransitionEvent) -> Void)?
    public var onReadingStatus: ((ReaderStatus) -> Void)?
    public var onUnavailable: ((PageTurnDirection, PageAvailability) -> Void)?
    public var onPageReplacement: ((PageReplacement) -> Void)?
    public var onContentError: ((Error) -> Void)?

    private let container = PageTurnViewController()
    private let decorations: ReaderSurfaceDecorations
    private let canvasColor: UIColor
    private var fixedViews = ReaderSurfaceDecorationViews()
    private var installedContext = ReaderSurfaceContext()
    private var lastPublishedStatus: ReaderStatus?
    private var operating = false
    private var applyingLayout = false
    private var deliveringStatus = false
    private var layoutScheduled = false
    private var lastPublishedLayout: ReaderSurfaceLayout?
    private var epoch = UUID()
    private var sceneID = UUID()
    private var failedEnvironment: ReaderViewportEnvironment?
    private let layoutSuspension = "surface-layout-\(UUID().uuidString)"

    private var currentPage: ReaderSurfacePageViewController? {
        pagedReader?.currentPage.controller as? ReaderSurfacePageViewController
    }

    /// - Parameters: metrics: 装饰高度、间距及正文内边距；motion: 三档移动策略；decorations: 未挂载装饰工厂；viewportPolicy: 默认安全区／保留区域中的单页布局，nil 为完整 bounds；backgroundColor: 全屏兜底底色。
    /// - Throws: 无效度量；此单页外壳不自动采用双页布局建议。
    public init(metrics: ReaderSurfaceMetrics = .init(), motion: ReaderSurfaceMotion = .contentOnly,
                decorations: ReaderSurfaceDecorations = .init(),
                viewportPolicy: ReaderAdaptiveLayoutPolicy? = .init(prefersSpread: false),
                backgroundColor: UIColor = .systemBackground) throws {
        try metrics.validate()
        self.metrics = metrics
        self.motion = motion
        self.decorations = decorations
        self.viewportPolicy = viewportPolicy
        self.canvasColor = backgroundColor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用页面外壳配置初始化") }

    public override func loadView() {
        let root = ReaderViewportView(frame: .zero)
        root.backgroundColor = canvasColor
        view = root
        root.onEnvironmentChange = { [weak self] environment in self?.environmentChanged(environment) }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        guard isActive else { return }
        addChild(container)
        container.loadViewIfNeeded()
        container.view.backgroundColor = .clear
        view.addSubview(container.view)
        container.didMove(toParent: self)
        refreshLayout()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshLayout()
    }

    /// - Parameter newMetrics: 新页眉页脚高度和正文边距；改变视口会取消翻页并通知宿主重新排版。
    /// - Throws: 失效、同步安装重入或非法几何。校验失败保留旧配置。
    public func updateMetrics(_ newMetrics: ReaderSurfaceMetrics) throws {
        try checkMutation()
        try newMetrics.validate()
        if let environment = currentEnvironment { _ = try resolve(environment, metrics: newMetrics, policy: viewportPolicy) }
        metrics = newMetrics
        failedEnvironment = nil
        refreshLayout()
    }

    /// - Parameter policy: 可读区域策略；nil 表示宿主已给定完整可用视口。
    /// - Throws: 不合法策略或双页建议；失败保留原策略。
    public func updateViewportPolicy(_ policy: ReaderAdaptiveLayoutPolicy?) throws {
        try checkMutation()
        if let environment = currentEnvironment { _ = try resolve(environment, metrics: metrics, policy: policy) }
        viewportPolicy = policy
        failedEnvironment = nil
        refreshLayout()
    }

    /// - Parameter target: 目标宿主视图；nil 表示窗口坐标。
    /// - Returns: 稳定排版矩形转换到目标坐标系；尚未布局时为 nil。
    public func layout(in target: UIView?) -> ReaderSurfaceLayout? {
        guard let layout, isViewLoaded else { return nil }
        return converted(layout) { self.view.convert($0, to: target) }
    }

    /// 查询当前页的实际显示矩形；有 Core Animation 过渡时读取 presentation layer，不改变排版尺寸。
    /// - Parameter target: 目标宿主视图；省略时为 surface.view。
    /// - Returns: 当前页的平面显示位置；纸张曲面过渡时返回 nil，排版几何仍可由 layout 读取。连续模式返回正文视口。
    public func currentPageFrames(in target: UIView? = nil) -> ReaderSurfaceLayout? {
        guard let layout, isViewLoaded else { return nil }
        if let pagedReader, pagedReader.isTransitioning,
           case .paged(let effect, _) = pagedReader.configuration.presentation,
           effect == .curl || effect == .arch { return nil }
        let destination = target ?? view
        guard let page = currentPage, let pageView = page.viewIfLoaded else { return self.layout(in: destination) }
        let targetLayer = destination?.layer.presentation() ?? destination?.layer
        let sourceLayer = pageView.layer.presentation() ?? pageView.layer
        let offset = layout.rendererFrame.origin
        func fixed(_ frame: CGRect) -> CGRect { view.convert(frame, to: destination) }
        func moving(_ frame: CGRect) -> CGRect {
            sourceLayer.convert(frame.offsetBy(dx: -offset.x, dy: -offset.y), to: targetLayer)
        }
        return .init(backgroundFrame: motion == .wholePage ? moving(layout.backgroundFrame) : fixed(layout.backgroundFrame),
                     readingFrame: fixed(layout.readingFrame), rendererFrame: moving(layout.rendererFrame),
                     bodyFrame: moving(layout.bodyFrame),
                     headerFrame: layout.headerFrame.map { motion == .contentOnly ? fixed($0) : moving($0) },
                     footerFrame: layout.footerFrame.map { motion == .contentOnly ? fixed($0) : moving($0) }, motion: motion)
    }

    /// - Parameters: body: 初始正文页面，背景及页眉页脚由外壳负责；configuration: 单页配置，任意分层支持 none/slide，整页模式也支持 cover/curl/arch。
    /// - Returns: 底层分页容器，可使用其自动阅读和交互驱动；不要覆盖外壳管理的 provider／状态／过渡回调。
    /// - Throws: 配置或视图归属无效；准备失败保持旧展示。
    @discardableResult
    public func showPaged(page body: PageContent, configuration: PageTurnConfiguration) throws -> PagedReaderViewController {
        try checkMutation()
        try configuration.validate()
        guard configuration.layout == .single, case .paged(let effect, _) = configuration.presentation,
              motion == .wholePage || effect == .none || effect == .slide else { throw ReaderSurfaceError.unsupportedPresentation }
        loadViewIfNeeded()
        refreshLayout()
        guard let layout else { throw ReaderSurfaceError.invalidBounds }
        operating = true
        defer { operating = false; scheduleLayoutNotification() }
        let context = ReaderSurfaceContext(identity: body.identity, readingInfo: body.readingInfo)
        let fixed = try makeFixed(context: context)
        let wrapped = try wrap(body, layout: layout)
        var installed = false
        defer {
            if !installed { wrapped.detachContents(); removeFixed(fixed) }
        }
        try stageFixed(fixed)
        let session = UUID()
        let previousScene = sceneID
        sceneID = session
        do {
            let paged = try container.showPaged(page: .init(identity: body.identity, controller: wrapped, readingInfo: body.readingInfo), configuration: configuration) { [weak self] paged in
                self?.prepare(paged, session: session)
            }
            guard isActive, paged.isActive else { throw ReaderSurfaceError.inactive }
            try installFixed(fixed)
            installed = true
            installedContext = context
            applyFrames()
            publishStatus(paged.readingStatus)
            return paged
        } catch {
            if !installed { sceneID = previousScene }
            throw error
        }
    }

    /// - Parameters: window: 纯正文异高块；provider: 宿主外部保留的内容工厂，内容背景由宿主决定；anchor: 当前语义位置映射出的锚点；fillPolicy: 连续补屏规则。
    /// - Returns: 真实连续容器；可设置其加载、自动阅读和可见锚点回调，不要替换 onReadingStatus。
    /// - Throws: 连续只接受 contentOnly，装饰不会混入块高度。
    @discardableResult
    public func showContinuous(window: ContinuousWindow, provider: any ContinuousContentProvider,
                               anchor: ContinuousAnchor? = nil, fillPolicy: ContinuousFillPolicy = .standard) throws -> ContinuousReaderViewController {
        try checkMutation()
        guard motion == .contentOnly else { throw ReaderSurfaceError.unsupportedPresentation }
        loadViewIfNeeded()
        refreshLayout()
        guard layout != nil else { throw ReaderSurfaceError.invalidBounds }
        operating = true
        defer { operating = false; scheduleLayoutNotification() }
        let fixed = try makeFixed(context: .init())
        let session = UUID()
        var installed = false
        defer { if !installed { removeFixed(fixed) } }
        try stageFixed(fixed)
        let previousScene = sceneID
        sceneID = session
        do {
            let continuous = try container.showContinuous(window: window, provider: provider, anchor: anchor, fillPolicy: fillPolicy) { [weak self] continuous in
                continuous.loadViewIfNeeded()
                continuous.view.backgroundColor = .clear
                continuous.onReadingStatus = { [weak self] status in
                    guard let self, self.sceneID == session else { return }
                    self.publishStatus(status)
                }
            }
            guard isActive, continuous.isActive else { throw ReaderSurfaceError.inactive }
            try installFixed(fixed)
            installed = true
            applyFrames()
            publishStatus(continuous.readingStatus)
            return continuous
        } catch { sceneID = previousScene; throw error }
    }

    /// - Parameters: page: 新正文页；expectedBinding: 请求开始时捕获的当前页绑定。
    /// - Returns: 真正安装后的绑定；沿用分页原位替换的唯一提交语义。
    @discardableResult
    public func replaceCurrentPage(_ page: PageContent, expectedBinding: PageViewBinding) throws -> PageViewBinding {
        try checkMutation()
        guard let pagedReader, let layout else { throw ReaderSurfaceError.unsupportedPresentation }
        operating = true
        defer { operating = false }
        let wrapped = try wrap(page, layout: layout)
        do {
            return try pagedReader.replaceCurrentPage(.init(identity: page.identity, controller: wrapped, readingInfo: page.readingInfo), expectedBinding: expectedBinding)
        } catch { wrapped.detachContents(); throw error }
    }

    /// - Parameters: page: 等待安装的纯正文；expectedBinding: 原请求绑定；completion: 分页容器确认的唯一终态。
    /// - Returns: 可交给 pagedReader.cancelPageReplacement 的票据。
    @discardableResult
    public func submitCurrentPage(_ page: PageContent, expectedBinding: PageViewBinding,
                                  completion: @escaping (PageReplacementOutcome) -> Void) throws -> PageReplacementTicket {
        try checkMutation()
        guard let pagedReader, let layout else { throw ReaderSurfaceError.unsupportedPresentation }
        operating = true
        defer { operating = false }
        let wrapped = try wrap(page, layout: layout)
        do {
            return try pagedReader.submitCurrentPage(.init(identity: page.identity, controller: wrapped, readingInfo: page.readingInfo), expectedBinding: expectedBinding) { outcome in
                if case .installed = outcome { } else { wrapped.detachContents() }
                completion(outcome)
            }
        } catch { wrapped.detachContents(); throw error }
    }

    /// - Parameters: suspended: 是否暂停；reason: 独立暂停原因，不覆盖宿主其他原因。
    public func setSuspended(_ suspended: Bool, reason: String) { container.setSuspended(suspended, reason: reason) }

    /// 失效所有 renderer 与待交付布局通知；已有异步票据仍按底层协议收到唯一终态。
    public func invalidate() {
        guard isActive else { return }
        isActive = false
        epoch = UUID()
        layoutScheduled = false
        container.invalidate()
        onLayoutChange = nil; onLayoutError = nil; pageProvider = nil
        onTransition = nil; onReadingStatus = nil; onUnavailable = nil
        onPageReplacement = nil; onContentError = nil
    }
}

private extension ReaderSurfaceViewController {
    var currentEnvironment: ReaderViewportEnvironment? {
        guard let root = viewIfLoaded as? ReaderViewportView else { return nil }
        return root.environment ?? ReaderViewportEnvironment.capture(from: root)
    }

    /// - Throws: 安装、同步状态通知或布局回调中不能嵌套修改视图归属。
    func checkMutation() throws {
        guard isActive else { throw ReaderSurfaceError.inactive }
        guard !operating, !applyingLayout, !deliveringStatus else { throw ReaderSurfaceError.interactionInProgress }
    }

    /// - Parameters: environment: 外层实际环境；metrics: 度量；policy: 可读区域策略。
    /// - Returns: 所有矩形均在同一外壳坐标系。背景始终全幅。
    func resolve(_ environment: ReaderViewportEnvironment, metrics: ReaderSurfaceMetrics,
                 policy: ReaderAdaptiveLayoutPolicy?) throws -> ReaderSurfaceLayout {
        let reading: CGRect
        if let policy {
            let adaptive = try policy.layout(for: environment)
            guard adaptive.pageLayout == .single else { throw ReaderSurfaceError.unsupportedPresentation }
            reading = adaptive.contentFrame
        } else { reading = environment.bounds }
        return try metrics.layout(in: environment.bounds, readingFrame: reading, motion: motion)
    }

    /// 收集当前环境，度量配置变化也会重新计算，不依赖环境值一定发生变化。
    func refreshLayout() {
        guard isActive, !applyingLayout, let environment = currentEnvironment else { return }
        environmentChanged(environment)
    }

    /// - Parameter environment: bounds、安全区或保留区域更新。
    func environmentChanged(_ environment: ReaderViewportEnvironment) {
        guard isActive, !applyingLayout, failedEnvironment != environment else { return }
        applyingLayout = true
        defer { applyingLayout = false; scheduleLayoutNotification() }
        do {
            let result = try resolve(environment, metrics: metrics, policy: viewportPolicy)
            failedEnvironment = nil
            guard result != layout else { container.setSuspended(false, reason: layoutSuspension); return }
            let previousLayout = layout
            container.setSuspended(true, reason: layoutSuspension)
            guard isActive else { return }
            layout = result
            layoutRevision &+= 1
            if let previousLayout, previousLayout.bodyFrame.size != result.bodyFrame.size,
               previousLayout.rendererFrame.size == result.rendererFrame.size {
                pagedReader?.invalidateEmbeddedContentLayout()
            }
            applyFrames()
            container.setSuspended(false, reason: layoutSuspension)
        } catch {
            failedEnvironment = environment
            container.setSuspended(true, reason: layoutSuspension)
            let token = epoch
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.epoch == token, self.failedEnvironment == environment else { return }
                self.onLayoutError?(error)
            }
        }
    }

    /// 根据外壳几何统一设置固定层、renderer 视口和真实正文尺寸，绝不重复扣页眉页脚。
    func applyFrames() {
        guard let layout, isViewLoaded, container.isViewLoaded else { return }
        fixedViews.background?.frame = layout.backgroundFrame
        for (chrome, frame) in [(fixedViews.header, layout.headerFrame), (fixedViews.footer, layout.footerFrame)] {
            chrome?.isHidden = frame == nil
            if let frame { chrome?.frame = frame }
        }
        container.view.frame = layout.rendererFrame
        if let pagedReader {
            for child in pagedReader.children {
                (child as? ReaderSurfacePageViewController)?.apply(layout)
            }
        }
        container.view.setNeedsLayout()
        container.view.layoutIfNeeded()
    }

    /// 合并到最新稳定几何，允许宿主在通知中按正文尺寸创建页面；不会每帧发出动画位置。
    func scheduleLayoutNotification() {
        guard isActive, failedEnvironment == nil, layout != nil, layout != lastPublishedLayout,
              !layoutScheduled else { return }
        layoutScheduled = true
        let token = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.epoch == token else { return }
            self.layoutScheduled = false
            guard !self.operating, !self.applyingLayout, self.failedEnvironment == nil,
                  let current = self.layout, current != self.lastPublishedLayout else { return }
            self.lastPublishedLayout = current
            self.onLayoutChange?(current)
        }
    }

    /// - Parameter context: 首次页面上下文；返回位于外壳的固定视图。
    func makeFixed(context: ReaderSurfaceContext) throws -> ReaderSurfaceDecorationViews {
        let views = decorations.make(context: context, chrome: motion == .contentOnly, background: motion != .wholePage)
        guard isActive else { throw ReaderSurfaceError.inactive }
        try views.validate(excluding: viewIfLoaded)
        return views
    }

    /// - Parameter newViews: 已验证的固定装饰；在 renderer 安装成功后替换旧实例。
    func installFixed(_ newViews: ReaderSurfaceDecorationViews) throws {
        guard isActive, newViews.all.allSatisfy({ $0.superview === viewIfLoaded }) else { throw ReaderSurfaceError.invalidDecoration }
        removeFixed(fixedViews)
        fixedViews = newViews
        lastPublishedStatus = nil
        newViews.all.forEach { $0.isHidden = false }
    }

    /// renderer 切换前隐藏挂载候选固定层，任意插入回调失败不会替换旧 renderer。
    func stageFixed(_ newViews: ReaderSurfaceDecorationViews) throws {
        try newViews.validate(excluding: viewIfLoaded)
        var finished = false
        defer { if !finished { removeFixed(newViews) } }
        newViews.all.forEach { $0.isHidden = true }
        if let background = newViews.background { view.insertSubview(background, at: 0) }
        for chrome in [newViews.header, newViews.footer].compactMap({ $0 }) {
            guard isActive, chrome.superview == nil, chrome !== view, !view.isDescendant(of: chrome) else { throw ReaderSurfaceError.invalidDecoration }
            view.addSubview(chrome)
        }
        guard isActive, newViews.all.allSatisfy({ $0.superview === viewIfLoaded }) else { throw ReaderSurfaceError.invalidDecoration }
        finished = true
    }

    /// - Parameter views: 只移除仍属于本外壳的视图，不影响同步回调中被其他宿主接管的内容。
    func removeFixed(_ views: ReaderSurfaceDecorationViews) {
        for item in views.all where item.superview === viewIfLoaded { item.removeFromSuperview() }
    }

    /// - Parameters: body: 待创建正文；layout: 本次几何。返回尚未挂到 reader 的真实包装页面。
    func wrap(_ body: PageContent, layout: ReaderSurfaceLayout) throws -> ReaderSurfacePageViewController {
        var ancestor: UIViewController? = self
        while let current = ancestor {
            guard body.controller !== current else { throw ReaderSurfaceError.invalidController }
            ancestor = current.parent
        }
        guard body.controller !== container, body.controller !== pagedReader, body.controller !== continuousReader,
              body.controller.parent == nil else { throw ReaderSurfaceError.invalidController }
        let context = ReaderSurfaceContext(identity: body.identity, readingInfo: body.readingInfo)
        let moving = decorations.make(context: context, chrome: motion != .contentOnly, background: motion == .wholePage)
        guard isActive else { throw ReaderSurfaceError.inactive }
        let wrapped = try ReaderSurfacePageViewController(body: body, decorations: moving, layout: layout, canvasColor: canvasColor)
        do {
            try wrapped.prepare()
            guard isActive, wrapped.hasValidContent else { throw ReaderSurfaceError.inactive }
            return wrapped
        } catch { wrapped.detachContents(); throw error }
    }

    /// - Parameters: paged: 候选分页容器；session: 避免旧 renderer 通知作用于新展示。
    func prepare(_ paged: PagedReaderViewController, session: UUID) {
        paged.loadViewIfNeeded()
        paged.view.backgroundColor = .clear
        paged.pageProvider = { [weak self] identity, direction in
            guard let self, self.isActive, self.sceneID == session, let layout = self.layout else { return .failed }
            self.operating = true
            defer { self.operating = false }
            let availability = self.pageProvider?(identity, direction, layout) ?? .waiting
            guard self.isActive, self.sceneID == session else { return .failed }
            guard case .page(let body) = availability else { return availability }
            do {
                let wrapper = try self.wrap(body, layout: layout)
                return .page(.init(identity: body.identity, controller: wrapper, readingInfo: body.readingInfo))
            } catch { self.onContentError?(error); return .failed }
        }
        paged.onTransition = { [weak self] event in
            guard let self else { return }
            let previous = self.deliveringStatus
            self.deliveringStatus = true
            self.onTransition?(event)
            self.deliveringStatus = previous
        }
        paged.onReadingStatus = { [weak self] status in
            guard let self, self.sceneID == session else { return }
            self.publishStatus(status)
        }
        paged.onUnavailable = { [weak self] direction, availability in
            guard let self, self.sceneID == session else { return }
            let previous = self.deliveringStatus
            self.deliveringStatus = true
            defer { self.deliveringStatus = previous }
            self.onUnavailable?(direction, availability)
        }
        paged.onPageReplacement = { [weak self] event in
            guard let self, self.sceneID == session else { return }
            let previous = self.deliveringStatus
            self.deliveringStatus = true
            defer { self.deliveringStatus = previous }
            if let layout = self.layout { self.currentPage?.apply(layout) }
            self.onPageReplacement?(event)
        }
    }

    /// - Parameter status: 当前真实状态；固定装饰在切页成功或连续位置变化后更新，取消不切到目标页。
    func publishStatus(_ status: ReaderStatus?) {
        guard isActive, let status,
              status.presentationID == pagedReader?.presentationID || status.presentationID == continuousReader?.presentationID else { return }
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        installedContext = .init(status: status)
        let previous = deliveringStatus
        deliveringStatus = true
        let visible = ReaderSurfaceDecorationViews(header: headerView, footer: footerView, background: backgroundView)
        decorations.update?(visible, installedContext)
        if isActive { onReadingStatus?(status) }
        deliveringStatus = previous
    }

    /// - Parameters: source: 原布局；transform: 同一坐标转换。返回完整矩形快照，nil 槽位保持 nil。
    func converted(_ source: ReaderSurfaceLayout, transform: (CGRect) -> CGRect) -> ReaderSurfaceLayout {
        .init(backgroundFrame: transform(source.backgroundFrame), readingFrame: transform(source.readingFrame),
              rendererFrame: transform(source.rendererFrame), bodyFrame: transform(source.bodyFrame),
              headerFrame: source.headerFrame.map(transform), footerFrame: source.footerFrame.map(transform), motion: source.motion)
    }
}
#endif
