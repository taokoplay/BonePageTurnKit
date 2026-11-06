import UIKit
import BonePageTurnKit

/// 独立宿主示例：原创短段落与彩色漫画占位页。小说按段落定位，漫画按源页及图内比例定位。
@MainActor
final class ReaderDemoViewController: UIViewController, ContinuousContentProvider {
    private let reader = PageTurnViewController()
    private let bookControl = UISegmentedControl(items: ["小说", "漫画"])
    private let modeControl = UISegmentedControl(items: ["无动画", "覆盖", "连续"])
    private let publicationControl = UISegmentedControl(items: ["完整内容", "连载快照"])
    private let updateButton = UIButton(type: .system)
    private var isSerial: Bool { publicationControl.selectedSegmentIndex == 1 }
    private var lastBoundary: ReaderBoundaryState { isSerial ? .latestAvailable : .endOfBook }
    private let status = UILabel()
    private var layoutVersion: UInt64 = 0
    private var installedWidth: CGFloat = 0
    private var comic: Bool { bookControl.selectedSegmentIndex == 1 }
    private var count = 16
    private let text = "傍晚，旧车站的钟慢了三分钟。林舟沿着河岸走回书店，把刚收到的信放在窗边。信封上没有署名，只有一张画着山路的地图。风翻动桌上的书页，他决定等雨停以后，去看看那条从未走过的小路。"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        bookControl.selectedSegmentIndex = ProcessInfo.processInfo.arguments.contains("--comic") ? 1 : 0
        modeControl.selectedSegmentIndex = ProcessInfo.processInfo.arguments.contains("--continuous") ? 2 : 1
        bookControl.addTarget(self, action: #selector(changeBook), for: .valueChanged)
        modeControl.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        publicationControl.selectedSegmentIndex = ProcessInfo.processInfo.arguments.contains("--serial") ? 1 : 0
        publicationControl.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        let first = UIButton(type: .system)
        first.setTitle("首页", for: .normal)
        first.addTarget(self, action: #selector(goFirst), for: .touchUpInside)
        let last = UIButton(type: .system)
        last.setTitle("末页／最新", for: .normal)
        last.addTarget(self, action: #selector(goLast), for: .touchUpInside)
        updateButton.setTitle("模拟更新", for: .normal)
        updateButton.addTarget(self, action: #selector(appendContent), for: .touchUpInside)
        let jumps = UIStackView(arrangedSubviews: [first, last, updateButton])
        jumps.distribution = .fillEqually
        let controls = UIStackView(arrangedSubviews: [bookControl, modeControl, publicationControl, jumps])
        controls.axis = .vertical
        controls.spacing = 10
        let previous = UIButton(type: .system)
        previous.setTitle("上一页／段", for: .normal)
        previous.addTarget(self, action: #selector(goPrevious), for: .touchUpInside)
        let next = UIButton(type: .system)
        next.setTitle("下一页／段", for: .normal)
        next.addTarget(self, action: #selector(goNext), for: .touchUpInside)
        status.font = .systemFont(ofSize: 12)
        status.textAlignment = .center
        status.numberOfLines = 3
        let navigation = UIStackView(arrangedSubviews: [previous, next])
        navigation.distribution = .fillEqually
        let bottom = UIStackView(arrangedSubviews: [status, navigation])
        bottom.axis = .vertical
        bottom.spacing = 4
        addChild(reader)
        for child in [controls, reader.view, bottom].compactMap({ $0 }) {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        reader.didMove(toParent: self)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            reader.view.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottom.heightAnchor.constraint(equalToConstant: 82)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, abs(installedWidth - view.bounds.width) > 0.5 else { return }
        installedWidth = view.bounds.width
        let position = capturePosition()
        layoutVersion += 1
        let startsAtLast = reader.configuration == nil && ProcessInfo.processInfo.arguments.contains("--last")
        install(index: startsAtLast ? count - 1 : position.0, fraction: startsAtLast ? 0.99 : position.1)
    }

    /// - Returns: 小说段落或漫画源页位置；生产宿主应进一步使用文本字符位置。
    private func capturePosition() -> (Int, Double) {
        if let continuous = reader.continuousReader, let anchor = continuous.visibleAnchor,
           let index = Int(anchor.identity.unitID) {
            let extent = continuous.window.items.first { $0.identity == anchor.identity }?.extent ?? 1
            return (index, comic ? anchor.offsetInItem / extent : 0)
        }
        return (Int(reader.pagedReader?.currentPage.identity.unitID ?? "0") ?? 0, 0)
    }

    /// - Parameter index: 示例段落／源页索引。
    /// - Returns: 当前内容与布局版本下的中性身份。
    private func identity(_ index: Int) -> PageItemIdentity {
        PageItemIdentity(sourceID: "\(comic ? "comic" : "novel")-\(index)", unitID: String(index), layoutVersion: layoutVersion)
    }

    /// - Parameter index: 示例段落／源页索引。
    /// - Returns: 真实页面控制器，无 SDK 专用基类。
    private func page(_ index: Int) throws -> PageContent {
        let controller = UIViewController()
        let label = makeContentView(reuseIdentifier: "demo")
        controller.view = label
        configure(label, index: index)
        return PageContent(identity: identity(index), controller: controller, readingInfo: try pageInfo(index, total: count))
    }

    /// - Parameters: index: 从零开始的内容单元索引；total: 当前目录快照的总数。
    /// - Returns: 全书和本章的独立计数；小说示例只按段落块计数，明确不冒充生产排版页。
    private func pagination(_ index: Int, total: Int) throws -> ReaderPagination {
        let unit: ReaderCountingUnit = comic ? .sourcePage : .contentBlock
        return ReaderPagination(book: try .init(current: index + 1, total: .exact(total), unit: unit),
                                section: try .init(sectionID: "chapter-\(index / 4)",
                                                   pages: .init(current: index % 4 + 1,
                                                                total: .exact(min(4, total - (index / 4) * 4)), unit: unit)))
    }

    /// - Parameters: index: 内容索引；total: 当前快照总数。
    /// - Returns: 本页统计和明确的内容前后边界。
    private func pageInfo(_ index: Int, total: Int) throws -> ReaderPageInfo {
        try ReaderPageInfo(pagination: pagination(index, total: total), before: index == 0 ? .startOfBook : .available,
                           after: index == total - 1 ? lastBoundary : .available)
    }

    /// - Returns: 按当前宽度排好的异高窗口，漫画高度无需等于视口。
    private func items(total: Int? = nil) throws -> [ContinuousItem] {
        let total = total ?? count
        return try (0..<total).map { index in
            let extent: Double
            if comic {
                extent = Double(380 + (index % 4) * 180)
            } else {
                let rect = ("第 \(index + 1) 段\n\n" + text).boundingRect(
                    with: CGSize(width: max(1, installedWidth - 40), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: 20)], context: nil)
                extent = Double(ceil(rect.height) + 80)
            }
            return ContinuousItem(identity: identity(index), sectionID: "chapter-\(index / 4)", extent: extent,
                                  pagination: try pagination(index, total: total))
        }
    }

    /// - Parameters: index: 源段落／页；fraction: 漫画源页内比例。
    private func install(index: Int, fraction: Double = 0) {
        updateButton.isEnabled = isSerial
        do {
            if modeControl.selectedSegmentIndex == 2 {
                let content = try items()
                let anchor = ContinuousAnchor(identity: identity(index), offsetInItem: content[index].extent * min(0.99, max(0, fraction)))
                try reader.showContinuous(window: ContinuousWindow(items: content, before: .startOfBook, after: lastBoundary), provider: self, anchor: anchor) { [weak self] continuous in
                    continuous.onReadingStatus = { [weak self] status in self?.displayStatus(status) }
                }
            } else {
                let effect: PageTurnEffect = modeControl.selectedSegmentIndex == 0 ? .none : .cover
                try reader.showPaged(page: page(index), configuration: .init(presentation: .paged(effect: effect, axis: .horizontal))) { [weak self] paged in
                    paged.pageProvider = { [weak self] identity, direction in
                        guard let self, let old = Int(identity.unitID) else { return .failed }
                        let target = old + (direction == .next ? 1 : -1)
                        guard (0..<self.count).contains(target) else {
                            return .boundary(target < 0 ? .startOfBook : self.lastBoundary)
                        }
                        do { return .page(try self.page(target)) } catch { return .failed }
                    }
                    paged.onReadingStatus = { [weak self] status in self?.displayStatus(status) }
                }
            }
            if let current = reader.pagedReader?.readingStatus ?? reader.continuousReader?.readingStatus { displayStatus(current) }
        } catch { status.text = "未切换：\(error)" }
    }

    /// - Parameter reuseIdentifier: 内容类别。
    /// - Returns: 复用标签；生产宿主可返回文本选择视图或图片渲染视图。
    func makeContentView(reuseIdentifier: String) -> UIView {
        let label = InsetLabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 20)
        return label
    }

    /// - Parameters: view: 复用内容视图；item: 内容元数据；binding: 本次绑定。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        configure(view, index: Int(item.identity.unitID) ?? 0)
    }

    /// - Parameters: view: 离屏视图；binding: 已失效绑定；示例没有异步解码任务。
    func unbind(_ view: UIView, binding: PageViewBinding) {}

    /// - Parameters: view: 标签；index: 内容索引。
    private func configure(_ view: UIView, index: Int) {
        guard let label = view as? UILabel else { return }
        label.textAlignment = comic ? .center : .left
        label.text = comic ? "\(index + 1)\n\n漫画源页\n异高内容示例" : "第 \(index + 1) 段\n\n" + text
        label.backgroundColor = comic ? UIColor(hue: CGFloat(index % 8) / 8, saturation: 0.22, brightness: 0.95, alpha: 1) : .secondarySystemBackground
        label.textColor = comic ? .black : .label
    }

    /// - Parameter value: SDK 发布的已提交／当前视口状态。
    private func displayStatus(_ value: ReaderStatus) {
        let unit = comic ? "源页" : "段"
        var boundary = ""
        if value.hasReachedBookEnd { boundary = " · 已到全书末尾" }
        else if value.hasReachedLatestAvailable { boundary = " · 已到最新，等待更新" }
        else if value.isAtBookStart { boundary = " · 首页" }
        status.text = "全书 \(format(value.pagination.book)) \(unit)\n本章 \(format(value.pagination.section?.pages)) \(unit)\(boundary)"
    }

    /// - Parameter metrics: 宿主统计，nil 时不显示虚假的 0/0。
    /// - Returns: 当前号码与已知程度明确的总数。
    private func format(_ metrics: ReaderPageMetrics?) -> String {
        guard let metrics else { return "— / 未知" }
        let total: String
        switch metrics.total {
        case .unknown: total = "未知"
        case .estimated(let value): total = "约 \(value)"
        case .exact(let value): total = String(value)
        }
        return "\(metrics.current.map(String.init) ?? "—") / \(total)"
    }

    @objc private func goFirst() { install(index: 0) }
    @objc private func goLast() { install(index: count - 1, fraction: 0.99) }

    /// 模拟宿主发现四个新内容单元；连续模式通过加载票据等待真实安装后再更新目录状态。
    @objc private func appendContent() {
        guard isSerial else { return }
        let newCount = count + 4
        do {
            if let continuous = reader.continuousReader {
                let window = try ContinuousWindow(items: items(total: newCount), before: .startOfBook, after: .latestAvailable)
                updateButton.isEnabled = false
                let ticket = try continuous.beginLoading(.next, token: continuous.updateToken, cancel: {}) { [weak self, weak continuous] result in
                    guard let self else { return }
                    self.updateButton.isEnabled = self.isSerial
                    guard self.reader.continuousReader === continuous else { return }
                    if case .installed = result { self.count = newCount }
                }
                try continuous.submit(window, for: ticket)
            } else if let paged = reader.pagedReader {
                let info = try pageInfo(capturePosition().0, total: newCount)
                try paged.updateReadingInfo(info, expectedToken: paged.metadataToken)
                count = newCount
            }
        } catch {
            updateButton.isEnabled = isSerial
            status.text = "更新未安装：\(error)"
        }
    }

    @objc private func changeBook() { layoutVersion += 1; install(index: 0) }
    @objc private func changeMode() { let position = capturePosition(); install(index: position.0, fraction: position.1) }
    @objc private func goPrevious() { navigate(.previous) }
    @objc private func goNext() { navigate(.next) }

    /// - Parameter direction: 逻辑前后方向；连续模式定位到相邻源段落／页顶部。
    private func navigate(_ direction: PageTurnDirection) {
        do {
            if let paged = reader.pagedReader { try paged.turn(direction) }
            else if let continuous = reader.continuousReader {
                let target = capturePosition().0 + (direction == .next ? 1 : -1)
                guard (0..<count).contains(target) else { return }
                try continuous.restore(.init(identity: identity(target), offsetInItem: 0), expectedToken: continuous.updateToken)
            }
        } catch { status.text = "未导航：\(error)" }
    }
}

/// 仅示例使用的正文边距；不属于 SDK 排版能力。
private final class InsetLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 20, dy: 24)) }
}
