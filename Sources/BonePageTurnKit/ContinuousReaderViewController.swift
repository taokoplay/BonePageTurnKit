#if canImport(UIKit)
import UIKit

@MainActor
public protocol ContinuousContentProvider: AnyObject {
    /// - Parameter reuseIdentifier: 内容视图类别。
    /// - Returns: 未挂载、可复用的视图；不要返回别的单元正在使用的视图。
    func makeContentView(reuseIdentifier: String) -> UIView
    /// 绑定时可以启动宿主任务；结果回到主线程后先调用容器 isCurrent(binding)。
    /// - Parameters: view: 内容视图；item: 元数据；binding: 本次复用绑定。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding)
    /// - Parameters: view: 离屏或失效视图；binding: 已失效绑定，宿主在此取消关联任务。
    func unbind(_ view: UIView, binding: PageViewBinding)
}

/// 纵向任意位置连续滚动；异高窗口、内容视图复用和锚点补偿均独立于宿主业务。
@MainActor
public final class ContinuousReaderViewController: UIViewController, UIScrollViewDelegate {
    public let presentationID = UUID()
    public private(set) var window: ContinuousWindow
    public private(set) var isActive = true
    public var onVisibleAnchor: ((ContinuousAnchor) -> Void)?
    public var onStableAnchor: ((ContinuousAnchor) -> Void)?
    /// 回调只提出需求，不代表全书结束，也不拥有宿主加载任务。异步结果携带此令牌安装。
    public var onEdgeApproach: ((PageTurnDirection, ContinuousUpdateToken) -> Void)?
    /// 结构化补屏需求：包含窗口外／占位目标与缺失可读高度。设置后优先于旧 onEdgeApproach。
    public var onContentDemand: ((ContinuousContentDemand) -> Void)?
    /// 自动补入达到预算时通知一次；不代表书尾，也不撤销已安装内容。
    public var onFillLimitReached: ((PageTurnDirection, ContinuousFillLimit) -> Void)?
    public let fillPolicy: ContinuousFillPolicy
    public var readableCoverage: ContinuousReadableCoverage? {
        guard visibleAnchor != nil else { return nil }
        return window.readableCoverage(at: Double(scrollView.contentOffset.y), viewportExtent: Double(scrollView.bounds.height))
    }
    public var onInteractionIdle: (() -> Void)?
    public var onViewportSizeChange: ((CGSize) -> Void)?
    /// 首次布局发现目标屏幕位置超出视口时通知宿主；解析完成前不发布阅读位置。
    public var onAnchorRestorationFailure: ((ContinuousAnchor) -> Void)?
    public var onReadingStatus: ((ReaderStatus) -> Void)?
    public var readingStatus: ReaderStatus? {
        guard visibleAnchor != nil else { return nil }
        guard let status = window.readingStatus(at: Double(scrollView.contentOffset.y),
                                                viewportExtent: Double(scrollView.bounds.height), presentationID: presentationID) else { return nil }
        guard paginationMatchesViewport else {
            return ReaderStatus(presentationID: presentationID, identity: status.identity,
                                info: .init(pagination: status.pagination.excludingLayoutPages,
                                            before: status.before, after: status.after))
        }
        return status
    }

    public var updateToken: ContinuousUpdateToken {
        ContinuousUpdateToken(presentationID: presentationID, revision: revision)
    }
    public var visibleAnchor: ContinuousAnchor? {
        guard isActive, isViewLoaded, initialAnchor == nil else { return nil }
        return window.anchor(at: Double(scrollView.contentOffset.y), viewportExtent: Double(scrollView.bounds.height))
    }
    public var mountedContentViewCount: Int { mounted.count }

