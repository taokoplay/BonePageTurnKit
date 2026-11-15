import UIKit
import BonePageTurnKit
import os

@MainActor
extension FullScreenReaderDemoViewController {
    /// - Parameters: effect: 效果；axis: 轴向。返回简短中文名称。
    func modeTitle(_ effect: String, axis: String) -> String {
        let labels = ["none": "无动画", "slide": "平移", "cover": "覆盖", "curl": "仿真", "arch": "拱页", "continuous": "连续滚屏"]
        return effect == "continuous" ? "连续滚屏" : "\(axis == "horizontal" ? "横向" : "纵向")\(labels[effect] ?? effect)"
    }

    /// 用类型网格与独立方向控件选择翻页；只有应用成功才替换当前阅读器。
    @objc func showModes() {
        let picker = FullScreenDemoModePickerController(settings: settings) { [weak self] value in
            guard let self else { return "阅读页已关闭" }
            if let error = self.install(value) { return error }
            self.automaticIntent = "stopped"
            self.persistSettings(); self.setControlsVisible(false)
            return nil
        } onSystemCurl: { [weak self] in
            // 系统仿真不经过 SDK 事务，直接在阅读页上打开对照视图。
            guard let self else { return }
            self.setControlsVisible(false)
            self.present(SystemCurlDemoViewController(), animated: true)
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        present(navigation, animated: true)
    }

    @objc func showAutomaticMenu() {
        let sheet = UIAlertController(title: "自动阅读", message: "菜单展开时自动驱动暂时暂停。外部手势可通过上下页按钮模拟。", preferredStyle: .actionSheet)
        for (title, mode) in [("定时翻页", "timed"), ("自动滚屏", "scroll"), ("外部手势翻页", "external")] {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                var next = self.settings; next.automaticMode = mode
                if mode == "scroll" {
                    next.effect = "continuous"; next.axis = "vertical"; next.motion = "contentOnly"
                    next.pageLayout = "single"; next.spine = "automatic"; next.zoomEnabled = false
                } else if next.effect == "continuous" {
                    next.effect = "slide"; next.axis = "horizontal"; next.motion = "wholePage"; next.pageLayout = "single"
                }
                if let error = self.install(next) { self.showNotice(error) }
                else {
                    self.automaticIntent = mode == "external" ? "stopped" : "playing"
                    self.persistSettings(); self.setControlsVisible(false); self.syncAutomatic()
                }
            })
        }
        sheet.addAction(UIAlertAction(title: automaticIntent == "playing" ? "主动暂停" : "继续自动阅读", style: .default) { [weak self] _ in
            guard let self else { return }
            self.automaticIntent = self.automaticIntent == "playing" ? "paused" : "playing"
            self.setControlsVisible(false); self.syncAutomatic()
        })
        sheet.addAction(UIAlertAction(title: "停止自动阅读", style: .default) { [weak self] _ in
            self?.automaticIntent = "stopped"; self?.syncAutomatic()
        })
        presentMenu(sheet)
    }

    @objc func showDebugMenu() {
        let sheet = UIAlertController(title: "SDK 调试", message: scene?.lastEvent, preferredStyle: .actionSheet)
        let commands: [(String, () -> Void)] = [
            ("简单对话框", { [weak self] in self?.showSimpleDialog() }),
            ("帧率诊断（翻页时观察）", { [weak self] in self?.toggleFrameMonitor() }),
            ("复制动画诊断日志", { [weak self] in self?.copyAnimationDiagnostics() }),
            ("系统仿真对比（pageCurl）", { [weak self] in
                guard let self else { return }
                self.setControlsVisible(false)
                self.present(SystemCurlDemoViewController(), animated: true)
            }),
            ("半翻预览 50%", { [weak self] in self?.previewTurn() }),
            ("完成当前翻页", { [weak self] in self?.scene?.paged?.endInteractiveTurn(velocity: 600, animated: self?.settings.animated ?? true) }),
            ("取消当前翻页", { [weak self] in self?.scene?.paged?.cancelTransition() }),
            ("异步回填当前内容", { [weak self] in self?.replaceCurrentContent() }),
            ("取消待安装回填", { [weak self] in self?.cancelReplacement() }),
            ("模拟下一页等待／占位", { [weak self] in self?.simulateWaiting() }),
            ("重试加载与重新补屏", { [weak self] in self?.retryContent() }),
            ("取消加载任务", { [weak self] in self?.cancelLoads() }),
            ("切换调试安装门禁", { [weak self] in self?.toggleInstallationGate() }),
            ("放大当前图片", { [weak self] in self?.changeZoom(reset: false) }),
            ("还原图片缩放", { [weak self] in self?.changeZoom(reset: true) }),
            ("查看状态与几何", { [weak self] in self?.showDiagnostics() }),
            ("开始退出（可取消）", { [weak self] in self?.beginExitDemo() }),
            ("取消退出", { [weak self] in self?.cancelExitDemo() }),
            ("确认退出并重新打开", { [weak self] in self?.finishExitDemo() })
        ]
        for (title, command) in commands { sheet.addAction(UIAlertAction(title: title, style: .default) { _ in command() }) }
        presentMenu(sheet)
    }

    private func presentMenu(_ sheet: UIAlertController) {
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = bottomMenu
        sheet.popoverPresentationController?.sourceRect = CGRect(x: bottomMenu.bounds.midX, y: 0, width: 1, height: 1)
        present(sheet, animated: true)
    }

    /// 展示原生双按钮对话框；等待调试菜单关闭后再呈现。
    private func showSimpleDialog() {
        let dialog = UIAlertController(title: "提示", message: "这是一个简单的对话框。", preferredStyle: .alert)
        dialog.view.accessibilityIdentifier = "reader-simple-dialog"
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        let confirm = UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            self?.showNotice("已确认")
        }
        dialog.addAction(confirm)
        dialog.preferredAction = confirm
        if let menu = presentedViewController {
            menu.dismiss(animated: true) { [weak self] in self?.present(dialog, animated: true) }
        } else {
            present(dialog, animated: true)
        }
    }

    private func previewTurn() {
        guard let paged = scene?.paged else { showNotice("连续模式没有分页预览事务"); return }
        do {
            if try paged.beginInteractiveTurn(.next) {
                let extent = settings.axis == "horizontal" ? paged.view.bounds.width : paged.view.bounds.height
                paged.updateInteractiveTurn(displacement: extent * 0.5)
                showNotice("已停在半翻状态，可完成、取消或提交回填")
            }
        } catch { showNotice("无法预览：\(error)") }
    }

    /// 以新的内容版本提交实际正文；翻页中可测试延期安装，不直接改旧视图。
    private func replaceCurrentContent() {
        guard let scene else { return }
        let version = (scene.factory.units.first?.identity.contentVersion ?? 0) + 1
        let factory = FullScreenDemoContentFactory(settings: settings, layoutVersion: scene.factory.units.first?.identity.layoutVersion ?? layoutVersion, contentVersion: version)
        if let reader = scene.paged {
            let binding = reader.currentPageBinding
            let taskID = UUID()
            let work = DispatchWorkItem { [weak self, weak scene, weak reader] in
                guard let self, let scene, let reader, self.scene === scene else { return }
                scene.works.removeValue(forKey: taskID)
                do {
                    let page: PageContent
                    if scene.layout == .spread {
                        let group = Int(binding.identity.unitID.replacingOccurrences(of: "group-", with: "")) ?? 0
                        page = try self.spreadPage(for: scene, group: group, override: factory)
                    } else { page = try factory.page(at: Int(binding.identity.unitID) ?? scene.focusedUnit) }
                    self.registerContent(in: page.controller, for: reader, scene: scene)
                    let completion: (PageReplacementOutcome) -> Void = { [weak self, weak scene] outcome in
                        guard let self, let scene, self.scene === scene else { return }
                        if case .installed = outcome { scene.factory = factory }
                        scene.lastEvent = "回填结果：\(outcome)"; self.showNotice(scene.lastEvent); self.updateStatus()
                    }
                    if let surface = scene.surface { scene.replacementTicket = try surface.submitCurrentPage(page, expectedBinding: binding, completion: completion) }
                    else { scene.replacementTicket = try reader.submitCurrentPage(page, expectedBinding: binding, completion: completion) }
                    self.showNotice("回填已提交，等待稳定状态安装")
                } catch { self.showNotice("回填被拒绝：\(error)") }
            }
            scene.works[taskID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.loadDelay, execute: work)
            showNotice("正在准备新版本内容")
        } else if let reader = scene.continuous, let anchor = reader.visibleAnchor {
            do {
                let items = try factory.items(in: scene.lower..<scene.upper, width: scene.bodyWidth)
                let updated = try ContinuousWindow(items: items, before: reader.window.before, after: reader.window.after)
                guard let target = updated.item(withID: anchor.identity.unitID) else { return }
                let taskID = UUID()
                let ticket = try reader.beginLoading(.next, token: reader.updateToken, cancel: {}, completion: { [weak self, weak scene] outcome in
                    scene?.tickets.removeValue(forKey: taskID)
                    scene?.pendingFactories.removeValue(forKey: taskID)
                    guard let self, let scene, self.scene === scene else { return }
                    if case .installed = outcome { scene.factory = factory }
                    scene.lastEvent = "回填结果：\(outcome)"; self.showNotice(scene.lastEvent)
                })
                scene.tickets[taskID] = ticket
                scene.pendingFactories[taskID] = factory
                do {
                    try reader.submit(updated, for: ticket, anchor: .init(identity: target.identity, offsetInItem: min(anchor.offsetInItem, target.extent), viewportOffset: anchor.viewportOffset))
                } catch {
                    reader.rejectLoading(ticket, error: .invalidWindow)
                    throw error
                }
                showNotice("新版本窗口已提交")
            } catch { showNotice("回填被拒绝：\(error)") }
        }
    }

    private func cancelReplacement() {
        guard let scene, let ticket = scene.replacementTicket, let reader = scene.paged else { showNotice("没有等待安装的分页回填"); return }
        showNotice(reader.cancelPageReplacement(ticket) ? "已取消待安装回填" : "回填已结束")
    }
    private func cancelLoads() {
        guard let scene else { return }
        for ticket in Array(scene.tickets.values) { scene.continuous?.cancelLoading(ticket) }
        scene.tickets.removeAll(); scene.works.values.forEach { $0.cancel() }; scene.works.removeAll()
        showNotice("已取消本场景的加载任务")
    }
    private func toggleInstallationGate() {
        guard let reader = scene?.continuous else { showNotice("该独立门禁用于连续模式；分页回填在翻页或暂停时自动延期"); return }
        let suspended = !reader.suspendedTargets.contains(.contentInstallation)
        showNotice(suspended ? "调试门禁已暂停安装，滚动仍可继续" : "已解除调试门禁；设置页的独立门禁仍保留")
        // 解除暂停可能同步完成安装，保留随后返回的真实完成提示。
        reader.setSuspended(suspended, targets: .contentInstallation, reason: "demo-debug-install")
    }
    private func simulateWaiting() {
        guard let scene else { return }
        if scene.paged != nil { scene.blockedNext = true; showNotice("下一页将等待内容，按加载延迟自动唤醒"); return }
        guard let reader = scene.continuous, scene.upper < scene.factory.count else { showNotice("已经到达样本末尾"); return }
        let index = scene.upper
        scene.upper += 1; scene.placeholderStates[index] = .loading
        do { try reader.apply(window(for: scene), expectedToken: reader.updateToken); showNotice("已插入真实占位块，等待内容需求回填") }
        catch { scene.upper -= 1; scene.placeholderStates.removeValue(forKey: index); showNotice("当前不能安装占位：\(error)") }
    }
    private func retryContent() {
        guard let scene else { return }
        scene.ignoreFailure = true; scene.blockedNext = false; scene.failedDirections.removeAll()
        for index in Array(scene.placeholderStates.keys) { scene.placeholderStates[index] = .loading }
        do {
            if let reader = scene.paged { try reader.notifyContentAvailable(expectedToken: reader.contentRequestToken) }
            if let reader = scene.continuous {
                try reader.apply(window(for: scene), expectedToken: reader.updateToken)
                try reader.resumeContentFilling()
            }
            showNotice("已解除模拟失败，并重新请求内容")
        } catch { showNotice("请在当前交互或任务结束后重试：\(error)") }
    }

    private func changeZoom(reset: Bool) {
        guard let scene else { return }
        var zooms: [ReaderZoomViewController] = []
        func scan(_ controller: UIViewController) {
            if let zoom = controller as? ReaderZoomViewController { zooms.append(zoom) }
            controller.children.forEach(scan)
        }
        if let current = scene.paged?.currentPage.controller { scan(current) }
        guard !zooms.isEmpty else { showNotice("先在设置中选择图片内容并开启缩放"); return }
        for zoom in zooms {
            if reset { zoom.resetZoom(animated: settings.animated) }
            else { do { try zoom.setZoomFactor(min(CGFloat(settings.maximumZoom), zoom.zoomFactor + 1), animated: settings.animated) } catch { showNotice("缩放错误：\(error)") } }
        }
    }

    private func beginExitDemo() {
        guard let scene else { return }
        do {
            scene.exitToken = try scene.surface?.beginExit() ?? scene.container?.beginExit()
            showNotice("退出事务已开始；可以取消，或确认后重建示例")
        } catch { showNotice("无法开始退出：\(error)") }
    }
    private func cancelExitDemo() {
        guard let scene, let token = scene.exitToken else { showNotice("尚未开始退出"); return }
        let cancelled = scene.surface?.cancelExit(token) ?? scene.container?.cancelExit(token) ?? false
        if cancelled { scene.exitToken = nil; syncAutomatic(); showNotice("已取消退出，其他暂停原因保留") }
    }
    private func finishExitDemo() {
        guard let scene else { return }
        if scene.exitToken == nil { beginExitDemo() }
        guard let token = scene.exitToken else { return }
        let finalize: (ReaderExitToken) -> Void = { [weak self, weak scene] _ in
            guard let self, let scene, self.scene === scene else { return }
            self.automaticIntent = "paused"
            scene.exitToken = nil
            if let error = self.install(self.settings) { self.showNotice(error) }
            else { self.showNotice("最终位置提交后已释放旧容器，并重新打开") }
        }
        if let surface = scene.surface { surface.onExitFinalized = finalize; _ = surface.finishExit(token) }
        else if let container = scene.container { container.onExitFinalized = finalize; _ = container.finishExit(token) }
    }

    private func showDiagnostics() {
        guard let scene else { return }
        var rows = ["展示：\(settings.effect) / \(settings.axis) / \(scene.layout)", "方向：\(settings.readingOrder)",
                    "移动层：\(settings.motion)", "当前展示单元：\(scene.focusedUnit)", "窗口：\(readerMount.bounds)",
                    "最新事件：\(scene.lastEvent)"]
        if let layout = scene.surface?.layout {
            rows += ["正文：\(layout.bodyFrame)", "页眉：\(String(describing: layout.headerFrame))", "页脚：\(String(describing: layout.footerFrame))", "背景：\(layout.backgroundFrame)"]
        }
        if let reader = scene.paged {
            rows += ["当前身份：\(reader.currentPage.identity)", "绑定：\(reader.currentPageBinding.id)",
                     "当前页实际平面位置：\(String(describing: scene.surface?.currentPageFrames(in: view)?.bodyFrame))",
                     "自动阅读：\(reader.automaticReadingState)", "计时进度：\(reader.automaticReadingProgress)"]
        }
        if let reader = scene.continuous {
            rows += ["锚点：\(String(describing: reader.visibleAnchor))", "窗口令牌：\(reader.updateToken)",
                     "挂载视图：\(reader.mountedContentViewCount)", "实际可见块：\(reader.visibleContents().count)",
                     "暂停目标：\(reader.suspendedTargets.rawValue)", "可读覆盖：\(String(describing: reader.readableCoverage))"]
            rows += reader.visibleContents(in: view).map { "\($0.item.identity.unitID)：\($0.visibleFrame)" }
        }
        let controller = FullScreenDemoDiagnosticsController(text: rows.joined(separator: "\n\n"))
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet; present(navigation, animated: true)
    }
}

