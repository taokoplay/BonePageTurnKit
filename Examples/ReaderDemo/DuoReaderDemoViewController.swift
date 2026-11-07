import UIKit
import BonePageTurnKit

/// 页面与所有外层共用动态背景；正文避让安全区，底色仍延伸到整个窗口。
@MainActor
private enum DuoReadingAppearance {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1)
    }
}

/// 状态栏可见性明确交由阅读页面控制，隐藏系统栏时由 UIKit 更新安全区。
@MainActor
final class DuoReaderNavigationController: UINavigationController {
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForStatusBarStyle: UIViewController? { topViewController }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DuoReadingAppearance.background
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationBar.standardAppearance = navigationAppearance
        navigationBar.compactAppearance = navigationAppearance
        navigationBar.scrollEdgeAppearance = navigationAppearance
        navigationBar.compactScrollEdgeAppearance = navigationAppearance
        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        toolbar.standardAppearance = toolbarAppearance
        toolbar.compactAppearance = toolbarAppearance
        toolbar.scrollEdgeAppearance = toolbarAppearance
        toolbar.compactScrollEdgeAppearance = toolbarAppearance
    }
}

/// 折叠屏接入示例：系统栏负责控制区，SDK 提供安全视口，宿主按源页锚点重建单双页。
@MainActor
final class DuoReaderDemoViewController: UIViewController {
    private let reader = PageTurnViewController()
    private let pageCount = 12
    private var anchorPage = 0
    private var layoutVersion: UInt64 = 0
    private var currentLayout: ReaderAdaptiveLayout?
    private var prefersSpread = true
    private var readingOrder = ReaderReadingOrder.leftToRight
    private var effect = PageTurnEffect.curl
    private var automaticIntent = false
    private var previousItem: UIBarButtonItem?
    private var nextItem: UIBarButtonItem?
    private var automaticItem: UIBarButtonItem?
    private var settingsItem: UIBarButtonItem?
    private var controlsHidden = false
    private var controlsChangeID = UUID()
    private let controlsSuspensionReason = "duo-controls-transition"
    private let showControlsButton = UIButton(type: .system)