    private struct Mounted {
        let item: ContinuousItem
        let binding: PageViewBinding
        let view: UIView
    }
    private weak var provider: (any ContinuousContentProvider)?
    // 内部保留访问，@testable 的 UIKit 测试可以驱动真实 UIScrollView。
    let scrollView = UIScrollView()
    private let contentView = UIView()
    private var mounted: [String: Mounted] = [:]
    private var pool: [(String, UIView)] = []
    private var revision: UInt64 = 0
    private var updating = false
    private var notifying = false
    private var suspensionReasons: Set<String> = []
    private var initialAnchor: ContinuousAnchor?
    private var viewportSize = CGSize.zero
    private var lastStableAnchor: ContinuousAnchor?
    private var filling = ContinuousFillController()
    private var fillMovementAnchor: ContinuousAnchor?
    private var fillMovementDistance: Double = 0
    private var lastPublishedStatus: ReaderStatus?
    private let loads = ContinuousLoadCoordinator()
    private var installingTicket: ContinuousLoadTicket?
    private var drainScheduled = false
    private var paginationMatchesViewport = true

    private enum AutomaticIntent { case stopped, playing, paused, finished }
    private var automaticIntent: AutomaticIntent = .stopped
    public private(set) var automaticReadingState: ContinuousAutomaticReadingState = .stopped
    public private(set) var automaticReadingSpeed: Double = 30
    public var onAutomaticReadingStateChange: ((ContinuousAutomaticReadingState) -> Void)?
    private let automaticClock = ReaderDisplayLink()
    private var automaticViewVisible = false
    private var automaticApplicationActive = true
    private var automaticInteractionActive = false
    private var notifyingAutomaticState = false
    private var automaticCommitPending = false
    private var automaticTargetOffset: Double?
    private var automaticLastAppliedOffset: Double?
    // 测试通过同一推进入口注入时间；生产默认使用真实 CADisplayLink。
    internal var usesDisplayLinkForAutomaticReading = true
    internal var isAutomaticClockRunning: Bool { automaticClock.isRunning }

    /// - Parameters: window: 首个有效窗口；provider: 宿主外部保留的视图工厂；anchor: 当前布局目标锚点；fillPolicy: 按可读高度自动补入的范围和预算。
    /// - Throws: 初始锚点不属于给定窗口。
    public init(window: ContinuousWindow, provider: any ContinuousContentProvider,
                anchor: ContinuousAnchor? = nil, fillPolicy: ContinuousFillPolicy = .standard) throws {
        if let anchor {
            // 初始化尚无视口，先校验身份、版本与块内位置；真正偏移在布局时计算。
            try window.validate(anchor)
        }
        self.window = window
        self.provider = provider
        initialAnchor = anchor
        self.fillPolicy = fillPolicy
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用窗口初始化方法") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        automaticClock.onTick = { [weak self] interval in self?.advanceAutomaticReading(elapsed: interval) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillDeactivate),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidActivate),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        automaticViewVisible = true
        refreshAutomaticReadingState()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        automaticViewVisible = false
        refreshAutomaticReadingState()
    }

    /// 应用失活时只暂停实际时钟，不改写用户播放／暂停意图。
    @objc private func applicationWillDeactivate() { setAutomaticApplicationActive(false) }
    @objc private func applicationDidActivate() { setAutomaticApplicationActive(true) }

    /// - Parameter active: 应用是否可交互；测试和系统通知共用此入口。
    internal func setAutomaticApplicationActive(_ active: Bool) {
        automaticApplicationActive = active
        refreshAutomaticReadingState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isActive, !updating, view.bounds.height > 0, view.bounds.width > 0 else { return }
        let changed = viewportSize != view.bounds.size
        if changed, viewportSize != .zero { paginationMatchesViewport = false }
        let anchor = initialAnchor ?? visibleAnchor
        updating = true
        if changed { revision += 1; filling.reset(); fillMovementDistance = 0 }
        scrollView.frame = view.bounds
        viewportSize = view.bounds.size
        layoutContent()
        var failedAnchor: ContinuousAnchor?
        if let anchor {
            do {
                let offset = try window.offset(for: anchor, viewportExtent: Double(viewportSize.height))
                scrollView.contentOffset.y = CGFloat(offset)
                initialAnchor = nil
            } catch {
                failedAnchor = anchor
                initialAnchor = anchor
            }
        }
        renderVisibleContent()
        if changed { loads.discard(except: updateToken) }
        updating = false
        fillMovementAnchor = visibleAnchor
        publishPosition(stable: true)
        if let failedAnchor, isActive { onAnchorRestorationFailure?(failedAnchor) }
        if changed, isActive { onViewportSizeChange?(viewportSize) }
        schedulePendingInstallation()
    }