@MainActor
private final class FullScreenDemoDiagnosticsController: UIViewController {
    let text: String
    init(text: String) { self.text = text; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "状态与几何"
        let textView = UITextView(); textView.isEditable = false; textView.text = text
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .systemBackground; textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view = textView
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    }
    @objc private func close() { dismiss(animated: true) }
}

// MARK: - 翻页类型与方向

/// 原生双维度选择面板；类型采用网格，方向独立选择，应用前不改动当前阅读器。
@MainActor
private final class FullScreenDemoModePickerController: UIViewController {
    private enum PageType: String, CaseIterable {
        case none, slide, cover, curl, systemCurl, arch, continuous

        var title: String {
            switch self {
            case .none: return "无动画"
            case .slide: return "平移"
            case .cover: return "覆盖"
            case .curl: return "仿真"
            case .systemCurl: return "系统仿真"
            case .arch: return "拱页"
            case .continuous: return "连续滚动"
            }
        }
        var symbol: String {
            switch self {
            case .none: return "rectangle"
            case .slide: return "rectangle.on.rectangle"
            case .cover: return "square.stack"
            case .curl: return "book"
            case .systemCurl: return "book.pages"
            case .arch: return "book.closed"
            case .continuous: return "scroll"
            }
        }
        var fixedAxis: String? {
            switch self {
            case .cover, .systemCurl: return "horizontal"
            case .continuous: return "vertical"
            default: return nil
            }
        }
        var hint: String {
            switch self {
            case .cover: return "覆盖仅支持横向，页面整体移动。"
            case .curl, .arch: return "支持两个方向，页面整体移动。"
            case .systemCurl: return "系统 UIPageViewController 的 pageCurl，只作对照，不经过 SDK 翻页事务。"
            case .continuous: return "连续滚动仅支持纵向，使用单页正文滚动并关闭图片缩放。"
            case .none, .slide: return "支持两个方向；“仅正文运动”等选项可在阅读设置中调整。"
            }
        }
    }

