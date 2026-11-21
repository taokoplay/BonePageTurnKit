import UIKit
import BonePageTurnKit

/// 一个已准备完成的展示会话；宿主样本、异步工作与实际 renderer 同生共死。
@MainActor
final class FullScreenDemoScene: ContinuousContentProvider {
    let id = UUID()
    let settings: FullScreenDemoSettings
    var factory: FullScreenDemoContentFactory
    let layout: ReaderPageLayout
    let root: UIViewController
    let surface: ReaderSurfaceViewController?
    let container: PageTurnViewController?
    var focusedUnit: Int
    var lower = 0
    var upper = 0
    var bodyWidth: CGFloat = 0
    var works: [UUID: DispatchWorkItem] = [:]
    var tickets: [UUID: ContinuousLoadTicket] = [:]
    var pendingFactories: [UUID: FullScreenDemoContentFactory] = [:]
    private var bindingFactories: [PageViewBinding: FullScreenDemoContentFactory] = [:]
    var placeholderStates: [Int: ContinuousContentState] = [:]
    var failedDirections: Set<PageTurnDirection> = []
    var blockedNext = false
    var ignoreFailure = false
    var exitToken: ReaderExitToken?
    var replacementTicket: PageReplacementTicket?
    var automaticStarted = false
    var lastEvent = "页面已准备"
    var paged: PagedReaderViewController? { surface?.pagedReader ?? container?.pagedReader }
    var continuous: ContinuousReaderViewController? { surface?.continuousReader }

    /// - Parameters: settings: 不变配置；factory: 样本来源；layout: 当前单双页；surface: 单页/连续外壳；container: 双页容器；focus: 当前展示单元。
    init(settings: FullScreenDemoSettings, factory: FullScreenDemoContentFactory, layout: ReaderPageLayout,
         surface: ReaderSurfaceViewController?, container: PageTurnViewController?, focus: Int) {
        self.settings = settings; self.factory = factory; self.layout = layout
        self.surface = surface; self.container = container; self.focusedUnit = focus
        if let surface { self.root = surface }
        else if let container { self.root = container }
        else { self.root = UIViewController() }
    }

    /// - Parameter reuseIdentifier: SDK 复用类别；返回与全部内容版本兼容的空容器。
    func makeContentView(reuseIdentifier: String) -> UIView {
        factory.makeContentView(reuseIdentifier: reuseIdentifier)
    }

    /// 按完整内容身份选择工厂；安装回调前也能绑定待提交版本。
    /// - Parameters: view: 复用视图；item: 新内容项；binding: 当前完整绑定；无返回值。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        let index = Int(item.identity.unitID) ?? -1
        let owner = ([factory] + Array(pendingFactories.values)).first {
            $0.units.indices.contains(index) && $0.units[index].identity == item.identity
        } ?? factory
        bindingFactories[binding] = owner
        owner.bind(view, to: item, binding: binding)
    }

    /// - Parameters: view: 被回收视图；binding: 原绑定；无返回值，旧版本存活至其最后一个绑定释放。
    func unbind(_ view: UIView, binding: PageViewBinding) {
        let owner = bindingFactories.removeValue(forKey: binding) ?? factory
        owner.unbind(view, binding: binding)
    }

    /// 取消宿主工作，再失效 renderer；旧回调同时由场景身份拒绝。
    func invalidate() {
        works.values.forEach { $0.cancel() }; works.removeAll()
        surface?.invalidate(); container?.invalidate()
        tickets.removeAll(); pendingFactories.removeAll(); bindingFactories.removeAll()
    }
}