    override var prefersStatusBarHidden: Bool { controlsHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .none }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DuoReadingAppearance.background
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        view.accessibilityIdentifier = "duo-reader"
        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--duo-source=") }),
           let number = Int(value.dropFirst("--duo-source=".count)) {
            anchorPage = min(pageCount - 1, max(0, number - 1))
        }
        reader.adaptiveLayoutPolicy = ReaderAdaptiveLayoutPolicy()
        reader.onAdaptiveLayoutChange = { [weak self] layout in self?.install(layout: layout) }
        reader.onAdaptiveLayoutError = { [weak self] _ in self?.navigationItem.prompt = "布局暂不可用" }
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        reader.view.backgroundColor = DuoReadingAppearance.background
        view.addSubview(reader.view)
        reader.didMove(toParent: self)
        // 背景全幅；reader 自己按四边安全区及实际保留区域给正文留空间。
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: view.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        previousItem = item("上一页", symbol: "chevron.backward", id: "duo-previous", action: #selector(previousPage))
        nextItem = item("下一页", symbol: "chevron.forward", id: "duo-next", action: #selector(nextPage))
        automaticItem = item("开始自动阅读", symbol: "play.fill", id: "duo-automatic", action: #selector(toggleAutomatic))
        let settings = UIBarButtonItem(title: "阅读设置", image: UIImage(systemName: "textformat.size"), primaryAction: nil, menu: makeMenu())
        settings.accessibilityIdentifier = "duo-settings"
        settingsItem = settings
        navigationItem.rightBarButtonItem = settings
        toolbarItems = [previousItem, nextItem, automaticItem].compactMap { $0 }
        navigationController?.setToolbarHidden(false, animated: false)
        var reveal = UIButton.Configuration.plain()
        reveal.image = UIImage(systemName: "sidebar.right")
        reveal.baseForegroundColor = .secondaryLabel
        reveal.background.backgroundColor = DuoReadingAppearance.background.withAlphaComponent(0.9)
        reveal.cornerStyle = .capsule
        showControlsButton.configuration = reveal
        showControlsButton.accessibilityIdentifier = "duo-show-controls"
        showControlsButton.accessibilityLabel = "显示控制栏"
        showControlsButton.addTarget(self, action: #selector(showControls), for: .touchUpInside)
        showControlsButton.isHidden = true
        view.addSubview(showControlsButton)
        updateStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutControlsButton()
    }

    /// 恢复按钮跟随 SDK 返回的可读区域，保持在摄像头与折痕之外，不使用固定侧栏宽度。
    private func layoutControlsButton() {
        guard let layout = reader.adaptiveLayout, layout.contentFrame.width >= 44,
              layout.contentFrame.height >= 44 else { return }
        let frame = reader.view.convert(layout.contentFrame, to: view)
        showControlsButton.frame = CGRect(x: max(frame.minX, frame.maxX - 56), y: min(frame.maxY - 44, frame.minY + 10),
                                         width: 44, height: 44)
    }

    /// - Parameter hidden: 隐藏全部阅读控制栏与状态栏，系统回报的新安全区决定正文可展开的范围。
    private func setControlsHidden(_ hidden: Bool) {
        guard hidden != controlsHidden else { return }
        reader.setSuspended(true, reason: controlsSuspensionReason)
        controlsHidden = hidden
        controlsChangeID = UUID()
        let changeID = controlsChangeID
        showControlsButton.isHidden = !hidden
        navigationController?.setNavigationBarHidden(hidden, animated: false)
        navigationController?.setToolbarHidden(hidden, animated: false)
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        reader.adaptiveLayoutPolicy = makeAdaptivePolicy()
        navigationController?.view.setNeedsLayout()
        view.setNeedsLayout()
        updateStatus()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controlsChangeID == changeID else { return }
            self.reader.setSuspended(false, reason: self.controlsSuspensionReason)
        }
    }

    @objc private func showControls() { setControlsHidden(false) }

    /// - Returns: 隐藏全部系统栏时，支持原生保留区域的系统用具体遮挡替代整列水平缩进。
    private func makeAdaptivePolicy() -> ReaderAdaptiveLayoutPolicy {
        var horizontal: ReaderHorizontalSafeAreaPolicy = .system
        #if compiler(>=6.4)
        if #available(iOS 27.1, *), controlsHidden { horizontal = .reservedRegions }
        #endif
        return .init(prefersSpread: prefersSpread, horizontalSafeArea: horizontal)
    }

    /// - Parameters: title: 语义标题；symbol: 可在侧栏呈现的符号；id: 测试标识；action: 操作方法。
    /// - Returns: 同时具有标题和图片的系统栏按钮。
    private func item(_ title: String, symbol: String, id: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.title = title
        item.accessibilityLabel = title
        item.accessibilityIdentifier = id
        return item
    }

    /// - Parameter layout: SDK 根据当前窗口而非设备型号计算的可读区域。
    private func install(layout: ReaderAdaptiveLayout) {
        guard layout.contentFrame.width > 1, layout.contentFrame.height > 1 else { return }
        let previousLayout = currentLayout
        currentLayout = layout
        layoutVersion += 1
        do {
            let group = try groupIndex(containing: anchorPage)
            let content = try presentation(group: group, preferredSource: anchorPage)
            let configuration = PageTurnConfiguration(presentation: .paged(effect: effect, axis: layout.axis),
                layout: layout.pageLayout, readingOrder: readingOrder)
            let paged = try reader.showPaged(page: content, configuration: configuration) { [weak self] paged in
                self?.prepare(paged)
            }
            if automaticIntent { try paged.startAutomaticReading(interval: 3) }
            navigationItem.prompt = nil
            updateStatus()
            layoutControlsButton()
        } catch {
            currentLayout = previousLayout
            navigationItem.prompt = "页面准备失败，原位置已保留"
        }
    }

    /// - Parameter source: 零基源页位置。
    /// - Returns: 当前编排中的展示组索引；只在源索引上转换，避免开合时丢失第二侧页的位置。
    private func groupIndex(containing source: Int) throws -> Int {
        guard currentLayout?.pageLayout == .spread else { return source }
        return try ReaderSpreadLayout(pageCount: pageCount).spreadIndex(containingPage: source)
    }

    private var groupCount: Int {
        if currentLayout?.pageLayout == .spread { return 1 + (pageCount - 1) / 2 + (pageCount - 1) % 2 }
        return pageCount
    }

    /// - Parameters: group: 展示组索引；preferredSource: 开合前的源页锚点，可位于一组的第二侧。
    /// - Returns: 当前源位置的单页或真实双页内容。
    private func presentation(group: Int, preferredSource: Int? = nil) throws -> PageContent {
        guard let layout = currentLayout else { throw PageTurnError.invalidPageLayout }
        let controller: UIViewController
        let focused: Int
        if layout.pageLayout == .spread {
            let indices = try ReaderSpreadLayout(pageCount: pageCount).spread(at: group)
            let candidates = [indices.first, indices.second].compactMap { $0 }
            focused = preferredSource.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first ?? 0
            let spread = try PageSpreadViewController(first: indices.first.map(sourcePage), second: indices.second.map(sourcePage),
                axis: layout.axis, readingOrder: readingOrder, gutter: layout.spreadGap)
            spread.loadViewIfNeeded()
            spread.view.accessibilityIdentifier = "duo-spread"
            spread.view.backgroundColor = DuoReadingAppearance.background
            controller = spread
        } else {
            focused = group
            controller = sourcePage(group).controller
        }
        let metrics = try ReaderPageMetrics(current: focused + 1, total: .exact(pageCount), unit: .sourcePage)
        return .init(identity: .init(sourceID: "duo-demo-book", unitID: String(group), layoutVersion: layoutVersion), controller: controller,
                     readingInfo: .init(pagination: .init(book: metrics), before: group == 0 ? .startOfBook : .available,
                                        after: group == groupCount - 1 ? .endOfBook : .available))
    }

    /// - Parameter index: 源页索引；返回普通真实正文控制器，解析／分页仍由宿主负责。
    private func sourcePage(_ index: Int) -> PageContent {
        let content = DuoDemoPageController(index: index)
        content.loadViewIfNeeded()
        return .init(identity: .init(sourceID: "duo-demo-book", unitID: "source-\(index)", layoutVersion: layoutVersion), controller: content)
    }

    /// - Parameter paged: 已准备的分页容器；只在真正翻页成功后推进源锚点。
    private func prepare(_ paged: PagedReaderViewController) {
        paged.loadViewIfNeeded()
        paged.view.backgroundColor = DuoReadingAppearance.background
        paged.view.accessibilityIdentifier = "duo-reading-viewport"
        registerText(in: paged.currentPage.controller, reader: paged)
        paged.pageProvider = { [weak self, weak paged] identity, direction in
            guard let self, let paged, let group = Int(identity.unitID) else { return .failed }
            let next = group + (direction == .next ? 1 : -1)
            guard next >= 0, next < self.groupCount else { return .boundary(next < 0 ? .startOfBook : .endOfBook) }
            do {
                let content = try self.presentation(group: next)
                self.registerText(in: content.controller, reader: paged)
                return .page(content)
            } catch { return .failed }
        }
        paged.onTransition = { [weak self, weak paged] event in
            guard let self, let paged else { return }
            if case .didCommit = event {
                self.anchorPage = (paged.currentPage.readingInfo.pagination.book?.current ?? 1) - 1
                self.updateStatus()
            }
        }
        paged.onAutomaticReadingStateChange = { [weak self] state in
            if case .finished = state { self?.automaticIntent = false }
            self?.updateStatus()
        }
    }

    /// - Parameters: controller: 当前或待显示内容树；reader: 登记内层滚动的分页容器。
    private func registerText(in controller: UIViewController, reader: PagedReaderViewController) {
        if let content = controller as? DuoDemoPageController { _ = try? reader.registerScrollableContent(content.textView) }
        if let spread = controller as? PageSpreadViewController {
            for page in spread.pages { registerText(in: page.controller, reader: reader) }
        }
    }

    /// 状态属于源页锚点而非双页组；系统栏会选择适合当前轴的标题或符号。
    private func updateStatus() {
        let mode = currentLayout?.pageLayout == .spread ? "双页" : "单页"
        navigationItem.title = "第 \(anchorPage + 1) / \(pageCount) 页"
        viewIfLoaded?.accessibilityValue = "第 \(anchorPage + 1) 页，\(mode)，\(controlsHidden ? "控制栏隐藏" : "控制栏显示")"
        previousItem?.isEnabled = anchorPage > 0
        nextItem?.isEnabled = anchorPage < pageCount - 1
        automaticItem?.image = UIImage(systemName: automaticIntent ? "pause.fill" : "play.fill")
        automaticItem?.title = automaticIntent ? "暂停自动阅读" : "开始自动阅读"
        automaticItem?.accessibilityLabel = automaticItem?.title
    }

    /// - Returns: 所有设置通过系统菜单呈现，在展开、合拢及折痕两侧均保持可达。
    private func makeMenu() -> UIMenu {
        let immersive = UIAction(title: "隐藏控制栏", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
            self?.setControlsHidden(true)
        }
        let automatic = UIAction(title: "自动单双页", image: UIImage(systemName: "book"), state: prefersSpread ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.prefersSpread = true
            self.reader.adaptiveLayoutPolicy = self.makeAdaptivePolicy()
            self.settingsItem?.menu = self.makeMenu()
        }
        let single = UIAction(title: "始终单页", image: UIImage(systemName: "doc"), state: prefersSpread ? .off : .on) { [weak self] _ in
            guard let self else { return }
            self.prefersSpread = false
            self.reader.adaptiveLayoutPolicy = self.makeAdaptivePolicy()
            self.settingsItem?.menu = self.makeMenu()
        }
        let reverse = UIAction(title: "从右向左阅读", image: UIImage(systemName: "text.alignright"), state: readingOrder == .rightToLeft ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.readingOrder = self.readingOrder == .leftToRight ? .rightToLeft : .leftToRight
            if let layout = self.currentLayout { self.install(layout: layout) }
            self.settingsItem?.menu = self.makeMenu()
        }
        let preview = UIAction(title: "半翻预览", image: UIImage(systemName: "book.pages")) { [weak self] _ in
            guard let paged = self?.reader.pagedReader else { return }
            do {
                if try paged.beginInteractiveTurn(.next) { paged.updateInteractiveTurn(displacement: paged.view.bounds.width * 0.45) }
            } catch { return }
        }
        let cancel = UIAction(title: "取消翻页", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.reader.pagedReader?.cancelTransition() }
        return UIMenu(children: [immersive, automatic, single, reverse, preview, cancel])
    }

    @objc private func previousPage() { _ = try? reader.pagedReader?.turn(.previous) }
    @objc private func nextPage() { _ = try? reader.pagedReader?.turn(.next) }
    @objc private func toggleAutomatic() {
        automaticIntent.toggle()
        if automaticIntent { try? reader.pagedReader?.startAutomaticReading(interval: 3) }
        else { reader.pagedReader?.pauseAutomaticReading() }
        updateStatus()
    }
}

/// 用短正文演示可交互页面；小窗口仍可内部滚动，不把正文永久截图化。
@MainActor
private final class DuoDemoPageController: UIViewController {
    let index: Int
    let textView = UITextView()
    init(index: Int) { self.index = index; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用源页索引初始化") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DuoReadingAppearance.background
        let heading = UILabel()
        heading.text = "第 \(index + 1) 页"
        heading.accessibilityIdentifier = "duo-source-\(index + 1)"
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.text = "窗外的光落在书页上。阅读器随着手里的空间展开，文字仍停在刚才读到的位置。\n\n打开时，两页各有自己的位置；合拢后，当前这一页继续陪着你。折痕留给书脊，正文和按钮留在清晰可见的区域。\n\n第 \(index + 1) 页的故事仍在继续。你可以拖动翻页、选择文字，或开始自动阅读。"
        textView.accessibilityIdentifier = "duo-text-\(index + 1)"
        for child in [heading, textView] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            textView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
    }
}