    private let original: FullScreenDemoSettings
    private let onApply: (FullScreenDemoSettings) -> String?
    private let onSystemCurl: (() -> Void)?
    private var selectedType: PageType
    private var selectedAxis: String
    private let directionControl = UISegmentedControl(items: ["横向", "纵向"])
    private let hintLabel = UILabel()
    private var typeButtons: [UIButton] = []
    /// 面板内直接切换的手感开关，与应用按钮一起提交。
    private let animatedSwitch = UISwitch()
    private let tapTurnsSwitch = UISwitch()
    private let panSwitch = UISwitch()

    /// - Parameters: settings: 当前已验证配置；onApply: 安装选择，失败返回原因并保留面板。
    init(settings: FullScreenDemoSettings, onApply: @escaping (FullScreenDemoSettings) -> String?,
         onSystemCurl: (() -> Void)? = nil) {
        guard let type = PageType(rawValue: settings.effect) else {
            preconditionFailure("翻页面板需要已验证的类型")
        }
        original = settings; selectedType = type; selectedAxis = settings.axis
        self.onApply = onApply; self.onSystemCurl = onSystemCurl
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持归档构造。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 创建可滚动的两组原生控件；无参数和返回值。
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "翻页方式"
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = .systemTeal
        navigationController?.navigationBar.tintColor = .systemTeal
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "mode-cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "应用", style: .done, target: self, action: #selector(apply))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "mode-apply"

        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "reader-mode-picker"
        scroll.contentInsetAdjustmentBehavior = .automatic
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let grid = UIStackView(); grid.axis = .vertical; grid.spacing = 8
        let types = PageType.allCases
        for rowStart in stride(from: 0, to: types.count, by: 3) {
            let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
            for index in rowStart..<min(rowStart + 3, types.count) {
                let button = UIButton(type: .system)
                button.tag = index
                button.accessibilityIdentifier = "mode-type-\(types[index].rawValue)"
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.addTarget(self, action: #selector(selectType(_:)), for: .touchUpInside)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
                typeButtons.append(button); row.addArrangedSubview(button)
            }
            grid.addArrangedSubview(row)
        }
        directionControl.accessibilityIdentifier = "mode-direction"
        directionControl.addTarget(self, action: #selector(selectDirection), for: .valueChanged)
        directionControl.heightAnchor.constraint(equalToConstant: 44).isActive = true
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .secondaryLabel; hintLabel.numberOfLines = 0
        hintLabel.accessibilityIdentifier = "mode-hint"
        animatedSwitch.isOn = original.animated
        animatedSwitch.accessibilityIdentifier = "mode-animated"
        tapTurnsSwitch.isOn = original.tapTurns
        tapTurnsSwitch.accessibilityIdentifier = "mode-tap-turns"
        panSwitch.isOn = original.panEnabled
        panSwitch.accessibilityIdentifier = "mode-pan"
        let toggles = UIStackView(arrangedSubviews: [toggleRow("翻页动画", control: animatedSwitch),
                                                     toggleRow("点击两侧翻页", control: tapTurnsSwitch),
                                                     toggleRow("拖动翻页", control: panSwitch)])
        toggles.axis = .vertical; toggles.spacing = 6
        let allSettings = UIButton(type: .system)
        allSettings.setTitle("全部阅读设置…", for: .normal)
        allSettings.accessibilityIdentifier = "mode-all-settings"
        allSettings.addTarget(self, action: #selector(openAllSettings), for: .touchUpInside)
        allSettings.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let content = UIStackView(arrangedSubviews: [section("类型", content: grid), section("方向", content: directionControl),
                                                     section("手感", content: toggles), hintLabel, allSettings])
        content.axis = .vertical; content.spacing = 16; content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        updateChoices()
    }

    /// - Parameter previousTraitCollection: 旧字体类别；无返回值，保持按钮动态字体与自然行高。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateChoices()
        }
    }

    /// - Parameters: title: 分组标题；content: 本组控件。返回纵向分组。
    private func section(_ title: String, content: UIView) -> UIStackView {
        let label = UILabel(); label.text = title
        label.font = .preferredFont(forTextStyle: .headline); label.adjustsFontForContentSizeCategory = true
        label.textColor = .label; label.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [label, content]); stack.axis = .vertical; stack.spacing = 8
        return stack
    }

