import UIKit
import BonePageTurnKit

/// 扩展展示示例：真实双页、显式阅读顺序、切片与原生缩放共用 SDK。
@MainActor
final class AdvancedReaderDemoViewController: UIViewController {
    private let container = PageTurnViewController()
    private let layouts = UISegmentedControl(items: ["单页", "双页"])
    private let axes = UISegmentedControl(items: ["横向", "纵向"])
    private let orders = UISegmentedControl(items: ["LTR", "RTL"])
    private let effects = UISegmentedControl(items: ["仿真", "拱页", "平移"])
    private let modes = UISegmentedControl(items: ["整图", "宽图切半", "长图分段", "长图滚动"])
    private let status = UILabel()
    private let notice = UILabel()
    private var installed = false
    private var changing = false
    private var sources: [UIImage] = []
    private var slices: [ComicPageSlice] = []
    private var selectedSource = 0
    private var installedSelections = [0, 0, 0, 0, 0]
    private var activeConfiguration = PageTurnConfiguration(presentation: .paged(effect: .curl, axis: .horizontal))
    private var count = 0
    private var launchActionsDone = false
    private var spreadLayout: ReaderSpreadLayout?
    private var isLongScroll = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let arguments = ProcessInfo.processInfo.arguments
        layouts.selectedSegmentIndex = arguments.contains("--spread") ? 1 : 0
        axes.selectedSegmentIndex = arguments.contains("--vertical") ? 1 : 0
        orders.selectedSegmentIndex = arguments.contains("--rtl") ? 1 : 0
        effects.selectedSegmentIndex = arguments.contains("--arch") ? 1 : (arguments.contains("--slide") ? 2 : 0)
        modes.selectedSegmentIndex = arguments.contains("--slice-wide") ? 1 : (arguments.contains("--slice-long") ? 2 : (arguments.contains("--long-scroll") ? 3 : 0))
        let heading = UILabel()
        heading.text = "双页 · 漫画 · 缩放"
        heading.font = .boldSystemFont(ofSize: 20)
        let controls = [layouts, axes, orders, effects, modes]
        for (index, control) in controls.enumerated() {
            control.accessibilityIdentifier = "advanced-option-\(index)"
            control.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        }
        let header = UIStackView(arrangedSubviews: [heading, row([layouts, axes, orders]), effects, modes])
        header.axis = .vertical; header.spacing = 6
        let navigation = row([
            button("上一页", "advanced-previous", #selector(previous)),
            button("下一页", "advanced-next", #selector(nextPage)),
            button("半翻", "advanced-preview", #selector(preview)),
            button("取消", "advanced-cancel", #selector(cancel))
        ])
        let zoomActions = row([
            button("放大/复位", "advanced-zoom", #selector(toggleZoom)),
            button("自动阅读", "advanced-auto", #selector(automatic)),
            button("暂停/继续", "advanced-pause", #selector(pauseOrResume))
        ])
        status.numberOfLines = 2
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textAlignment = .center
        status.accessibilityIdentifier = "advanced-status"
        notice.numberOfLines = 2; notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabel
        notice.textAlignment = .center
        notice.text = "双击或捏合缩放；滚到边缘后继续拖动可翻页。"
        let footer = UIStackView(arrangedSubviews: [navigation, zoomActions, status, notice])
        footer.axis = .vertical; footer.spacing = 6
        addChild(container)
        container.loadViewIfNeeded()
        container.view.accessibilityIdentifier = "advanced-viewport"
        for element in [header, container.view, footer].compactMap({ $0 }) {
            element.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(element)
        }
        container.didMove(toParent: self)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heading.heightAnchor.constraint(equalToConstant: 25),
            effects.heightAnchor.constraint(equalToConstant: 30),
            modes.heightAnchor.constraint(equalToConstant: 30),
            container.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -5),
            navigation.heightAnchor.constraint(equalToConstant: 34),
            zoomActions.heightAnchor.constraint(equalToConstant: 34),
            status.heightAnchor.constraint(equalToConstant: 36),
            notice.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !installed, container.view.bounds.width > 0, container.view.bounds.height > 0 else { return }
        installed = true
        install()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !launchActionsDone else { return }
        launchActionsDone = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.preview() }
        } else if arguments.contains("--auto-start") { automatic() }
    }

    /// - Parameter views: 控件列表；返回等宽水平栈。
    private func row(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.distribution = .fillEqually; row.spacing = 6
        return row
    }

    /// - Parameters: title: 文案；id: UI 测试标识；action: 点击方法。
    /// - Returns: 原生按钮。
    private func button(_ title: String, _ id: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 14)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// 重新按源页定位，不把旧双页组索引作为新布局位置。
    private func install() {
        guard !changing else { return }
        changing = true
        defer { changing = false }
        let selections = [layouts, axes, orders, effects, modes].map(\.selectedSegmentIndex)
        let oldSources = sources
        let oldSlices = slices
        let oldConfiguration = activeConfiguration
        let oldSpread = spreadLayout
        let oldCount = count
        let oldLongScroll = isLongScroll
        let axis: PageTurnAxis = selections[1] == 0 ? .horizontal : .vertical
        let order: ReaderReadingOrder = selections[2] == 0 ? .leftToRight : .rightToLeft
        let effect: PageTurnEffect = [.curl, .arch, .slide][selections[3]]
        let config = PageTurnConfiguration(presentation: .paged(effect: effect, axis: axis),
            layout: selections[0] == 0 ? .single : .spread, readingOrder: order)
        do {
            try config.validate()
            sources = (0..<6).map { makeImage($0, kind: selections[4]) }
            slices = try sources.enumerated().flatMap { index, image in
                try ComicPageSlicing.slices(for: .init(sourceID: "advanced-book", unitID: String(index)),
                    pixelSize: image.size, mode: selections[4] == 1 ? .splitWide : (selections[4] == 2 ? .vertical : .whole),
                    readingOrder: order, maximumHeightToWidth: 1.5)
            }
            activeConfiguration = config
            isLongScroll = selections[4] == 3
            spreadLayout = selections[0] == 1 ? try ReaderSpreadLayout(pageCount: slices.count) : nil
            count = spreadLayout?.spreadCount ?? slices.count
            let sliceIndex = slices.firstIndex { $0.sourceIdentity.unitID == String(selectedSource) } ?? 0
            let initialIndex = try spreadLayout?.spreadIndex(containingPage: sliceIndex) ?? sliceIndex
            let initial = try page(initialIndex)
            let reader = try container.showPaged(page: initial, configuration: config) { [weak self] reader in
                self?.prepare(reader)
            }
            reader.view.layoutIfNeeded()
            installedSelections = selections
            updateStatus(reader)
        } catch {
            sources = oldSources; slices = oldSlices; activeConfiguration = oldConfiguration
            spreadLayout = oldSpread; count = oldCount; isLongScroll = oldLongScroll
            for (control, selection) in zip([layouts, axes, orders, effects, modes], installedSelections) { control.selectedSegmentIndex = selection }
            notice.text = "配置失败：\(error)"
        }
    }

    /// - Parameter index: 展示组索引；返回真实单页或双页，页码以源页计数。
    private func page(_ index: Int) throws -> PageContent {
        let indices = try spreadLayout?.spread(at: index)
        let sliceIndices = indices.map { [$0.first, $0.second].compactMap { $0 } } ?? [index]
        guard let firstIndex = sliceIndices.first, slices.indices.contains(firstIndex) else { throw PageTurnError.invalidPageLayout }
        let controller: UIViewController
        if let indices {
            controller = try PageSpreadViewController(first: try indices.first.map(makeSlice), second: try indices.second.map(makeSlice),
                axis: installedAxis, readingOrder: activeConfiguration.readingOrder)
        } else { controller = try makeSlice(index).controller }
        let sourceNumber = (Int(slices[firstIndex].sourceIdentity.unitID) ?? 0) + 1
        let metrics = try ReaderPageMetrics(current: sourceNumber, total: .exact(sources.count), unit: .sourcePage)
        return .init(identity: .init(sourceID: "advanced-display", unitID: String(index)), controller: controller,
            readingInfo: .init(pagination: .init(book: metrics), before: index == 0 ? .startOfBook : .available,
                               after: index == count - 1 ? .endOfBook : .available))
    }

    private var installedAxis: PageTurnAxis {
        if case .paged(_, let axis) = activeConfiguration.presentation { return axis }
        return .horizontal
    }

    /// - Parameter index: 切片逻辑索引；返回正式 SDK 的裁图与缩放容器。
    private func makeSlice(_ index: Int) throws -> PageContent {
        let slice = slices[index]
        let source = Int(slice.sourceIdentity.unitID) ?? 0
        let imageView = try ComicSliceView(image: sources[source], slice: slice)
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "漫画源页 \(source + 1)，切片 \(slice.index + 1)/\(slice.count)"
        let content = UIViewController()
        content.view = imageView
        let zoom = try ReaderZoomViewController(content: content, contentSize: imageView.preferredContentSize,
                                                fit: isLongScroll ? .width : .aspectFit)
        zoom.loadViewIfNeeded()
        zoom.scrollView.accessibilityIdentifier = "comic-scroll-\(index)"
        return .init(identity: slice.identity, controller: zoom)
    }

    /// - Parameter reader: 新容器；provider 返回相邻展示组，SDK 保留逻辑顺序。
    private func prepare(_ reader: PagedReaderViewController) {
        reader.pageProvider = { [weak self] identity, direction in
            guard let self, let index = Int(identity.unitID) else { return .failed }
            let next = index + (direction == .next ? 1 : -1)
            guard next >= 0, next < self.count else { return .boundary(next < 0 ? .startOfBook : .endOfBook) }
            do { return .page(try self.page(next)) } catch { return .failed }
        }
        reader.onTransition = { [weak self, weak reader] event in
            guard let self, let reader else { return }
            if case .didCommit = event { self.updateStatus(reader) }
        }
        reader.onAutomaticReadingStateChange = { [weak self, weak reader] _ in
            if let reader { self?.updateStatus(reader) }
        }
        reader.onViewportSizeChange = { [weak reader] _ in
            guard let reader else { return }
            let token = reader.contentRequestToken
            DispatchQueue.main.async { [weak reader] in try? reader?.notifyContentAvailable(expectedToken: token) }
        }
        reader.onUnavailable = { [weak self] _, _ in self?.notice.text = "已到内容边界。" }
    }

    /// - Parameter reader: 当前阅读器；源页号码与展示组数分开显示。
    private func updateStatus(_ reader: PagedReaderViewController) {
        let index = Int(reader.currentPage.identity.unitID) ?? 0
        let source = reader.currentPage.readingInfo.pagination.book?.current ?? 1
        selectedSource = source - 1
        let mode = activeConfiguration.layout == .spread ? "双页" : "单页"
        status.text = "组 \(index + 1)/\(count) · 源页 \(source)/\(sources.count) · \(mode)\n\(reader.automaticReadingState)"
    }

    /// - Parameters: index: 源页号；kind: 宽图、长图或普通图；返回自行绘制的无外部版权素材。
    private func makeImage(_ index: Int, kind: Int) -> UIImage {
        let size = kind == 1 ? CGSize(width: 900, height: 600) : (kind >= 2 ? CGSize(width: 450, height: 1800) : CGSize(width: 450, height: 650))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.96, green: 0.94, blue: 0.86, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            let columns = kind == 1 ? 2 : 1
            let rows = kind >= 2 ? 4 : 1
            for row in 0..<rows {
                for column in 0..<columns {
                    let panel = CGRect(x: CGFloat(column) * size.width / CGFloat(columns) + 12,
                                       y: CGFloat(row) * size.height / CGFloat(rows) + 12,
                                       width: size.width / CGFloat(columns) - 24, height: size.height / CGFloat(rows) - 24)
                    UIColor(hue: CGFloat((index * 3 + row + column) % 12) / 12, saturation: 0.32, brightness: 0.9, alpha: 1).setFill()
                    context.fill(panel)
                    let text = "\(index + 1)\n\(column == 0 ? "L →" : "R →")\n片段 \(row + 1)"
                    (text as NSString).draw(in: panel.insetBy(dx: 24, dy: 24), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.black])
                    UIColor.white.withAlphaComponent(0.7).setFill()
                    UIBezierPath(ovalIn: CGRect(x: panel.midX - 55, y: panel.midY + 40, width: 110, height: 110)).fill()
                }
            }
        }
    }

    @objc private func changeMode() { install() }
    @objc private func previous() { turn(.previous) }
    @objc private func nextPage() { turn(.next) }
    private func turn(_ direction: PageTurnDirection) {
        do { _ = try container.pagedReader?.turn(direction) } catch { notice.text = "当前交互尚未结束。" }
    }
    @objc private func preview() {
        guard let reader = container.pagedReader else { return }
        do {
            if try reader.beginInteractiveTurn(.next) {
                reader.updateInteractiveTurn(displacement: (installedAxis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height) * 0.65)
                notice.text = "翻页停在 65%，点击取消恢复。"
            }
        } catch { notice.text = "当前交互尚未结束。" }
    }
    @objc private func cancel() { container.pagedReader?.cancelTransition() }
    @objc private func automatic() { try? container.pagedReader?.startAutomaticReading(interval: 1) }
    @objc private func pauseOrResume() {
        guard let reader = container.pagedReader else { return }
        if reader.automaticReadingState == .paused { try? reader.resumeAutomaticReading() } else { reader.pauseAutomaticReading() }
    }
    @objc private func toggleZoom() {
        guard let current = container.pagedReader?.currentPage.controller else { return }
        let candidates = ([current] + current.children).compactMap { $0 as? ReaderZoomViewController }
        for zoom in candidates { try? zoom.setZoomFactor(zoom.zoomFactor > 1.01 ? 1 : 2, animated: false) }
    }
}
