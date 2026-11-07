import UIKit
import BonePageTurnKit

/// 阅读装饰组合示例：正文、页眉页脚和带纹理背景通过正式外壳分层，界面显示布局输出。
@MainActor
final class ReaderSurfaceDemoViewController: UIViewController {
    private let modes = UISegmentedControl(items: ["正文动", "正文+页眉页脚", "整页动", "连续"])
    private let axes = UISegmentedControl(items: ["横向", "纵向"])
    private let geometryLabel = UILabel()
    private let mount = UIView()
    private var surface: ReaderSurfaceViewController?
    private var provider: SurfaceDemoProvider?
    private var started = false
    private var chromeVisible = true
    private var version: UInt64 = 0
    private var currentIndex = 0
    private let pageCount = 12

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let arguments = ProcessInfo.processInfo.arguments
        modes.selectedSegmentIndex = arguments.contains("--surface-whole") ? 2 : (arguments.contains("--surface-chrome") ? 1 : (arguments.contains("--continuous") ? 3 : 0))
        axes.selectedSegmentIndex = arguments.contains("--vertical") ? 1 : 0
        modes.accessibilityIdentifier = "surface-mode"
        axes.accessibilityIdentifier = "surface-axis"
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        axes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        let heading = UILabel()
        heading.text = "正文 · 页眉页脚 · 背景"
        heading.font = .boldSystemFont(ofSize: 18)
        let actions = UIStackView(arrangedSubviews: [
            button("下一页", "surface-next", #selector(nextPage)),
            button("半翻预览", "surface-preview", #selector(preview)),
            button("取消", "surface-cancel", #selector(cancel)),
            button("装饰显隐", "surface-chrome", #selector(toggleChrome))
        ])
        actions.distribution = .fillEqually; actions.spacing = 4
        let header = UIStackView(arrangedSubviews: [heading, modes, axes, actions])
        header.axis = .vertical; header.spacing = 7
        geometryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        geometryLabel.numberOfLines = 4
        geometryLabel.accessibilityIdentifier = "surface-geometry"
        for child in [header, mount, geometryLabel] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            actions.heightAnchor.constraint(equalToConstant: 32),
            mount.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            mount.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            mount.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            mount.bottomAnchor.constraint(equalTo: geometryLabel.topAnchor, constant: -8),
            geometryLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            geometryLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            geometryLabel.heightAnchor.constraint(equalToConstant: 62),
            geometryLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -5)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface?.view.frame = mount.bounds
        guard !started, mount.bounds.width > 0, mount.bounds.height > 0 else { return }
        started = true
        install()
    }

    private var metrics: ReaderSurfaceMetrics {
        .init(headerHeight: chromeVisible ? 38 : 0, footerHeight: chromeVisible ? 30 : 0,
              headerGap: 8, footerGap: 8, bodyInsets: .init(top: 6, left: 20, bottom: 6, right: 20))
    }

    /// - Parameters: title: 文字；identifier: 原生测试标识；action: 方法。返回原生按钮。
    private func button(_ title: String, _ identifier: String, _ action: Selector) -> UIButton {
        let item = UIButton(type: .system)
        item.setTitle(title, for: .normal); item.titleLabel?.font = .systemFont(ofSize: 13)
        item.accessibilityIdentifier = identifier
        item.addTarget(self, action: action, for: .touchUpInside)
        return item
    }

    /// 配置改变后创建新的外壳，源页位置由宿主保留，不复用旧布局组索引。
    private func install() {
        let motion: ReaderSurfaceMotion = modes.selectedSegmentIndex == 2 ? .wholePage : (modes.selectedSegmentIndex == 1 ? .contentAndChrome : .contentOnly)
        do {
            let decorations = ReaderSurfaceDecorations(makeHeader: { context in
                let label = UILabel(); label.font = .systemFont(ofSize: 14, weight: .medium)
                label.textAlignment = .center
                label.text = "页眉 · 第 \((Int(context.identity?.unitID ?? "0") ?? 0) + 1) 页"
                label.accessibilityIdentifier = "surface-header-\(context.identity?.unitID ?? "fixed")"
                return label
            }, makeFooter: { context in
                let label = UILabel(); label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textAlignment = .center
                label.text = "页脚 · \((Int(context.identity?.unitID ?? "0") ?? 0) + 1) / 12"
                label.accessibilityIdentifier = "surface-footer-\(context.identity?.unitID ?? "fixed")"
                return label
            }, makeBackground: { _ in SurfaceDemoBackground() }, update: { views, context in
                let page = (Int(context.identity?.unitID ?? "0") ?? 0) + 1
                (views.header as? UILabel)?.text = "页眉 · 第 \(page) 页"
                (views.footer as? UILabel)?.text = "页脚 · \(page) / 12"
            })
            let next = try ReaderSurfaceViewController(metrics: metrics, motion: motion, decorations: decorations,
                                                       viewportPolicy: nil, backgroundColor: UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1))
            next.loadViewIfNeeded(); next.view.frame = mount.bounds
            next.view.setNeedsLayout(); next.view.layoutIfNeeded()
            next.onLayoutChange = { [weak self, weak next] layout in
                self?.showGeometry(layout)
                guard let next, let paged = next.pagedReader else { return }
                // 示例内容可自行适应新 bounds；真实分页器应按 layout.bodyFrame.size 重新排版后回填。
                try? paged.notifyContentAvailable(expectedToken: paged.contentRequestToken)
            }
            next.onReadingStatus = { [weak self] status in
                self?.currentIndex = Int(status.identity.unitID) ?? 0
            }
            next.pageProvider = { [weak self] identity, direction, _ in
                guard let self, let index = Int(identity.unitID) else { return .failed }
                let target = index + (direction == .next ? 1 : -1)
                guard target >= 0, target < self.pageCount else { return .boundary(target < 0 ? .startOfBook : .endOfBook) }
                return .page(self.page(target))
            }
            let nextProvider: SurfaceDemoProvider?
            if modes.selectedSegmentIndex == 3 {
                let content = SurfaceDemoProvider()
                nextProvider = content
                let window = try ContinuousWindow(items: (0..<pageCount).map { index in
                    .init(identity: .init(sourceID: "surface-demo", unitID: String(index), layoutVersion: version),
                          sectionID: "chapter", extent: 240, state: .ready)
                }, before: .startOfBook, after: .endOfBook)
                _ = try next.showContinuous(window: window, provider: content)
            } else {
                nextProvider = nil
                _ = try next.showPaged(page: page(currentIndex), configuration: .init(presentation: .paged(effect: .slide, axis: axes.selectedSegmentIndex == 0 ? .horizontal : .vertical)))
            }
            surface?.invalidate()
            surface?.willMove(toParent: nil); surface?.view.removeFromSuperview(); surface?.removeFromParent()
            provider = nextProvider
            surface = next
            addChild(next); mount.addSubview(next.view); next.didMove(toParent: self)
            if let layout = next.layout { showGeometry(layout) }
        } catch { geometryLabel.text = "无法安装：\(error)" }
    }

    /// - Parameter index: 零基源页索引；返回透明正文，局部底色仍由正文拥有并随正文移动。
    private func page(_ index: Int) -> PageContent {
        let content = UIViewController()
        content.view.backgroundColor = .clear
        content.view.accessibilityIdentifier = "surface-body-\(index)"
        let text = UILabel()
        text.numberOfLines = 0; text.font = .systemFont(ofSize: 20)
        text.text = "正文第 \(index + 1) 页\n\n拖动观察页眉、页脚和背景。\n\n只有正文模式中，固定装饰保持原位。背景上的蓝色竖线用于辨认它是否移动。\n\n正文局部底色属于内容。"
        text.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.10)
        text.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: content.view.topAnchor),
            text.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: content.view.bottomAnchor)
        ])
        return .init(identity: .init(sourceID: "surface-demo", unitID: String(index), layoutVersion: version), controller: content)
    }

    /// - Parameter layout: surface.view 坐标的稳定矩形；位置变化时无需宿主猜测页眉页脚占用。
    private func showGeometry(_ layout: ReaderSurfaceLayout) {
        func text(_ frame: CGRect?) -> String {
            guard let frame else { return "关闭" }
            return String(format: "(%.1f, %.1f)  %.1f × %.1f", frame.minX, frame.minY, frame.width, frame.height)
        }
        geometryLabel.text = "正文  \(text(layout.bodyFrame))\n页眉  \(text(layout.headerFrame))\n页脚  \(text(layout.footerFrame))\n背景  \(text(layout.backgroundFrame))"
    }

    @objc private func changeMode() { version += 1; install() }
    @objc private func nextPage() { _ = try? surface?.pagedReader?.turn(.next) }
    @objc private func cancel() { surface?.pagedReader?.cancelTransition() }
    @objc private func preview() {
        guard let paged = surface?.pagedReader else { return }
        do {
            if try paged.beginInteractiveTurn(.next) {
                paged.updateInteractiveTurn(displacement: (axes.selectedSegmentIndex == 0 ? paged.view.bounds.width : paged.view.bounds.height) * 0.4)
            }
        } catch { return }
    }
    @objc private func toggleChrome() {
        chromeVisible.toggle()
        do { try surface?.updateMetrics(metrics) } catch { geometryLabel.text = "布局错误：\(error)" }
    }
}

@MainActor
private final class SurfaceDemoProvider: ContinuousContentProvider {
    func makeContentView(reuseIdentifier: String) -> UIView { UILabel() }
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let label = view as? UILabel else { return }
        label.font = .systemFont(ofSize: 21); label.numberOfLines = 0
        label.text = "正文块 \((Int(item.identity.unitID) ?? 0) + 1)\n\n上下滚动只移动正文，页眉页脚和全屏背景保持固定。"
        label.backgroundColor = .clear
    }
    func unbind(_ view: UIView, binding: PageViewBinding) { (view as? UILabel)?.text = nil }
}

@MainActor
private final class SurfaceDemoBackground: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isUserInteractionEnabled = false; contentMode = .redraw }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用无参初始化") }
    override func draw(_ rect: CGRect) {
        UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1).setFill()
        UIBezierPath(rect: bounds).fill()
        UIColor.systemBlue.withAlphaComponent(0.18).setFill()
        for x in stride(from: CGFloat(10), to: bounds.width, by: 60) {
            UIBezierPath(rect: CGRect(x: x, y: 0, width: 5, height: bounds.height)).fill()
        }
    }
}