    /// - Parameters: title: 行标题；control: 右侧开关。返回左侧标题、右侧开关的原生行。
    private func toggleRow(_ title: String, control: UISwitch) -> UIStackView {
        let label = UILabel(); label.text = title
        label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal; row.alignment = .center
        return row
    }

    /// 从翻页面板直接进入完整阅读设置；面板内已改的手感开关一并带过去。
    @objc private func openAllSettings() {
        let controller = FullScreenDemoSettingsController(settings: proposedSettings()) { [weak self] value in
            guard let self else { return "阅读页已关闭" }
            return self.onApply(value)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    /// - Parameter sender: 选中的类型按钮；无返回值，固定方向立即显示在独立方向区。
    @objc private func selectType(_ sender: UIButton) {
        guard PageType.allCases.indices.contains(sender.tag) else { return }
        selectedType = PageType.allCases[sender.tag]
        if let axis = selectedType.fixedAxis { selectedAxis = axis }
        updateChoices()
    }

    /// 接收原生方向选择；无参数及返回值。
    @objc private func selectDirection() {
        selectedAxis = directionControl.selectedSegmentIndex == 0 ? "horizontal" : "vertical"
    }

    /// 更新选中态及不支持的方向；无参数及返回值。
    private func updateChoices() {
        for (index, button) in typeButtons.enumerated() {
            let type = PageType.allCases[index], selected = type == selectedType
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: type.symbol)
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 19, weight: .regular)
            configuration.imagePlacement = .top; configuration.imagePadding = 4
            configuration.titleAlignment = .center; configuration.titleLineBreakMode = .byWordWrapping
            configuration.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
            var attributes = AttributeContainer()
            attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.preferredFont(forTextStyle: .subheadline)
            configuration.attributedTitle = AttributedString(type.title, attributes: attributes)
            configuration.baseForegroundColor = selected ? .systemTeal : .label
            configuration.background.backgroundColor = selected ? UIColor.systemTeal.withAlphaComponent(0.16) : .secondarySystemGroupedBackground
            configuration.background.cornerRadius = 12; configuration.cornerStyle = .fixed
            configuration.background.strokeColor = selected ? .systemTeal : .clear
            configuration.background.strokeWidth = 1
            button.configuration = configuration; button.isSelected = selected
        }
        directionControl.setEnabled(selectedType.fixedAxis != "vertical", forSegmentAt: 0)
        directionControl.setEnabled(selectedType.fixedAxis != "horizontal", forSegmentAt: 1)
        directionControl.selectedSegmentIndex = selectedAxis == "horizontal" ? 0 : 1
        hintLabel.text = selectedType.hint + (original.automaticMode == "manual" ? "" : "\n应用后切换为手动阅读。")
    }

