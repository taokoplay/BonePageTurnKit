#if canImport(UIKit)
import UIKit

@MainActor
public struct PageContent {
    public let identity: PageItemIdentity
    public let controller: UIViewController
    public let readingInfo: ReaderPageInfo

    /// - Parameters: identity: 页面身份；controller: 尚未挂载到父控制器的真实页面；readingInfo: 当前页码、总数与内容边界。
    public init(identity: PageItemIdentity, controller: UIViewController, readingInfo: ReaderPageInfo = .init()) {
        self.identity = identity
        self.controller = controller
        self.readingInfo = readingInfo
    }
}

@MainActor
public enum PageAvailability {
    case page(PageContent)
    case waiting
    case end
    /// 明确区分本章末尾、全书末尾和连载最新内容；旧 end 只表示供给边界。
    case boundary(ReaderBoundaryState)
    case failed
}

/// 固定分页容器，统一管理无动画、覆盖、平移和纸张曲面事务；稳定状态保留真实页面。
@MainActor
public final class PagedReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    public let configuration: PageTurnConfiguration
    public let presentationID = UUID()
    public private(set) var currentPage: PageContent
    public private(set) var isActive = true
    public var pageProvider: ((PageItemIdentity, PageTurnDirection) -> PageAvailability)?
    public var onTransition: ((PageTransitionEvent) -> Void)?
    public var onUnavailable: ((PageTurnDirection, PageAvailability) -> Void)?
    /// 宿主可以根据缩放、选区或内层 pan 状态进一步拒绝手势。
    public var shouldBeginPan: ((UIPanGestureRecognizer) -> Bool)?
    /// 默认关闭点击分区；设置后沿当前分页轴解释位置。
    public var tapConfiguration: ReaderTapConfiguration? {
        didSet { tap.isEnabled = isActive && suspensionReasons.isEmpty && tapConfiguration != nil }
    }
    /// 宿主可先处理链接、图片或选区；返回 false 表示已消费本次点击。
    public var shouldHandleTap: ((CGPoint) -> Bool)?
    /// 仅通知中心点击位置，不承担菜单等业务。
    public var onCenterTap: ((CGPoint) -> Void)?
    public var onReadingStatus: ((ReaderStatus) -> Void)?
    public var onViewportSizeChange: ((CGSize) -> Void)?
    /// 异步更新当前页面统计时必须携带该令牌；提交新页、尺寸变化或统计更新都会换代。
    public private(set) var metadataToken: PageViewBinding
    /// 与统计令牌独立；新的邻页查询、页面提交及视口变化使旧就绪通知失效。
    public private(set) var contentRequestToken: PageViewBinding
    /// 当前展示内容的绑定；邻页查询和单纯统计更新不使它失效，切页／替换／尺寸变化会换代。
    public private(set) var currentPageBinding: PageViewBinding
    public var onPageReplacement: ((PageReplacement) -> Void)?
    /// 双页保留两个真实子页身份；单页返回一个。源页码仍由宿主 readingInfo 提供。
    public var visiblePageIdentities: [PageItemIdentity] {
        (currentPage.controller as? PageSpreadViewController)?.pages.map(\.identity) ?? [currentPage.identity]
    }
    private var scrollHandoffs: [ReaderScrollHandoff] = []
    private var scrollInteractionIDs: Set<UUID> = []
    private var startingScrollHandoff = false
    private weak var startingScrollHandoffOwner: ReaderScrollHandoff?
    internal var activeTransitionID: UUID? { pending?.transition.id }
    public var readingStatus: ReaderStatus? {
        guard isActive else { return nil }
        return ReaderStatus(presentationID: presentationID, identity: currentPage.identity, info: currentPage.readingInfo)
    }
    private var lastPublishedStatus: ReaderStatus?

    private struct Pending {
        let page: PageContent
        let transition: PageTransition
        var progress: CGFloat = 0
    }
    private var pending: Pending?
    private var animator: UIViewPropertyAnimator?
    private struct PaperRelease {
        let transitionID: UUID
        let start: CGFloat
        let target: CGFloat
        let duration: TimeInterval
        let completed: Bool
        var elapsed: TimeInterval = 0
    }
    private var paperView: PaperTransitionView?
    private var paperRelease: PaperRelease?
    private let paperClock = ReaderDisplayLink()
    internal var usesDisplayLinkForPaperAnimation = true
    internal var activePaperView: PaperTransitionView? { paperView }
    internal var isPaperClockRunning: Bool { paperClock.isRunning }
    private var isSettling: Bool { animator != nil || paperRelease != nil }
    private var suspensionReasons: Set<String> = []
    private var deliveringEvents = false
    private var requestingPage = false
    private var mountingPage = false
    private var lastSize = CGSize.zero
    private struct QueuedReplacement {
        let page: PageContent
        let ticket: PageReplacementTicket
        let completion: (PageReplacementOutcome) -> Void
    }
    private var queuedReplacement: QueuedReplacement?
    private var replacementScheduled = false
    private var replacingPage = false
    private var deliveringReplacementOutcome = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))

    private enum AutomaticIntent { case stopped, playing, paused, finished }
    private var automaticIntent: AutomaticIntent = .stopped
    public private(set) var automaticReadingState: PagedAutomaticReadingState = .stopped
    public private(set) var automaticReadingInterval: TimeInterval = 5
    public var automaticReadingProgress: Double { min(1, automaticElapsed / automaticReadingInterval) }
    public var onAutomaticReadingStateChange: ((PagedAutomaticReadingState) -> Void)?
    private let automaticClock = ReaderDisplayLink()
    private var automaticElapsed: TimeInterval = 0
    private var automaticAnimated = true
    private var automaticWaitingBoundary: ReaderBoundaryState?
    private var automaticViewVisible = false
    private var automaticApplicationActive = true
    private var automaticLayoutReady = true
    private var automaticOperation = false
    private var notifyingAutomaticState = false
    internal var usesDisplayLinkForAutomaticReading = true
    internal var isAutomaticClockRunning: Bool { automaticClock.isRunning }

    public var isTransitioning: Bool { pending != nil }
    private var axis: PageTurnAxis {
        if case .paged(_, let axis) = configuration.presentation { return axis }
        return .horizontal
    }
    private var usesCover: Bool { configuration.presentation == .paged(effect: .cover, axis: .horizontal) }
    private var usesSlide: Bool {
        if case .paged(effect: .slide, axis: _) = configuration.presentation { return true }
        return false
    }
    private var extent: CGFloat { axis == .horizontal ? view.bounds.width : view.bounds.height }
    private var paperEffect: PageTurnEffect? {
        switch configuration.presentation {
        case .paged(effect: .curl, axis: _): return .curl
        case .paged(effect: .arch, axis: _): return .arch
        default: return nil
        }
    }
    /// 阅读顺序及显式书脊共同决定几何方向；provider 的逻辑方向保持不变。
    private var forwardSign: CGFloat { CGFloat(configuration.forwardDisplacementSign) }

    /// - Parameters: page: 初始页面；configuration: 已实现的分页配置。
    /// - Throws: 不支持的配置或已被其他控制器持有的页面。
    public init(page: PageContent, configuration: PageTurnConfiguration) throws {
        try configuration.validate()
        guard case .paged = configuration.presentation else { throw PageTurnError.wrongPresentation }
        guard page.controller.parent == nil else { throw PageTurnError.invalidPageController }
        try Self.validatePageLayout(page, configuration: configuration)
        self.currentPage = page
        self.configuration = configuration
        self.metadataToken = PageViewBinding(identity: page.identity, presentationID: presentationID)
        self.contentRequestToken = PageViewBinding(identity: page.identity, presentationID: presentationID)
        self.currentPageBinding = PageViewBinding(identity: page.identity, presentationID: presentationID)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用页面初始化方法") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.backgroundColor = .systemBackground
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        tap.delegate = self
        tap.require(toFail: pan)
        tap.isEnabled = isActive && suspensionReasons.isEmpty && tapConfiguration != nil
        view.addGestureRecognizer(tap)
        automaticClock.onTick = { [weak self] elapsed in self?.advanceAutomaticReading(elapsed: elapsed) }
        paperClock.onTick = { [weak self] elapsed in self?.advancePaperAnimation(elapsed: elapsed) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillDeactivate),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidActivate),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        attach(currentPage.controller)
        do { try Self.validatePageLayout(currentPage, configuration: configuration) }
        catch { invalidate() }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        automaticViewVisible = true
        refreshAutomaticReadingState()
        scheduleCurrentPageReplacement()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        automaticViewVisible = false
        cancelScrollInteractions()
        if paperEffect != nil { cancelTransition() }
        refreshAutomaticReadingState()
    }

    @objc private func applicationWillDeactivate() { setAutomaticApplicationActive(false) }
    @objc private func applicationDidActivate() { setAutomaticApplicationActive(true) }

    /// - Parameter active: 应用是否可交互；系统通知与测试使用同一入口。
    internal func setAutomaticApplicationActive(_ active: Bool) {
        automaticApplicationActive = active
        if !active { cancelScrollInteractions() }
        if !active, paperEffect != nil { cancelTransition() }
        refreshAutomaticReadingState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isActive, !mountingPage, !replacingPage else { return }
        let changed = lastSize != view.bounds.size
        if lastSize != .zero, changed {
            cancelScrollInteractions()
            automaticLayoutReady = false
            automaticElapsed = 0
            cancelTransition()
            // 页码依赖旧排版；宿主准备新布局期间暂不发布旧统计。
            let info = currentPage.readingInfo
            currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                      readingInfo: .init(before: info.before, after: info.after))
        }
        if changed {
            metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            currentPageBinding = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        }
        lastSize = view.bounds.size
        layoutPages()
        publishReadingStatus()
        if changed, isActive { onViewportSizeChange?(lastSize) }
        refreshAutomaticReadingState()
        scheduleCurrentPageReplacement()
    }

    /// 外壳装饰改变正文尺寸但 renderer 尺寸不变时，同样使旧排版绑定和等待结果失效。
    internal func invalidateEmbeddedContentLayout() {
        guard isActive else { return }
        cancelScrollInteractions()
        automaticLayoutReady = false
        automaticElapsed = 0
        cancelTransition()
        let info = currentPage.readingInfo
        currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                  readingInfo: .init(before: info.before, after: info.after))
        metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        currentPageBinding = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        publishReadingStatus()
        refreshAutomaticReadingState()
        scheduleCurrentPageReplacement()
    }

    /// 仅更新当前页的统计和边界，不替换正文视图；迟到统计不得覆盖另一次展示。
    /// - Parameters: info: 宿主当前目录／排版快照的元数据；expectedToken: 请求开始时令牌。
    /// - Throws: renderer 失效、请求过期或翻页／回调占用。
    public func updateReadingInfo(_ info: ReaderPageInfo, expectedToken: PageViewBinding) throws {
        guard isActive else { throw PageTurnError.inactive }
        guard expectedToken.presentationID == presentationID else { throw PageTurnError.stalePresentation }
        guard expectedToken == metadataToken else { throw PageTurnError.staleWindow }
        guard pending == nil, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome else { throw PageTurnError.interactionInProgress }
        currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller, readingInfo: info)
        metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        publishReadingStatus()
    }

    /// 发起一次相邻翻页。请求等待／边界不会创建翻页事务。
    /// - Parameters: direction: 内容逻辑方向；animated: 本次是否播放已配置效果。
    /// - Returns: 是否接受请求。
    @discardableResult
    public func turn(_ direction: PageTurnDirection, animated: Bool = true) throws -> Bool {
        guard try beginTurn(direction, capturesPaper: animated && !UIAccessibility.isReduceMotionEnabled) else { return false }
        settle(completed: true, animated: animated)
        return true
    }

    /// 内置点击手势与宿主程序驱动共用的入口；无配置或无效位置不消费点击。
    /// - Parameters: point: 容器视图 bounds 坐标中的点击位置，允许边界；animated: 翻页时是否播放已配置效果。
    /// - Returns: 是否接受翻页或中心点击；宿主拒绝、无效分区或邻页不可用时为 false。
    /// - Throws: renderer 已失效，或正在暂停、翻页、派发回调、请求／挂载页面。
    @discardableResult
    public func handleTap(at point: CGPoint, animated: Bool = true) throws -> Bool {
        guard tapConfiguration != nil else { return false }
        try validateTapInteraction()
        loadViewIfNeeded()
        try validateTapInteraction()
        guard tapAction(at: point) != .ignored else { return false }
        if let shouldHandleTap {
            let accepted: Bool
            do {
                deliveringEvents = true
                defer { deliveringEvents = false; refreshAutomaticReadingState() }
                accepted = shouldHandleTap(point)
            }
            // 宿主命中处理可能暂停或退出阅读器，返回后必须重新校验。
            try validateTapInteraction()
            guard accepted else { return false }
        }
        switch tapAction(at: point) {
        case .previous: return try turn(.previous, animated: animated)
        case .next: return try turn(.next, animated: animated)
        case .center:
            deliveringEvents = true
            defer { deliveringEvents = false; refreshAutomaticReadingState() }
            onCenterTap?(point)
            return true
        case .ignored: return false
        }
    }

    /// - Throws: 点击入口与宿主回调返回时不可接受新交互的状态错误。
    private func validateTapInteraction() throws {
        guard isActive else { throw PageTurnError.inactive }
        guard scrollInteractionIDs.isEmpty, pending == nil, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome, suspensionReasons.isEmpty else {
            throw PageTurnError.interactionInProgress
        }
    }

    /// - Parameter point: 容器视图 bounds 坐标中的位置。
    /// - Returns: 当前有效配置与视口下的意图，非法几何忽略。
    private func tapAction(at point: CGPoint) -> ReaderTapAction {
        guard let tapConfiguration, point.x.isFinite, point.y.isFinite else { return .ignored }
        let bounds = view.bounds
        guard bounds.minX.isFinite, bounds.maxX.isFinite, bounds.minY.isFinite, bounds.maxY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return .ignored }
        let fraction = axis == .horizontal
            ? (point.x - bounds.minX) / bounds.width
            : (point.y - bounds.minY) / bounds.height
        let logicalFraction = forwardSign > 0 ? 1 - fraction : fraction
        return tapConfiguration.action(at: Double(logicalFraction))
    }

    /// 用于内置 pan 和宿主自定义交互；快速重入明确拒绝。
    /// - Parameter direction: 内容逻辑方向。
    /// - Returns: 是否取得可展示邻页并开始事务。
    @discardableResult
    public func beginInteractiveTurn(_ direction: PageTurnDirection) throws -> Bool {
        try beginTurn(direction, capturesPaper: !UIAccessibility.isReduceMotionEnabled)
    }

    /// - Parameters: direction: 逻辑方向；capturesPaper: 立即跳转或 Reduce Motion 时不创建快照。
    /// - Returns: 是否开始有效事务；快照失败会取消并保持原页。
    private func beginTurn(_ direction: PageTurnDirection, capturesPaper: Bool) throws -> Bool {
        guard isActive else { throw PageTurnError.inactive }
        guard pending == nil, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              (scrollInteractionIDs.isEmpty || startingScrollHandoff),
              !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil, suspensionReasons.isEmpty else {
            throw PageTurnError.interactionInProgress
        }
        loadViewIfNeeded()
        guard extent.isFinite, extent > 0 else { throw PageTurnError.interactionInProgress }
        if !automaticOperation { automaticElapsed = 0; automaticWaitingBoundary = nil }
        requestingPage = true
        let availability = pageProvider?(currentPage.identity, direction) ?? .waiting
        if let owner = startingScrollHandoffOwner, !owner.isActive {
            requestingPage = false
            throw PageTurnError.interactionInProgress
        }
        requestingPage = false
        guard isActive else { throw PageTurnError.inactive }
        guard suspensionReasons.isEmpty else { throw PageTurnError.interactionInProgress }
        guard case .page(let page) = availability else {
            let boundary: ReaderBoundaryState
            switch availability {
            case .waiting: boundary = .loading
            case .failed: boundary = .failed
            case .end: boundary = .end
            case .boundary(let value): boundary = value
            case .page: boundary = .available
            }
            let info = currentPage.readingInfo
            currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                      readingInfo: .init(pagination: info.pagination,
                                                         before: direction == .previous ? boundary : info.before,
                                                         after: direction == .next ? boundary : info.after))
            metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            if direction == .next { automaticWaitingBoundary = boundary }
            publishReadingStatus()
            let wasDelivering = deliveringEvents
            deliveringEvents = true
            onUnavailable?(direction, availability)
            deliveringEvents = wasDelivering
            refreshAutomaticReadingState()
            return false
        }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            guard page.controller !== controller else { throw PageTurnError.invalidPageController }
            ancestor = controller.parent
        }
        try Self.validatePageLayout(page, configuration: configuration)
        guard page.controller.parent == nil, page.controller !== currentPage.controller,
              page.identity.unitID != currentPage.identity.unitID else { throw PageTurnError.invalidPageController }
        let info = currentPage.readingInfo
        currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                  readingInfo: .init(pagination: info.pagination,
                                                     before: direction == .previous ? .available : info.before,
                                                     after: direction == .next ? .available : info.after))
        metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        automaticWaitingBoundary = nil
        let transition = PageTransition(presentationID: presentationID, from: currentPage.identity,
                                        to: page.identity, direction: direction)
        pending = Pending(page: page, transition: transition)
        startingScrollHandoffOwner?.takeOwnership(of: transition.id)
        deliveringEvents = true
        onTransition?(.willBegin(transition))
        deliveringEvents = false
        publishReadingStatus()
        guard canAttach(transitionID: transition.id), attach(page.controller, transitionID: transition.id) else { return false }
        do { try Self.validatePageLayout(page, configuration: configuration) }
        catch { cancelTransition(); throw error }
        if direction == .next { view.sendSubviewToBack(page.controller.view) }
        if capturesPaper, paperEffect != nil {
            do {
                guard try preparePaperTransition(for: transition, target: page) else { return false }
            } catch {
                cancelTransition()
                throw error
            }
        }
        layoutPages()
        refreshAutomaticReadingState()
        return isActive && pending?.transition.id == transition.id
    }

    /// - Parameter displacement: 沿本次逻辑方向的位移，point；负值钳制为零。
    public func updateInteractiveTurn(displacement: CGFloat) {
        guard isActive, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              pending != nil, !isSettling, displacement.isFinite, extent > 0 else { return }
        pending?.progress = min(1, max(0, displacement / extent))
        layoutPages()
    }

    /// - Parameters: velocity: 沿本次逻辑方向的速度，point/s；animated: 是否播放收尾动画。
    public func endInteractiveTurn(velocity: CGFloat, animated: Bool = true) {
        guard isActive, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              let pending, !isSettling else { return }
        let completed: Bool
        if paperEffect != nil {
            completed = velocity.isFinite && velocity > -500 && (velocity >= 500 || pending.progress >= 0.17)
        } else {
            completed = PageTurnReleasePolicy.shouldComplete(
                displacement: Double(pending.progress * extent), extent: Double(extent), velocity: Double(velocity))
        }
        settle(completed: completed, animated: animated)
    }

    /// 取消当前事务并恢复原页；无事务时无副作用。
    public func cancelTransition() {
        guard let transition = pending?.transition else { return }
        animator?.stopAnimation(true)
        animator = nil
        paperClock.stop()
        paperRelease = nil
        finish(transitionID: transition.id, completed: false)
    }

    /// - Parameters: suspended: 是否暂停；reason: 独立原因，解除一个原因不会覆盖其他暂停。
    public func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { cancelScrollInteractions() }
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if suspended { cancelTransition() }
        pan.isEnabled = isActive && suspensionReasons.isEmpty
        tap.isEnabled = isActive && suspensionReasons.isEmpty && tapConfiguration != nil
        refreshAutomaticReadingState()
        if !suspended { scheduleCurrentPageReplacement() }
    }

    /// 终止 renderer；动画完成闭包与后续操作不能再次提交。调用方切换模式或退出时调用。
    public func invalidate() {
        guard isActive else { return }
        isActive = false
        automaticIntent = .stopped
        automaticReadingState = .stopped
        automaticElapsed = 0
        let registered = scrollHandoffs
        scrollHandoffs.removeAll()
        registered.forEach { $0.invalidate() }
        automaticWaitingBoundary = nil
        automaticClock.stop()
        NotificationCenter.default.removeObserver(self)
        pan.isEnabled = false
        tap.isEnabled = false
        cancelTransition()
        if let replacement = queuedReplacement {
            queuedReplacement = nil
            deliverReplacement(replacement, outcome: .invalidated)
        }
        pageProvider = nil
        onTransition = nil
        onUnavailable = nil
        shouldBeginPan = nil
        shouldHandleTap = nil
        onCenterTap = nil
        onReadingStatus = nil
        onViewportSizeChange = nil
        onAutomaticReadingStateChange = nil
        onPageReplacement = nil
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard scrollInteractionIDs.isEmpty, isActive, pending == nil, suspensionReasons.isEmpty,
              !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil else { return false }
        if gestureRecognizer === tap { return tapConfiguration != nil }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let speed = pan.velocity(in: view)
        let primary = axis == .horizontal ? abs(speed.x) : abs(speed.y)
        let secondary = axis == .horizontal ? abs(speed.y) : abs(speed.x)
        return primary > secondary && (shouldBeginPan?(pan) ?? true)
    }

    /// - Parameters: gestureRecognizer: 待识别手势；otherGestureRecognizer: 需要优先裁决的手势。
    /// - Returns: 点击必须等待内置 pan 失败，动态规则与安装时的依赖保持一致。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === tap && otherGestureRecognizer === pan
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target, current !== view {
            if current is UIControl { return false }
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { return false }
            target = current.superview
        }
        return true
    }

    /// - Parameter tap: 内置点击手势，使用与程序调用相同的校验和回调入口。
    @objc private func handleTapGesture(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        _ = try? handleTap(at: tap.location(in: view))
    }

    /// - Parameter pan: 内置手势；位移与速度统一投影到逻辑方向。
    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let speed = pan.velocity(in: view)
        let position = axis == .horizontal ? translation.x : translation.y
        let velocity = axis == .horizontal ? speed.x : speed.y
        switch pan.state {
        case .began:
            do { try beginInteractiveTurn(velocity * forwardSign > 0 ? .next : .previous) }
            catch { pan.isEnabled = false; pan.isEnabled = isActive && suspensionReasons.isEmpty }
        case .changed:
            guard let pending else { return }
            updateInteractiveTurn(displacement: position * (pending.transition.direction == .next ? forwardSign : -forwardSign))
        case .ended:
            guard let pending else { return }
            endInteractiveTurn(velocity: velocity * (pending.transition.direction == .next ? forwardSign : -forwardSign))
        case .cancelled, .failed: cancelTransition()
        default: break
        }
    }

    /// - Parameters: completed: 提交还是取消；animated: 是否播放收尾。
    private func settle(completed: Bool, animated: Bool) {
        guard let transition = pending?.transition, !isSettling else { return }
        guard (usesCover || usesSlide || paperEffect != nil), animated, !UIAccessibility.isReduceMotionEnabled else {
            finish(transitionID: transition.id, completed: completed)
            return
        }
        if paperEffect != nil {
            guard paperView?.hasResources == true, let progress = pending?.progress else {
                finish(transitionID: transition.id, completed: completed)
                return
            }
            let target: CGFloat = completed ? 1 : 0
            let duration = min(completed ? 0.36 : 0.28, 0.12 + Double(abs(target - progress)) * 0.24)
            paperRelease = PaperRelease(transitionID: transition.id, start: progress, target: target,
                                        duration: duration, completed: completed)
            if usesDisplayLinkForPaperAnimation { paperClock.start() }
            return
        }
        let animation = UIViewPropertyAnimator(duration: 0.25, curve: .easeOut) { [weak self] in
            self?.pending?.progress = completed ? 1 : 0
            self?.layoutPages()
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, self.isActive, self.pending?.transition.id == transition.id else { return }
            self.animator = nil
            self.finish(transitionID: transition.id, completed: completed && position == .end)
        }
        animation.startAnimation()
    }

    /// 先提交不可变身份并恢复视图，再向宿主同步发送一次 commit／settle。
    /// - Parameters: transitionID: 待结束事务；completed: 是否成功。
    private func finish(transitionID: UUID, completed: Bool) {
        guard let pending, pending.transition.id == transitionID else { return }
        let handler = onTransition
        self.pending = nil
        releasePaperResources()
        scrollHandoffs.forEach { $0.transitionDidSettle(transitionID) }
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        defer {
            deliveringEvents = wasDelivering
            refreshAutomaticReadingState()
            scheduleCurrentPageReplacement()
        }
        automaticElapsed = 0
        automaticWaitingBoundary = nil
        if completed {
            let previous = currentPage.controller
            currentPage = pending.page
            metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            currentPageBinding = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            detach(previous)
        } else {
            detach(pending.page.controller)
        }
        layoutPages()
        pruneScrollHandoffs()
        if completed { handler?(.didCommit(pending.transition)) }
        handler?(.didSettle(pending.transition, completed: completed))
        if completed { publishReadingStatus() }
    }

    /// 状态变化时同步发布不可变快照，阻止宿主在状态事件中重入翻页。
    private func publishReadingStatus() {
        guard let status = readingStatus, status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        defer {
            deliveringEvents = wasDelivering
            refreshAutomaticReadingState()
            scheduleCurrentPageReplacement()
        }
        onReadingStatus?(status)
    }

    /// 根据进度布局真实页面；无动画模式只在提交时替换可见页。
    private func layoutPages() {
        guard isViewLoaded, let currentView = currentPage.controller.viewIfLoaded else { return }
        currentView.frame = view.bounds
        currentView.isHidden = false
        guard let pending, let incomingView = pending.page.controller.viewIfLoaded else { return }
        incomingView.frame = view.bounds
        incomingView.isHidden = false
        if paperEffect != nil {
            incomingView.isHidden = true
            if let paperView {
                currentView.isHidden = scrollInteractionIDs.isEmpty
                paperView.frame = view.bounds
                paperView.update(progress: pending.progress)
            }
        } else if usesSlide {
            let sign: CGFloat = pending.transition.direction == .next ? forwardSign : -forwardSign
            currentView.frame = frame(offset: sign * pending.progress * extent)
            incomingView.frame = frame(offset: sign * (pending.progress - 1) * extent)
        } else if usesCover {
            let moving = pending.transition.direction == .next ? currentView : incomingView
            let fraction = pending.transition.direction == .next ? forwardSign * pending.progress : forwardSign * (1 - pending.progress)
            moving.frame = frame(offset: fraction * extent)
        } else {
            incomingView.isHidden = true
        }
    }

    // MARK: - 纸张曲面与资源

    /// 在挂载保护内捕获两个页面，画面由事务身份固定，迟到异步内容留待稳定真实视图显示。
    /// - Parameters: transition: 当前事务；target: 目标真实页面。
    /// - Returns: 捕获期间未被取消／失效时为 true。
    /// - Throws: 尺寸或快照失败；不静默切换为其他效果。
    private func preparePaperTransition(for transition: PageTransition, target: PageContent) throws -> Bool {
        guard let effect = paperEffect, let currentView = currentPage.controller.viewIfLoaded,
              let incomingView = target.controller.viewIfLoaded else { throw PageTurnError.snapshotUnavailable }
        let wasMounting = mountingPage
        mountingPage = true
        defer { mountingPage = wasMounting; refreshAutomaticReadingState(); scheduleCurrentPageReplacement() }
        let size = view.bounds.size
        currentView.frame = view.bounds
        incomingView.frame = view.bounds
        currentView.isHidden = false
        incomingView.isHidden = false
        currentView.setNeedsLayout()
        currentView.layoutIfNeeded()
        guard canAttach(transitionID: transition.id) else { return false }
        incomingView.setNeedsLayout()
        incomingView.layoutIfNeeded()
        guard canAttach(transitionID: transition.id) else { return false }
        let overlay = try PaperTransitionView(currentView: currentView, targetView: incomingView,
                                              effect: effect, direction: transition.direction,
                                              spine: configuration.resolvedSpine, options: configuration.paper,
                                              axis: axis, readingOrder: configuration.readingOrder)
        guard canAttach(transitionID: transition.id) else { overlay.invalidateResources(); return false }
        guard view.bounds.size == size else { overlay.invalidateResources(); throw PageTurnError.snapshotUnavailable }
        paperView = overlay
        overlay.frame = view.bounds
        view.addSubview(overlay)
        return true
    }

    /// - Parameter elapsed: 帧间秒数；单帧最多计入 0.1 秒，控制后台积压。
    internal func advancePaperAnimation(elapsed: TimeInterval) {
        guard isActive, elapsed.isFinite, elapsed > 0, var release = paperRelease,
              pending?.transition.id == release.transitionID else { return }
        release.elapsed = min(release.duration, release.elapsed + min(elapsed, 0.1))
        paperRelease = release
        let t = CGFloat(release.elapsed / release.duration)
        let remainder = 1 - t
        let blend = 1 - remainder * remainder * remainder
        pending?.progress = release.start + (release.target - release.start) * blend
        layoutPages()
        if release.elapsed >= release.duration {
            paperClock.stop()
            paperRelease = nil
            finish(transitionID: release.transitionID, completed: release.completed)
        }
    }

    /// 动画终态或失效时释放局部快照和条带，不进入跨页缓存。
    private func releasePaperResources() {
        paperClock.stop()
        paperRelease = nil
        paperView?.invalidateResources()
        paperView?.removeFromSuperview()
        paperView = nil
    }

    /// 内存告警取消纸张事务并暂停自动驱动，防止立即再次申请快照。
    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        guard paperEffect != nil else { return }
        pauseAutomaticReading()
        cancelTransition()
        releasePaperResources()
    }

    /// - Parameter offset: 主轴位移，保留容器 bounds 的原点及另一轴坐标。
    /// - Returns: 当前轴向下真实页面的 frame。
    private func frame(offset: CGFloat) -> CGRect {
        view.bounds.offsetBy(dx: axis == .horizontal ? offset : 0, dy: axis == .vertical ? offset : 0)
    }

    /// - Parameters: controller: 将要挂载的页面；transitionID: 邻页对应事务，初始或替换页为 nil；initiallyHidden: 替换提交前隐藏新视图。
    /// - Returns: 所有 UIKit 同步回调返回后挂载是否仍有效。
    @discardableResult
    private func attach(_ controller: UIViewController, transitionID: UUID? = nil, initiallyHidden: Bool = false) -> Bool {
        guard canAttach(transitionID: transitionID) else { return false }
        let wasMounting = mountingPage
        mountingPage = true
        defer { mountingPage = wasMounting; refreshAutomaticReadingState(); scheduleCurrentPageReplacement() }
        addChild(controller)
        guard canAttach(transitionID: transitionID) else { detach(controller); return false }
        let childView = controller.view
        guard canAttach(transitionID: transitionID), let childView else { detach(controller); return false }
        childView.frame = view.bounds
        childView.isHidden = initiallyHidden
        view.addSubview(childView)
        guard canAttach(transitionID: transitionID) else { detach(controller); return false }
        registerZoomContent(in: controller)
        controller.didMove(toParent: self)
        guard canAttach(transitionID: transitionID) else { detach(controller); return false }
        return true
    }

    /// - Parameter transitionID: 挂载对应事务；nil 表示初始页面。
    /// - Returns: 容器与事务是否仍活跃。
    private func canAttach(transitionID: UUID?) -> Bool {
        isActive && (transitionID == nil || pending?.transition.id == transitionID)
    }

    /// - Parameter controller: 将要卸载的页面；不为取消尚未加载的页面触发 viewDidLoad。
    private func detach(_ controller: UIViewController) {
        if controller.parent === self {
            controller.willMove(toParent: nil)
            controller.viewIfLoaded?.removeFromSuperview()
            controller.removeFromParent()
        }
        // willMove(toSuperview:) 可以在 addSubview 尚未完成时取消 containment；
        // 外层 UIKit 随后仍可能插入根视图，因此视图归属需要独立、幂等地清理。
        if controller.parent == nil, let childView = controller.viewIfLoaded,
           childView.superview === viewIfLoaded {
            childView.removeFromSuperview()
        }
    }

    // MARK: - 双页与内层滚动

    /// - Parameters: page: 候选展示单元；configuration: 单双页、排列轴及显式顺序。
    /// - Throws: 内容与配置不匹配；中央书脊不能静默把普通单页当成两页。
    private static func validatePageLayout(_ page: PageContent, configuration: PageTurnConfiguration) throws {
        if let spread = page.controller as? PageSpreadViewController {
            try spread.validate(for: configuration)
        } else if configuration.layout == .spread { throw PageTurnError.invalidPageLayout }
        if let zoom = page.controller as? ReaderZoomViewController, !zoom.hasValidContent {
            throw PageTurnError.invalidPageController
        }
    }

    /// 登记内层滚动手势。可以在供给目标页时提前登记，只有当前页的触摸能启动交接。
    /// - Parameters: scrollView: 宿主真实滚动视图；policy: 启动阈值和高倍缩放策略。
    /// - Returns: 可显式 invalidate 的登记对象；重复登记同一视图返回已有对象。
    /// - Throws: 失效或参数无效；不接管 UIScrollView.delegate。
    @discardableResult
    public func registerScrollableContent(_ scrollView: UIScrollView,
                                          policy: ReaderScrollHandoffPolicy = .standard) throws -> ReaderScrollHandoff {
        guard isActive else { throw PageTurnError.inactive }
        guard policy.threshold.isFinite, (1...200).contains(policy.threshold) else { throw PageTurnError.invalidExtent("handoff") }
        if let existing = scrollHandoffs.first(where: { $0.isActive && $0.scrollView === scrollView }) { return existing }
        let handoff = ReaderScrollHandoff(scrollView: scrollView, reader: self, policy: policy)
        scrollHandoffs.append(handoff)
        return handoff
    }

    /// - Parameter view: 被登记内容；只有当前真实页面下的视图可启动交接。
    /// - Returns: 是否属于当前内容树。
    internal func containsCurrentContent(_ view: UIView) -> Bool {
        guard let root = currentPage.controller.viewIfLoaded else { return false }
        return view === root || view.isDescendant(of: root)
    }

    internal var canTrackScrollInteraction: Bool {
        isActive && pending == nil && suspensionReasons.isEmpty && !deliveringEvents && !requestingPage &&
            !mountingPage && !notifyingAutomaticState && !replacingPage && !deliveringReplacementOutcome && queuedReplacement == nil
    }

    /// - Parameters: active: 是否正在内层拖动或捏合；id: 独立登记身份。
    internal func setScrollInteraction(_ active: Bool, id: UUID) {
        if active { scrollInteractionIDs.insert(id) } else { scrollInteractionIDs.remove(id) }
        automaticElapsed = 0
        refreshAutomaticReadingState()
        if !active { scheduleCurrentPageReplacement() }
    }

    /// - Parameter direction: 越界后推导的逻辑方向。
    /// - Returns: 是否建立同一分页事务；忙碌和内容边界沿用原错误／回调。
    internal func beginScrollHandoff(_ direction: PageTurnDirection, owner: ReaderScrollHandoff) throws -> Bool {
        startingScrollHandoff = true
        startingScrollHandoffOwner = owner
        defer { startingScrollHandoff = false; startingScrollHandoffOwner = nil }
        return try beginInteractiveTurn(direction)
    }

    /// SDK 缩放容器默认登记；普通 UIScrollView 由宿主显式登记，避免改变嵌套内容的既有行为。
    /// - Parameter controller: 已挂载的页面及其子控制器。
    private func registerZoomContent(in controller: UIViewController) {
        if let zoom = controller as? ReaderZoomViewController { _ = try? registerScrollableContent(zoom.scrollView) }
        for child in controller.children { registerZoomContent(in: child) }
    }

    /// 终态移除离开当前页面的登记，归还弹性属性并释放手势目标。
    private func pruneScrollHandoffs() {
        let removed = scrollHandoffs.filter { handoff in
            guard handoff.isActive, let scroll = handoff.scrollView else { return true }
            return !containsCurrentContent(scroll)
        }
        scrollHandoffs.removeAll { item in removed.contains { $0 === item } }
        removed.forEach { $0.invalidate() }
    }

    /// 生命周期中断时终止所有内层交接；保留登记供恢复后的新手势使用。
    private func cancelScrollInteractions() {
        scrollHandoffs.forEach { $0.cancelInteraction() }
    }


    // MARK: - 当前页原位替换

    /// 原子替换当前页，不重建 renderer，不发送翻页 commit。新页可改变展示单元，但必须属于同一源且版本不倒退。
    /// - Parameters: page: 尚未挂载的新页面；expectedBinding: 请求开始时的 currentPageBinding。
    /// - Returns: 实际安装的新绑定。
    /// - Throws: 旧绑定、版本倒退、非法控制器或 UI 忙碌；提交前失败保持旧页。
    @discardableResult
    public func replaceCurrentPage(_ page: PageContent, expectedBinding: PageViewBinding) throws -> PageViewBinding {
        try validateReplacement(page, expectedBinding: expectedBinding)
        guard canInstallCurrentPageReplacement else { throw PageTurnError.interactionInProgress }
        replacingPage = true
        automaticClock.stop()
        defer {
            replacingPage = false
            if isViewLoaded { view.setNeedsLayout() }
            refreshAutomaticReadingState()
            scheduleCurrentPageReplacement()
        }
        loadViewIfNeeded()
        let expectedSize = view.bounds.size
        page.controller.loadViewIfNeeded()
        try validateReplacement(page, expectedBinding: expectedBinding)
        try Self.validatePageLayout(page, configuration: configuration)
        guard suspensionReasons.isEmpty, view.bounds.size == expectedSize else { throw PageTurnError.interactionInProgress }
        var committed = false
        defer { if !committed { detach(page.controller) } }
        guard attach(page.controller, initiallyHidden: true) else { throw PageTurnError.inactive }
        guard isActive else { throw PageTurnError.inactive }
        guard expectedBinding == currentPageBinding, view.bounds.size == expectedSize else { throw PageTurnError.staleWindow }
        try Self.validatePageLayout(page, configuration: configuration)
        guard suspensionReasons.isEmpty else { throw PageTurnError.interactionInProgress }
        let oldPage = currentPage
        let installed = PageViewBinding(identity: page.identity, presentationID: presentationID)
        let event = PageReplacement(previousBinding: expectedBinding, installedBinding: installed)
        let handler = onPageReplacement
        currentPage = page
        currentPageBinding = installed
        metadataToken = PageViewBinding(identity: page.identity, presentationID: presentationID)
        contentRequestToken = PageViewBinding(identity: page.identity, presentationID: presentationID)
        automaticElapsed = 0
        automaticWaitingBoundary = nil
        automaticLayoutReady = true
        committed = true
        detach(oldPage.controller)
        layoutPages()
        pruneScrollHandoffs()
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        handler?(event)
        deliveringEvents = wasDelivering
        publishReadingStatus()
        return installed
    }

    /// 接受一个最新优先的替换；过渡、暂停或同步通知结束后安装，再确认唯一终态。
    /// - Parameters: page: 未挂载的新页面；expectedBinding: 当前内容绑定；completion: 安装或取消的唯一结果。
    /// - Returns: 可用于取消尚未开始安装的票据。
    /// - Throws: 无效内容、旧绑定、安装或终态回调重入。抛错时不接管新请求。
    @discardableResult
    public func submitCurrentPage(_ page: PageContent, expectedBinding: PageViewBinding,
                                  completion: @escaping (PageReplacementOutcome) -> Void) throws -> PageReplacementTicket {
        try validateReplacement(page, expectedBinding: expectedBinding)
        guard !replacingPage, !deliveringReplacementOutcome else { throw PageTurnError.interactionInProgress }
        if let previous = queuedReplacement {
            queuedReplacement = nil
            deliverReplacement(previous, outcome: .superseded)
            try validateReplacement(page, expectedBinding: expectedBinding)
        }
        let ticket = PageReplacementTicket(expectedBinding: expectedBinding)
        queuedReplacement = QueuedReplacement(page: page, ticket: ticket, completion: completion)
        refreshAutomaticReadingState()
        scheduleCurrentPageReplacement()
        return ticket
    }

    /// - Parameter ticket: 尚未开始安装的替换票据。
    /// - Returns: 实际取消为 true；原子安装中的请求不能被普通取消改写终态。
    @discardableResult
    public func cancelPageReplacement(_ ticket: PageReplacementTicket) -> Bool {
        guard let replacement = queuedReplacement, replacement.ticket == ticket else { return false }
        queuedReplacement = nil
        deliverReplacement(replacement, outcome: .cancelled)
        refreshAutomaticReadingState()
        return true
    }

    private var canInstallCurrentPageReplacement: Bool {
        isActive && pending == nil && !replacingPage && !deliveringEvents && !requestingPage &&
            !mountingPage && !notifyingAutomaticState && !deliveringReplacementOutcome &&
            !automaticOperation && suspensionReasons.isEmpty && scrollInteractionIDs.isEmpty
    }

    /// - Parameters: page: 候选页面；expectedBinding: 原位替换的前置绑定。
    /// - Throws: 非同源内容、回退版本、旧请求或不安全的 containment。
    private func validateReplacement(_ page: PageContent, expectedBinding: PageViewBinding) throws {
        guard isActive else { throw PageTurnError.inactive }
        try Self.validatePageLayout(page, configuration: configuration)
        guard expectedBinding.presentationID == presentationID else { throw PageTurnError.stalePresentation }
        guard expectedBinding == currentPageBinding else { throw PageTurnError.staleWindow }
        guard page.identity.sourceID == currentPage.identity.sourceID,
              page.identity.contentVersion >= currentPage.identity.contentVersion,
              page.identity.layoutVersion >= currentPage.identity.layoutVersion else {
            throw PageTurnError.staleContent(page.identity.unitID)
        }
        guard page.controller !== currentPage.controller, page.controller.parent == nil else { throw PageTurnError.invalidPageController }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            guard page.controller !== controller else { throw PageTurnError.invalidPageController }
            ancestor = controller.parent
        }
    }

    /// 只安排一个主队列安装，不在宿主回调内部切换真实视图。
    private func scheduleCurrentPageReplacement() {
        guard isActive, queuedReplacement != nil, !replacementScheduled else { return }
        replacementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replacementScheduled = false
            self.installPendingCurrentPageIfIdle()
        }
    }

    /// 稳定后消费一次最新替换；成功翻页会通过绑定校验拒绝上一页的迟到回填。
    internal func installPendingCurrentPageIfIdle() {
        guard canInstallCurrentPageReplacement, let replacement = queuedReplacement else { return }
        queuedReplacement = nil
        do {
            let binding = try replaceCurrentPage(replacement.page, expectedBinding: replacement.ticket.expectedBinding)
            deliverReplacement(replacement, outcome: .installed(binding))
        } catch let error as PageTurnError {
            deliverReplacement(replacement, outcome: error == .inactive ? .invalidated : .rejected(error))
        } catch {
            deliverReplacement(replacement, outcome: .rejected(.invalidPageController))
        }
        refreshAutomaticReadingState()
    }

    /// - Parameters: replacement: 已移除队列所有权的请求；outcome: 已确定且唯一的终态。
    private func deliverReplacement(_ replacement: QueuedReplacement, outcome: PageReplacementOutcome) {
        let wasDelivering = deliveringReplacementOutcome
        deliveringReplacementOutcome = true
        replacement.completion(outcome)
        deliveringReplacementOutcome = wasDelivering
    }

    // MARK: - 分页自动阅读

    /// 从当前页重新计时，停留时间不包含过渡动画；当前页未显示时保留意图但不运行时钟。
    /// - Parameters: interval: 有限的 0.1...3600 秒；animated: 是否播放所配置的翻页效果。
    /// - Throws: 非法时间、失效 renderer 或 UI 同步回调重入。
    public func startAutomaticReading(interval: TimeInterval = 5, animated: Bool = true) throws {
        try validateAutomaticCommand()
        guard interval.isFinite, (0.1...3600).contains(interval) else { throw PagedAutomaticReadingError.invalidInterval }
        automaticReadingInterval = interval
        automaticAnimated = animated
        automaticElapsed = 0
        automaticWaitingBoundary = nil
        automaticIntent = .playing
        refreshAutomaticReadingState()
    }

    /// 用户主动暂停计时，保留进度；已开始的翻页事务仍按既有规则结束。
    public func pauseAutomaticReading() {
        guard isActive, automaticIntent == .playing else { return }
        automaticIntent = .paused
        refreshAutomaticReadingState()
    }

    /// 恢复主动暂停；加载未就绪时继续等待，不自动轮询 provider。
    /// - Throws: 失效 renderer 或同步回调重入。
    public func resumeAutomaticReading() throws {
        try validateAutomaticCommand()
        guard automaticIntent == .paused else { return }
        automaticIntent = .playing
        refreshAutomaticReadingState()
    }

    /// 停止并清空本页计时，不撤销已开始的事务；成功提交／取消仍由原回调报告。
    public func stopAutomaticReading() {
        guard isActive else { return }
        automaticIntent = .stopped
        automaticElapsed = 0
        automaticWaitingBoundary = nil
        refreshAutomaticReadingState()
    }

    /// 宿主完成当前布局或下一页供给后显式唤醒；旧请求不得唤醒另一次页面展示。
    /// - Parameter expectedToken: onUnavailable／onViewportSizeChange 时捕获的内容请求令牌，不使用 metadataToken。
    /// - Throws: 过期令牌、失效或回调重入。主动暂停／停止意图不会被修改。
    public func notifyContentAvailable(expectedToken: PageViewBinding) throws {
        try validateAutomaticCommand()
        guard expectedToken.presentationID == presentationID else { throw PageTurnError.stalePresentation }
        guard expectedToken == contentRequestToken else { throw PageTurnError.staleWindow }
        automaticWaitingBoundary = nil
        automaticLayoutReady = true
        refreshAutomaticReadingState()
    }

    /// - Throws: 控制命令不能进入页面请求、挂载、过渡通知或自动状态通知内部。
    private func validateAutomaticCommand() throws {
        guard isActive else { throw PageTurnError.inactive }
        guard !deliveringEvents, !requestingPage, !mountingPage, !automaticOperation, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome else {
            throw PageTurnError.interactionInProgress
        }
    }

    /// 系统时钟与测试共用的推进路径，一次 tick 最多触发一笔翻页，不追赶后台积压时间。
    /// - Parameter elapsed: 距上次帧的实际秒数，单次最多计入 0.1 秒。
    internal func advanceAutomaticReading(elapsed: TimeInterval) {
        guard isActive, elapsed.isFinite, elapsed > 0, !automaticOperation,
              !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome else { return }
        refreshAutomaticReadingState()
        guard automaticReadingState == .running else { return }
        automaticElapsed = min(automaticReadingInterval, automaticElapsed + min(elapsed, 0.1))
        guard automaticElapsed >= automaticReadingInterval - 0.000000001 else { return }
        if currentPage.readingInfo.after == .endOfBook {
            automaticIntent = .finished
            refreshAutomaticReadingState()
            return
        }
        automaticOperation = true
        defer { automaticOperation = false; refreshAutomaticReadingState() }
        do { _ = try turn(.next, animated: automaticAnimated) }
        catch let error as PageTurnError where error == .interactionInProgress {
            // provider 回调可添加临时暂停；保留播放意图，不伪造内容失败。
        } catch {
            if isActive, automaticIntent == .playing { automaticWaitingBoundary = .failed }
        }
    }

    /// 统一推导实际状态，先开关时钟再通知宿主；回调中的暂停／停止优先于外层继续执行。
    private func refreshAutomaticReadingState() {
        guard isActive, !deliveringEvents, !requestingPage, !mountingPage, !automaticOperation,
              !replacingPage, !deliveringReplacementOutcome else { return }
        let state: PagedAutomaticReadingState
        switch automaticIntent {
        case .stopped: state = .stopped
        case .paused: state = .paused
        case .finished: state = .finished(.endOfBook)
        case .playing:
            if !automaticViewVisible || !automaticApplicationActive || !suspensionReasons.isEmpty || !scrollInteractionIDs.isEmpty ||
                !isViewLoaded || view.bounds.width <= 0 || view.bounds.height <= 0 {
                state = .paused
            } else if pending != nil {
                state = .turning
            } else if !automaticLayoutReady || queuedReplacement != nil {
                state = .waiting(.loading)
            } else if let boundary = automaticWaitingBoundary {
                if boundary == .endOfBook { automaticIntent = .finished; state = .finished(.endOfBook) }
                else { state = .waiting(boundary) }
            } else { state = .running }
        }
        if state == .running, usesDisplayLinkForAutomaticReading { automaticClock.start() }
        else { automaticClock.stop() }
        guard state != automaticReadingState else { return }
        automaticReadingState = state
        let wasNotifying = notifyingAutomaticState
        notifyingAutomaticState = true
        onAutomaticReadingStateChange?(state)
        notifyingAutomaticState = wasNotifying
        scheduleCurrentPageReplacement()
    }
}
#endif
