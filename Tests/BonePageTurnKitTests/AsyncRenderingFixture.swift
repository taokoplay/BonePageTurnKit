#if canImport(UIKit)
import UIKit
import BonePageTurnKit

/// 测试和独立示例共用的宿主渲染配置；延迟模拟 I/O 完成时序，不代表后台排版性能。
struct AsyncStyledRenderPlan: Equatable, Sendable {
    enum Theme: Sendable { case light, dark }
    var title = "异步正文"
    var fontSize: CGFloat = 17
    var theme: Theme = .light
    var textDelay: UInt64 = 30_000_000
    var imageDelay: UInt64 = 80_000_000
    var imageFails = false
    var ignoresCancellation = false
}

struct AsyncStyledRenderEvent: Sendable {
    enum Stage: Sendable { case text, image }
    enum Result: Sendable { case applied, failed, discarded, cancelled }
    let identity: PageItemIdentity
    let generation: UUID
    let stage: Stage
    let result: Result
}

/// 真实 UITextView + UIImageView 宿主内容。样式绘制和视图更新均在主 actor。
@MainActor
final class AsyncStyledContentView: UIView {
    let stateLabel = UILabel()
    let textView = UITextView()
    let imageView = UIImageView()
    let captionLabel = UILabel()
    private(set) var renderedIdentity: PageItemIdentity?
    private(set) var generation = UUID()
    private(set) var textReady = false
    private(set) var imageFinished = false
    private(set) var imageFailed = false
    private(set) var plan: AsyncStyledRenderPlan?
    private var tasks: [Task<Void, Never>] = []
    var isFullyRendered: Bool { textReady && imageFinished }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        stateLabel.accessibilityIdentifier = "render-state"
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "styled-body"
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.numberOfLines = 2
        for child in [stateLabel, textView, imageView, captionLabel] { addSubview(child) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用显式初始化") }

    /// - Parameters: identity: 当前内容及布局版本；plan: 样式和模拟时序；isCurrent: 宿主／SDK 绑定校验；onEvent: 每阶段唯一结果；onHeight: 全部阶段完成后的实际测量高度。
    /// - Returns: 本轮渲染代际。完成的同内容可复用，不重复闪回占位。
    @discardableResult
    func render(identity: PageItemIdentity, plan: AsyncStyledRenderPlan,
                isCurrent: @escaping @MainActor () -> Bool,
                onEvent: @escaping @MainActor (AsyncStyledRenderEvent) -> Void,
                onHeight: (@MainActor (Double) -> Void)? = nil) -> UUID {
        let reuseCompleted = renderedIdentity == identity && self.plan == plan && isFullyRendered
        cancelRendering()
        self.plan = plan
        renderedIdentity = identity
        let generation = self.generation
        if reuseCompleted { return generation }
        textReady = false
        imageFinished = false
        imageFailed = false
        textView.attributedText = nil
        imageView.image = nil
        let dark = plan.theme == .dark
        backgroundColor = dark ? UIColor(white: 0.08, alpha: 1) : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        stateLabel.textColor = dark ? .lightGray : .darkGray
        captionLabel.textColor = dark ? .lightGray : .darkGray
        imageView.backgroundColor = dark ? UIColor(white: 0.15, alpha: 1) : UIColor(white: 0.9, alpha: 1)
        captionLabel.text = "插图加载中…"
        textView.text = "正文排版中…"
        textView.font = .systemFont(ofSize: plan.fontSize)
        textView.textColor = dark ? .white : .black
        updateState()
        setNeedsLayout()
        for stage in [AsyncStyledRenderEvent.Stage.text, .image] {
            let delay = stage == .text ? plan.textDelay : plan.imageDelay
            let task = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: delay) }
                catch {
                    onEvent(.init(identity: identity, generation: generation, stage: stage, result: .cancelled))
                    return
                }
                guard let self, self.generation == generation, self.renderedIdentity == identity, isCurrent() else {
                    onEvent(.init(identity: identity, generation: generation, stage: stage, result: .discarded))
                    return
                }
                let result: AsyncStyledRenderEvent.Result
                switch stage {
                case .text:
                    self.textView.attributedText = Self.styledText(identity: identity, plan: plan)
                    self.textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]
                    self.textReady = true
                    result = .applied
                case .image:
                    self.imageFinished = true
                    self.imageFailed = plan.imageFails
                    self.imageView.image = plan.imageFails ? nil : Self.illustration(label: identity.unitID, dark: dark)
                    self.captionLabel.text = plan.imageFails ? "插图加载失败，可重试" : "插图已到达 · \(identity.unitID) · 与正文独立完成"
                    result = plan.imageFails ? .failed : .applied
                }
                self.updateState()
                self.setNeedsLayout()
                self.layoutIfNeeded()
                if self.isFullyRendered, self.bounds.width > 0 { onHeight?(Double(self.measuredHeight(width: self.bounds.width))) }
                onEvent(.init(identity: identity, generation: generation, stage: stage, result: result))
            }
            tasks.append(task)
        }
        return generation
    }

    /// 模拟可取消和不可取消任务；无论任务是否合作，代际都会失效。
    func cancelRendering() {
        generation = UUID()
        if plan?.ignoresCancellation != true { tasks.forEach { $0.cancel() } }
        tasks.removeAll()
    }

    /// - Parameter width: 实际内容宽度。
    /// - Returns: 含状态、真实富文本、插图和说明的测量高度。
    func measuredHeight(width: CGFloat) -> CGFloat {
        let innerWidth = max(1, width - 40)
        let body = textView.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height
        return 20 + 20 + 12 + ceil(body) + 14 + 112 + 8 + 36 + 20
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, bounds.width - 40)
        stateLabel.frame = CGRect(x: 20, y: 18, width: width, height: 20)
        let bodyHeight = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        textView.frame = CGRect(x: 20, y: 50, width: width, height: bodyHeight)
        imageView.frame = CGRect(x: 20, y: textView.frame.maxY + 14, width: width, height: 112)
        captionLabel.frame = CGRect(x: 20, y: imageView.frame.maxY + 8, width: width, height: 36)
    }

    /// 显示两条异步链各自状态，图片先到不会被后到的正文清空。
    private func updateState() {
        stateLabel.text = "正文 \(textReady ? "就绪" : "等待")  ·  插图 \(imageFinished ? (imageFailed ? "失败" : "就绪") : "等待")"
    }

    /// - Parameters: identity: 内容身份；plan: 主线程字体／颜色配置。
    /// - Returns: 具有真实可选择文本与行内附件的富文本。
    static func styledText(identity: PageItemIdentity, plan: AsyncStyledRenderPlan) -> NSAttributedString {
        let text = "\(plan.title) · \(identity.unitID)\n" +
            "清晨的书店还没有开门。这是正文，包含重点强调、斜体提示与彩色标记。\n" +
            "“引用段落有独立缩进和底色。”\n" +
            "• 列表与行距\n" +
            "行内代码 let page = 1；链接示例\n" +
            "行内图片："
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let foreground: UIColor = plan.theme == .dark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.12, alpha: 1)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: plan.fontSize), .foregroundColor: foreground, .paragraphStyle: paragraph
        ])
        let source = text as NSString
        func style(_ fragment: String, _ attributes: [NSAttributedString.Key: Any]) {
            let range = source.range(of: fragment)
            if range.location != NSNotFound { result.addAttributes(attributes, range: range) }
        }
        style("\(plan.title) · \(identity.unitID)", [.font: UIFont.boldSystemFont(ofSize: plan.fontSize + 5)])
        style("重点强调", [.font: UIFont.boldSystemFont(ofSize: plan.fontSize)])
        style("斜体提示", [.font: UIFont.italicSystemFont(ofSize: plan.fontSize)])
        style("彩色标记", [.foregroundColor: UIColor.systemOrange, .underlineStyle: NSUnderlineStyle.single.rawValue])
        let quote = NSMutableParagraphStyle()
        quote.headIndent = 12
        quote.firstLineHeadIndent = 12
        quote.lineSpacing = 4
        quote.paragraphSpacing = 8
        style("“引用段落有独立缩进和底色。”", [.paragraphStyle: quote, .backgroundColor: UIColor.systemTeal.withAlphaComponent(0.12)])
        style("let page = 1", [.font: UIFont.monospacedSystemFont(ofSize: plan.fontSize - 1, weight: .regular), .backgroundColor: UIColor.systemGray.withAlphaComponent(0.15)])
        if let url = URL(string: "https://example.invalid/reader-fixture") { style("链接示例", [.link: url]) }
        let attachment = NSTextAttachment()
        attachment.image = illustration(label: "图", dark: plan.theme == .dark)
        attachment.bounds = CGRect(x: 0, y: -4, width: 42, height: 22)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    /// - Parameters: label: 内容标记；dark: 深色模式。
    /// - Returns: 经 PNG 编解码的本地原创测试插图；不请求外部图片服务。
    static func illustration(label: String, dark: Bool) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 180), format: format)
        let image = renderer.image { context in
            (dark ? UIColor(red: 0.1, green: 0.25, blue: 0.3, alpha: 1) : UIColor(red: 0.76, green: 0.88, blue: 0.86, alpha: 1)).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 180))
            UIColor.systemOrange.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 350, y: 20, width: 70, height: 70))
            UIColor.systemTeal.setFill()
            let hills = UIBezierPath()
            hills.move(to: CGPoint(x: 0, y: 180))
            hills.addLine(to: CGPoint(x: 160, y: 45))
            hills.addLine(to: CGPoint(x: 310, y: 180))
            hills.close()
            hills.fill()
            ("PAGE " + label as NSString).draw(at: CGPoint(x: 22, y: 126), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.white])
        }
        return image.pngData().flatMap { UIImage(data: $0) }
    }
}

