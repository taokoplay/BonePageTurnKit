import UIKit
import BonePageTurnKit

/// 只演示 SDK 通用交互，不连接现有 App 的菜单、章节服务或数据库。
@MainActor
final class SDKInteractionDemoViewController: UIViewController, ContinuousContentProvider {
    private let reader = PageTurnViewController()
    private let modes = UISegmentedControl(items: ["点击翻页", "连续自动阅读"])
    private let status = UILabel()
    private var loadedCount = 2
    private var menuPaused = false
    private var exitToken: ReaderExitToken?
    private let availableCount = 8

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        modes.selectedSegmentIndex = 1
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        let title = UILabel()
        title.text = "通用阅读交互"
        title.font = .boldSystemFont(ofSize: 19)
        let readingActions = row([
            button("开始", action: #selector(start)), button("暂停", action: #selector(pause)),
            button("恢复", action: #selector(resume)), button("停止", action: #selector(stop))
        ])
        let exitActions = row([
            button("菜单暂停", action: #selector(toggleMenu)), button("开始退出", action: #selector(beginExit)),
            button("取消退出", action: #selector(cancelExit)), button("确认退出", action: #selector(finishExit))
        ])
        let controls = UIStackView(arrangedSubviews: [title, modes, readingActions, exitActions])
        controls.axis = .vertical
        controls.spacing = 8
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.numberOfLines = 3
        status.textAlignment = .center
        addChild(reader)
        for child in [controls, reader.view, status].compactMap({ $0 }) {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        reader.didMove(toParent: self)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            reader.view.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 60)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if reader.configuration == nil, reader.view.bounds.height > 0 { presentReader() }
    }

    /// - Parameters: title: 按钮文案；action: 操作入口。
    /// - Returns: 原生测试操作按钮。
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    /// - Parameter views: 一行按钮。
    /// - Returns: 等宽排列。
    private func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.distribution = .fillEqually
        return stack
    }
    private func identity(_ index: Int) -> PageItemIdentity { .init(sourceID: "demo-book", unitID: String(index)) }
    private func text(_ index: Int) -> String {
        "第 \(index + 1) 段\n\n雨停之后，书店门前的石板路映出了天空。\n\n这是一段真实可滚动的示例内容。前后内容高度不同，接近已加载窗口末尾时，宿主会延迟一秒补入下两段。\n\n可以拖动、打开菜单暂停，或模拟返回后取消。"
    }
    private func contentWindow(count: Int) throws -> ContinuousWindow {
        let items = (0..<count).map {
            ContinuousItem(identity: identity($0), sectionID: "section-\($0 / 2)", extent: Double(400 + ($0 % 3) * 80))
        }
        return try ContinuousWindow(items: items, before: .startOfBook, after: count < availableCount ? .available : .endOfBook)
    }
    private func page(_ index: Int) -> PageContent {
        let controller = UIViewController()
        let label = makeContentView(reuseIdentifier: "text")
        configure(label, index: index)
        controller.view = label
        return .init(identity: identity(index), controller: controller)
    }

    /// 新模式使用同一个外壳和暂停协调器；未支持的业务不在示例中补假实现。
    private func presentReader() {
        reader.onExitFinalized = { [weak self] _ in
            self?.exitToken = nil
            self?.status.text = "退出已确认，renderer 已失效\n切换模式可重新开始示例"
        }
        do {
            if modes.selectedSegmentIndex == 0 {
                let taps = try ReaderTapConfiguration()
                try reader.showPaged(page: page(0), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal))) { [weak self] paged in
                    paged.tapConfiguration = taps
                    paged.onCenterTap = { [weak self] _ in self?.toggleMenu() }
                    paged.pageProvider = { [weak self] identity, direction in
                        guard let self, let old = Int(identity.unitID) else { return .failed }
                        let target = old + (direction == .next ? 1 : -1)
                        guard (0..<self.availableCount).contains(target) else { return .boundary(target < 0 ? .startOfBook : .endOfBook) }
                        return .page(self.page(target))
                    }
                    paged.onTransition = { [weak self] event in
                        if case .didCommit(let transaction) = event { self?.status.text = "当前第 \((Int(transaction.to.unitID) ?? 0) + 1) 段\n左／右点击翻页，中间点击触发菜单暂停" }
                    }
                }
                status.text = "左／右点击翻页\n中间点击触发菜单暂停，顶部按钮解除"
            } else {
                loadedCount = 2
                try reader.showContinuous(window: contentWindow(count: loadedCount), provider: self) { [weak self] continuous in
                    continuous.onEdgeApproach = { [weak self, weak continuous] direction, token in
                        guard let self, let continuous, direction == .next else { return }
                        self.loadNext(into: continuous, token: token)
                    }
                    continuous.onAutomaticReadingStateChange = { [weak self] state in self?.showState(state) }
                    continuous.onStableAnchor = { [weak self] anchor in
                        guard let self else { return }
                        self.status.accessibilityValue = "稳定位置 \(anchor.identity.unitID):\(Int(anchor.offsetInItem))"
                    }
                }
                status.text = "已加载 2 段，边缘加载延迟 1 秒\n点开始，速度为 80 point/s"
                if ProcessInfo.processInfo.arguments.contains("--auto-start") { try reader.continuousReader?.startAutomaticReading(pointsPerSecond: 80) }
            }
        } catch { status.text = "操作未完成：\(error)" }
    }