/// 全屏 SDK 手动验收入口；菜单为覆盖层，显示/隐藏不改变阅读视口。
@MainActor
final class FullScreenReaderDemoViewController: UIViewController, UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate {
    var settings = FullScreenDemoSettings()
    var scene: FullScreenDemoScene?
    var layoutVersion: UInt64 = 0
    var installing = false
    var rebuilding = false
    var rebuildScheduled = false
    var lastEnvironment: ReaderViewportEnvironment?
    var controlsVisible = false
    var settingsPresented = false
    var automaticIntent = "stopped"
    var chromeAnimator: UIViewPropertyAnimator?
    var chromeRevision = UUID()
    let readerMount = UIView()
    let navigationBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    let navigationBar = UINavigationBar()
    let bottomMenu = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    /// 真机收尾诊断用的帧间隔浮层。
    let frameMonitor = DemoFrameMonitor()
    let frameLabel = UILabel()
    private var frameLabelTimer: Timer?
    let pageLabel = UILabel()
    let stateLabel = UILabel()
    let positionSlider = UISlider()
    let automaticProgress = UIProgressView(progressViewStyle: .bar)
    let noticeLabel = UILabel()
    let revealButton = UIButton(type: .system)
    var tapRecognizer: UITapGestureRecognizer?
    /// 轻点的处理方在按下时固定；跨越收尾落定也不改由另一方重新命中。
    enum CanvasTapOwner { case unassigned, host, sdk }
    var canvasTapOwner = CanvasTapOwner.unassigned
    var savedIndex = 0
    var didStart = false
    /// v2：快照预算默认改为机型自适应（DemoSnapshotBudget）。v1 存档不含自适应语义，
    /// 升级时整份忽略一次，用户重新「应用」即按新默认值持久化；不写针对旧值的迁移特例。
    let settingsKey = "fullscreen.reader.settings.v2"
    let sourceKey = "fullscreen.reader.source.v1"

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !ProcessInfo.processInfo.arguments.contains("--reset-demo-settings"),
           let data = UserDefaults.standard.data(forKey: settingsKey),
           let restored = try? JSONDecoder().decode(FullScreenDemoSettings.self, from: data),
           restored.validationMessage() == nil { settings = restored }
        if ProcessInfo.processInfo.arguments.contains("--reset-demo-settings") { savedIndex = 0 }
        else { savedIndex = max(0, UserDefaults.standard.integer(forKey: sourceKey)) }
        view.backgroundColor = FullScreenDemoContentFactory.paperColor
        view.accessibilityIdentifier = "fullscreen-demo"
        readerMount.frame = view.bounds; readerMount.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        readerMount.accessibilityIdentifier = "fullscreen-reader-canvas"
        view.addSubview(readerMount)
        buildControls()
        applyAppearance()
        frameLabel.frame = CGRect(x: 12, y: 60, width: view.bounds.width - 24, height: 138)
        frameLabel.autoresizingMask = [.flexibleWidth]
        frameLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .systemYellow
        frameLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        frameLabel.textAlignment = .center
        frameLabel.accessibilityIdentifier = "reader-frame-monitor"
        frameLabel.numberOfLines = 0
        frameLabel.isUserInteractionEnabled = false
        frameLabel.layer.cornerRadius = 8; frameLabel.layer.masksToBounds = true
        frameLabel.isHidden = true
        view.addSubview(frameLabel)
        navigationBackdrop.isHidden = true; bottomMenu.isHidden = true
        navigationBackdrop.alpha = 0; bottomMenu.alpha = 0
        automaticIntent = settings.automaticMode == "manual" || settings.automaticMode == "external" ? "stopped" : "paused"
        // 无人值守录制：--curl-autoplay／--burn-autoplay 用定时翻页连续驱动对应效果，便于逐帧对比与截图验收。
        if ProcessInfo.processInfo.arguments.contains("--curl-autoplay") {
            settings.automaticMode = "timed"; settings.pageInterval = 0.45; automaticIntent = "playing"
            settings.effect = "curl"; settings.axis = "horizontal"
            settings.motion = "wholePage"; settings.pageLayout = "single"; settings.spine = "automatic"
        }
        if ProcessInfo.processInfo.arguments.contains("--burn-autoplay") {
            settings.automaticMode = "timed"; settings.pageInterval = 0.45; automaticIntent = "playing"
            settings.effect = "burn"; settings.axis = "horizontal"
            settings.motion = "wholePage"; settings.pageLayout = "single"; settings.spine = "automatic"
        }
        NotificationCenter.default.addObserver(self, selector: #selector(savePosition), name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scene?.root.view.frame = readerMount.bounds
        let safe = view.safeAreaInsets
        navigationBackdrop.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: safe.top + 52)
        navigationBar.frame = CGRect(x: safe.left, y: safe.top, width: max(0, view.bounds.width - safe.left - safe.right), height: 52)
        bottomMenu.frame = CGRect(x: 0, y: view.bounds.height - safe.bottom - 150, width: view.bounds.width, height: safe.bottom + 150)
        revealButton.frame = CGRect(x: view.bounds.width - safe.right - 56, y: safe.top + 8, width: 44, height: 44)
        frameLabel.frame = CGRect(x: safe.left + 12, y: safe.top + 6,
                                  width: max(0, view.bounds.width - safe.left - safe.right - 24), height: 138)
        noticeLabel.frame = CGRect(x: safe.left + 24, y: navigationBackdrop.frame.maxY + 8,
                                  width: max(0, view.bounds.width - safe.left - safe.right - 48), height: 56)
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let environment = ReaderViewportEnvironment.capture(from: view)
        if !didStart {
            didStart = true
            lastEnvironment = environment
            if let error = install(settings, sourcePage: savedIndex) { showNotice(error) }
            if ProcessInfo.processInfo.arguments.contains("--frame-diagnostics"), !frameMonitor.isRunning {
                toggleFrameMonitor()
            }
        } else if environment != lastEnvironment {
            lastEnvironment = environment
            if !installing { scheduleRebuild() }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { scheduleRebuild() }
    }