    /// 立即原子替换窗口并补偿锚点。交互中仍拒绝直接安装；加载结果可用 beginLoading／submit 自动延期。
    /// - Parameters: newWindow: 完整窗口；expectedToken: 请求开始时版本；anchor: 重排后由宿主重新解析的锚点，nil 表示保持当前锚点。
    /// - Throws: 旧请求、交互占用、内容状态倒退或不可恢复的锚点。失败时保持原窗口。
    public func apply(_ newWindow: ContinuousWindow, expectedToken: ContinuousUpdateToken,
                      anchor: ContinuousAnchor? = nil) throws {
        try validateMutation(expectedToken)
        try newWindow.validateReplacement(of: window)
        let preserved = anchor ?? initialAnchor ?? visibleAnchor
        let offset = try preserved.map { try offsetWhenLaidOut(for: $0, in: newWindow) } ?? 0
        if let ticket = installingTicket { try loads.lockForInstallation(ticket) }
        let oldWindow = window
        let oldAnchor = initialAnchor ?? visibleAnchor
        updating = true
        filling.installed(from: oldWindow, to: newWindow, token: expectedToken,
                          owner: installingTicket?.direction, anchor: oldAnchor)
        window = newWindow
        paginationMatchesViewport = true
        revision += 1
        initialAnchor = scrollView.bounds.height > 0 ? nil : preserved
        if isViewLoaded {
            layoutContent()
            scrollView.contentOffset.y = CGFloat(offset)
            renderVisibleContent()
        }
        if installingTicket != nil, isActive { loads.confirmInstallation(token: updateToken) }
        loads.discard(except: updateToken)
        updating = false
        fillMovementAnchor = visibleAnchor
        publishPosition(stable: true)
    }

    /// 在同一窗口内显式定位并推进修订号，旧窗口请求不能将位置拉回。
    /// - Parameters: anchor: 当前布局锚点；expectedToken: 当前窗口令牌。
    /// - Throws: 交互占用、旧令牌或无效锚点。
    public func restore(_ anchor: ContinuousAnchor, expectedToken: ContinuousUpdateToken) throws {
        try validateMutation(expectedToken)
        let offset = try offsetWhenLaidOut(for: anchor, in: window)
        automaticIntent = .stopped
        automaticCommitPending = false
        automaticClock.stop()
        updating = true
        revision += 1
        filling.reset()
        fillMovementDistance = 0
        initialAnchor = scrollView.bounds.height > 0 ? nil : anchor
        scrollView.contentOffset.y = CGFloat(offset)
        if isViewLoaded { renderVisibleContent() }
        loads.discard(except: updateToken)
        updating = false
        fillMovementAnchor = visibleAnchor
        publishPosition(stable: true)
    }

    /// - Parameter direction: 加载方向。
    /// - Returns: 本周期自动补入的阻塞原因；手动加载不受自动需求预算限制。
    public func fillLimit(in direction: PageTurnDirection) -> ContinuousFillLimit? { filling.limit(in: direction) }

    /// 由用户重试／宿主预算许可显式开始新补屏周期；不推进窗口令牌，也不冒充数据已经就绪。
    /// - Throws: 失效容器、UI 回调重入或仍有未终止的加载任务。
    public func resumeContentFilling() throws {
        try validateMutation(updateToken)
        guard loads.activeCount == 0 else { throw PageTurnError.interactionInProgress }
        filling.reset()
        fillMovementDistance = 0
        fillMovementAnchor = visibleAnchor
        publishPosition(stable: false)
    }

