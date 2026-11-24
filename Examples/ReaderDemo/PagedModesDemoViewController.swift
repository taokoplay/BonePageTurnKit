import UIKit
import BonePageTurnKit

/// 分页效果与自动阅读示例：页面由宿主提供，第三页首次请求模拟一秒加载。
@MainActor
final class PagedModesDemoViewController: UIViewController {
    private let reader = PageTurnViewController()
    private let effects = UISegmentedControl(items: ["平移", "覆盖", "无动画", "仿真", "拱页"])
    private let axes = UISegmentedControl(items: ["横向", "纵向"])
    private let spines = UISegmentedControl(items: ["自动书脊", "左书脊", "中央", "右书脊"])
    private let status = UILabel()
    private let notice = UILabel()
    private let menuButton = UIButton(type: .system)
    private let effectValues: [PageTurnEffect] = [.slide, .cover, .none, .curl, .arch]
    private let axisValues: [PageTurnAxis] = [.horizontal, .vertical]
    private let spineValues: [PageSpinePlacement] = [.automatic, .minimum, .center, .maximum]
    private let titles = ["雨后的书店", "门前的灯", "迟来的书页", "窗边的座位", "午后的来客", "夹在书里的信", "归途", "最后一页"]
    private let sourceID = "paged-modes-demo-book"
    private let readingInterval: TimeInterval = 2
    private var installedEffectIndex = 0
    private var installedAxisIndex = 0
    private var installedSpineIndex = 0
    private var installing = false
    private var attemptedInitialPresentation = false
    private var handledAutoStart = false
    private var menuPaused = false
    private var thirdPageReady = false
    private var loadingToken: PageViewBinding?
    private var loadingTask: Task<Void, Never>?
    private var replacementTask: Task<Void, Never>?

    deinit { loadingTask?.cancel(); replacementTask?.cancel() }