    /// 原生导航和底部操作区；所有内容仍挂在全幅 readerMount 内。
    private func buildControls() {
        navigationBackdrop.accessibilityIdentifier = "reader-navigation"
        navigationBar.accessibilityIdentifier = "reader-navigation-bar"
        let appearance = UINavigationBarAppearance(); appearance.configureWithTransparentBackground()
        navigationBar.standardAppearance = appearance; navigationBar.scrollEdgeAppearance = appearance
        let item = UINavigationItem(title: FullScreenDemoContentFactory.articleTitle + " · M14")
        item.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: self, action: #selector(hideControls))
        item.leftBarButtonItem?.accessibilityLabel = "隐藏菜单"; item.leftBarButtonItem?.accessibilityIdentifier = "reader-hide-menu"
        item.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), style: .plain, target: self, action: #selector(openSettings))
        item.rightBarButtonItem?.accessibilityLabel = "阅读设置"; item.rightBarButtonItem?.accessibilityIdentifier = "reader-settings-button"
        navigationBar.setItems([item], animated: false)
        navigationBackdrop.contentView.addSubview(navigationBar); view.addSubview(navigationBackdrop)
        bottomMenu.accessibilityIdentifier = "reader-menu"; view.addSubview(bottomMenu)
        pageLabel.font = .preferredFont(forTextStyle: .footnote); pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.accessibilityIdentifier = "reader-position"; pageLabel.textColor = .label
        stateLabel.font = .preferredFont(forTextStyle: .caption2); stateLabel.textColor = .secondaryLabel
        stateLabel.accessibilityIdentifier = "reader-state"; stateLabel.numberOfLines = 1
        let status = UIStackView(arrangedSubviews: [pageLabel, UIView(), stateLabel])
        positionSlider.accessibilityLabel = "阅读位置"; positionSlider.accessibilityIdentifier = "reader-position-slider"
        positionSlider.addTarget(self, action: #selector(previewPosition), for: .valueChanged)
        positionSlider.addTarget(self, action: #selector(commitPositionSlider), for: [.touchUpInside, .touchUpOutside])
        let actions = UIStackView(arrangedSubviews: [
            control("上一页", "chevron.left", "reader-previous", #selector(previousPage)),
            control("自动", "play.circle", "reader-automatic", #selector(showAutomaticMenu)),
            control("翻页", "book", "reader-modes", #selector(showModes)),
            control("调试", "wrench.and.screwdriver", "reader-debug", #selector(showDebugMenu)),
            control("下一页", "chevron.right", "reader-next", #selector(nextPage))
        ])
        actions.distribution = .fillEqually; actions.spacing = 4
        let stack = UIStackView(arrangedSubviews: [status, positionSlider, actions])
        stack.axis = .vertical; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false
        bottomMenu.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bottomMenu.contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            status.heightAnchor.constraint(equalToConstant: 22), positionSlider.heightAnchor.constraint(equalToConstant: 34),
            actions.heightAnchor.constraint(equalToConstant: 62)
        ])
        automaticProgress.isUserInteractionEnabled = false; automaticProgress.accessibilityIdentifier = "reader-auto-progress"
        automaticProgress.translatesAutoresizingMaskIntoConstraints = false; bottomMenu.contentView.addSubview(automaticProgress)
        NSLayoutConstraint.activate([automaticProgress.topAnchor.constraint(equalTo: bottomMenu.contentView.topAnchor),
                                     automaticProgress.leadingAnchor.constraint(equalTo: bottomMenu.contentView.leadingAnchor),
                                     automaticProgress.trailingAnchor.constraint(equalTo: bottomMenu.contentView.trailingAnchor)])
        noticeLabel.textAlignment = .center; noticeLabel.numberOfLines = 3
        noticeLabel.font = .preferredFont(forTextStyle: .caption1); noticeLabel.textColor = .label
        noticeLabel.backgroundColor = .secondarySystemBackground; noticeLabel.layer.cornerRadius = 12; noticeLabel.clipsToBounds = true
        noticeLabel.accessibilityIdentifier = "reader-notice"; noticeLabel.isHidden = true; view.addSubview(noticeLabel)
        revealButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        revealButton.accessibilityLabel = "显示阅读菜单"; revealButton.accessibilityIdentifier = "reader-reveal"
        revealButton.addTarget(self, action: #selector(revealControls), for: .touchUpInside); view.addSubview(revealButton)
        updateRevealButton()
    }

    /// - Parameters: title: 按钮文字；symbol: SF Symbol；id: 测试标识；action: 操作。返回 >=44pt 的原生按钮。
    private func control(_ title: String, _ symbol: String, _ id: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title; configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top; configuration.imagePadding = 5
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 19, weight: .regular)
        var attributes = AttributeContainer()
        attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.preferredFont(forTextStyle: .caption1)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = configuration; button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// - Parameter visible: 顶部导航和底部菜单一起切换；只改变覆盖层，不修改正文 frame。
    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible; chromeRevision = UUID(); let revision = chromeRevision
        chromeAnimator?.stopAnimation(true)
        if visible { navigationBackdrop.isHidden = false; bottomMenu.isHidden = false }
        let changes = {
            self.navigationBackdrop.alpha = visible ? 1 : 0
            self.bottomMenu.alpha = visible ? 1 : 0
        }
        let completion: (UIViewAnimatingPosition) -> Void = { [weak self] _ in
            guard let self, self.chromeRevision == revision else { return }
            self.navigationBackdrop.isHidden = !visible; self.bottomMenu.isHidden = !visible
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            let animator = UIViewPropertyAnimator(duration: 0.18, curve: .easeOut, animations: changes)
            animator.addCompletion(completion); chromeAnimator = animator; animator.startAnimation()
        } else { changes(); completion(.end) }
        if !visible { noticeLabel.isHidden = true }
        updateRevealButton(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        // SDK 的点击回调有同步重入门禁，恢复命令下一轮再读取最新菜单和会话状态。
        DispatchQueue.main.async { [weak self] in self?.syncAutomatic() }
    }

    func updateRevealButton() {
        let hasMenuTap = settings.tapsEnabled && (!settings.tapTurns || settings.previousEnd < settings.nextStart)
        revealButton.isHidden = controlsVisible || hasMenuTap
    }
    /// 切换帧率诊断浮层；无参数及返回值。
    func toggleFrameMonitor() {
        setControlsVisible(false)
        if frameMonitor.isRunning {
            frameMonitor.stop()
            frameLabelTimer?.invalidate(); frameLabelTimer = nil
            frameLabel.isHidden = true
            return
        }
        frameMonitor.bind(scene?.paged)
        frameMonitor.start(screen: view.window?.screen ?? UIScreen.main)
        frameLabel.isHidden = false
        frameLabel.text = frameMonitor.summary()
        frameLabelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.frameLabel.text = self.frameMonitor.summary()
            }
        }
    }

    func copyAnimationDiagnostics() {
        UIPasteboard.general.string = frameMonitor.exportText()
        showNotice("已复制最近的翻页参数与帧率日志")
    }

    @objc func hideControls() { setControlsVisible(false) }
    @objc func revealControls() { setControlsVisible(true) }

    /// 点击在正文中切换菜单；开启分区翻页时保留中央区域作为菜单入口。
    @objc func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, settings.tapsEnabled, let scene else { return }
        if scene.exitToken != nil || (settings.effect != "curl" && scene.paged?.isTransitioning == true) {
            setControlsVisible(!controlsVisible); return
        }
        let point = gesture.location(in: readerMount)
        if scene.layout == .spread, let spread = scene.paged?.currentPage.controller as? PageSpreadViewController {
            for page in spread.pages where page.controller.view.convert(page.controller.view.bounds, to: readerMount).contains(point) {
                if let index = Int(page.identity.unitID) { scene.focusedUnit = index }
            }
        }
        if controlsVisible || !settings.tapTurns || scene.continuous != nil { setControlsVisible(!controlsVisible); return }
        let rect = scene.paged.map { $0.view.convert($0.view.bounds, to: readerMount) } ?? readerMount.bounds
        let fraction = settings.axis == "horizontal" ? (point.x - rect.minX) / rect.width : (point.y - rect.minY) / rect.height
        guard fraction.isFinite, let configuration = try? ReaderTapConfiguration(previousEnd: settings.previousEnd, nextStart: settings.nextStart) else { return }
        var action = configuration.action(at: Double(fraction))
        if settings.axis == "horizontal", settings.readingOrder == "rtl" {
            if action == .next { action = .previous } else if action == .previous { action = .next }
        }
        switch action {
        case .previous: turn(.previous)
        case .next: turn(.next)
        case .center: setControlsVisible(true)
        case .ignored: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === tapRecognizer else { return true }
        canvasTapOwner = .unassigned
        if touch.view?.isDescendant(of: navigationBackdrop) == true || touch.view?.isDescendant(of: bottomMenu) == true { return false }
        var ancestor = touch.view
        var insideScrollableBody = false
        var insideTextBody = false
        while let candidate = ancestor {
            if candidate is UIControl { return false }
            if let text = candidate as? UITextView {
                if text.selectedRange.length > 0 { return false }
                insideTextBody = true
            }
            if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled { insideScrollableBody = true }
            ancestor = candidate.superview
        }
        if scene?.exitToken != nil || (settings.effect != "curl" && scene?.paged?.isTransitioning == true) {
            canvasTapOwner = .host; return settings.tapsEnabled
        }
        // 固定文字的菜单点击与 TextKit 同时识别，选区优先；正文不承担内部滚动。
        if insideTextBody { canvasTapOwner = .host; return settings.tapsEnabled }
        if scene?.paged != nil, insideScrollableBody { canvasTapOwner = .host; return settings.tapsEnabled }
        if let active = scene?.paged?.view ?? scene?.continuous?.view,
           active.convert(active.bounds, to: readerMount).contains(touch.location(in: readerMount)) {
            canvasTapOwner = .sdk; return false
        }
        canvasTapOwner = .host
        return settings.tapsEnabled
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === tapRecognizer && otherGestureRecognizer is UITapGestureRecognizer
    }

    @objc func openSettings() {
        guard !settingsPresented else { return }
        settingsPresented = true; syncAutomatic()
        let controller = FullScreenDemoSettingsController(settings: settings) { [weak self] value in
            guard let self else { return "阅读页已关闭" }
            let previousMode = self.settings.automaticMode
            let result = self.install(value)
            if result == nil {
                if previousMode != value.automaticMode { self.automaticIntent = value.automaticMode == "manual" || value.automaticMode == "external" ? "stopped" : "playing" }
                self.persistSettings(); self.syncAutomatic()
            }
            return result
        }
        controller.onClose = { [weak self] in self?.settingsDidClose() }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.large()]; sheet.prefersGrabberVisible = true }
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { settingsDidClose() }
    func settingsDidClose() { settingsPresented = false; syncAutomatic(); updateStatus() }

    /// - Parameter message: 简短结果或明确失败原因。
    func showNotice(_ message: String) {
        noticeLabel.text = message; noticeLabel.isHidden = false
        view.bringSubviewToFront(noticeLabel)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func applyAppearance() {
        let style: UIUserInterfaceStyle = settings.appearance == "dark" ? .dark : (settings.appearance == "light" ? .light : .unspecified)
        overrideUserInterfaceStyle = style
        // 设置、调试弹窗和键盘也继承所选外观，不只改变正文控制器。
        view.window?.overrideUserInterfaceStyle = style
        view.tintColor = .systemTeal
    }
    func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: settingsKey) }
        savePosition()
    }
    @objc func savePosition() {
        guard let scene, scene.factory.units.indices.contains(scene.focusedUnit) else { return }
        UserDefaults.standard.set(scene.factory.units[scene.focusedUnit].sourceIndex, forKey: sourceKey)
    }
    @objc private func previewPosition() { pageLabel.text = "第 \(Int(positionSlider.value.rounded()) + 1) 个展示单元" }
    @objc private func commitPositionSlider() { jump(to: Int(positionSlider.value.rounded())) }
    @objc func previousPage() { turn(.previous) }
    @objc func nextPage() { turn(.next) }

