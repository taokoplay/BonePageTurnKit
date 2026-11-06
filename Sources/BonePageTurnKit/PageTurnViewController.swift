#if canImport(UIKit)
import UIKit

/// 模式切换入口。宿主先解析新模式的内容／语义位置，再调用 show；校验失败保留旧 renderer。
@MainActor
public final class PageTurnViewController: UIViewController {
    public private(set) var pagedReader: PagedReaderViewController?
    public private(set) var continuousReader: ContinuousReaderViewController?
    public private(set) var configuration: PageTurnConfiguration?
    private var switching = false
    private var candidate: Candidate?
    /// 最终位置提交与 renderer 失效完成后通知；宿主可在此执行实际导航。
    public var onExitFinalized: ((ReaderExitToken) -> Void)?
    private var suspensionReasons: Set<String> = []
    private let exitSuspensionReason = "reader-exit-\(UUID().uuidString)"
    private var exitToken: ReaderExitToken?
    private var finishingExit = false
    public var isExitInProgress: Bool { exitToken != nil }

    /// 可选的安全区／保留区域策略。默认 nil，保持宿主直接指定视口的既有行为。
    public var adaptiveLayoutPolicy: ReaderAdaptiveLayoutPolicy? {
        didSet { refreshAdaptiveLayout() }
    }
    public private(set) var adaptiveLayout: ReaderAdaptiveLayout?
    /// 下一主队列事务通知最新布局；宿主按原语义位置准备单页或双页，不在布局回调中重排正文。
    public var onAdaptiveLayoutChange: ((ReaderAdaptiveLayout) -> Void)? {
        didSet { publishedAdaptiveLayout = nil; scheduleAdaptiveNotification() }
    }
    public var onAdaptiveLayoutError: ((Error) -> Void)?
    private var publishedAdaptiveLayout: ReaderAdaptiveLayout?
    private var adaptiveNotificationScheduled = false
    private var adaptiveEpoch = UUID()
    private var adaptiveObservationActive = true
    private var failedAdaptiveEnvironment: ReaderViewportEnvironment?
    private var failedAdaptivePolicy: ReaderAdaptiveLayoutPolicy?
    private var adaptiveResultID = UUID()
    private var deliveringAdaptiveLayout = false
    private let adaptiveSuspensionReason = "reader-adaptive-layout-\(UUID().uuidString)"

    @MainActor
    private enum Candidate {
        case paged(PagedReaderViewController)
        case continuous(ContinuousReaderViewController)

        var controller: UIViewController {
            switch self {
            case .paged(let reader): return reader
            case .continuous(let reader): return reader
            }
        }
        var isActive: Bool {
            switch self {
            case .paged(let reader): return reader.isActive
            case .continuous(let reader): return reader.isActive
            }
        }
        /// 终止准备或安装中的 renderer，使宿主退出能同步阻止后续安装。
        func invalidate() {
            switch self {
            case .paged(let reader): reader.invalidate()
            case .continuous(let reader): reader.invalidate()
            }
        }
        /// - Parameters: suspended: 是否暂停；reason: 外壳独立暂停原因。
        func setSuspended(_ suspended: Bool, reason: String) {
            switch self {
            case .paged(let reader): reader.setSuspended(suspended, reason: reason)
            case .continuous(let reader): reader.setSuspended(suspended, reason: reason)
            }
        }
    }

    /// 创建空容器；首次 show 前不产生阅读位置事件。
    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用无参初始化方法") }

    public override func loadView() {
        let viewport = ReaderViewportView(frame: .zero)
        view = viewport
        viewport.onEnvironmentChange = { [weak self] environment in
            self?.updateAdaptiveLayout(for: environment)
        }
    }