    /// 创建固定头尾控件，正文容器只占据两者之间的空间。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "分页模式"
        let arguments = ProcessInfo.processInfo.arguments
        effects.selectedSegmentIndex = arguments.contains("--cover-style") ? 1 : (arguments.contains("--paper-arch") ? 4 : (arguments.contains("--paper-curl") ? 3 : 0))
        spines.selectedSegmentIndex = arguments.contains("--right-spine") ? 3 : 0
        spines.accessibilityIdentifier = "paged-spine"
        spines.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        axes.selectedSegmentIndex = 0
        effects.accessibilityIdentifier = "paged-effect"
        axes.accessibilityIdentifier = "paged-axis"
        effects.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        axes.addTarget(self, action: #selector(changeMode), for: .valueChanged)

        let heading = UILabel()
        heading.text = "分页效果与自动阅读"
        heading.font = .boldSystemFont(ofSize: 19)
        menuButton.setTitle("菜单暂停", for: .normal)
        menuButton.titleLabel?.font = .systemFont(ofSize: 14)
        menuButton.accessibilityIdentifier = "paged-menu"
        menuButton.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside)
        let navigation = row([
            button("上一页", identifier: "paged-previous", action: #selector(previousPage)),
            button("下一页", identifier: "paged-next", action: #selector(nextPage)), menuButton
        ])
        let contentActions = row([
            button("回填本页", identifier: "paged-replace", action: #selector(replacePage)),
            button("半翻预览", identifier: "paged-preview", action: #selector(previewPaper)),
            button("取消翻页", identifier: "paged-cancel", action: #selector(cancelTurn))
        ])
        let header = UIStackView(arrangedSubviews: [heading, effects, axes, spines, navigation, contentActions])
        header.axis = .vertical
        header.spacing = 6

        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.numberOfLines = 2
        status.textAlignment = .center
        status.accessibilityIdentifier = "paged-status"
        notice.font = .systemFont(ofSize: 12)
        notice.numberOfLines = 2
        notice.textAlignment = .center
        notice.accessibilityIdentifier = "paged-message"
        let automatic = row([
            button("自动开始", identifier: "paged-auto-start", action: #selector(startAutomatic)),
            button("暂停", identifier: "paged-auto-pause", action: #selector(pauseAutomatic)),
            button("恢复", identifier: "paged-auto-resume", action: #selector(resumeAutomatic)),
            button("停止", identifier: "paged-auto-stop", action: #selector(stopAutomatic))
        ])
        let footer = UIStackView(arrangedSubviews: [automatic, status, notice])
        footer.axis = .vertical
        footer.spacing = 6

        reader.loadViewIfNeeded()
        guard let readingView = reader.viewIfLoaded else { return }
        addChild(reader)
        for child in [header, readingView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        reader.didMove(toParent: self)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heading.heightAnchor.constraint(equalToConstant: 24),
            effects.heightAnchor.constraint(equalToConstant: 32),
            axes.heightAnchor.constraint(equalToConstant: 32),
            spines.heightAnchor.constraint(equalToConstant: 32),
            contentActions.heightAnchor.constraint(equalToConstant: 32),
            navigation.heightAnchor.constraint(equalToConstant: 32),
            readingView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            readingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readingView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            automatic.heightAnchor.constraint(equalToConstant: 32),
            status.heightAnchor.constraint(equalToConstant: 40),
            notice.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    /// 首次安装等待正文视口有实际尺寸，避免零尺寸交互。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !attemptedInitialPresentation, reader.view.bounds.width > 0, reader.view.bounds.height > 0 else { return }
        attemptedInitialPresentation = true
        installSelectedMode()
    }

    /// - Parameter animated: UIKit 展示动画标记；命令行自动启动只执行一次。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ProcessInfo.processInfo.arguments.contains("--paper-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.previewPaper() }
        }
        guard !handledAutoStart, reader.pagedReader != nil,
              ProcessInfo.processInfo.arguments.contains("--auto-start") else { return }
        handledAutoStart = true
        startAutomatic()
    }

    /// - Parameter animated: UIKit 离场动画标记；真正离开示例时终止请求和阅读器。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelLoading()
            reader.invalidate()
        }
    }

    /// - Parameters: title: 文案；identifier: 无障碍标识；action: 点击入口。
    /// - Returns: 原生按钮。
    private func button(_ title: String, identifier: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// - Parameter views: 同行控件。
    /// - Returns: 等宽按钮行。
    private func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.distribution = .fillEqually
        stack.spacing = 6
        return stack
    }

    /// - Parameter index: 从零开始的固定示例页索引。
    /// - Returns: 带真实富文本、图片、页码和明确书籍边界的页面。
    /// - Throws: 示例页码无效。
    private func page(_ index: Int, version: UInt64 = 0) throws -> PageContent {
        let identity = PageItemIdentity(sourceID: sourceID, unitID: String(index), contentVersion: version, layoutVersion: version)
        var plan = AsyncStyledRenderPlan()
        plan.title = titles[index] + (version == 0 ? "" : " · 回填 \(version)")
        plan.fontSize = 17
        let controller = AsyncStyledPageController(identity: identity, plan: plan)
        let metrics = try ReaderPageMetrics(current: index + 1, total: .exact(titles.count), unit: .sourcePage)
        let info = ReaderPageInfo(pagination: .init(book: metrics),
                                  before: index == 0 ? .startOfBook : .available,
                                  after: index == titles.count - 1 ? .endOfBook : .available)
        return .init(identity: identity, controller: controller, readingInfo: info)
    }

    /// - Parameters: identity: 请求起点身份；direction: 逻辑方向。
    /// - Returns: 由身份计算的相邻页面，第三页首次等待，其余边界如实报告。
    private func availability(from identity: PageItemIdentity, direction: PageTurnDirection) -> PageAvailability {
        guard identity.sourceID == sourceID, let current = Int(identity.unitID), titles.indices.contains(current) else {
            return .failed
        }
        let target = current + (direction == .next ? 1 : -1)
        guard titles.indices.contains(target) else {
            return .boundary(target < 0 ? .startOfBook : .endOfBook)
        }
        if current == 1, target == 2, !thirdPageReady { return .waiting }
        do { return .page(try page(target)) }
        catch { return .failed }
    }

    /// 先验证组合；非法选择保留旧阅读器并把两个控件恢复到上次成功配置。
    private func installSelectedMode() {
        guard !installing, effectValues.indices.contains(effects.selectedSegmentIndex),
              axisValues.indices.contains(axes.selectedSegmentIndex), spineValues.indices.contains(spines.selectedSegmentIndex) else { return }
        installing = true
        defer { installing = false }
        let effectIndex = effects.selectedSegmentIndex
        let axisIndex = axes.selectedSegmentIndex
        let spineIndex = spines.selectedSegmentIndex
        let configuration = PageTurnConfiguration(presentation: .paged(effect: effectValues[effectIndex], axis: axisValues[axisIndex]),
                                                 spine: spineValues[spineIndex],
                                                 cover: ProcessInfo.processInfo.arguments.contains("--cover-style")
                                                    ? .init(cornerRadius: 36, shadowOpacity: 0.35, shadowRadius: 24, shadowOffsetX: 12) : .standard)
        do {
            try configuration.validate()
            let index = reader.pagedReader.flatMap { Int($0.currentPage.identity.unitID) } ?? 0
            let initialPage = try page(index, version: reader.pagedReader?.currentPage.identity.contentVersion ?? 0)
            let taps = try ReaderTapConfiguration()
            let paged = try reader.showPaged(page: initialPage, configuration: configuration) { [weak self] paged in
                self?.prepare(paged, taps: taps)
            }
            // 只有新模式安装成功才清理旧任务；失败不会破坏原模式正在进行的加载。
            cancelLoading()
            installedEffectIndex = effectIndex
            installedAxisIndex = axisIndex
            installedSpineIndex = spineIndex
            paged.view.setNeedsLayout()
            paged.view.layoutIfNeeded()
            refreshStatus(paged)
            showNotice("拖动或点击翻页；回填本页延迟一秒提交，半翻预览可取消。")
        } catch {
            effects.selectedSegmentIndex = installedEffectIndex
            axes.selectedSegmentIndex = installedAxisIndex
            spines.selectedSegmentIndex = installedSpineIndex
            if effectValues[effectIndex] == .cover, axisValues[axisIndex] == .vertical {
                showNotice("覆盖翻页不支持纵向。已恢复为\(modeDescription)。", isError: true)
            } else {
                showNotice("模式切换失败：\(message(for: error))", isError: true)
            }
        }
    }

    /// - Parameters: paged: 尚在安装中的新容器；taps: 沿配置主轴解释的点击分区。
    private func prepare(_ paged: PagedReaderViewController, taps: ReaderTapConfiguration) {
        paged.tapConfiguration = taps
        // 与全屏示例一致：快速连点时上一笔收尾立即落定、新一笔同步起播，连翻节奏贴近系统卷页。
        paged.handsOverActiveTransitionOnNewIntent = true
        // 左滑（上一页）带细微斜向折痕（参考主流阅读 App 的轻微弧度），折叠仍自由跟手；
        // 右滑（下一页）点击带系统卷页式的斜向卷曲，拖动仍自由跟手不斜。
        paged.previousTurnSlant = 0.05
        paged.nextTurnSlant = 0.05
        // 空闲预取邻页快照：点击翻页几乎零准备延迟。
        paged.prefetchNeighborSnapshots = true
        paged.pageProvider = { [weak self] identity, direction in
            self?.availability(from: identity, direction: direction) ?? .failed
        }
        paged.onPageReplacement = { [weak self, weak paged] _ in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            self.refreshStatus(paged)
        }
        paged.onCenterTap = { [weak self] _ in self?.toggleMenu() }
        paged.onReadingStatus = { [weak self, weak paged] _ in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            self.refreshStatus(paged)
        }
        paged.onAutomaticReadingStateChange = { [weak self, weak paged] _ in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            self.refreshStatus(paged)
        }
        paged.onTransition = { [weak self, weak paged] event in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            if case .didCommit = event {
                if let token = self.loadingToken, token != paged.contentRequestToken { self.cancelLoading() }
                self.refreshStatus(paged)
            }
        }
        paged.onViewportSizeChange = { [weak self, weak paged] _ in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            self.cancelLoading()
            // 固定示例页仅重新排版；这是新的布局通知，不复用已取消加载的令牌。
            let token = paged.contentRequestToken
            paged.currentPage.controller.view.setNeedsLayout()
            paged.currentPage.controller.view.layoutIfNeeded()
            do { try paged.notifyContentAvailable(expectedToken: token) }
            catch { self.showNotice(self.message(for: error), isError: true) }
            self.refreshStatus(paged)
        }
        paged.onUnavailable = { [weak self, weak paged] direction, availability in
            guard let self, let paged, self.reader.pagedReader === paged else { return }
            switch availability {
            case .waiting:
                self.showNotice("第三页准备中，约一秒后就绪；暂停后可用“恢复”继续。")
                self.loadThirdPage(into: paged, direction: direction)
            case .boundary(let boundary): self.showNotice(self.boundaryDescription(boundary))
            case .end: self.showNotice("当前内容已到末尾。")
            case .failed: self.showNotice("页面加载失败，请重试。", isError: true)
            case .page: break
            }
            self.refreshStatus(paged)
        }
    }

    /// - Parameters: paged: 发出不可用通知的容器；direction: 请求方向。
    /// 捕获通知时的内容令牌；完成时检查同一令牌，不改读新令牌来安装旧请求。
    private func loadThirdPage(into paged: PagedReaderViewController, direction: PageTurnDirection) {
        guard direction == .next, paged.currentPage.identity.unitID == "1", !thirdPageReady else { return }
        let token = paged.contentRequestToken
        guard loadingToken != token || loadingTask == nil else { return }
        cancelLoading()
        loadingToken = token
        loadingTask = Task { @MainActor [weak self, weak paged] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled, let self, let paged, paged.isActive,
                  self.reader.pagedReader === paged, self.loadingToken == token else { return }
            self.loadingTask = nil
            self.loadingToken = nil
            guard paged.contentRequestToken == token else {
                self.showNotice("页面位置或尺寸已改变，请再次点击下一页。")
                return
            }
            self.thirdPageReady = true
            do {
                // 只通知供给已改变，是否继续由 SDK 的自动状态决定，手动暂停保持有效。
                try paged.notifyContentAvailable(expectedToken: token)
                self.showNotice("第三页已就绪。暂停时可点恢复，也可手动翻页。")
            } catch {
                self.showNotice("内容通知未完成：\(self.message(for: error))", isError: true)
            }
            self.refreshStatus(paged)
        }
    }

    /// 取消旧模式或旧页面的任务；下一次明确请求才重新加载。
    private func cancelLoading() {
        loadingTask?.cancel()
        replacementTask?.cancel()
        replacementTask = nil
        loadingTask = nil
        loadingToken = nil
    }

    private var modeDescription: String {
        let effect = effects.titleForSegment(at: installedEffectIndex) ?? "平移"
        let axis = axes.titleForSegment(at: installedAxisIndex) ?? "横向"
        let spine = installedSpineIndex == 0 ? "" : " · \(spines.titleForSegment(at: installedSpineIndex) ?? "")"
        return axis + effect + spine
    }

    /// - Parameter paged: 当前成功安装的容器；页码与自动状态分别显示。
    private func refreshStatus(_ paged: PagedReaderViewController) {
        let number = paged.readingStatus?.pagination.book?.current ?? ((Int(paged.currentPage.identity.unitID) ?? 0) + 1)
        let interval = String(format: "%.1f", paged.automaticReadingInterval)
        status.text = "第 \(number) / \(titles.count) 页 · \(modeDescription) · v\(paged.currentPage.identity.contentVersion)\n自动：\(automaticDescription(paged.automaticReadingState)) · \(interval) 秒/页"
    }

    /// - Parameter state: SDK 分页自动状态。
    /// - Returns: 面向读者的状态文字。
    private func automaticDescription(_ state: PagedAutomaticReadingState) -> String {
        switch state {
        case .stopped: return "已停止"
        case .running: return "阅读中"
        case .paused: return "已暂停"
        case .turning: return "翻页中"
        case .waiting(let boundary): return "等待（\(boundaryDescription(boundary))）"
        case .finished(let boundary): return boundary == .endOfBook ? "已到全书末尾" : boundaryDescription(boundary)
        }
    }

    /// - Parameter boundary: 当前真实供给边界。
    /// - Returns: 边界或加载状态说明。
    private func boundaryDescription(_ boundary: ReaderBoundaryState) -> String {
        switch boundary {
        case .unknown: return "内容状态待确认"
        case .available: return "内容已就绪"
        case .loading: return "内容加载中"
        case .failed: return "内容加载失败"
        case .end: return "当前内容末尾"
        case .startOfBook: return "已到全书开头"
        case .endOfSection: return "已到本章末尾"
        case .endOfBook: return "已到全书末尾"
        case .latestAvailable: return "已到最新内容"
        }
    }

    /// - Parameters: text: 操作反馈；isError: 是否用错误色明确提示。
    private func showNotice(_ text: String, isError: Bool = false) {
        notice.text = text
        notice.textColor = isError ? .systemRed : .secondaryLabel
    }

    /// - Parameter error: 当前操作错误。
    /// - Returns: 可采取下一步操作的说明。
    private func message(for error: Error) -> String {
        guard let error = error as? PageTurnError else { return "操作未完成，请重试。" }
        switch error {
        case .unsupportedPresentation: return "所选效果与方向尚不支持。"
        case .unsupportedSpine: return "当前模式不支持所选书脊；中央书脊需要双页编排。"
        case .snapshotUnavailable: return "页面快照不可用，已恢复原页。"
        case .interactionInProgress: return "翻页或暂停尚未结束，请稍后再试。"
        case .inactive: return "阅读会话已结束，请重新选择模式。"
        case .stalePresentation, .staleWindow: return "页面已改变，请重新请求。"
        default: return "页面暂时不可用，请重试。"
        }
    }

    /// 延迟回填同一页；使用请求开始时的绑定，迟到结果不能覆盖已经翻到的新页面。
    @objc private func replacePage() {
        guard let paged = reader.pagedReader, let index = Int(paged.currentPage.identity.unitID) else { return }
        let binding = paged.currentPageBinding
        replacementTask?.cancel()
        showNotice("正在准备本页回填；翻页中或暂停时会等待稳定后安装。")
        replacementTask = Task { @MainActor [weak self, weak paged] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled, let self, let paged, self.reader.pagedReader === paged else { return }
            self.replacementTask = nil
            do {
                let content = try self.page(index, version: binding.identity.contentVersion + 1)
                _ = try paged.submitCurrentPage(content, expectedBinding: binding) { [weak self, weak paged] outcome in
                    guard let self, let paged, self.reader.pagedReader === paged else { return }
                    switch outcome {
                    case .installed: self.showNotice("本页已原位回填，保留同一个阅读容器。")
                    case .superseded: self.showNotice("本次回填已被更新的请求替代。")
                    case .cancelled, .invalidated: self.showNotice("本次回填已取消。")
                    case .rejected(let error): self.showNotice(self.message(for: error), isError: true)
                    }
                    self.refreshStatus(paged)
                }
            } catch { self.showNotice(self.message(for: error), isError: true) }
        }
    }

    /// 在 45% 进度停住真实交互事务，可观察曲面或触发回填后取消。
    @objc private func previewPaper() {
        guard let paged = reader.pagedReader else { return }
        do {
            if try paged.beginInteractiveTurn(.next) {
                let extent = axisValues[installedAxisIndex] == .horizontal ? paged.view.bounds.width : paged.view.bounds.height
                paged.updateInteractiveTurn(displacement: extent * 0.45)
                showNotice("当前停在翻页中途，点击取消翻页后恢复真实页面。")
            }
        } catch { showNotice(message(for: error), isError: true) }
    }

    /// 取消当前交互，触发 SDK 的唯一 settle 及延期回填。
    @objc private func cancelTurn() {
        reader.pagedReader?.cancelTransition()
        showNotice("已取消翻页，恢复当前页。")
    }

    /// 应用当前控件值；非法组合由安装入口明确报告并回滚控件。
    @objc private func changeMode() { installSelectedMode() }

    /// 请求上一页，边界反馈由不可用回调显示。
    @objc private func previousPage() { turn(.previous) }

    /// 请求下一页，等待时不安排轮询。
    @objc private func nextPage() { turn(.next) }

    /// - Parameter direction: 手动翻页的逻辑方向。
    private func turn(_ direction: PageTurnDirection) {
        guard let paged = reader.pagedReader else { return }
        do {
            if try paged.turn(direction) { showNotice("按所选方向拖动或点击，也可使用自动阅读。") }
        } catch { showNotice(message(for: error), isError: true) }
        refreshStatus(paged)
    }

    /// 从当前页开始，每页停留两秒；最后一页同样等待完整停留时间。
    @objc private func startAutomatic() {
        guard let paged = reader.pagedReader else { return }
        do {
            try paged.startAutomaticReading(interval: readingInterval, animated: true)
            showNotice("每页停留两秒，最后一页停留结束后停止自动阅读。")
        } catch { showNotice(message(for: error), isError: true) }
        refreshStatus(paged)
    }

    /// 手动暂停不会被异步内容通知解除。
    @objc private func pauseAutomatic() {
        guard let paged = reader.pagedReader else { return }
        paged.pauseAutomaticReading()
        showNotice("自动阅读已暂停，可点恢复或手动翻页。")
        refreshStatus(paged)
    }

    /// 由读者明确恢复自动阅读。
    @objc private func resumeAutomatic() {
        guard let paged = reader.pagedReader else { return }
        do { try paged.resumeAutomaticReading() }
        catch { showNotice(message(for: error), isError: true) }
        refreshStatus(paged)
    }

    /// 停止计时，保留当前阅读页面。
    @objc private func stopAutomatic() {
        guard let paged = reader.pagedReader else { return }
        paged.stopAutomaticReading()
        showNotice("自动阅读已停止。")
        refreshStatus(paged)
    }

    /// 独立菜单暂停原因可与手动自动阅读暂停并存。
    @objc private func toggleMenu() {
        menuPaused.toggle()
        reader.setSuspended(menuPaused, reason: "paged-demo-menu")
        menuButton.setTitle(menuPaused ? "关闭菜单" : "菜单暂停", for: .normal)
        showNotice(menuPaused ? "菜单暂停中，点“关闭菜单”解除。" : "菜单已关闭。")
        if let paged = reader.pagedReader { refreshStatus(paged) }
    }
}