    /// 外部手势、工具栏与分区点击共用真实 SDK 翻页入口。
    func turn(_ direction: PageTurnDirection) {
        guard let scene, scene.exitToken == nil else { return }
        do {
            if let paged = scene.paged { _ = try paged.turn(direction, animated: settings.animated) }
            else { jump(to: scene.focusedUnit + (direction == .next ? 1 : -1)) }
        } catch { showNotice("当前操作暂不可用：\(error)") }
    }

    /// - Parameter index: 展示单元位置；连续窗口外的定位通过新会话准备，而不伪造旧窗口锚点。
    func jump(to index: Int) {
        guard let scene else { return }
        let target = min(max(0, index), scene.factory.count - 1)
        if let continuous = scene.continuous, continuous.window.item(withID: String(target)) != nil {
            do {
                try continuous.restore(.init(identity: scene.factory.units[target].identity, offsetInItem: 0), expectedToken: continuous.updateToken)
                scene.focusedUnit = target; scene.automaticStarted = false; automaticIntent = "paused"
                updateStatus(); savePosition()
            } catch { showNotice("定位等待当前交互结束：\(error)") }
        } else {
            if let message = install(settings, unitIndex: target) { showNotice(message) }
            else { savePosition() }
        }
    }

    /// 值变化或真正视口变化时重建一次；菜单显隐不进入此路径。
    func scheduleRebuild() {
        guard didStart, !rebuildScheduled, !installing else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.scene?.exitToken == nil else { return }
            if let message = self.install(self.settings) { self.showNotice(message) }
        }
    }
}