/// 分页宿主自己管理页面内部渲染代际；不把页码 metadataToken 当作内容渲染绑定。
@MainActor
final class AsyncStyledPageController: UIViewController {
    let identity: PageItemIdentity
    var renderPlan: AsyncStyledRenderPlan
    let content = AsyncStyledContentView()
    var onEvent: ((AsyncStyledRenderEvent) -> Void)?

    /// - Parameters: identity: 固定页面身份；plan: 渲染计划。
    init(identity: PageItemIdentity, plan: AsyncStyledRenderPlan) {
        self.identity = identity
        renderPlan = plan
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用显式初始化") }
    override func loadView() { view = content }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent is PagedReaderViewController { startRendering() } else { content.cancelRendering() }
    }

    /// 使用真实父容器、展示代际和宿主内容身份校验；支持已挂载的当前页与过渡目标页。
    func startRendering() {
        guard let reader = parent as? PagedReaderViewController else { return }
        let presentationID = reader.presentationID
        let identity = self.identity
        content.render(identity: identity, plan: renderPlan, isCurrent: { [weak self, weak reader] in
            guard let self, let reader else { return false }
            return reader.isActive && reader.presentationID == presentationID && self.parent === reader && self.identity == identity
        }, onEvent: { [weak self] event in self?.onEvent?(event) })
    }
}