    /// 仅调整所选类型要求的配置；无参数，返回完整候选值，兼容的单双页和运动范围保持不变。
    private func proposedSettings() -> FullScreenDemoSettings {
        var next = original
        next.effect = selectedType.rawValue; next.axis = selectedAxis; next.automaticMode = "manual"
        next.animated = animatedSwitch.isOn
        next.tapTurns = tapTurnsSwitch.isOn
        next.panEnabled = panSwitch.isOn
        switch selectedType {
        case .none, .slide: next.spine = "automatic"
        case .cover: next.spine = "automatic"; next.motion = "wholePage"
        case .curl, .arch, .systemCurl: next.motion = "wholePage"
        case .continuous:
            next.pageLayout = "single"; next.spine = "automatic"; next.motion = "contentOnly"; next.zoomEnabled = false
        }
        return next
    }

    /// 验证并交给宿主安装；无参数及返回值，失败不关闭、不改动当前页面。
    @objc private func apply() {
        if selectedType == .systemCurl {
            dismiss(animated: true) { [onSystemCurl] in onSystemCurl?() }
            return
        }
        let next = proposedSettings()
        if let message = next.validationMessage() ?? onApply(next) {
            let alert = UIAlertController(title: "无法应用翻页方式", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default)); present(alert, animated: true)
            return
        }
        dismiss(animated: true)
    }

    /// 丢弃本次选择；无参数及返回值。
    @objc private func cancel() { dismiss(animated: true) }
}