    /// - Parameters: page: 已解析到目标位置的页面；configuration: 支持的分页配置；prepare: 安装前设置 provider 和事件。
    /// - Returns: 新分页 renderer。
    /// - Throws: 不支持的配置、非法页面、候选失效或切换重入；候选加载失败时保留旧展示。
    @discardableResult
    public func showPaged(page: PageContent, configuration: PageTurnConfiguration,
                          prepare: ((PagedReaderViewController) -> Void)? = nil) throws -> PagedReaderViewController {
        guard !switching, exitToken == nil, !finishingExit else { throw PageTurnError.interactionInProgress }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            guard page.controller !== controller else { throw PageTurnError.invalidPageController }
            ancestor = controller.parent
        }
        let reader = try PagedReaderViewController(page: page, configuration: configuration)
        let candidate = Candidate.paged(reader)
        self.candidate = candidate
        switching = true
        defer { self.candidate = nil; switching = false; scheduleAdaptiveNotification() }
        for reason in suspensionReasons { candidate.setSuspended(true, reason: reason) }
        prepare?(reader)
        try install(candidate)
        pagedReader = reader
        continuousReader = nil
        self.configuration = configuration
        adaptiveObservationActive = true
        refreshAdaptiveLayout()
        return reader
    }

    /// - Parameters: window: 新布局窗口；provider: 内容工厂；anchor: 宿主解析的新锚点；fillPolicy: 自动补屏目标和预算；prepare: 安装前设置事件。
    /// - Returns: 新连续 renderer。
    /// - Throws: 无效锚点、候选失效或切换重入；候选加载失败时保留旧展示。
    @discardableResult
    public func showContinuous(window: ContinuousWindow, provider: any ContinuousContentProvider,
                               anchor: ContinuousAnchor? = nil, fillPolicy: ContinuousFillPolicy = .standard,
                               prepare: ((ContinuousReaderViewController) -> Void)? = nil) throws -> ContinuousReaderViewController {
        guard !switching, exitToken == nil, !finishingExit else { throw PageTurnError.interactionInProgress }
        let reader = try ContinuousReaderViewController(window: window, provider: provider, anchor: anchor, fillPolicy: fillPolicy)
        let candidate = Candidate.continuous(reader)
        self.candidate = candidate
        switching = true
        defer { self.candidate = nil; switching = false; scheduleAdaptiveNotification() }
        for reason in suspensionReasons { candidate.setSuspended(true, reason: reason) }
        prepare?(reader)
        try install(candidate)
        continuousReader = reader
        pagedReader = nil
        configuration = PageTurnConfiguration(presentation: .continuous(axis: .vertical))
        adaptiveObservationActive = true
        refreshAdaptiveLayout()
        return reader
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (viewIfLoaded as? ReaderViewportView)?.refreshEnvironment()
        layoutReaders()
    }

    /// 停止当前与准备中的 renderer。后续可显式 show 新模式，但本次被取消的安装不会复活。
    public func invalidate() {
        exitToken = nil
        adaptiveObservationActive = false
        failedAdaptiveEnvironment = nil
        failedAdaptivePolicy = nil
        adaptiveResultID = UUID()
        adaptiveEpoch = UUID()
        adaptiveNotificationScheduled = false
        suspensionReasons.remove(adaptiveSuspensionReason)
        onAdaptiveLayoutChange = nil
        onAdaptiveLayoutError = nil
        suspensionReasons.remove(exitSuspensionReason)
        candidate?.invalidate()
        pagedReader?.invalidate()
        continuousReader?.invalidate()
        onExitFinalized = nil
    }

    /// 将通用菜单、选区等暂停原因作用于当前和准备中的 renderer；模式切换仍保留暂停。
    /// - Parameters: suspended: 是否暂停；reason: 由调用方稳定配对的独立原因。
    public func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        pagedReader?.setSuspended(suspensionReasons.contains(reason), reason: reason)
        continuousReader?.setSuspended(suspensionReasons.contains(reason), reason: reason)
        if let candidate, candidate.controller !== pagedReader, candidate.controller !== continuousReader {
            candidate.setSuspended(suspensionReasons.contains(reason), reason: reason)
        }
    }

    /// 开始可取消的退出；只暂停，不终止加载或销毁 renderer，重复开始返回同一令牌。
    /// - Returns: 仅能结束本容器当前退出事务的凭据。
    public func beginExit() -> ReaderExitToken {
        if let exitToken { return exitToken }
        let token = ReaderExitToken()
        exitToken = token
        setSuspended(true, reason: exitSuspensionReason)
        return token
    }

    /// - Parameter token: 本次退出凭据。
    /// - Returns: 取消成功为 true；旧凭据或正在最终退出时无副作用并返回 false。
    @discardableResult
    public func cancelExit(_ token: ReaderExitToken) -> Bool {
        guard exitToken == token, !finishingExit else { return false }
        exitToken = nil
        setSuspended(false, reason: exitSuspensionReason)
        scheduleAdaptiveNotification()
        return true
    }

    /// 确认退出：先提交有效位置，再失效 renderer。若在通知中调用，下一主线程轮完成。
    /// - Parameter token: 本次退出凭据。
    /// - Returns: 请求被接受为 true；实际完成由 onExitFinalized 通知，旧凭据不影响新会话。
    @discardableResult
    public func finishExit(_ token: ReaderExitToken) -> Bool {
        guard exitToken == token, !finishingExit else { return false }
        finishingExit = true
        let finalize: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard self.exitToken == token else { self.finishingExit = false; return }
            let handler = self.onExitFinalized
            self.invalidate()
            self.finishingExit = false
            handler?(token)
        }
        if let continuousReader { continuousReader.completeReadingBeforeExit(finalize) }
        else { finalize() }
        return true
    }

    /// - Parameter candidate: 已构造的候选；加载验证在停止旧容器之前完成。
    /// - Throws: 候选在任意同步 UIKit 回调中失效，或已被外部挂载。
    private func install(_ candidate: Candidate) throws {
        guard candidate.isActive else { throw PageTurnError.inactive }
        let reader = candidate.controller
        guard reader.parent == nil else { throw PageTurnError.invalidPageController }
        reader.loadViewIfNeeded()
        guard candidate.isActive else { throw PageTurnError.inactive }
        guard let incomingView = reader.viewIfLoaded else { throw PageTurnError.invalidPageController }
        loadViewIfNeeded()
        pagedReader?.invalidate()
        continuousReader?.invalidate()
        guard candidate.isActive else { throw PageTurnError.inactive }
        pagedReader = nil
        continuousReader = nil
        configuration = nil
        for old in children {
            old.willMove(toParent: nil)
            old.viewIfLoaded?.removeFromSuperview()
            old.removeFromParent()
        }
        guard candidate.isActive else { throw PageTurnError.inactive }
        var installed = false
        defer {
            if !installed, reader.parent === self {
                reader.willMove(toParent: nil)
                incomingView.removeFromSuperview()
                reader.removeFromParent()
            }
        }
        addChild(reader)
        incomingView.frame = adaptiveLayout?.contentFrame ?? view.bounds
        incomingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(incomingView)
        guard candidate.isActive else { throw PageTurnError.inactive }
        reader.didMove(toParent: self)
        guard candidate.isActive else { throw PageTurnError.inactive }
        incomingView.setNeedsLayout()
        installed = true
    }
    // MARK: - 可用视口与折叠布局

    /// 策略改变后即使系统环境值相同，也重新计算；不为设置策略提前加载视图。
    private func refreshAdaptiveLayout() {
        guard let viewport = viewIfLoaded as? ReaderViewportView else { return }
        viewport.refreshEnvironment()
        if let environment = viewport.environment { updateAdaptiveLayout(for: environment) }
    }

    /// - Parameter environment: 当前 view 坐标下的四边安全区和系统保留区域。
    private func updateAdaptiveLayout(for environment: ReaderViewportEnvironment) {
        guard adaptiveObservationActive else { return }
        guard let policy = adaptiveLayoutPolicy else {
            adaptiveResultID = UUID()
            adaptiveLayout = nil
            publishedAdaptiveLayout = nil
            failedAdaptiveEnvironment = nil
            failedAdaptivePolicy = nil
            if suspensionReasons.contains(adaptiveSuspensionReason) { setSuspended(false, reason: adaptiveSuspensionReason) }
            layoutReaders()
            return
        }
        guard failedAdaptiveEnvironment != environment || failedAdaptivePolicy != policy else { return }
        adaptiveResultID = UUID()
        do {
            let layout = try policy.layout(for: environment)
            failedAdaptiveEnvironment = nil
            failedAdaptivePolicy = nil
            guard layout != adaptiveLayout else { scheduleAdaptiveNotification(); return }
            adaptiveLayout = layout
            // 同尺寸的折痕／摄像头区域变化也会取消旧事务，不能只观察 bounds.size。
            setSuspended(true, reason: adaptiveSuspensionReason)
            layoutReaders()
            scheduleAdaptiveNotification()
        } catch {
            failedAdaptiveEnvironment = environment
            failedAdaptivePolicy = policy
            setSuspended(true, reason: adaptiveSuspensionReason)
            let epoch = adaptiveEpoch
            let resultID = adaptiveResultID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.adaptiveEpoch == epoch, self.adaptiveResultID == resultID else { return }
                self.onAdaptiveLayoutError?(error)
            }
        }
    }

    /// 仅使用已计算的可读区域，背景由外壳保留全幅；不镜像非对称安全区。
    private func layoutReaders() {
        guard let bounds = viewIfLoaded?.bounds else { return }
        let frame = adaptiveLayout?.contentFrame ?? bounds
        pagedReader?.viewIfLoaded?.frame = frame
        continuousReader?.viewIfLoaded?.frame = frame
    }

    /// 合并快速开合过程中的布局变化，退出／模式安装期间不重入宿主内容工厂。
    private func scheduleAdaptiveNotification() {
        guard adaptiveObservationActive, failedAdaptivePolicy == nil, adaptiveLayoutPolicy != nil,
              let layout = adaptiveLayout else { return }
        if layout == publishedAdaptiveLayout { settleAdaptiveSuspension(); return }
        guard !adaptiveNotificationScheduled else { return }
        adaptiveNotificationScheduled = true
        let epoch = adaptiveEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.adaptiveEpoch == epoch else { return }
            self.adaptiveNotificationScheduled = false
            guard self.adaptiveObservationActive, self.failedAdaptivePolicy == nil, !self.switching,
                  self.exitToken == nil, !self.finishingExit, self.adaptiveLayoutPolicy != nil,
                  let current = self.adaptiveLayout else { return }
            if current == self.publishedAdaptiveLayout { self.settleAdaptiveSuspension(); return }
            self.publishedAdaptiveLayout = current
            self.deliveringAdaptiveLayout = true
            self.onAdaptiveLayoutChange?(current)
            self.deliveringAdaptiveLayout = false
            guard self.adaptiveEpoch == epoch else { return }
            // 回调可以改策略、失效或生成另一个布局；按返回后的最新状态收尾。
            self.scheduleAdaptiveNotification()
        }
    }

    /// 只有最新策略有效且展示建议稳定时归还适配暂停，不能清掉回调中新加的失败暂停。
    private func settleAdaptiveSuspension() {
        guard adaptiveObservationActive, !deliveringAdaptiveLayout, failedAdaptivePolicy == nil,
              adaptiveLayoutPolicy != nil, adaptiveLayout == publishedAdaptiveLayout,
              suspensionReasons.contains(adaptiveSuspensionReason) else { return }
        setSuspended(false, reason: adaptiveSuspensionReason)
    }

}
#endif