@MainActor
final class AsyncStyledContentProvider: ContinuousContentProvider {
    private final class WeakView {
        weak var value: AsyncStyledContentView?
        init(_ value: AsyncStyledContentView) { self.value = value }
    }
    weak var reader: ContinuousReaderViewController?
    var planForItem: (ContinuousItem) -> AsyncStyledRenderPlan = { _ in .init() }
    var onEvent: ((AsyncStyledRenderEvent) -> Void)?
    var onHeight: ((PageViewBinding, Double) -> Void)?
    private var views: [String: WeakView] = [:]
    private(set) var bindings: [String: PageViewBinding] = [:]

    /// - Parameter reuseIdentifier: 内容类别。
    /// - Returns: 未挂载的真实富文本／图片视图。
    func makeContentView(reuseIdentifier: String) -> UIView { AsyncStyledContentView() }

    /// - Parameters: view: 新建或复用视图；item: 当前窗口数据；binding: SDK 安装的复用绑定。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let view = view as? AsyncStyledContentView else { return }
        views[item.identity.unitID] = WeakView(view)
        bindings[item.identity.unitID] = binding
        view.render(identity: item.identity, plan: planForItem(item), isCurrent: { [weak reader] in
            reader?.isCurrent(binding) == true
        }, onEvent: { [weak self] event in self?.onEvent?(event) }, onHeight: { [weak self] height in
            guard let self, self.reader?.isCurrent(binding) == true else { return }
            self.onHeight?(binding, height)
        })
    }

    /// - Parameters: view: SDK 已使绑定失效的视图；binding: 被终止绑定。
    func unbind(_ view: UIView, binding: PageViewBinding) {
        (view as? AsyncStyledContentView)?.cancelRendering()
        if bindings[binding.identity.unitID] == binding {
            bindings.removeValue(forKey: binding.identity.unitID)
            views.removeValue(forKey: binding.identity.unitID)
        }
    }

    /// - Parameter unitID: 当前已挂载内容单元 ID。
    /// - Returns: 仅当前绑定对应的弱引用视图。
    func contentView(for unitID: String) -> AsyncStyledContentView? { views[unitID]?.value }
}
#endif