/// 只统计正在翻页的主线程回调，结束后保留上一页结果；屏幕上限、申请值与实际帧率分开显示。
@MainActor
final class DemoFrameMonitor {
    @MainActor private final class Target: NSObject {
        weak var owner: DemoFrameMonitor?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
    private let target = Target()
    private var link: CADisplayLink?
    private weak var reader: PagedReaderViewController?
    private var last: CFTimeInterval?
    private var activeID: UUID?
    private var wasTurning = false
    private var lastSequence = 0
    private var progressChangedAt: TimeInterval?
    private var sampledProgress: Double?
    private var latest: PageTurnAnimationDiagnostic?
    private var logLines: [String] = []
    private var maximumFPS = 0
    private var requestedFPS = 0
    private static let logger = Logger(subsystem: "com.bone.page-turn-demo", category: "AnimationFrames")
    private(set) var intervals: [TimeInterval] = []
    private var totals = ReaderFrameRateTotals(targetFramesPerSecond: 60)
    var isRunning: Bool { link != nil }

    init() { target.owner = self }

    func bind(_ next: PagedReaderViewController?) {
        guard reader !== next else { return }
        collectDiagnostics()
        reader?.animationDiagnosticsEnabled = false
        reader = next
        lastSequence = 0; activeID = nil; last = nil; wasTurning = false
        latest = nil; intervals.removeAll(keepingCapacity: true)
        progressChangedAt = nil; sampledProgress = nil
        totals = ReaderFrameRateTotals(targetFramesPerSecond: max(1, requestedFPS))
        next?.animationDiagnosticsEnabled = isRunning
    }

