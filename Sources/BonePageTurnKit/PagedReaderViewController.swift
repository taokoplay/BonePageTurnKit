#if canImport(UIKit)
import UIKit
import os

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
    /// 显式开启后记录动画参数、渲染等待和终止原因；关闭时不采集 GPU 呈现数据。
    public var animationDiagnosticsEnabled = false {
        didSet {
            paperView?.setMetalPresentationMetricsEnabled(animationDiagnosticsEnabled)
            if !animationDiagnosticsEnabled { animationDiagnosticTrace = nil }
        }
    }
    /// 最近 180 条有界诊断记录；关闭诊断后保留，供宿主复制或展示。
    public private(set) var recentAnimationDiagnostics: [PageTurnAnimationDiagnostic] = []
    public var animationDiagnostic: PageTurnAnimationDiagnostic? { recentAnimationDiagnostics.last }
    private struct AnimationDiagnosticTrace {
        let id: UUID
        let startedAt: TimeInterval
        var emittedAt: TimeInterval = 0
        var event = PageTurnAnimationDiagnostic.Event.began
        var updates = 0
        var preparation: TimeInterval?
        var duration: TimeInterval?
        var elapsed: TimeInterval?
        var startProgress: Double?
        var targetProgress: Double?
        var animatorProgress: Double?
        var curve = "interactive"
        var durationScale: Double = 1
    }
    private var animationDiagnosticTrace: AnimationDiagnosticTrace?
    private var animationDiagnosticSequence = 0
    private static let animationLogger = Logger(subsystem: "com.bone.BonePageTurnKit", category: "PageTurnAnimation")
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
    /// 过渡中收到新意图时，是否立即把当前收尾推到终点并开始新一笔（“最新一笔优先”）。
    /// 只对平移、覆盖和无动画生效；仿真／拱页仍需重建纸面快照，接管会看到跳变，因此继续排队。
    /// 关闭时所有效果都按队列等待上一笔播完。
    public var handsOverActiveTransitionOnNewIntent = false
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
        var cornerDrag: PaperCornerDrag?
        var isDiscreteTurn = false
    }
    /// 收尾动画的目标结果；接管时按它落定，不能让取消动画被误提交。
    private var settlingCompletion: Bool?
    /// 上一笔的目标页位图缓存：下一笔的当前页与其身份、尺寸和预算一致时直接复用。
    /// 用身份 + 代际作键：`PageViewBinding` 每次构造都带新 UUID，不能直接比较。
    private var paperSnapshotCache: (identity: PageItemIdentity, presentationID: UUID,
                                     size: CGSize, pixels: Int, image: CGImage,
                                     texture: PaperCornerMetalRenderer.TextureSnapshot?, traits: UITraitCollection)?
    /// 实际发生的页面抓取次数；复用缓存时一次翻页只抓一张。
    private(set) var paperSnapshotCaptureCount = 0
    /// 最近一次是否命中快照缓存；供测试读取。
    private(set) var lastPaperSnapshotReused = false
    private(set) var paperTextureUploadCount = 0
    internal var hasCachedPaperSnapshot: Bool { paperSnapshotCache != nil }
    private var pending: Pending?
    private var animator: UIViewPropertyAnimator?
    private var coverDecoration: CoverTransitionDecoration?
    internal var activeCoverDecoration: CoverTransitionDecoration? { coverDecoration }
    private struct PaperRelease {
        let transitionID: UUID
        let start: CGFloat
        let target: CGFloat
        let duration: TimeInterval
        let completed: Bool
        let cornerStart: PaperCornerDrag?
        let cornerIntent: PaperCornerDrag?
        let cornerEndFraction: CGFloat
        var frameGate: PaperReleaseFrameGate
        var awaitingFinalFrame = false
        var elapsed: TimeInterval = 0
    }
    private var paperView: PaperTransitionView?
    private var paperRelease: PaperRelease?
    private var queuedDiscreteTurns: [PageTurnDirection] = []
    private let maximumQueuedDiscreteTurns = 32
    private var drainingDiscreteTurns = false
    /// 手指仍按住拖动时，新意图继续按原门禁拒绝；只有动画收尾阶段才排队。
    private var interactiveDragActive = false
    private var panQueuedWhileTransitioning = false
    /// 上一笔翻页意图的系统时间与平滑后的间隔；用于按手速压缩收尾动画。
    private var lastTurnIntentAt: TimeInterval?
    internal var smoothedTurnInterval: TimeInterval?
    private let paperClock = ReaderDisplayLink()
    internal var usesDisplayLinkForPaperAnimation = true
    internal var activePaperView: PaperTransitionView? { paperView }
    internal var isPaperClockRunning: Bool { paperClock.isRunning || paperView?.isNativeReleaseClockRunning == true }
    private var isSettling: Bool { animator != nil || paperRelease != nil }
    /// 纸张需要看清完整卷曲，连续输入最多加速到 0.8 倍；平移／覆盖沿用原来的倍率。
    internal var transitionDurationScale: CGFloat {
        guard let interval = smoothedTurnInterval, interval.isFinite else { return 1 }
        let clamped = min(max(interval, 0.10), 0.30)
        let minimum: CGFloat = paperEffect == nil ? 0.4 : 0.8
        return minimum + (1 - minimum) * CGFloat((clamped - 0.10) / 0.20)
    }

    private static let fullPagePaperCurve = UICubicTimingParameters(animationCurve: .easeInOut)

    /// 按系统缓入缓出曲线播放整页纸面，避免把大部分卷曲挤在收尾动画的开头。
    private static func fullPagePaperBlend(at fraction: CGFloat) -> CGFloat {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        let first = fullPagePaperCurve.controlPoint1
        let second = fullPagePaperCurve.controlPoint2
        func sample(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let remainder = 1 - t
            return 3 * remainder * remainder * t * a + 3 * remainder * t * t * b + t * t * t
        }
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<14 {
            let t = (lower + upper) / 2
            if sample(t, first.x, second.x) < fraction { lower = t } else { upper = t }
        }
        return sample((lower + upper) / 2, first.y, second.y)
    }
    /// 记录一次真实翻页意图；间隔过长视为新手势，恢复原速。
    private func recordTurnIntent() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTurnIntentAt = now }
        guard let last = lastTurnIntentAt else { return }
        let interval = now - last
        guard interval.isFinite, interval > 0, interval <= 2 else { smoothedTurnInterval = nil; return }
        smoothedTurnInterval = smoothedTurnInterval.map { $0 * 0.55 + interval * 0.45 } ?? interval
    }
    /// 已松手的 curl 可由新输入接管；仍在拖动及其他效果继续遵守原占用门禁。
    private var interruptibleCurlRelease: PaperRelease? {
        guard paperEffect == .curl, let release = paperRelease,
              pending?.transition.id == release.transitionID else { return nil }
        return release
    }
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
    /// 当前页停留进度 0...1；设置时立即交付，之后仅在值变化时通知。回调中禁止同步开始／导航／变速。
    public var onAutomaticReadingProgress: ((Double) -> Void)? {
        didSet { lastPublishedAutomaticProgress = nil; publishAutomaticProgress() }
    }
    private var lastPublishedAutomaticProgress: Double?
    private var publishingAutomaticProgress = false
    private var automaticProgressScheduled = false
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
        if paperEffect != nil { PaperCornerMetalRenderer.prewarm() }
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
        cancelScrollInteractions(reason: .offscreen)
        if paperEffect != nil || usesCover { cancelTransition(reason: .offscreen) }
        refreshAutomaticReadingState()
    }

    @objc private func applicationWillDeactivate() {
        if usesCover { cancelTransition(reason: .applicationInactive) }
        setAutomaticApplicationActive(false)
    }
    @objc private func applicationDidActivate() { setAutomaticApplicationActive(true) }

    /// - Parameter active: 应用是否可交互；系统通知与测试使用同一入口。
    internal func setAutomaticApplicationActive(_ active: Bool) {
        automaticApplicationActive = active
        if !active { cancelScrollInteractions(reason: .applicationInactive) }
        if !active, paperEffect != nil { cancelTransition(reason: .applicationInactive) }
        refreshAutomaticReadingState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isActive, !mountingPage, !replacingPage else { return }
        let changed = lastSize != view.bounds.size
        if lastSize != .zero, changed {
            cancelScrollInteractions(reason: .viewportChanged)
            automaticLayoutReady = false
            automaticElapsed = 0
            cancelTransition(reason: .viewportChanged)
            // 页码依赖旧排版；宿主准备新布局期间暂不发布旧统计。
            let info = currentPage.readingInfo
            currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                      readingInfo: .init(before: info.before, after: info.after))
        }
        if changed {
            paperSnapshotCache = nil
            metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
            currentPageBinding = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        }
        lastSize = view.bounds.size
        layoutPages()
        publishReadingStatus()
        if changed, isActive { onViewportSizeChange?(lastSize) }
        refreshAutomaticReadingState()
        publishAutomaticProgress()
        scheduleCurrentPageReplacement()
    }

    /// 外壳装饰改变正文尺寸但 renderer 尺寸不变时，同样使旧排版绑定和等待结果失效。
    internal func invalidateEmbeddedContentLayout() {
        guard isActive else { return }
        cancelScrollInteractions(reason: .viewportChanged)
        automaticLayoutReady = false
        automaticElapsed = 0
        cancelTransition(reason: .viewportChanged)
        paperSnapshotCache = nil
        let info = currentPage.readingInfo
        currentPage = PageContent(identity: currentPage.identity, controller: currentPage.controller,
                                  readingInfo: .init(before: info.before, after: info.after))
        metadataToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        contentRequestToken = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        currentPageBinding = PageViewBinding(identity: currentPage.identity, presentationID: presentationID)
        publishReadingStatus()
        refreshAutomaticReadingState()
        publishAutomaticProgress()
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

    /// 发起一次相邻翻页；任何效果在上一笔收尾期间都按序排队，等待／边界不创建伪事务。
    /// - Parameters: direction: 内容逻辑方向；animated: 本次是否播放已配置效果。
    /// - Returns: 是否接受请求；过渡中最多暂存 32 笔方向意图，邻页在实际播放时查询。
    @discardableResult
    public func turn(_ direction: PageTurnDirection, animated: Bool = true) throws -> Bool {
        // 过渡中只排入下一笔意图：动画资源仍只有一份，收尾后按序执行；curl 松手后同样走这里。
        if animated, !UIAccessibility.isReduceMotionEnabled, pending != nil, !interactiveDragActive {
            try validateQueuedTurnStart()
            guard queuedDiscreteTurns.count < maximumQueuedDiscreteTurns else { return false }
            recordTurnIntent()
            // 纸张效果（仿真／拱页）接管要重做快照会看到跳变，因此继续排队；只让轻量效果立即接管。
            if handsOverActiveTransitionOnNewIntent, queuedDiscreteTurns.isEmpty, paperEffect == nil {
                queuedDiscreteTurns.append(direction)
                recordAnimationDiagnostic(.queued)
                // 立即接管：当前动画推到本笔终点，落定回调后马上开始这一笔，不等上一段播完。
                handOverActiveTransition()
                return true
            }
            queuedDiscreteTurns.append(direction)
            recordAnimationDiagnostic(.queued)
            return true
        }
        try validateTurnStart()
        if animated, !UIAccessibility.isReduceMotionEnabled { recordTurnIntent() }
        // 显式无动画导航优先，避免跳转之后继续消费旧的轻点意图。
        if !animated || UIAccessibility.isReduceMotionEnabled { queuedDiscreteTurns.removeAll(keepingCapacity: false) }
        return try startDiscreteTurn(direction, animated: animated)
    }


    /// - Parameters: direction: 内容方向；animated: 是否播放配置动画。
    /// - Returns: 是否实际开始；纸张点击使用对应原生曲面，非动画路径沿用原处理。
    private func startDiscreteTurn(_ direction: PageTurnDirection, animated: Bool) throws -> Bool {
        let capturesPaper = animated && !UIAccessibility.isReduceMotionEnabled
        let cornerPoint: CGPoint?
        if capturesPaper, paperEffect != nil {
            loadViewIfNeeded()
            let sign = direction == .next ? forwardSign : -forwardSign
            cornerPoint = axis == .horizontal
                ? CGPoint(x: sign < 0 ? view.bounds.maxX : view.bounds.minX, y: view.bounds.midY)
                : CGPoint(x: view.bounds.midX, y: sign < 0 ? view.bounds.maxY : view.bounds.minY)
        } else { cornerPoint = nil }
        guard try beginTurn(direction, capturesPaper: capturesPaper, cornerPoint: cornerPoint) else { return false }
        pending?.isDiscreteTurn = true
        if let seed = pending?.cornerDrag, let transitionID = pending?.transition.id {
            // 回翻从画布外的上一张纸开始；不能把尚未接触的种子直接作为半展开起点。
            let size = view.bounds.size
            let spread = configuration.layout == .spread
            guard let folding = seed.foldingPresentation(direction: direction, size: size, spread: spread),
                  let initial = folding.interactivePresentation(direction: direction, size: size, spread: spread) else {
                cancelTransition(); throw PageTurnError.invalidInteractionPoint
            }
            var start = initial
            if start.effect == .arch { start.archContactStrength = 0 }
            pending?.cornerDrag = start
            paperView?.update(progress: 0, cornerDrag: start, followsTouch: false)
            guard isActive, pending?.transition.id == transitionID else { return false }
        }
        settle(completed: true, animated: animated)
        return true
    }

    /// 无参数；前一笔终态及宿主回调完成后，逐个执行已接受的点击，始终只持有一笔动画资源。无返回值。
    private func drainDiscreteTurns() {
        guard !drainingDiscreteTurns, !queuedDiscreteTurns.isEmpty else { return }
        drainingDiscreteTurns = true
        defer { drainingDiscreteTurns = false }
        while pending == nil, !queuedDiscreteTurns.isEmpty {
            guard isActive, suspensionReasons.isEmpty, automaticApplicationActive, scrollInteractionIDs.isEmpty,
                  !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
                  !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil else {
                queuedDiscreteTurns.removeAll(keepingCapacity: false); return
            }
            let direction = queuedDiscreteTurns.removeFirst()
            do {
                // 边界只消费这一笔意图，后续相反方向仍可从真实落定页继续。
                _ = try startDiscreteTurn(direction, animated: true)
            } catch {
                queuedDiscreteTurns.removeAll(keepingCapacity: false)
                guard isActive, suspensionReasons.isEmpty else { return }
                let wasDelivering = deliveringEvents
                deliveringEvents = true
                onUnavailable?(direction, .failed)
                deliveringEvents = wasDelivering
                refreshAutomaticReadingState()
                return
            }
        }
    }

    /// 内置点击手势与宿主程序驱动共用的入口；无配置或无效位置不消费点击。
    /// - Parameters: point: 容器视图 bounds 坐标中的点击位置，允许边界；animated: 翻页时是否播放已配置效果。
    /// - Returns: 是否接受翻页或中心点击；宿主拒绝、无效分区或邻页不可用时为 false。
    /// - Throws: renderer 已失效，或正在暂停、派发回调、请求／挂载页面。
    @discardableResult
    public func handleTap(at point: CGPoint, animated: Bool = true) throws -> Bool {
        guard tapConfiguration != nil else { return false }
        // 收尾中的两侧轻点排成下一笔翻页；宿主 veto、中央区与无效分区仍交回原路径处理。
        if pending != nil, !interactiveDragActive, animated, !UIAccessibility.isReduceMotionEnabled {
            loadViewIfNeeded()
            let action = tapAction(at: point)
            if action == .previous || action == .next {
                if let shouldHandleTap {
                    let accepted: Bool
                    do {
                        deliveringEvents = true
                        defer { deliveringEvents = false; refreshAutomaticReadingState() }
                        accepted = shouldHandleTap(point)
                    }
                    // 宿主可能在回调中暂停、退出或替换内容，返回后仍以当前状态为准。
                    guard accepted, isActive, suspensionReasons.isEmpty else { return false }
                }
                return try turn(action == .next ? .next : .previous, animated: true)
            }
        }
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
        guard scrollInteractionIDs.isEmpty, pending == nil || interruptibleCurlRelease != nil,
              !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
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

    /// 用于内置 pan 和宿主自定义交互；curl 可接管已松手的收尾，持有中的手势与同步回调重入仍拒绝。
    /// - Parameter direction: 内容逻辑方向。
    /// - Returns: 是否取得可展示邻页并开始事务。
    @discardableResult
    public func beginInteractiveTurn(_ direction: PageTurnDirection) throws -> Bool {
        try validateTurnStart()
        queuedDiscreteTurns.removeAll(keepingCapacity: false)
        let started = try beginTurn(direction, capturesPaper: !UIAccessibility.isReduceMotionEnabled)
        if started { interactiveDragActive = true }
        return started
    }

    /// 从 reader.view 指定点开始二维纸张；curl 按角落／中段折起，arch 保留真实抓取点并随斜向位移倾斜。
    /// - Parameters: direction: 内容逻辑方向；point: 页内按下位置，包含当前 bounds 原点。
    /// - Returns: 是否取得邻页并开始；非纸张效果、非法坐标或交互占用会抛错。
    @discardableResult
    public func beginInteractiveTurn(_ direction: PageTurnDirection, at point: CGPoint) throws -> Bool {
        try beginInteractiveTurn(direction, at: point, prefersFlatTurn: false)
    }

    /// 原生 pan 在首帧准备纸面前选定平翻，避免先显示底角再切换形态。
    private func beginInteractiveTurn(_ direction: PageTurnDirection, at point: CGPoint,
                                      prefersFlatTurn: Bool) throws -> Bool {
        guard isActive else { throw PageTurnError.inactive }
        guard paperEffect != nil else { throw PageTurnError.unsupportedPresentation }
        loadViewIfNeeded()
        guard makeCornerDrag(direction: direction, at: point, prefersFlatTurn: prefersFlatTurn) != nil else { throw PageTurnError.invalidInteractionPoint }
        try validateTurnStart()
        queuedDiscreteTurns.removeAll(keepingCapacity: false)
        let started = try beginTurn(direction, capturesPaper: !UIAccessibility.isReduceMotionEnabled,
                                    cornerPoint: point, prefersFlatTurn: prefersFlatTurn)
        guard started, let transitionID = pending?.transition.id else { return false }
        interactiveDragActive = true
        updateInteractiveTurn(to: point)
        return isActive && pending?.transition.id == transitionID
    }

    /// - Parameters: direction: 逻辑方向；point: 当前 bounds 中的绝对触点。
    /// - Returns: 按最新视口建立的材料坐标；非法起点返回 nil。
    private func makeCornerDrag(direction: PageTurnDirection, at point: CGPoint,
                                prefersFlatTurn: Bool = false) -> PaperCornerDrag? {
        let local = CGPoint(x: point.x - view.bounds.minX, y: point.y - view.bounds.minY)
        var drag = PaperCornerDrag(size: view.bounds.size, axis: axis, spread: configuration.layout == .spread,
            inwardSign: direction == .next ? forwardSign : -forwardSign, origin: local, effect: paperEffect ?? .curl)
        if paperEffect == .arch, let candidate = drag {
            let hinge = axis == .horizontal
                ? (candidate.inwardSign < 0 ? candidate.page.minX : candidate.page.maxX)
                : (candidate.inwardSign < 0 ? candidate.page.minY : candidate.page.maxY)
            let distance = ((axis == .horizontal ? local.x : local.y) - hinge) * -candidate.inwardSign
            guard distance > 1e-7, distance <= candidate.length else { return nil }
            drag?.slidesOuterPaperFlat = paperEffect == .arch
        }
        drag?.prefersFlatTurn = paperEffect == .curl && prefersFlatTurn
        return drag
    }

    /// 无参数；检查新翻页门禁，不结束动画或调用宿主。无返回值；不可接受时抛错。
    private func validateTurnStart() throws {
        guard isActive else { throw PageTurnError.inactive }
        guard pending == nil || interruptibleCurlRelease != nil,
              !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              (scrollInteractionIDs.isEmpty || startingScrollHandoff),
              !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil, suspensionReasons.isEmpty else {
            throw PageTurnError.interactionInProgress
        }
    }

    /// 过渡中排队的门禁：除“已有进行中的事务”外与立即翻页一致；不可接受时抛错。
    private func validateQueuedTurnStart() throws {
        guard isActive else { throw PageTurnError.inactive }
        guard !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              (scrollInteractionIDs.isEmpty || startingScrollHandoff),
              !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil,
              suspensionReasons.isEmpty else {
            throw PageTurnError.interactionInProgress
        }
    }

    /// - Parameters: direction: 逻辑方向；capturesPaper: 立即跳转或 Reduce Motion 时不创建快照；cornerPoint: 可选绝对触点。
    /// - Returns: 是否开始有效事务；快照失败会取消并保持当前已落定页。
    private func beginTurn(_ direction: PageTurnDirection, capturesPaper: Bool, cornerPoint: CGPoint? = nil,
                           prefersFlatTurn: Bool = false) throws -> Bool {
        try validateTurnStart()
        if let release = interruptibleCurlRelease {
            // 新输入立即衔接；沿用上一页已决定的完成／取消结果，旧资源和终态只清理一次。
            finish(transitionID: release.transitionID, completed: release.completed, reason: .handoff)
            // 落定回调可暂停、退出、回填或改变视口，不能以回调前的状态继续查询邻页。
            try validateTurnStart()
        }
        loadViewIfNeeded()
        guard extent.isFinite, extent > 0 else { throw PageTurnError.interactionInProgress }
        let cornerDrag: PaperCornerDrag?
        if let cornerPoint {
            guard let drag = makeCornerDrag(direction: direction, at: cornerPoint,
                                           prefersFlatTurn: prefersFlatTurn) else { throw PageTurnError.invalidInteractionPoint }
            cornerDrag = drag
        } else { cornerDrag = nil }
        if !automaticOperation { automaticElapsed = 0; automaticWaitingBoundary = nil }
        defer { if pending == nil { publishAutomaticProgress() } }
        requestingPage = true
        let diagnosticRequestStart = animationDiagnosticsEnabled ? CACurrentMediaTime() : 0
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
        pending = Pending(page: page, transition: transition, cornerDrag: cornerDrag)
        if animationDiagnosticsEnabled {
            let start = diagnosticRequestStart > 0 ? diagnosticRequestStart : CACurrentMediaTime()
            animationDiagnosticTrace = AnimationDiagnosticTrace(id: transition.id, startedAt: start)
            animationDiagnosticTrace?.preparation = CACurrentMediaTime() - start
        }
        recordAnimationDiagnostic(.began)
        startingScrollHandoffOwner?.takeOwnership(of: transition.id)
        deliveringEvents = true
        onTransition?(.willBegin(transition))
        deliveringEvents = false
        publishReadingStatus()
        guard canAttach(transitionID: transition.id), attach(page.controller, transitionID: transition.id) else { return false }
        do { try Self.validatePageLayout(page, configuration: configuration) }
        catch { cancelTransition(reason: .snapshotFailure); throw error }
        if direction == .next { view.sendSubviewToBack(page.controller.view) }
        if capturesPaper, paperEffect != nil {
            do {
                guard try preparePaperTransition(for: transition, target: page) else { return false }
            } catch {
                cancelTransition(reason: .snapshotFailure)
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
        let progress = min(1, max(0, displacement / extent))
        pending?.progress = progress
        if var drag = pending?.cornerDrag {
            if drag.effect == .arch {
                let point = axis == .horizontal
                    ? CGPoint(x: drag.origin.x + drag.inwardSign * extent * progress, y: drag.origin.y)
                    : CGPoint(x: drag.origin.x, y: drag.origin.y + drag.inwardSign * extent * progress)
                if let moved = drag.moved(to: point) { drag = moved; pending?.progress = moved.gestureProgress }
            } else {
                drag.translation = axis == .horizontal ? CGPoint(x: drag.inwardSign * 2 * drag.length * progress, y: 0)
                    : CGPoint(x: 0, y: drag.inwardSign * 2 * drag.length * progress)
            }
            pending?.cornerDrag = drag
        }
        recordAnimationDiagnostic(.frame)
        layoutPages()
    }

    /// - Parameter point: 当前手指在 reader.view 中的绝对位置；纸面控制点直接贴合触点，非有限输入保持上一帧。
    public func updateInteractiveTurn(to point: CGPoint) {
        updateInteractiveTurn(to: point, tracksPanAngle: false)
    }

    /// 原生手势持续观察滑动角度；显式二维接口仍直接采用宿主给出的触点。
    private func updateInteractiveTurn(to point: CGPoint, tracksPanAngle: Bool) {
        guard isActive, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !isSettling, var drag = pending?.cornerDrag,
              let direction = pending?.transition.direction else { return }
        let local = CGPoint(x: point.x - view.bounds.minX, y: point.y - view.bounds.minY)
        if tracksPanAngle { drag.trackPanAngle(to: local) }
        guard let moved = drag.moved(to: local, direction: direction) else { return }
        pending?.cornerDrag = moved
        pending?.progress = moved.gestureProgress
        recordAnimationDiagnostic(.frame)
        layoutPages()
    }

    /// - Parameters: velocity: 沿本次逻辑方向的速度，point/s；animated: 是否播放收尾动画。
    public func endInteractiveTurn(velocity: CGFloat, animated: Bool = true) {
        // 手指已离开：此后收尾期间的新意图改为排队，而不是被拒绝。
        interactiveDragActive = false
        guard isActive, !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              let pending, !isSettling else { return }
        let completed: Bool
        if paperEffect != nil {
            // 抓取点过中线或目标页实际显露过半均可完成；静止按下和快速反甩仍取消。
            let reachesMidpoint = pending.cornerDrag.map { drag in
                guard drag.gestureProgress > 0 else { return false }
                if drag.hasReachedCanvasMidpoint, drag.effect == .curl || configuration.layout == .spread { return true }
                guard drag.effect == .curl else { return false }
                // 仅容忍投影面积求和的浮点误差，不放宽可见半屏阈值。
                return (paperView?.visibleTargetFraction(for: drag) ?? 0) + 1e-9 >= 0.5
            } ?? false
            completed = velocity.isFinite && velocity > -500
                && (velocity >= 500 || pending.progress >= 0.17 || reachesMidpoint)
        } else {
            completed = PageTurnReleasePolicy.shouldComplete(
                displacement: Double(pending.progress * extent), extent: Double(extent), velocity: Double(velocity))
        }
        settle(completed: completed, animated: animated)
    }

    /// 取消当前事务并恢复原页；无事务时无副作用。
    public func cancelTransition() { cancelTransition(reason: .cancelled) }

    internal func cancelTransition(reason: PageTurnAnimationDiagnostic.EndReason) {
        queuedDiscreteTurns.removeAll(keepingCapacity: false)
        interactiveDragActive = false
        panQueuedWhileTransitioning = false
        preserveAnimationDiagnosticTiming()
        settlingCompletion = nil
        guard let transition = pending?.transition else { return }
        animator?.stopAnimation(true)
        animator = nil
        paperClock.stop()
        paperRelease = nil
        finish(transitionID: transition.id, completed: false, reason: reason)
    }

    /// 把进行中的收尾动画直接推到本笔终点并落定，随后由 `finish` 的收尾流程开始排队的那一笔。
    /// 落定结果沿用动画既定目标，取消动画不会被误提交。
    private func handOverActiveTransition() {
        guard let transition = pending?.transition else { queuedDiscreteTurns.removeAll(keepingCapacity: false); return }
        let completed = paperRelease?.completed ?? settlingCompletion ?? true
        preserveAnimationDiagnosticTiming()
        animator?.stopAnimation(true)
        animator = nil
        paperClock.stop()
        paperRelease = nil
        settlingCompletion = nil
        finish(transitionID: transition.id, completed: completed, reason: .handoff)
    }

    /// - Parameters: suspended: 是否暂停；reason: 独立原因，解除一个原因不会覆盖其他暂停。
    public func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { cancelScrollInteractions(reason: .suspended) }
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if suspended { cancelTransition(reason: .suspended) }
        pan.isEnabled = isActive && suspensionReasons.isEmpty
        tap.isEnabled = isActive && suspensionReasons.isEmpty && tapConfiguration != nil
        refreshAutomaticReadingState()
        if !suspended { scheduleCurrentPageReplacement() }
    }

    /// 终止 renderer；动画完成闭包与后续操作不能再次提交。调用方切换模式或退出时调用。
    public func invalidate() {
        paperSnapshotCache = nil
        guard isActive else { return }
        isActive = false
        automaticIntent = .stopped
        automaticReadingState = .stopped
        automaticElapsed = 0
        let registered = scrollHandoffs
        scrollHandoffs.removeAll()
        registered.forEach { $0.invalidate(reason: .invalidated) }
        automaticWaitingBoundary = nil
        automaticClock.stop()
        NotificationCenter.default.removeObserver(self)
        pan.isEnabled = false
        tap.isEnabled = false
        cancelTransition(reason: .invalidated)
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
        onAutomaticReadingProgress = nil
        automaticProgressScheduled = false
        onPageReplacement = nil
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 手指仍按住拖动时不接受第二个手势；动画收尾阶段放行，由处理入口排成下一笔意图。
        guard scrollInteractionIDs.isEmpty, isActive, !interactiveDragActive, suspensionReasons.isEmpty,
              !deliveringEvents, !requestingPage, !mountingPage, !notifyingAutomaticState,
              !replacingPage, !deliveringReplacementOutcome, queuedReplacement == nil else { return false }
        if gestureRecognizer === tap { return tapConfiguration != nil }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let speed = pan.velocity(in: view)
        let primary = axis == .horizontal ? abs(speed.x) : abs(speed.y)
        let secondary = axis == .horizontal ? abs(speed.y) : abs(speed.x)
        let acceptsDirection = paperEffect != nil ? (primary > 0 || secondary > 0) : primary > secondary
        return acceptsDirection && (shouldBeginPan?(pan) ?? true)
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
            // 新滑动排在当前收尾之后，保留上一页完整的卷曲与落页过程。
            if pending != nil, !interactiveDragActive {
                panQueuedWhileTransitioning = true
                let sign = velocity == 0 ? position : velocity
                _ = try? turn(sign * forwardSign > 0 ? .next : .previous, animated: true)
                return
            }
            panQueuedWhileTransitioning = false
            do {
                if paperEffect != nil {
                    let location = pan.location(in: view)
                    let origin = CGPoint(x: min(view.bounds.maxX, max(view.bounds.minX, location.x - translation.x)),
                                         y: min(view.bounds.maxY, max(view.bounds.minY, location.y - translation.y)))
                    let primaryOrigin = axis == .horizontal ? origin.x - view.bounds.minX : origin.y - view.bounds.minY
                    let crossOrigin = axis == .horizontal ? origin.y - view.bounds.minY : origin.x - view.bounds.minX
                    let crossExtent = axis == .horizontal ? view.bounds.height : view.bounds.width
                    let atSide = primaryOrigin < extent * 0.25 || primaryOrigin > extent * 0.75
                    let atEnd = crossOrigin < crossExtent * 0.25 || crossOrigin > crossExtent * 0.75
                    let flat = PaperCornerDrag.isFlatGesture(translation: translation, velocity: speed, axis: axis)
                    let motion: CGFloat
                    if paperEffect == .arch, max(abs(translation.x), abs(translation.y)) >= 4 { motion = position }
                    else { motion = velocity == 0 ? position : velocity }
                    let usesCorner = paperEffect == .curl && !flat && atSide && atEnd
                    let physical = usesCorner || motion == 0
                        ? (primaryOrigin < extent / 2 ? CGFloat(1) : -1) : motion
                    if try beginInteractiveTurn(physical * forwardSign > 0 ? .next : .previous,
                                                at: origin, prefersFlatTurn: flat) {
                        updateInteractiveTurn(to: location, tracksPanAngle: true)
                    }
                } else { _ = try beginInteractiveTurn(velocity * forwardSign > 0 ? .next : .previous) }
            } catch { pan.isEnabled = false; pan.isEnabled = isActive && suspensionReasons.isEmpty }
        case .changed, .ended:
            if panQueuedWhileTransitioning {
                if pan.state == .ended { panQueuedWhileTransitioning = false }
                return
            }
            guard let pending else { return }
            if let drag = pending.cornerDrag {
                updateInteractiveTurn(to: CGPoint(x: drag.origin.x + view.bounds.minX + translation.x,
                                                   y: drag.origin.y + view.bounds.minY + translation.y), tracksPanAngle: true)
            } else {
                updateInteractiveTurn(displacement: position * (pending.transition.direction == .next ? forwardSign : -forwardSign))
            }
            if pan.state == .ended {
                endInteractiveTurn(velocity: velocity * (pending.transition.direction == .next ? forwardSign : -forwardSign))
            }
        case .cancelled, .failed:
            if panQueuedWhileTransitioning {
                panQueuedWhileTransitioning = false
                return
            }
            cancelTransition()
        default: break
        }
    }

    /// - Parameters: completed: 提交还是取消；animated: 是否播放收尾。
    private func settle(completed: Bool, animated: Bool) {
        guard let transition = pending?.transition, !isSettling else { return }
        guard (usesCover || usesSlide || paperEffect != nil), animated, !UIAccessibility.isReduceMotionEnabled else {
            finish(transitionID: transition.id, completed: completed,
                   reason: UIAccessibility.isReduceMotionEnabled ? .reducedMotion : .unanimated)
            return
        }
        if paperEffect != nil {
            guard paperView?.hasResources == true, let logicalProgress = pending?.progress else {
                finish(transitionID: transition.id, completed: completed)
                return
            }
            let hasNativePresentation = paperView?.hasLiveNativeCornerPresentation == true
            let usesNativeRelease = usesDisplayLinkForPaperAnimation && hasNativePresentation
            let cornerStart: PaperCornerDrag?
            if let live = pending?.cornerDrag {
                if usesNativeRelease {
                    cornerStart = paperView?.cornerReleaseStart ?? live
                } else if hasNativePresentation, let shown = paperView?.submittedCornerDrag,
                          abs(shown.gestureProgress - live.gestureProgress) <= 0.08 {
                    // 手动时钟与真实 GPU 混合验收沿用原来的近接触点规则。
                    cornerStart = shown
                } else { cornerStart = live }
            } else { cornerStart = nil }
            // 完成判定沿用手指意图，播放从可见姿态开始；手动／离屏驱动保留原进度语义。
            let progress = usesNativeRelease ? (cornerStart?.gestureProgress ?? logicalProgress) : logicalProgress
            let target: CGFloat = completed ? 1 : 0
            let baseDuration = min(completed ? 0.36 : 0.28, 0.12 + Double(abs(target - progress)) * 0.24)
            let duration = baseDuration * (cornerStart == nil || pending?.isDiscreteTurn == true ? 1 : 1.2) * transitionDurationScale
            let waitsForGPU = cornerStart != nil && usesNativeRelease
            let cornerIntent = usesNativeRelease && completed ? pending?.cornerDrag : nil
            let cornerEndFraction: CGFloat
            if let cornerStart, cornerStart.effect == .arch, completed,
               transition.direction == .next, configuration.layout == .single {
                cornerEndFraction = PaperArchGeometry.visibleCompletionFraction(length: cornerStart.length)
            } else { cornerEndFraction = 1 }
            let frameGate = PaperReleaseFrameGate(waitsForGPU: waitsForGPU,
                submittedFrameCount: paperView?.nativeCornerSubmittedFrameCount ?? 0)
            paperRelease = PaperRelease(transitionID: transition.id, start: progress, target: target,
                                        duration: duration, completed: completed, cornerStart: cornerStart,
                                        cornerIntent: cornerIntent, cornerEndFraction: cornerEndFraction, frameGate: frameGate)
            if let cornerStart {
                // 从最后已提交的姿态继续；收尾自身已计时，不再叠加跟随缓冲。
                pending?.progress = progress
                pending?.cornerDrag = cornerStart
                paperView?.update(progress: progress, cornerDrag: cornerStart, followsTouch: false)
            }
            if usesDisplayLinkForPaperAnimation {
                let nativeDriven = usesNativeRelease && paperView?.driveNativeRelease({ [weak self] elapsed in
                    self?.advancePaperAnimation(elapsed: elapsed)
                }) == true
                if nativeDriven { paperClock.stop() }
                else { paperClock.start(maximumFramesPerSecond: view.window?.screen.maximumFramesPerSecond) }
            }
            recordAnimationDiagnostic(.releaseStarted)
            return
        }
        settlingCompletion = completed
        let animation = UIViewPropertyAnimator(duration: 0.25 * transitionDurationScale, curve: .easeOut) { [weak self] in
            self?.pending?.progress = completed ? 1 : 0
            self?.layoutPages()
        }
        animator = animation
        recordAnimationDiagnostic(.releaseStarted)
        animation.addCompletion { [weak self] position in
            guard let self, self.isActive, self.pending?.transition.id == transition.id else { return }
            self.preserveAnimationDiagnosticTiming(animatorFinished: position == .end)
            self.animator = nil
            self.finish(transitionID: transition.id, completed: completed && position == .end)
        }
        animation.startAnimation()
    }

    /// 先提交不可变身份并恢复视图，再向宿主同步发送一次 commit／settle。
    /// - Parameters: transitionID: 待结束事务；completed: 是否成功。
    private func finish(transitionID: UUID, completed: Bool, reason: PageTurnAnimationDiagnostic.EndReason? = nil) {
        guard let pending, pending.transition.id == transitionID else { return }
        recordAnimationDiagnostic(.finished, reason: reason ?? (completed ? .completed : .cancelled))
        animationDiagnosticTrace = nil
        settlingCompletion = nil
        interactiveDragActive = false
        let handler = onTransition
        self.pending = nil
        releaseCoverDecoration()
        releasePaperResources()
        scrollHandoffs.forEach { $0.transitionDidSettle(transitionID) }
        let completed = completed && (!usesCover || (isActive && ownsCoverPage(currentPage.controller) && ownsCoverPage(pending.page.controller)))
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        defer {
            deliveringEvents = wasDelivering
            refreshAutomaticReadingState()
            publishAutomaticProgress()
            scheduleCurrentPageReplacement()
            drainDiscreteTurns()
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

    /// - Parameters: transitionID: 布局开始时的事务；currentView: 当时的真实当前页。
    /// - Returns: 同步宿主回调尚未更换页面或事务时为 true；失效清理仍允许恢复稳定页。
    private func matchesPageLayout(_ transitionID: UUID?, currentView: UIView) -> Bool {
        pending?.transition.id == transitionID && currentPage.controller.viewIfLoaded === currentView
    }

    /// 根据进度布局真实页面；每次可重入的视图写入后核对页面及事务身份。
    private func layoutPages() {
        if usesCover { layoutCoverPages(); return }
        guard isViewLoaded, let currentView = currentPage.controller.viewIfLoaded else { return }
        let transitionID = pending?.transition.id
        if paperEffect != nil, let pending, let incomingView = pending.page.controller.viewIfLoaded,
           let paperView, paperView.hasLiveNativeCornerPresentation {
            // 原生动态帧只更新纸面；真实页已经完成准备，不再每帧显示后又隐藏。
            if currentView.frame != view.bounds { currentView.frame = view.bounds }
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            if incomingView.frame != view.bounds { incomingView.frame = view.bounds }
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            if !incomingView.isHidden { incomingView.isHidden = true }
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            let hideCurrent = scrollInteractionIDs.isEmpty
            if currentView.isHidden != hideCurrent { currentView.isHidden = hideCurrent }
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            if paperView.frame != view.bounds { paperView.frame = view.bounds }
            guard matchesPageLayout(transitionID, currentView: currentView), self.paperView === paperView else { return }
            paperView.update(progress: pending.progress, cornerDrag: pending.cornerDrag, followsTouch: !isSettling)
            return
        }
        currentView.frame = view.bounds
        guard matchesPageLayout(transitionID, currentView: currentView) else { return }
        currentView.isHidden = false
        guard matchesPageLayout(transitionID, currentView: currentView),
              let pending, let incomingView = pending.page.controller.viewIfLoaded else { return }
        incomingView.frame = view.bounds
        guard matchesPageLayout(transitionID, currentView: currentView) else { return }
        incomingView.isHidden = false
        guard matchesPageLayout(transitionID, currentView: currentView) else { return }
        if paperEffect != nil {
            incomingView.isHidden = true
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            if let paperView {
                currentView.isHidden = scrollInteractionIDs.isEmpty
                guard matchesPageLayout(transitionID, currentView: currentView) else { return }
                paperView.frame = view.bounds
                guard matchesPageLayout(transitionID, currentView: currentView), self.paperView === paperView else { return }
                paperView.update(progress: pending.progress, cornerDrag: pending.cornerDrag, followsTouch: !isSettling)
            }
        } else if usesSlide {
            let sign: CGFloat = pending.transition.direction == .next ? forwardSign : -forwardSign
            currentView.frame = frame(offset: sign * pending.progress * extent)
            guard matchesPageLayout(transitionID, currentView: currentView) else { return }
            incomingView.frame = frame(offset: sign * (pending.progress - 1) * extent)
        } else {
            incomingView.isHidden = true
        }
    }

    // MARK: - 覆盖翻页装饰

    /// - Parameter controller: 本次真实页面。
    /// - Returns: 根视图和控制器是否仍由本容器持有。
    private func ownsCoverPage(_ controller: UIViewController) -> Bool {
        guard let container = viewIfLoaded, let pageView = controller.viewIfLoaded else { return false }
        return controller.parent === self && pageView.superview === container
    }

    /// - Parameter transitionID: 开始本次布局时的事务；nil 表示稳定页。
    /// - Returns: 同步回调未取消事务或将页面交给其他容器时为 true。
    private func validateCoverOwnership(transitionID: UUID?) -> Bool {
        guard pending?.transition.id == transitionID else { return false }
        guard ownsCoverPage(currentPage.controller), pending.map({ ownsCoverPage($0.page.controller) }) ?? true else {
            cancelTransition()
            releaseCoverDecoration()
            return false
        }
        return true
    }

    /// 布局真实移动页；每次可重入的视图写入之后重新核对事务和所有权。
    private func layoutCoverPages() {
        let transitionID = pending?.transition.id
        guard validateCoverOwnership(transitionID: transitionID),
              let currentView = currentPage.controller.viewIfLoaded else { return }
        currentView.frame = view.bounds
        guard validateCoverOwnership(transitionID: transitionID) else { return }
        currentView.isHidden = false
        guard validateCoverOwnership(transitionID: transitionID) else { return }
        guard let pending, let incomingView = pending.page.controller.viewIfLoaded else {
            releaseCoverDecoration()
            return
        }
        incomingView.frame = view.bounds
        guard validateCoverOwnership(transitionID: transitionID) else { return }
        incomingView.isHidden = false
        guard validateCoverOwnership(transitionID: transitionID) else { return }
        let movingPage = pending.transition.direction == .next ? currentPage.controller : pending.page.controller
        let moving = pending.transition.direction == .next ? currentView : incomingView
        let fraction = pending.transition.direction == .next ? forwardSign * pending.progress : forwardSign * (1 - pending.progress)
        moving.frame = frame(offset: fraction * extent)
        guard validateCoverOwnership(transitionID: transitionID), configuration.cover.isEnabled else { return }
        if coverDecoration == nil {
            let decoration = CoverTransitionDecoration(owner: self, page: movingPage, options: configuration.cover,
                                                       horizontalShadowSign: -forwardSign)
            coverDecoration = decoration
            guard decoration.install(), validateCoverOwnership(transitionID: transitionID), coverDecoration === decoration else {
                decoration.invalidate()
                if coverDecoration === decoration { coverDecoration = nil }
                if self.pending?.transition.id == transitionID { cancelTransition() }
                return
            }
        }
        if coverDecoration?.update(progress: pending.progress) == false { cancelTransition() }
    }

    /// 统一在 commit／cancel 之前恢复宿主样式，清理回调可以安全重入。
    private func releaseCoverDecoration() {
        guard let decoration = coverDecoration else { return }
        coverDecoration = nil
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        defer { deliveringEvents = wasDelivering }
        decoration.invalidate()
    }

    // MARK: - 纸张曲面与资源

    /// 在挂载保护内捕获两个页面，画面由事务身份固定，迟到异步内容留待稳定真实视图显示。
    /// - Parameters: transition: 当前事务；target: 目标真实页面。
    /// - Returns: 捕获期间未被取消／失效时为 true。
    /// - Throws: 尺寸或快照失败；不静默切换为其他效果。
    private func preparePaperTransition(for transition: PageTransition, target: PageContent) throws -> Bool {
        guard let effect = paperEffect, let currentView = currentPage.controller.viewIfLoaded,
              let incomingView = target.controller.viewIfLoaded else { throw PageTurnError.snapshotUnavailable }
        let diagnosticPreparationStart = animationDiagnosticsEnabled ? CACurrentMediaTime() : 0
        let wasMounting = mountingPage
        mountingPage = true
        defer { mountingPage = wasMounting; refreshAutomaticReadingState(); scheduleCurrentPageReplacement() }
        let size = view.bounds.size
        currentView.frame = view.bounds
        incomingView.frame = view.bounds
        currentView.isHidden = false
        incomingView.isHidden = false
        let reused = paperSnapshotCache.flatMap { entry in
            entry.identity == currentPage.identity && entry.presentationID == presentationID
                && entry.size == size && entry.pixels == configuration.paper.maximumSnapshotPixels
                && entry.traits.isEqual(currentView.traitCollection) ? entry : nil
        }
        if reused == nil {
            currentView.setNeedsLayout()
            currentView.layoutIfNeeded()
            guard canAttach(transitionID: transition.id) else { return false }
        }
        incomingView.setNeedsLayout()
        incomingView.layoutIfNeeded()
        guard canAttach(transitionID: transition.id) else { return false }
        let overlay = try PaperTransitionView(currentView: currentView, targetView: incomingView,
                                              effect: effect, direction: transition.direction,
                                              spine: configuration.resolvedSpine, options: configuration.paper,
                                              axis: axis, readingOrder: configuration.readingOrder,
                                              cornerDriven: pending?.cornerDrag != nil,
                                              cachedCurrent: reused?.image, cachedCurrentTexture: reused?.texture)
        guard canAttach(transitionID: transition.id) else { overlay.invalidateResources(); return false }
        guard view.bounds.size == size else { overlay.invalidateResources(); throw PageTurnError.snapshotUnavailable }
        paperSnapshotCaptureCount += overlay.didReuseCurrentSnapshot ? 1 : 2
        lastPaperSnapshotReused = overlay.didReuseCurrentSnapshot
        paperTextureUploadCount += overlay.textureUploadCount
        paperSnapshotCache = overlay.targetSnapshot.map {
            (target.identity, presentationID, size, configuration.paper.maximumSnapshotPixels, $0,
             overlay.targetTextureSnapshot, incomingView.traitCollection)
        }
        paperView = overlay
        overlay.setMetalPresentationMetricsEnabled(animationDiagnosticsEnabled)
        overlay.frame = view.bounds
        view.addSubview(overlay)
        if animationDiagnosticsEnabled {
            let preparation = (animationDiagnosticTrace?.preparation ?? 0) + CACurrentMediaTime() - diagnosticPreparationStart
            animationDiagnosticTrace?.preparation = preparation
            recordAnimationDiagnostic(.prepared)
        }
        return true
    }

    /// - Parameter elapsed: 帧间秒数；单帧最多计入 0.1 秒，控制后台积压。
    internal func advancePaperAnimation(elapsed: TimeInterval) {
        guard isActive, elapsed.isFinite, elapsed > 0, var release = paperRelease,
              pending?.transition.id == release.transitionID else { return }
        guard let step = release.frameGate.step(elapsed: elapsed,
            submittedFrameCount: paperView?.nativeCornerSubmittedFrameCount ?? 0,
            framesExhausted: paperView?.nativeFramesExhausted ?? true) else {
            paperRelease = release
            recordAnimationDiagnostic(.waitingForFrame)
            return
        }
        if release.awaitingFinalFrame {
            // 终态已经请求，且之后取得了成功提交；此时才恢复真实页面并交付落定。
            paperClock.stop(); paperRelease = nil
            finish(transitionID: release.transitionID, completed: release.completed)
            return
        }
        release.elapsed = min(release.duration, release.elapsed + step)
        paperRelease = release
        let t = CGFloat(release.elapsed / release.duration)
        let blend: CGFloat
        if pending?.isDiscreteTurn == true || (release.completed && release.cornerStart?.effect == .arch) {
            blend = Self.fullPagePaperBlend(at: t)
        } else {
            let remainder = 1 - t
            blend = 1 - remainder * remainder * remainder
        }
        pending?.progress = release.start + (release.target - release.start) * blend
        if let drag = release.cornerStart, let direction = pending?.transition.direction {
            // 可见纸面与投影先完整离开视口；仅在终帧落定其余隐藏行程。
            let fraction = t < 1 ? blend * release.cornerEndFraction : blend
            pending?.cornerDrag = drag.released(completed: release.completed, fraction: fraction, direction: direction,
                                                angleIntent: release.cornerIntent)
        }
        layoutPages()
        // 布局可同步接管另一笔翻页，旧帧不得清除新时钟或新收尾。
        guard isActive, pending?.transition.id == release.transitionID,
              paperRelease?.transitionID == release.transitionID else { return }
        recordAnimationDiagnostic(.frame)
        if release.elapsed >= release.duration {
            if release.frameGate.waitsForGPU {
                release.awaitingFinalFrame = true
                paperRelease = release
            } else {
                paperClock.stop(); paperRelease = nil
                finish(transitionID: release.transitionID, completed: release.completed)
            }
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
        paperSnapshotCache = nil
        guard paperEffect != nil else { return }
        pauseAutomaticReading()
        cancelTransition(reason: .memoryWarning)
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
        if usesCover, controller.parent != nil || controller.viewIfLoaded?.superview != nil {
            cancelTransition()
            return false
        }
        let wasMounting = mountingPage
        mountingPage = true
        defer { mountingPage = wasMounting; refreshAutomaticReadingState(); scheduleCurrentPageReplacement() }
        addChild(controller)
        guard canAttach(transitionID: transitionID), !usesCover || controller.parent === self else {
            if usesCover { cancelTransition() }
            detach(controller)
            return false
        }
        let childView = controller.view
        guard canAttach(transitionID: transitionID), let childView,
              !usesCover || (controller.parent === self && childView.superview == nil) else {
            if usesCover { cancelTransition() }
            detach(controller)
            return false
        }
        childView.frame = view.bounds
        if usesCover, !canAttach(transitionID: transitionID) || controller.parent !== self || childView.superview != nil {
            cancelTransition()
            detach(controller)
            return false
        }
        childView.isHidden = initiallyHidden
        if usesCover, !canAttach(transitionID: transitionID) || controller.parent !== self || childView.superview != nil {
            cancelTransition()
            detach(controller)
            return false
        }
        view.addSubview(childView)
        guard canAttach(transitionID: transitionID), !usesCover || ownsCoverPage(controller) else {
            if usesCover { cancelTransition() }
            detach(controller)
            return false
        }
        registerZoomContent(in: controller)
        controller.didMove(toParent: self)
        guard canAttach(transitionID: transitionID), !usesCover || ownsCoverPage(controller) else {
            if usesCover { cancelTransition() }
            detach(controller)
            return false
        }
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
            // cover 的同步回调可能把目标交给外部；只清理仍属于自己的 containment 和视图。
            if !usesCover || controller.parent === self {
                if !usesCover || controller.viewIfLoaded?.superview === viewIfLoaded {
                    controller.viewIfLoaded?.removeFromSuperview()
                }
                if !usesCover || controller.parent === self { controller.removeFromParent() }
            }
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
        publishAutomaticProgress()
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
    private func cancelScrollInteractions(reason: PageTurnAnimationDiagnostic.EndReason) {
        scrollHandoffs.forEach { $0.cancelInteraction(reason: reason) }
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
            publishAutomaticProgress()
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
        paperSnapshotCache = nil
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
        queuedDiscreteTurns.removeAll(keepingCapacity: false)
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

    /// 发布瞬时进度；复用 UI 事务门禁，允许暂停／停止／失效但拒绝同步发起新翻页。
    private func publishAutomaticProgress() {
        guard isActive, !publishingAutomaticProgress else { return }
        let value = automaticReadingProgress
        guard value != lastPublishedAutomaticProgress else { return }
        guard !deliveringEvents, !requestingPage, !mountingPage, !replacingPage,
              !notifyingAutomaticState, !deliveringReplacementOutcome else {
            scheduleAutomaticProgress()
            return
        }
        publishingAutomaticProgress = true
        let wasDelivering = deliveringEvents
        deliveringEvents = true
        lastPublishedAutomaticProgress = value
        onAutomaticReadingProgress?(value)
        deliveringEvents = wasDelivering
        publishingAutomaticProgress = false
        refreshAutomaticReadingState()
        scheduleCurrentPageReplacement()
        // 回调可能 stop 清零；合并到下一主队列轮，避免递归通知和迟到旧进度。
        if automaticReadingProgress != lastPublishedAutomaticProgress { scheduleAutomaticProgress() }
    }

    /// 将安装／状态通知中的进度变化合并到下一主队列轮，读取最新进度而不保存过期值。
    private func scheduleAutomaticProgress() {
        guard isActive, !automaticProgressScheduled else { return }
        automaticProgressScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.automaticProgressScheduled = false
            self.publishAutomaticProgress()
        }
    }

    /// 修改单页停留时长，保留已读百分比及当前播放／主动暂停／等待意图。
    /// - Parameter interval: 有限的 0.1...3600 秒。
    /// - Throws: 非法间隔、失效或同步 UI 回调重入；失败保持原设置。
    public func updateAutomaticReadingInterval(_ interval: TimeInterval) throws {
        try validateAutomaticCommand()
        guard interval.isFinite, (0.1...3600).contains(interval) else { throw PagedAutomaticReadingError.invalidInterval }
        let fraction = automaticReadingProgress
        automaticReadingInterval = interval
        automaticElapsed = fraction * interval
        publishAutomaticProgress()
    }

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
        publishAutomaticProgress()
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
        publishAutomaticProgress()
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
        publishAutomaticProgress()
        guard isActive, automaticReadingState == .running,
              automaticElapsed >= automaticReadingInterval - 0.000000001 else { return }
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
        if state == .running, usesDisplayLinkForAutomaticReading { automaticClock.start(maximumFramesPerSecond: view.window?.screen.maximumFramesPerSecond) }
        else { automaticClock.stop() }
        guard state != automaticReadingState else { return }
        automaticReadingState = state
        let wasNotifying = notifyingAutomaticState
        notifyingAutomaticState = true
        onAutomaticReadingStateChange?(state)
        notifyingAutomaticState = wasNotifying
        scheduleCurrentPageReplacement()
    }

    /// 清理动画资源前保留推进时间，避免结束记录丢失为起始的 0ms。
    private func preserveAnimationDiagnosticTiming(animatorFinished: Bool = false) {
        guard animationDiagnosticsEnabled, var trace = animationDiagnosticTrace else { return }
        if let release = paperRelease {
            trace.elapsed = release.elapsed
        } else if let animator {
            let fraction = animatorFinished ? 1 : Double(animator.fractionComplete)
            trace.elapsed = animator.duration * fraction
            let start = trace.startProgress ?? 0
            trace.animatorProgress = start + ((trace.targetProgress ?? 1) - start) * fraction
        }
        animationDiagnosticTrace = trace
    }

    /// 记录只读值，不调用宿主回调，不干预动画推进；高频进度最多每 100ms 一条。
    private func recordAnimationDiagnostic(_ event: PageTurnAnimationDiagnostic.Event,
                                           reason: PageTurnAnimationDiagnostic.EndReason? = nil) {
        guard animationDiagnosticsEnabled, let pending else { return }
        let now = CACurrentMediaTime()
        var trace = animationDiagnosticTrace.flatMap { $0.id == pending.transition.id ? $0 : nil }
            ?? AnimationDiagnosticTrace(id: pending.transition.id, startedAt: now)
        if event == .frame { trace.updates += 1 }
        if event == .releaseStarted { trace.durationScale = Double(transitionDurationScale) }
        if let release = paperRelease {
            trace.duration = release.duration; trace.elapsed = release.elapsed
            trace.startProgress = Double(release.start); trace.targetProgress = Double(release.target)
            trace.curve = pending.isDiscreteTurn || (release.completed && release.cornerStart?.effect == .arch)
                ? "systemEaseInOut" : "cubicEaseOut"
        } else if let animator {
            trace.duration = animator.duration
            trace.elapsed = animator.duration * Double(animator.fractionComplete)
            if event == .releaseStarted { trace.startProgress = Double(pending.progress) }
            trace.targetProgress = settlingCompletion == false ? 0 : 1
            let start = trace.startProgress ?? Double(pending.progress)
            trace.animatorProgress = start + ((trace.targetProgress ?? 1) - start) * Double(animator.fractionComplete)
            trace.curve = "uiViewEaseOut"
        }
        if (event == .frame || event == .waitingForFrame), now - trace.emittedAt < 0.1 {
            animationDiagnosticTrace = trace
            return
        }
        trace.emittedAt = now; trace.event = event
        animationDiagnosticTrace = trace
        animationDiagnosticSequence += 1
        let presentationTimes = paperView?.metalPresentationTimes ?? []
        let gpuFPS: Double?
        if presentationTimes.count > 1, let first = presentationTimes.min(), let last = presentationTimes.max(), last > first {
            gpuFPS = Double(presentationTimes.count - 1) / (last - first)
        } else { gpuFPS = nil }
        #if targetEnvironment(simulator)
        let presentationCount: Int? = nil
        #else
        let presentationCount: Int? = paperView?.usesMetalCornerRendering == true ? paperView?.metalPresentationCount : nil
        #endif
        let requested = paperClock.isRunning ? Int(paperClock.activeFrameRateRange?.preferred ?? 0)
            : paperView?.nativeRequestedFramesPerSecond
        let effect: PageTurnEffect
        if case .paged(let value, _) = configuration.presentation { effect = value } else { effect = .none }
        let snapshot = PageTurnAnimationDiagnostic(sequence: animationDiagnosticSequence,
            transitionID: pending.transition.id, timestamp: now, event: event, endReason: reason,
            effect: effect, direction: pending.transition.direction,
            progress: trace.animatorProgress ?? Double(pending.progress), queueDepth: queuedDiscreteTurns.count,
            wallElapsed: now - trace.startedAt, duration: trace.duration, animationElapsed: trace.elapsed,
            startProgress: trace.startProgress, targetProgress: trace.targetProgress,
            durationScale: trace.durationScale, curve: trace.curve, updateCount: trace.updates,
            gpuSubmissionCount: paperView?.metalDiagnosticSubmissionCount ?? 0,
            gpuPresentationCount: presentationCount, gpuPresentedFramesPerSecond: gpuFPS,
            maximumFramesPerSecond: viewIfLoaded?.window?.screen.maximumFramesPerSecond ?? 0,
            requestedFramesPerSecond: requested, preparationDuration: trace.preparation,
            snapshotPixels: paperView?.snapshotPixelCount ?? 0, frameCPUTime: paperView?.metalLastTiming?.cpu,
            waitingForFinalFrame: paperRelease?.awaitingFinalFrame ?? false)
        recentAnimationDiagnostics.append(snapshot)
        if recentAnimationDiagnostics.count > 180 { recentAnimationDiagnostics.removeFirst(recentAnimationDiagnostics.count - 180) }
        let line = snapshot.logLine
        if event == .frame { Self.animationLogger.debug("\(line, privacy: .public)") }
        else { Self.animationLogger.notice("\(line, privacy: .public)") }
    }
}
#endif