    /// 为一个方向登记加载所有权。SDK 不执行磁盘／网络读取；宿主提供任务取消句柄。
    /// - Parameters: direction: 加载方向；token: 需求版本；target: 目标，默认关联最近发出的同版本需求；cancel: 任务取消动作；completion: 唯一终止通知。
    /// - Returns: 后续 submit 使用的唯一任务票据。
    /// - Throws: 过期窗口、失效容器或重复方向任务。
    public func beginLoading(_ direction: PageTurnDirection, token: ContinuousUpdateToken,
                             target: ContinuousLoadTarget? = nil, cancel: @escaping () -> Void,
                             completion: @escaping (ContinuousLoadOutcome) -> Void) throws -> ContinuousLoadTicket {
        try validateLoadToken(token)
        let target = target ?? filling.pendingTarget(in: direction, token: token) ?? .edge
        if case .item(let identity) = target, window.item(withID: identity.unitID)?.identity != identity {
            throw PageTurnError.staleContent(identity.unitID)
        }
        return try loads.begin(direction: direction, token: token, target: target, cancel: cancel, completion: completion)
    }

    /// 提交完整窗口；拖动、减速、暂停或同步回调中只登记，空闲后重新捕获可见锚点再安装。
    /// - Parameters: newWindow: 宿主合并后的完整窗口；ticket: 任务票据；anchor: 显式重排锚点，nil 为安装时保留当前位置。
    /// - Throws: 过期或重复提交；已接受结果通过 completion 通知 installed／superseded／rejected 等终态。
    public func submit(_ newWindow: ContinuousWindow, for ticket: ContinuousLoadTicket,
                       anchor: ContinuousAnchor? = nil) throws {
        try validateLoadToken(ticket.token)
        try loads.accept(ticket, window: newWindow, anchor: anchor)
        schedulePendingInstallation()
    }

    /// - Parameter ticket: 宿主主动取消的任务；重复取消无副作用，已进入原子安装的票据不可再取消。
    public func cancelLoading(_ ticket: ContinuousLoadTicket) { loads.finish(ticket, outcome: .cancelled) }

    /// - Parameters: ticket: 读取／排版失败的任务；error: 中性失败原因，错误视图由宿主单独提供。
    public func rejectLoading(_ ticket: ContinuousLoadTicket, error: PageTurnError) {
        loads.finish(ticket, outcome: .rejected(error))
    }

    /// - Parameter token: 需求／结果携带的版本；允许交互中登记，但不允许旧结果接管。
    private func validateLoadToken(_ token: ContinuousUpdateToken) throws {
        guard isActive else { throw PageTurnError.inactive }
        guard token.presentationID == presentationID else { throw PageTurnError.stalePresentation }
        guard token == updateToken else { throw PageTurnError.staleWindow }
    }