    func start(screen: UIScreen) {
        guard link == nil else { return }
        reset()
        maximumFPS = screen.maximumFramesPerSecond
        requestedFPS = max(1, maximumFPS)
        totals = ReaderFrameRateTotals(targetFramesPerSecond: requestedFPS)
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = .init(minimum: Float(min(80, requestedFPS)),
            maximum: Float(requestedFPS), preferred: Float(requestedFPS))
        link.add(to: .main, forMode: .common)
        self.link = link
        reader?.animationDiagnosticsEnabled = true
    }

    func stop() {
        collectDiagnostics()
        reader?.animationDiagnosticsEnabled = false
        link?.invalidate(); link = nil; last = nil
    }

    func reset() {
        intervals.removeAll(keepingCapacity: true)
        totals = ReaderFrameRateTotals(targetFramesPerSecond: max(1, requestedFPS))
        last = nil; activeID = nil; wasTurning = false
        latest = nil; progressChangedAt = nil; sampledProgress = nil
    }

    func summary() -> String {
        collectDiagnostics()
        let stats = ReaderFrameRateSummary(intervals: intervals, targetFramesPerSecond: max(1, requestedFPS))
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        let state = reader?.isTransitioning == true ? "翻页中" : (latest?.event == .finished ? "上一页" : "等待翻页")
        var lines = [
            "屏幕 \(maximumFPS)Hz | 申请 \(requestedFPS)Hz | \(state)",
            "回调 \(number(reader?.isTransitioning == true ? stats.framesPerSecond : totals.framesPerSecond))FPS | GPU呈现 \(number(latest?.gpuPresentedFramesPerSecond))FPS",
            "avg \(number(totals.averageMilliseconds)) p95窗 \(number(stats.p95Milliseconds)) max \(number(totals.maximumMilliseconds))ms",
            "超预算 \(totals.overBudgetCount)/\(totals.sampleCount) | 估计缺帧 \(totals.estimatedMissedFrames)"
        ]
        if let latest {
            lines.append("\(latest.effect) \(latest.direction) 进度 \(String(format: "%.0f%%", latest.progress * 100)) | 排队 \(latest.queueDepth)")
            lines.append("时长 \(number(latest.duration.map { $0 * 1_000 }))ms | 准备 \(number(latest.preparationDuration.map { $0 * 1_000 }))ms")
            lines.append("\(latest.event.rawValue) / \(latest.endReason?.rawValue ?? "进行中") | 更新\(latest.updateCount) 提交\(latest.gpuSubmissionCount)")
            if reader?.isTransitioning == true, latest.duration != nil,
               CACurrentMediaTime() - (progressChangedAt ?? latest.timestamp) > 0.5 {
                lines.append("⚠ 超过500ms无新进度：查看等待或终止日志")
            }
        } else {
            lines.append(reader == nil ? "当前模式没有分页动画参数" : "翻页后显示时长、进度与结束原因")
        }
        return lines.joined(separator: "\n")
    }

