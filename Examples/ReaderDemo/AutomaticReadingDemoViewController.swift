import UIKit
import BonePageTurnKit

/// 三种自动阅读接入示例；摄像头识别由宿主提供，这里用原生滑动和按钮输入外部翻页事件。
@MainActor
final class AutomaticReadingDemoViewController: UIViewController {
    private let modes = UISegmentedControl(items: ["手势翻页", "自动滚屏", "定时翻页"])
    private let status = UILabel()
    private let position = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let mount = UIView()
    private let pauseButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private var surface: ReaderSurfaceViewController?
    private let provider = AutomaticDemoProvider()
    private var index = 0
    private var started = false
    private var paused = false
    private var menuOpen = false
    private var speed: Double = 1
    private let count = 30

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        modes.selectedSegmentIndex = 0
        modes.accessibilityIdentifier = "automatic-mode"
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        status.font = .systemFont(ofSize: 14); status.accessibilityIdentifier = "automatic-state"
        position.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        position.accessibilityIdentifier = "automatic-position"
        progress.accessibilityIdentifier = "automatic-progress"
        pauseButton.setTitle("暂停", for: .normal)
        pauseButton.accessibilityIdentifier = "automatic-pause"
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        menuButton.setTitle("菜单暂停", for: .normal)
        menuButton.accessibilityIdentifier = "automatic-menu"
        menuButton.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [
            button("上一页", "automatic-previous", #selector(previous)),
            button("下一页", "automatic-next", #selector(nextPage)), pauseButton,
            button("速度 ×2", "automatic-speed", #selector(changeSpeed))
        ])
        controls.distribution = .fillEqually
        let note = UILabel(); note.numberOfLines = 0; note.font = .systemFont(ofSize: 12)
        note.text = "手势模式可左右滑动；上下页按钮模拟摄像头识别后的事件。滚屏与定时翻页使用 SDK 自动驱动。"
        let header = UIStackView(arrangedSubviews: [modes, controls, menuButton, status, position, progress, note])
        header.axis = .vertical; header.spacing = 7
        for child in [header, mount] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        mount.accessibilityIdentifier = "automatic-reader"
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            mount.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            mount.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            mount.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            mount.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface?.view.frame = mount.bounds
        guard !started, mount.bounds.width > 0, mount.bounds.height > 0 else { return }
        started = true
        installMode()
    }

    /// - Parameters: title: 按钮文字；id: 测试标识；action: 事件。返回原生按钮。
    private func button(_ title: String, _ id: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// 在宿主保存源页后切换 renderer，演示内容一块对应一源页，真实 App 应使用字符／源页定位。
    private func installMode() {
        do {
            let next = try ReaderSurfaceViewController(metrics: .init(bodyInsets: .init(top: 16, left: 20, bottom: 16, right: 20)),
                                                       motion: .contentOnly, viewportPolicy: nil,
                                                       backgroundColor: .secondarySystemBackground)
            next.view.frame = mount.bounds; next.view.layoutIfNeeded()
            next.onReadingStatus = { [weak self] state in
                self?.index = Int(state.identity.unitID) ?? 0
                self?.updatePosition()
            }
            next.onLayoutChange = { [weak next] _ in
                if let reader = next?.pagedReader { try? reader.notifyContentAvailable(expectedToken: reader.contentRequestToken) }
            }
            next.pageProvider = { [weak self] identity, direction, _ in
                guard let self, let current = Int(identity.unitID) else { return .failed }
                let target = current + (direction == .next ? 1 : -1)
                guard target >= 0, target < self.count else { return .boundary(target < 0 ? .startOfBook : .endOfBook) }
                return .page(self.page(target))
            }
            if modes.selectedSegmentIndex == 1 {
                let window = try ContinuousWindow(items: (0..<count).map {
                    .init(identity: .init(sourceID: "automatic", unitID: String($0)), sectionID: "sample", extent: 320)
                }, before: .startOfBook, after: .endOfBook)
                let reader = try next.showContinuous(window: window, provider: provider,
                                                     anchor: .init(identity: window.items[index].identity, offsetInItem: 0))
                reader.shouldBeginPan = { [weak self] _ in self?.menuOpen == false }
                reader.onVisibleAnchor = { [weak self] _ in self?.updatePosition() }
                reader.onAutomaticReadingStateChange = { [weak self] state in self?.status.text = "滚屏：\(state)" }
            } else {
                let reader = try next.showPaged(page: page(index), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal)))
                reader.onAutomaticReadingStateChange = { [weak self] state in self?.status.text = "翻页：\(state)" }
                reader.onAutomaticReadingProgress = { [weak self] value in
                    self?.progress.setProgress(Float(value), animated: false)
                    self?.progress.accessibilityValue = String(format: "%.2f", value)
                }
            }
            surface?.invalidate(); surface?.willMove(toParent: nil)
            surface?.view.removeFromSuperview(); surface?.removeFromParent()
            surface = next
            addChild(next); mount.addSubview(next.view); next.didMove(toParent: self)
            next.view.frame = mount.bounds; next.view.layoutIfNeeded()
            menuOpen = false; paused = false; progress.progress = 0
            menuButton.setTitle("菜单暂停", for: .normal); pauseButton.setTitle("暂停", for: .normal)
            if modes.selectedSegmentIndex == 1 { try next.continuousReader?.startAutomaticReading(pointsPerSecond: 60 * speed) }
            else if modes.selectedSegmentIndex == 2 { try next.pagedReader?.startAutomaticReading(interval: 2 / speed) }
            else { status.text = "手势：等待输入" }
            updatePosition()
        } catch { status.text = "错误：\(error)" }
    }