    /// 将同步回调产生的结果推迟到本轮 UI 事务之后；只安排一个主队列动作。
    private func schedulePendingInstallation() {
        guard isActive, !drainScheduled, loads.preparedUpdate != nil else { return }
        drainScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.installPendingUpdateIfIdle()
        }
    }

    /// 空闲时消费最新完整窗口；测试通过同一入口验证拖动后的安装与终态。
    func installPendingUpdateIfIdle() {
        guard isActive, !updating, !notifying, !notifyingAutomaticState, !loads.isInTerminalCallback,
              isViewLoaded, scrollView.bounds.height > 0, scrollView.bounds.width > 0,
              !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating,
              suspensionReasons.isEmpty, let prepared = loads.preparedUpdate else { return }
        installingTicket = prepared.ticket
        defer { installingTicket = nil }
        do {
            try apply(prepared.window, expectedToken: prepared.ticket.token, anchor: prepared.anchor)
        } catch let error as PageTurnError {
            loads.finish(prepared.ticket, outcome: .rejected(error))
        } catch {
            loads.finish(prepared.ticket, outcome: .rejected(.invalidWindow))
        }
        loads.discard(except: updateToken)
    }

    /// - Parameter binding: 异步结果携带的完整绑定。
    /// - Returns: 视图仍挂载且身份、内容、布局、复用代际均匹配时为 true。
    public func isCurrent(_ binding: PageViewBinding) -> Bool {
        isActive && binding.presentationID == presentationID && mounted[binding.identity.unitID]?.binding == binding
    }

    /// - Parameters: suspended: 是否暂停；reason: 独立原因。解除后仅恢复原先仍为播放意图的自动阅读。
    public func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if suspended { scrollView.setContentOffset(scrollView.contentOffset, animated: false) }
        scrollView.isScrollEnabled = isActive && suspensionReasons.isEmpty
        refreshAutomaticReadingState()
        if !suspended, suspensionReasons.isEmpty, isActive {
            installPendingUpdateIfIdle()
            onInteractionIdle?()
        }
    }

    /// 退出／模式切换时终止回调并使所有绑定失效；可重复调用。
    public func invalidate() {
        guard isActive else { return }
        isActive = false
        automaticIntent = .stopped
        automaticReadingState = .stopped
        automaticCommitPending = false
        automaticClock.stop()
        NotificationCenter.default.removeObserver(self)
        scrollView.delegate = nil
        scrollView.isScrollEnabled = false
        loads.invalidate()
        for key in Array(mounted.keys) { recycle(key) }
        pool.removeAll()
        onVisibleAnchor = nil
        onStableAnchor = nil
        onEdgeApproach = nil
        onContentDemand = nil
        onFillLimitReached = nil
        filling.reset()
        onInteractionIdle = nil
        onViewportSizeChange = nil
        onAnchorRestorationFailure = nil
        onReadingStatus = nil
        onAutomaticReadingStateChange = nil
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isActive, !updating else { return }
        updating = true
        renderVisibleContent()
        updating = false
        updateFillCycleForMovement()
        publishPosition(stable: false)
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        automaticInteractionActive = true
        refreshAutomaticReadingState()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrolling() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrolling() }

    /// - Parameters: anchor: 待定位锚点；window: 目标窗口。
    /// - Returns: 已布局时的实际偏移；未布局时只验证锚点并返回占位零值。
    /// - Throws: 无效锚点；不使用虚构视口拒绝合法的屏幕偏移。
    private func offsetWhenLaidOut(for anchor: ContinuousAnchor, in window: ContinuousWindow) throws -> Double {
        try window.validate(anchor)
        guard scrollView.bounds.height > 0 else { return 0 }
        return try window.offset(for: anchor, viewportExtent: Double(scrollView.bounds.height))
    }

    /// - Parameter token: 安装前置版本。
    /// - Throws: 生命周期、版本或交互占用错误。
    private func validateMutation(_ token: ContinuousUpdateToken) throws {
        guard isActive else { throw PageTurnError.inactive }
        guard token.presentationID == presentationID else { throw PageTurnError.stalePresentation }
        guard token.revision == revision else { throw PageTurnError.staleWindow }
        guard !updating, !notifying, !notifyingAutomaticState, !loads.isInTerminalCallback, !scrollView.isTracking, !scrollView.isDragging,
              !scrollView.isDecelerating, suspensionReasons.isEmpty else { throw PageTurnError.interactionInProgress }
    }

    /// 更新内容大小；调用方抑制中间 scroll 回调。
    private func layoutContent() {
        contentView.frame = CGRect(x: 0, y: 0, width: scrollView.bounds.width, height: CGFloat(window.totalExtent))
        scrollView.contentSize = contentView.bounds.size
    }

    /// 内存告警时立即释放离屏复用池，保留当前可见视图与阅读锚点。
    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        pool.removeAll()
    }

    /// 仅安装可见范围与前后各半屏的内容，复用池最多保留八个视图。
    private func renderVisibleContent() {
        guard isActive, scrollView.bounds.height > 0, let provider else { return }
        let height = Double(scrollView.bounds.height)
        let offset = window.clampedOffset(Double(scrollView.contentOffset.y), viewportExtent: height)
        let range = window.indices(intersecting: offset - height * 0.5, offset + height * 1.5)
        let wanted = Set(range.map { window.items[$0].identity.unitID })
        for key in Array(mounted.keys) where !wanted.contains(key) { recycle(key) }
        for index in range {
            guard isActive else { return }
            let item = window.items[index]
            let key = item.identity.unitID
            if let old = mounted[key], old.item != item { recycle(key) }
            guard isActive else { return }
            if mounted[key] == nil {
                let view: UIView
                if let poolIndex = pool.firstIndex(where: { $0.0 == item.reuseIdentifier }) {
                    view = pool.remove(at: poolIndex).1
                } else {
                    view = provider.makeContentView(reuseIdentifier: item.reuseIdentifier)
                }
                guard isActive else { return }
                let binding = PageViewBinding(identity: item.identity, presentationID: presentationID)
                mounted[key] = Mounted(item: item, binding: binding, view: view)
                contentView.addSubview(view)
                view.frame = CGRect(x: 0, y: CGFloat(window.origin(of: key) ?? 0),
                                    width: scrollView.bounds.width, height: CGFloat(item.extent))
                provider.bind(view, to: item, binding: binding)
            }
            mounted[key]?.view.frame = CGRect(x: 0, y: CGFloat(window.origin(of: key) ?? 0),
                                             width: scrollView.bounds.width, height: CGFloat(item.extent))
        }
    }

    /// - Parameter key: 将要回收的稳定单元 ID；先使绑定失效，再通知宿主。
    private func recycle(_ key: String) {
        guard let entry = mounted.removeValue(forKey: key) else { return }
        entry.view.removeFromSuperview()
        provider?.unbind(entry.view, binding: entry.binding)
        if isActive, pool.count < 8 { pool.append((entry.item.reuseIdentifier, entry.view)) }
    }

    /// - Parameter stable: 是否尝试发布可持久化位置；加载占位、回弹和交互中不发布稳定事件。
    private func publishPosition(stable: Bool) {
        guard isActive, !updating, !notifying, !notifyingAutomaticState, let anchor = visibleAnchor else { return }
        notifying = true
        defer {
            notifying = false
            refreshAutomaticReadingState()
        }
        if let status = readingStatus, status != lastPublishedStatus {
            lastPublishedStatus = status
            onReadingStatus?(status)
        }
        guard isActive else { return }
        onVisibleAnchor?(anchor)
        guard isActive else { return }
        let height = Double(scrollView.bounds.height)
        let offset = Double(scrollView.contentOffset.y)
        let clamped = window.clampedOffset(offset, viewportExtent: height)
        let index = window.indices(intersecting: clamped, clamped + 1).first
        if (stable || automaticCommitPending), automaticIntent != .playing,
           !automaticInteractionActive, !scrollView.isDragging, !scrollView.isDecelerating, !scrollView.isTracking,
           (suspensionReasons.isEmpty || automaticCommitPending), abs(offset - clamped) < 0.5,
           let index, window.items[index].state == .ready,
           mounted[anchor.identity.unitID]?.binding.identity == anchor.identity {
            automaticCommitPending = false
            if lastStableAnchor != anchor {
                lastStableAnchor = anchor
                onStableAnchor?(anchor)
            }
        }
        guard isActive else { return }
        publishContentDemands()
    }

    /// 在同一通知事务内生成有界补屏需求；旧接口只通知物理边缘，不定位窗口内占位。
    private func publishContentDemands() {
        guard let coverage = readableCoverage else { return }
        let token = updateToken
        let demands: [ContinuousContentDemand]
        if onContentDemand != nil {
            demands = window.contentDemands(at: coverage.viewportOffset, viewportExtent: coverage.viewportExtent,
                                            token: token, policy: fillPolicy)
        } else if onEdgeApproach != nil {
            // 保持原边缘协议兼容。需要区分内部占位时使用 onContentDemand。
            let height = coverage.viewportExtent
            var edges: [ContinuousContentDemand] = []
            if coverage.viewportOffset < height * fillPolicy.leadingViewports, window.before == .available {
                edges.append(.init(direction: .previous, target: .edge, token: token, coverage: coverage,
                                   missingReadyExtent: max(0, height * fillPolicy.leadingViewports - coverage.contiguousReadyBefore)))
            }
            if window.totalExtent - coverage.viewportOffset - height < height * fillPolicy.trailingViewports,
               window.after == .available {
                edges.append(.init(direction: .next, target: .edge, token: token, coverage: coverage,
                                   missingReadyExtent: max(0, height * (1 + fillPolicy.trailingViewports) - coverage.contiguousReadyFromTop)))
            }
            demands = edges
        } else { return }
        for demand in demands {
            guard isActive else { return }
            guard !loads.hasRequest(in: demand.direction), !loads.hasRequest(for: demand.target, token: demand.token) else { continue }
            if filling.admit(demand, policy: fillPolicy) {
                if let onContentDemand { onContentDemand(demand) }
                else { onEdgeApproach?(demand.direction, demand.token) }
            } else if onFillLimitReached != nil, let limit = filling.takeUnreportedLimit(in: demand.direction) {
                onFillLimitReached?(demand.direction, limit)
            }
        }
    }

    /// 真正移动至少一个视口才重开预算；安装补偿会更新检查点，但不触发此重置。
    private func updateFillCycleForMovement() {
        guard let anchor = visibleAnchor else { return }
        guard let previous = fillMovementAnchor,
              let previousOrigin = window.origin(of: previous.identity.unitID),
              let currentOrigin = window.origin(of: anchor.identity.unitID) else {
            fillMovementAnchor = anchor
            return
        }
        let distance = (currentOrigin + anchor.offsetInItem) - (previousOrigin + previous.offsetInItem)
        fillMovementDistance += distance
        fillMovementAnchor = anchor
        if abs(fillMovementDistance) >= max(1, Double(scrollView.bounds.height)) {
            filling.reset()
            fillMovementDistance = 0
        }
    }

    /// 滚动停止时发布稳定位置，随后允许宿主重试被拒绝的最新窗口。
    private func finishScrolling() {
        guard isActive else { return }
        automaticInteractionActive = false
        installPendingUpdateIfIdle()
        publishPosition(stable: true)
        if isActive { onInteractionIdle?() }
    }

    // MARK: - 连续自动阅读

    /// 开始向后连续阅读。速度有限且为 (0, 2000] point/s；不改变窗口请求版本。
    /// - Parameter pointsPerSecond: 每秒前进的 point 数。
    /// - Throws: 非法速度、失效 renderer 或 UI 事务重入；失败不改变旧状态。
    public func startAutomaticReading(pointsPerSecond: Double = 30) throws {
        guard isActive else { throw PageTurnError.inactive }
        guard pointsPerSecond.isFinite, pointsPerSecond > 0, pointsPerSecond <= 2000 else {
            throw ContinuousAutomaticReadingError.invalidSpeed
        }
        guard !updating, !notifying, !notifyingAutomaticState, !loads.isInTerminalCallback else {
            throw PageTurnError.interactionInProgress
        }
        automaticReadingSpeed = pointsPerSecond
        automaticIntent = .playing
        automaticCommitPending = false
        refreshAutomaticReadingState()
        publishPosition(stable: false)
    }

    /// 主动暂停并尝试提交有效位置；后续加载完成、关闭菜单或前台恢复不会擅自继续。
    public func pauseAutomaticReading() {
        guard isActive, automaticIntent != .stopped, automaticIntent != .finished else { return }
        automaticIntent = .paused
        automaticCommitPending = true
        refreshAutomaticReadingState()
        publishPosition(stable: true)
    }

    /// 恢复此前主动暂停的会话，保持速度；已停止／已结束的会话需要显式 start。
    /// - Throws: 容器失效或同步回调重入。
    public func resumeAutomaticReading() throws {
        guard isActive else { throw PageTurnError.inactive }
        guard !updating, !notifying, !notifyingAutomaticState, !loads.isInTerminalCallback else {
            throw PageTurnError.interactionInProgress
        }
        guard automaticIntent == .paused else { return }
        automaticIntent = .playing
        automaticCommitPending = false
        refreshAutomaticReadingState()
        publishPosition(stable: false)
    }

    /// 退出在通知事务中发生时，将最终提交移到下一主线程轮；保留 renderer 到提交结束。
    /// - Parameter completion: 有效位置尝试提交之后执行的最终失效动作。
    internal func completeReadingBeforeExit(_ completion: @escaping @MainActor () -> Void) {
        if updating || notifying || notifyingAutomaticState || loads.isInTerminalCallback {
            DispatchQueue.main.async { [self] in
                stopAutomaticReading(commitPosition: true)
                completion()
            }
        } else {
            stopAutomaticReading(commitPosition: true)
            completion()
        }
    }

    /// 停止自动阅读，允许在菜单／退出暂停期间提交一次有效稳定位置。
    /// - Parameter commitPosition: 是否提交有效位置；拖动、回弹和未就绪内容仍不提交。
    public func stopAutomaticReading(commitPosition: Bool = true) {
        guard isActive else { return }
        automaticIntent = .stopped
        automaticCommitPending = commitPosition
        refreshAutomaticReadingState()
        if commitPosition { publishPosition(stable: true) }
    }

    /// 系统与测试共用的推进路径；限制单帧积压为 0.1 秒，不使用 restore、不更改窗口令牌。
    /// - Parameter elapsed: 本帧与上一帧的实际间隔。
    internal func advanceAutomaticReading(elapsed: TimeInterval) {
        guard isActive, elapsed.isFinite, elapsed > 0, !updating, !notifying,
              !notifyingAutomaticState, !loads.isInTerminalCallback else { return }
        refreshAutomaticReadingState()
        guard isActive, automaticReadingState == .running else { return }
        let offset = Double(scrollView.contentOffset.y)
        let limit = window.automaticReadingLimit(at: offset, viewportExtent: Double(scrollView.bounds.height))
        let continuesPreviousFrame = automaticLastAppliedOffset.map { abs(offset - $0) < 0.001 } ?? false
        let origin = continuesPreviousFrame ? (automaticTargetOffset ?? offset) : offset
        let next = min(limit.offset, origin + automaticReadingSpeed * min(elapsed, 0.1))
        automaticTargetOffset = next
        let scale = Double(max(1, traitCollection.displayScale))
        let pixelAligned = min(limit.offset, (next * scale).rounded() / scale)
        automaticLastAppliedOffset = offset
        guard pixelAligned > offset else { refreshAutomaticReadingState(); return }
        updating = true
        scrollView.contentOffset.y = CGFloat(pixelAligned)
        automaticLastAppliedOffset = Double(scrollView.contentOffset.y)
        renderVisibleContent()
        updating = false
        updateFillCycleForMovement()
        publishPosition(stable: false)
    }

    /// 由用户意图、交互门禁和可读窗口推导实际运行状态；先停／开时钟，再通知宿主。
    private func refreshAutomaticReadingState() {
        guard isActive, !updating, !notifying else { return }
        let state: ContinuousAutomaticReadingState
        switch automaticIntent {
        case .stopped: state = .stopped
        case .paused: state = .paused
        case .finished: state = .finished(.endOfBook)
        case .playing:
            if !automaticViewVisible || !automaticApplicationActive || automaticInteractionActive ||
                !suspensionReasons.isEmpty || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                state = .paused
            } else if !isViewLoaded || initialAnchor != nil || !paginationMatchesViewport || provider == nil ||
                        scrollView.bounds.height <= 0 || scrollView.bounds.width <= 0 {
                state = .waiting(.loading)
            } else {
                let offset = Double(scrollView.contentOffset.y)
                let clamped = window.clampedOffset(offset, viewportExtent: Double(scrollView.bounds.height))
                let limit = window.automaticReadingLimit(at: clamped, viewportExtent: Double(scrollView.bounds.height))
                if abs(offset - clamped) > 0.5 {
                    state = .paused
                } else if clamped >= limit.offset - 1 / Double(max(1, traitCollection.displayScale)) {
                    if limit.boundary == .endOfBook {
                        automaticIntent = .finished
                        automaticCommitPending = true
                        state = .finished(.endOfBook)
                    } else { state = .waiting(limit.boundary) }
                } else { state = .running }
            }
        }
        if state == .running, usesDisplayLinkForAutomaticReading { automaticClock.start() }
        else { automaticClock.stop() }
        if state != .running {
            automaticTargetOffset = nil
            automaticLastAppliedOffset = nil
        }
        guard state != automaticReadingState else { return }
        automaticReadingState = state
        let wasNotifying = notifyingAutomaticState
        notifyingAutomaticState = true
        onAutomaticReadingStateChange?(state)
        notifyingAutomaticState = wasNotifying
        if automaticCommitPending { publishPosition(stable: true) }
        schedulePendingInstallation()
    }
}
#endif