    func exportText() -> String {
        collectDiagnostics()
        return summary() + "\n\n" + logLines.joined(separator: "\n")
    }

    private func collectDiagnostics() {
        guard let reader else { return }
        for entry in reader.recentAnimationDiagnostics where entry.sequence > lastSequence {
            if activeID != entry.transitionID {
                if wasTurning { recordCallbackSummary() }
                activeID = entry.transitionID
                intervals.removeAll(keepingCapacity: true)
                totals = ReaderFrameRateTotals(targetFramesPerSecond: max(1, requestedFPS))
                last = nil; wasTurning = false
            }
            let moved = sampledProgress.map { abs($0 - entry.progress) > 0.0001 } ?? true
            if latest?.transitionID != entry.transitionID || moved {
                progressChangedAt = entry.timestamp
                sampledProgress = entry.progress
            }
            if entry.event == .finished, entry.transitionID == activeID, wasTurning {
                // 只统计已收到的回调间隔；不把结束后的宿主阻塞或部分尾帧当成新回调。
                recordCallbackSummary()
                wasTurning = false; last = nil
            }
            logLines.append(entry.logLine)
            lastSequence = entry.sequence
            latest = entry
        }
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private func recordCallbackSummary() {
        guard let activeID, !intervals.isEmpty else { return }
        let stats = ReaderFrameRateSummary(intervals: intervals, targetFramesPerSecond: max(1, requestedFPS))
        let line = String(format: "[FrameRate %@] screenMax=%d requested=%d callbackFPS=%.1f avgTotal=%.1fms p95Window=%.1fms maxTotal=%.1fms overBudget=%d/%d estimatedMissed=%d",
            String(activeID.uuidString.prefix(8)), maximumFPS, requestedFPS, totals.framesPerSecond ?? 0,
            totals.averageMilliseconds ?? 0, stats.p95Milliseconds ?? 0, totals.maximumMilliseconds ?? 0,
            totals.overBudgetCount, totals.sampleCount, totals.estimatedMissedFrames)
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        Self.logger.notice("\(line, privacy: .public)")
    }

    private func appendInterval(endingAt timestamp: TimeInterval) {
        guard let last, timestamp > last else { return }
        let interval = timestamp - last
        intervals.append(interval)
        totals.record(interval)
        if intervals.count > 240 { intervals.removeFirst(intervals.count - 240) }
    }

    private func tick(_ link: CADisplayLink) {
        collectDiagnostics()
        let now = CACurrentMediaTime()
        let turning = reader?.isTransitioning == true
        let id = reader?.animationDiagnostic?.transitionID
        if wasTurning, !turning || id != activeID {
            recordCallbackSummary()
        }
        if turning, id != activeID {
            activeID = id
            intervals.removeAll(keepingCapacity: true)
            totals = ReaderFrameRateTotals(targetFramesPerSecond: max(1, requestedFPS))
            last = nil
        }
        if turning, wasTurning { appendInterval(endingAt: now) }
        wasTurning = turning
        last = turning ? now : nil
    }
}