    /// - Parameter index: 源页索引。返回未挂载的正文页面。
    private func page(_ index: Int) -> PageContent {
        let controller = UIViewController()
        let text = UILabel(); text.numberOfLines = 0; text.font = .systemFont(ofSize: 23)
        text.text = "第 \(index + 1) 页\n\n山间的风吹过树林，远处河流沿着山谷流向天边。\n\n切换三种阅读方式，观察当前位置、暂停状态和进度。"
        text.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view = text
        return .init(identity: .init(sourceID: "automatic", unitID: String(index)), controller: controller,
                     readingInfo: .init(before: index == 0 ? .startOfBook : .available,
                                        after: index == count - 1 ? .endOfBook : .available))
    }

    /// 只显示当前 renderer 的真实位置，不以计时器估算滚动距离。
    private func updatePosition() {
        let offset = surface?.continuousReader?.visibleAnchor?.offsetInItem ?? 0
        position.text = String(format: "源页 %d / %d · 偏移 %.0f · 速度 %.0fx", index + 1, count, offset, speed)
    }
    @objc private func changeMode() { installMode() }
    /// - Parameter direction: 宿主摄像头/硬件识别后的逻辑方向，旧模式事件在此丢弃。
    private func receiveExternalTurn(_ direction: PageTurnDirection) {
        guard modes.selectedSegmentIndex == 0, !paused, !menuOpen else { return }
        do { _ = try surface?.pagedReader?.turn(direction) } catch { status.text = "手势暂不可用：\(error)" }
    }
    @objc private func previous() { receiveExternalTurn(.previous) }
    @objc private func nextPage() { receiveExternalTurn(.next) }
    @objc private func togglePause() {
        paused.toggle(); pauseButton.setTitle(paused ? "继续" : "暂停", for: .normal)
        do {
            if modes.selectedSegmentIndex == 0 {
                surface?.setSuspended(paused, reason: "external-user")
                status.text = paused ? "手势：已暂停" : "手势：等待输入"
            } else if paused { surface?.pagedReader?.pauseAutomaticReading(); surface?.continuousReader?.pauseAutomaticReading() }
            else { try surface?.pagedReader?.resumeAutomaticReading(); try surface?.continuousReader?.resumeAutomaticReading() }
        } catch { status.text = "错误：\(error)" }
    }
    @objc private func toggleMenu() {
        menuOpen.toggle(); menuButton.setTitle(menuOpen ? "关闭菜单" : "菜单暂停", for: .normal)
        if let continuous = surface?.continuousReader {
            // 菜单通过开始问询拦截用户 pan；计时、点击、安装分别暂停。
            continuous.setSuspended(menuOpen, targets: [.automaticReading, .taps, .contentInstallation], reason: "menu")
        } else { surface?.setSuspended(menuOpen, reason: "menu") }
    }
    @objc private func changeSpeed() {
        speed = speed == 1 ? 2 : 1
        do {
            try surface?.pagedReader?.updateAutomaticReadingInterval(2 / speed)
            try surface?.continuousReader?.updateAutomaticReadingSpeed(pointsPerSecond: 60 * speed)
            updatePosition()
        } catch { status.text = "错误：\(error)" }
    }
}

@MainActor
private final class AutomaticDemoProvider: ContinuousContentProvider {
    func makeContentView(reuseIdentifier: String) -> UIView { UILabel() }
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let label = view as? UILabel else { return }
        label.numberOfLines = 0; label.font = .systemFont(ofSize: 22)
        label.text = "第 \((Int(item.identity.unitID) ?? 0) + 1) 个源页\n\n连续文字自动向上移动。\n拖动时暂停驱动，松手并停止减速后继续。\n主动暂停会一直保留，调速不会擅自恢复。"
    }
    func unbind(_ view: UIView, binding: PageViewBinding) { (view as? UILabel)?.text = nil }
}
