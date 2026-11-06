import UIKit
import BonePageTurnKit

/// 独立演示按可读高度补屏；接入方只提供有界数据批次，不把数据页数视作屏幕数。
@MainActor
final class ContinuousFillingDemoViewController: UIViewController, ContinuousContentProvider {
    private let container = PageTurnViewController()
    private let scenarios = UISegmentedControl(items: ["四块一屏", "占位补齐", "无进展"])
    private let status = UILabel()
    private var viewport = CGSize.zero
    private var requests = 0
    private var event = "准备窗口"
    private let maximumCount = 20

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "连续阅读 · 按高度补屏"
        title.font = .boldSystemFont(ofSize: 19)
        let detail = UILabel()
        detail.text = "每批 4 个数据块；可读正文与占位分开计算。"
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabel
        scenarios.selectedSegmentIndex = ProcessInfo.processInfo.arguments.contains("--fill-stalled") ? 2 :
            (ProcessInfo.processInfo.arguments.contains("--fill-placeholder") ? 1 : 0)
        scenarios.addTarget(self, action: #selector(restart), for: .valueChanged)
        let retry = UIButton(type: .system)
        retry.setTitle("允许新一轮补屏", for: .normal)
        retry.addTarget(self, action: #selector(retryFilling), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [title, detail, scenarios, retry])
        controls.axis = .vertical
        controls.spacing = 8
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.numberOfLines = 4
        status.textAlignment = .center
        addChild(container)
        for child in [controls, container.view, status].compactMap({ $0 }) {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        container.didMove(toParent: self)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.view.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.view.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 80)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = container.view.bounds.size
        guard size.width > 0, size.height > 0, size != viewport else { return }
        viewport = size
        restart()
    }

    /// - Parameters: index: 数据块索引；height: 接入方排好的最终占用高度；state: 可读状态。
    /// - Returns: 有稳定身份的内容块，刻意不提供虚假的全书显示页数。
    private func item(_ index: Int, height: Double, state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: .init(sourceID: "data-\(index)", unitID: String(index)), sectionID: "chapter", extent: height, state: state)
    }

    @objc private func restart() {
        guard viewport.height > 0 else { return }
        requests = 0
        event = "初始 4 块恰好一屏，继续补足下方余量"
        let isPlaceholder = scenarios.selectedSegmentIndex == 1
        let items = isPlaceholder ? [item(0, height: Double(viewport.height) * 3, state: .loading)] :
            (0..<4).map { item($0, height: Double(viewport.height) / 4) }
        do {
            let window = try ContinuousWindow(items: items, before: .startOfBook, after: .available)
            try container.showContinuous(window: window, provider: self) { [weak self] reader in
                reader.onContentDemand = { [weak self, weak reader] demand in
                    guard let self, let reader else { return }
                    self.load(demand, into: reader)
                }
                reader.onFillLimitReached = { [weak self, weak reader] _, limit in
                    guard let self, let reader else { return }
                    self.event = "自动补入已暂停：\(limit)"
                    self.refreshStatus(reader)
                }
                reader.onVisibleAnchor = { [weak self, weak reader] _ in
                    guard let self, let reader else { return }
                    self.refreshStatus(reader)
                }
            }
        } catch { status.text = "无法建立示例：\(error)" }
    }

    /// - Parameters: demand: SDK 需求及可读高度缺口；reader: 当前示例容器。
    private func load(_ demand: ContinuousContentDemand, into reader: ContinuousReaderViewController) {
        requests += 1
        event = demand.target == .edge ? "读取下一批 4 块" : "优先补齐窗口内占位"
        refreshStatus(reader)
        let scenario = scenarios.selectedSegmentIndex
        let blockHeight = Double(viewport.height) / 4
        let oldWindow = reader.window
        var task: Task<Void, Never>?
        do {
            let ticket = try reader.beginLoading(demand.direction, token: demand.token, cancel: { task?.cancel() }) { [weak self, weak reader] result in
                guard let self, let reader, self.container.continuousReader === reader else { return }
                if case .installed = result { self.event = "结果已安装，重新检查可读覆盖" }
                self.refreshStatus(reader)
            }
            task = Task { @MainActor [weak self, weak reader] in
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, let reader, reader.isActive else { return }
                    let next: ContinuousWindow
                    if scenario == 2 {
                        next = oldWindow
                    } else {
                        var items = oldWindow.items
                        switch demand.target {
                        case .item(let identity):
                            if let index = items.firstIndex(where: { $0.identity == identity }) {
                                items[index] = self.item(Int(identity.unitID) ?? 0, height: blockHeight)
                            }
                        case .edge:
                            let oldCount = items.count
                            for index in oldCount..<min(self.maximumCount, oldCount + 4) {
                                items.append(self.item(index, height: blockHeight))
                            }
                        }
                        next = try ContinuousWindow(items: items, before: .startOfBook,
                                                    after: items.count >= self.maximumCount ? .endOfBook : .available)
                    }
                    try reader.submit(next, for: ticket)
                } catch is CancellationError { return }
                catch { reader?.rejectLoading(ticket, error: .invalidWindow) }
            }
        } catch { status.text = "读取未登记：\(error)" }
    }

    /// - Parameter reader: 当前 renderer，显示实际可读覆盖，不使用已加载块数换算页码。
    private func refreshStatus(_ reader: ContinuousReaderViewController) {
        let coverage = reader.readableCoverage
        status.text = "视口 \(Int(viewport.height)) pt · 可见可读 \(Int(coverage?.visibleReadyExtent ?? 0)) pt\n" +
            "从顶部连续可读 \(Int(coverage?.contiguousReadyFromTop ?? 0)) pt\n" +
            "已装入 \(reader.window.items.count) 块 · 请求 \(requests) 次\n\(event)"
    }

    @objc private func retryFilling() {
        do { try container.continuousReader?.resumeContentFilling() }
        catch { status.text = "当前尚不能重试：\(error)" }
    }

    func makeContentView(reuseIdentifier: String) -> UIView {
        let label = FillingInsetLabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        return label
    }
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let label = view as? UILabel else { return }
        let index = Int(item.identity.unitID) ?? 0
        label.text = item.state == .ready ? "数据块 \(index + 1)\n占正文视口的 1/4；四块才组成一屏。" : "加载占位\n虽然很高，但可读高度为 0。"
        label.backgroundColor = index.isMultiple(of: 2) ? .secondarySystemBackground : .tertiarySystemBackground
        label.textColor = .label
    }
    func unbind(_ view: UIView, binding: PageViewBinding) {}
}

private final class FillingInsetLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 20, dy: 12)) }
}
