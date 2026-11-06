import UIKit
import BonePageTurnKit

/// 与 XCTest 共用实际渲染组件，便于观察正文与插图的独立异步完成。
@MainActor
final class AsyncRenderingDemoViewController: UIViewController {
    private let reader = PageTurnViewController()
    private let modes = UISegmentedControl(items: ["覆盖分页", "连续滚动"])
    private let message = UILabel()
    private var provider: AsyncStyledContentProvider?
    private var version: UInt64 = 0
    private var largeText = false
    private var dark = false
    private var imageFails = false
    private var currentIndex = 0
    private let count = 6

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "当前页 · 异步渲染验收"
        title.font = .boldSystemFont(ofSize: 19)
        let subtitle = UILabel()
        subtitle.text = "正文和图片独立返回，可在加载中翻页或重排。"
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabel
        modes.selectedSegmentIndex = ProcessInfo.processInfo.arguments.contains("--continuous") ? 1 : 0
        modes.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        let reflow = button("字号／主题", action: #selector(changeStyle))
        let retry = button("图片失败／重试", action: #selector(toggleImageFailure))
        let next = button("下一页", action: #selector(nextPage))
        let actions = UIStackView(arrangedSubviews: [reflow, retry, next])
        actions.distribution = .fillEqually
        let top = UIStackView(arrangedSubviews: [title, subtitle, modes, actions])
        top.axis = .vertical
        top.spacing = 8
        message.numberOfLines = 2
        message.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.text = "准备当前页面"
        addChild(reader)
        for child in [top, reader.view, message].compactMap({ $0 }) {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        reader.didMove(toParent: self)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            reader.view.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -6),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            message.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if reader.configuration == nil, reader.view.bounds.height > 0 { presentCurrent() }
    }

    /// - Parameters: title: 操作标题；action: 目标方法。
    /// - Returns: 系统样式按钮。
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// - Parameter index: 从零开始的测试内容编号。
    /// - Returns: 当前内容／排版版本的身份。
    private func identity(_ index: Int) -> PageItemIdentity {
        .init(sourceID: "styled-chapter", unitID: String(index), contentVersion: version, layoutVersion: version)
    }

    /// - Parameter index: 当前内容编号；偶数正文先到，奇数图片先到。
    /// - Returns: 有明确延迟且故意不合作取消的模拟计划。
    private func plan(_ index: Int) -> AsyncStyledRenderPlan {
        var plan = AsyncStyledRenderPlan()
        plan.title = "雨后的书店"
        plan.fontSize = largeText ? 20 : 16
        plan.theme = dark ? .dark : .light
        plan.imageFails = imageFails
        plan.ignoresCancellation = true
        plan.textDelay = index.isMultiple(of: 2) ? 350_000_000 : 1_000_000_000
        plan.imageDelay = index.isMultiple(of: 2) ? 1_000_000_000 : 350_000_000
        return plan
    }

    /// - Parameter index: 当前页面编号。
    /// - Returns: 可交互的真实异步渲染页面。
    private func page(_ index: Int) -> PageContent {
        let controller = AsyncStyledPageController(identity: identity(index), plan: plan(index))
        controller.onEvent = { [weak self] event in self?.display(event) }
        return .init(identity: controller.identity, controller: controller)
    }

    /// 显式重排／切换产生新 renderer，旧渲染结果仅记录为 discarded。
    private func presentCurrent() {
        do {
            if modes.selectedSegmentIndex == 0 {
                try reader.showPaged(page: page(currentIndex), configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal))) { [weak self] paged in
                    paged.pageProvider = { [weak self] identity, direction in
                        guard let self, let current = Int(identity.unitID) else { return .failed }
                        let target = current + (direction == .next ? 1 : -1)
                        guard (0..<self.count).contains(target) else { return .boundary(target < 0 ? .startOfBook : .endOfBook) }
                        return .page(self.page(target))
                    }
                    paged.onTransition = { [weak self] event in
                        if case .didCommit(let transaction) = event { self?.currentIndex = Int(transaction.to.unitID) ?? 0 }
                    }
                }
                provider = nil
            } else {
                let provider = AsyncStyledContentProvider()
                self.provider = provider
                provider.planForItem = { [weak self] item in self?.plan(Int(item.identity.unitID) ?? 0) ?? .init() }
                provider.onEvent = { [weak self] event in self?.display(event) }
                // 示例预留足够高度展示完整样式；真实测量回填与锚点补偿由专用测试验收。
                let items = (0..<count).map { ContinuousItem(identity: identity($0), sectionID: "chapter", extent: 820) }
                try reader.showContinuous(window: ContinuousWindow(items: items, before: .startOfBook, after: .endOfBook), provider: provider,
                                          anchor: .init(identity: identity(currentIndex), offsetInItem: 0)) { [weak self] continuous in
                    provider.reader = continuous
                    continuous.onVisibleAnchor = { [weak self] anchor in self?.currentIndex = Int(anchor.identity.unitID) ?? 0 }
                }
            }
        } catch { message.text = "操作未完成：\(error)" }
    }

    /// - Parameter event: 实际阶段结果，拒绝旧结果只显示诊断，不更改正文。
    private func display(_ event: AsyncStyledRenderEvent) {
        let stage = event.stage == .text ? "正文" : "插图"
        let result: String
        switch event.result {
        case .applied: result = "已显示"
        case .failed: result = "加载失败"
        case .discarded: result = "旧结果已拒绝"
        case .cancelled: result = "已取消"
        }
        message.text = "内容 \((Int(event.identity.unitID) ?? 0) + 1)/\(count) · \(stage)\(result)\n布局版本 \(event.identity.layoutVersion)"
    }

    @objc private func changeMode() { presentCurrent() }
    @objc private func changeStyle() { version += 1; largeText.toggle(); dark.toggle(); presentCurrent() }
    @objc private func toggleImageFailure() { version += 1; imageFails.toggle(); presentCurrent() }
    @objc private func nextPage() {
        do {
            if let paged = reader.pagedReader { try paged.turn(.next) }
            else if let continuous = reader.continuousReader, currentIndex + 1 < count {
                try continuous.restore(.init(identity: identity(currentIndex + 1), offsetInItem: 0), expectedToken: continuous.updateToken)
            }
        } catch { message.text = "操作未完成：\(error)" }
    }
}