    /// - Parameters: continuous: 当前 renderer；token: 边缘需求的窗口版本。
    private func loadNext(into continuous: ContinuousReaderViewController, token: ContinuousUpdateToken) {
        guard loadedCount < availableCount else { return }
        let nextCount = min(availableCount, loadedCount + 2)
        var task: Task<Void, Never>?
        do {
            let ticket = try continuous.beginLoading(.next, token: token, cancel: { task?.cancel() }) { [weak self, weak continuous] result in
                guard let self, let continuous, self.reader.continuousReader === continuous else { return }
                if case .installed = result {
                    self.loadedCount = nextCount
                    self.showState(continuous.automaticReadingState)
                }
            }
            task = Task { @MainActor [weak self, weak continuous] in
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, let continuous, continuous.isActive else { return }
                    try continuous.submit(self.contentWindow(count: nextCount), for: ticket)
                } catch is CancellationError {
                    return
                } catch {
                    continuous?.rejectLoading(ticket, error: .invalidWindow)
                }
            }
        } catch { status.text = "加载未登记：\(error)" }
    }

    private func showState(_ state: ContinuousAutomaticReadingState) {
        let text: String
        switch state {
        case .stopped: text = "已停止"
        case .running: text = "正在自动阅读"
        case .paused: text = "已暂停"
        case .waiting(let boundary): text = "等待内容：\(boundary)"
        case .finished: text = "已到全书末尾"
        }
        status.text = "\(text)\n已加载 \(loadedCount) / \(availableCount) 段 · 80 point/s"
    }

    func makeContentView(reuseIdentifier: String) -> UIView {
        let label = InteractionInsetLabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 18)
        return label
    }
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) { configure(view, index: Int(item.identity.unitID) ?? 0) }
    func unbind(_ view: UIView, binding: PageViewBinding) {}
    private func configure(_ view: UIView, index: Int) {
        (view as? UILabel)?.text = text(index)
        view.backgroundColor = index.isMultiple(of: 2) ? .secondarySystemBackground : .tertiarySystemBackground
    }

    @objc private func changeMode() {
        guard !reader.isExitInProgress else {
            modes.selectedSegmentIndex = reader.pagedReader == nil ? 1 : 0
            status.text = "请先取消退出或确认退出"
            return
        }
        presentReader()
    }
    @objc private func start() {
        do { try reader.continuousReader?.startAutomaticReading(pointsPerSecond: 80) }
        catch { status.text = "无法开始：\(error)" }
    }
    @objc private func pause() { reader.continuousReader?.pauseAutomaticReading() }
    @objc private func resume() {
        do { try reader.continuousReader?.resumeAutomaticReading() }
        catch { status.text = "无法恢复：\(error)" }
    }
    @objc private func stop() { reader.continuousReader?.stopAutomaticReading() }
    @objc private func toggleMenu() {
        menuPaused.toggle()
        reader.setSuspended(menuPaused, reason: "demo-menu")
        if modes.selectedSegmentIndex == 0 { status.text = menuPaused ? "菜单暂停中，点击顶部“菜单暂停”解除" : "菜单暂停已解除" }
    }
    @objc private func beginExit() { exitToken = reader.beginExit(); status.text = "正在退出：原页面已暂停\n可以取消退出或确认退出" }
    @objc private func cancelExit() {
        guard let exitToken else { return }
        if reader.cancelExit(exitToken) {
            self.exitToken = nil
            status.text = "退出已取消；其他暂停原因继续保留"
        }
    }
    @objc private func finishExit() {
        guard let exitToken else { return }
        _ = reader.finishExit(exitToken)
    }
}

private final class InteractionInsetLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 22, dy: 20)) }
}
