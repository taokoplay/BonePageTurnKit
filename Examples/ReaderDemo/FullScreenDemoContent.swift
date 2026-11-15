import UIKit
import BonePageTurnKit

/// 源页与展示单元的对应关系；切片的物理身份独立于展示顺序。
struct FullScreenDemoUnit {
    let identity: PageItemIdentity
    let sourceIndex: Int
    let title: String
    let slice: ComicPageSlice?
}

/// 全屏示例的同步内容工厂；只拥有正文、源图缓存与内容元数据。
@MainActor
final class FullScreenDemoContentFactory: ContinuousContentProvider {
    let settings: FullScreenDemoSettings
    let units: [FullScreenDemoUnit]

    var count: Int { units.count }

    /// 正文总标题；长文资源缺失或损坏时回退为内置短篇标题。
    nonisolated static let articleTitle = FullScreenDemoArticleLoader.resolvedTitle

    /// 阅读底纸随系统外观变化，夜间保持较低亮度。
    static var paperColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.105, green: 0.125, blue: 0.12, alpha: 1)
                : UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
        }
    }

    /// 正文墨色随系统外观变化。
    static var inkColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.80, green: 0.82, blue: 0.77, alpha: 1)
                : UIColor(red: 0.17, green: 0.23, blue: 0.21, alpha: 1)
        }
    }

    private let imageCache = FullScreenDemoImageCache()
    private let planningError: Error?
    private lazy var measuringTextView = FullScreenDemoTextView(frame: .zero, textContainer: nil)
    private static let trailingSpacing: CGFloat = 24
    private var isText: Bool { settings.content == "text" }
    private var sourceCount: Int { isText ? FullScreenDemoStory.pages.count : 6 }
    private var sourcePixelSize: CGSize {
        settings.content == "wideImage" ? CGSize(width: 1_200, height: 800) : CGSize(width: 600, height: 1_800)
    }

    /// 仅规划身份和整数像素切片，不生成图片。
    /// - Parameters: settings: 内容设置快照；layoutVersion: 排版版本；contentVersion: 正文版本。
    init(settings: FullScreenDemoSettings, layoutVersion: UInt64, contentVersion: UInt64 = 0) {
        self.settings = settings
        let sourceID = "fullscreen-demo-" + settings.content
        var result: [FullScreenDemoUnit] = []
        var error: Error?
        if settings.content == "text" {
            result = FullScreenDemoStory.pages.enumerated().map { index, page in
                FullScreenDemoUnit(
                    identity: PageItemIdentity(sourceID: sourceID, unitID: String(index),
                                               contentVersion: contentVersion, layoutVersion: layoutVersion),
                    sourceIndex: index, title: page.title, slice: nil
                )
            }
        } else if settings.content == "wideImage" || settings.content == "tallImage" {
            let size = settings.content == "wideImage"
                ? CGSize(width: 1_200, height: 800) : CGSize(width: 600, height: 1_800)
            do {
                for source in 0..<6 {
                    let sourceIdentity = PageItemIdentity(
                        sourceID: sourceID, unitID: "source-\(source)",
                        contentVersion: contentVersion, layoutVersion: layoutVersion
                    )
                    let slices = try ComicPageSlicing.slices(
                        for: sourceIdentity, pixelSize: size, mode: settings.sdkSliceMode,
                        readingOrder: settings.sdkOrder, maximumHeightToWidth: settings.sliceRatio
                    )
                    for slice in slices {
                        result.append(FullScreenDemoUnit(
                            identity: PageItemIdentity(sourceID: sourceID, unitID: String(result.count),
                                                       contentVersion: contentVersion, layoutVersion: layoutVersion),
                            sourceIndex: source,
                            title: "\(FullScreenDemoImageCache.titles[source]) · \(slice.index + 1)/\(slice.count)",
                            slice: slice
                        ))
                    }
                }
            } catch let caught {
                result.removeAll()
                error = caught
            }
        } else {
            error = FullScreenDemoContentError.unsupportedContent
        }
        units = result
        planningError = error
    }

    /// 创建独立的纯正文控制器，内层滚动视图可由宿主遍历并注册交接。
    /// - Parameter index: 从零开始的展示索引。
    /// - Returns: 包含稳定身份和阅读统计的真实页面。
    /// - Throws: 索引、切片或缩放设置错误。
    func page(at index: Int) throws -> PageContent {
        let unit = try checkedUnit(at: index)
        let content = FullScreenDemoContentView()
        let naturalSize: CGSize
        if isText {
            let story = FullScreenDemoStory.pages[unit.sourceIndex]
            // 分页正文固定在页内，拖动交给外层翻页器；连续模式也由外层容器统一滚动。
            content.showText(story, fontSize: settings.fontSize, scrollEnabled: false)
            content.trailingSpacing = Self.trailingSpacing
            if settings.zoomEnabled {
                // 缩放正文使用固定书页宽度；其高度仍由同一套 TextKit 排版实测。
                let width: CGFloat = 420
                naturalSize = CGSize(width: width, height: measuredHeight(story: story, width: width) + Self.trailingSpacing)
            } else {
                naturalSize = .zero
            }
        } else {
            guard let slice = unit.slice else { throw FullScreenDemoContentError.missingSlice }
            try showImage(unit, in: content)
            naturalSize = slice.sourcePixelRect.size
        }
        let body = FullScreenDemoPageController(content: content)
        body.preferredContentSize = naturalSize
        let controller: UIViewController
        if settings.zoomEnabled {
            let zoom = try ReaderZoomViewController(
                content: body, contentSize: naturalSize, fit: settings.sdkZoomFit,
                maximumZoomFactor: CGFloat(settings.maximumZoom)
            )
            try zoom.setZoomFactor(CGFloat(settings.initialZoom), animated: false)
            controller = zoom
        } else {
            controller = body
        }
        return PageContent(identity: unit.identity, controller: controller, readingInfo: try readingInfo(at: index))
    }

    /// 返回当前内容快照的统计；图片按源页计数，不把切片数当作书页总数。
    /// - Parameter index: 从零开始的展示索引。
    /// - Returns: 一基页码、每六个源页一章的统计和明确的书籍边界。
    /// - Throws: 元数据或索引错误。
    func readingInfo(at index: Int) throws -> ReaderPageInfo {
        let unit = try checkedUnit(at: index)
        let section = unit.sourceIndex / 6
        let countingUnit: ReaderCountingUnit = isText ? .contentBlock : .sourcePage
        let book = try ReaderPageMetrics(current: unit.sourceIndex + 1,
                                         total: total(sourceCount), unit: countingUnit)
        let sectionPages = try ReaderPageMetrics(current: unit.sourceIndex % 6 + 1,
                                                 total: total(min(6, sourceCount - section * 6)), unit: countingUnit)
        let pagination = ReaderPagination(
            book: book,
            section: try ReaderSectionPagination(sectionID: sectionID(section), pages: sectionPages)
        )
        let after: ReaderBoundaryState
        if index == count - 1 {
            switch settings.bookBoundary {
            case "endOfBook": after = .endOfBook
            case "latestAvailable": after = .latestAvailable
            default: after = .unknown
            }
        } else if units[index + 1].sourceIndex / 6 != section {
            after = .endOfSection(sectionID(section))
        } else {
            after = .available
        }
        return ReaderPageInfo(pagination: pagination, before: index == 0 ? .startOfBook : .available, after: after)
    }

    /// 按真实可用宽度测量连续块，不补齐视口高度，也不生成源图。
    /// - Parameters: range: 展示索引区间；width: 实际块宽度；state: 宿主指定的加载状态。
    /// - Returns: 含且仅含一次尾间距的连续块元数据。
    /// - Throws: 非法宽度、索引或切片规划错误。
    func items(in range: Range<Int>, width: CGFloat, state: ContinuousContentState = .ready) throws -> [ContinuousItem] {
        if let planningError { throw planningError }
        guard width.isFinite, width > 0 else { throw FullScreenDemoContentError.invalidWidth }
        guard range.lowerBound >= 0, range.upperBound <= count else { throw FullScreenDemoContentError.invalidIndex }
        defer { measuringTextView.clearContent() }
        return try range.map { index in
            let unit = units[index]
            let height: CGFloat
            if state != .ready {
                measuringTextView.showMessage(placeholder(for: unit, state: state), fontSize: settings.fontSize)
                height = measuringTextView.measuredHeight(width: width)
            } else if isText {
                height = measuredHeight(story: FullScreenDemoStory.pages[unit.sourceIndex], width: width)
            } else {
                guard let slice = unit.slice else { throw FullScreenDemoContentError.missingSlice }
                height = width * slice.sourcePixelRect.height / slice.sourcePixelRect.width
            }
            let extent = height + Self.trailingSpacing
            guard extent.isFinite, extent > 0 else { throw FullScreenDemoContentError.invalidWidth }
            return ContinuousItem(
                identity: unit.identity, sectionID: sectionID(unit.sourceIndex / 6), extent: Double(extent),
                reuseIdentifier: "fullscreen-demo-content", state: state,
                pagination: try readingInfo(at: index).pagination
            )
        }
    }

    /// 跨切片方式或阅读顺序恢复源图中的位置。
    /// - Parameters: forSourcePage: 从零开始的源页；point: 源图归一化坐标，与 slice.normalizedRect 同坐标系；nil 取阅读顺序首片。
    /// - Returns: 包含该物理点的展示索引；页号和坐标越界均钳制。空内容返回零。
    func index(forSourcePage: Int, point: CGPoint? = nil) -> Int {
        guard !units.isEmpty else { return 0 }
        let source = min(max(0, forSourcePage), sourceCount - 1)
        let candidates = units.indices.filter { units[$0].sourceIndex == source }
        guard let first = candidates.first, let point, !isText else { return candidates.first ?? 0 }
        let size = sourcePixelSize
        let x = point.x.isNaN ? 0 : min(max(0, point.x * size.width), size.width.nextDown)
        let y = point.y.isNaN ? 0 : min(max(0, point.y * size.height), size.height.nextDown)
        return candidates.first { index in
            guard let rect = units[index].slice?.sourcePixelRect else { return false }
            return x >= rect.minX && x < rect.maxX && y >= rect.minY && y < rect.maxY
        } ?? first
    }

    /// 创建独立底纸；无参数。
    /// - Returns: 按自身 bounds 绘制、支持明暗外观和纹理开关的全幅背景。
    func makeBackground() -> UIView {
        FullScreenDemoBackgroundView(wallpaper: settings.wallpaper)
    }

    /// 创建尚未绑定、未挂载的可复用容器。
    /// - Parameter reuseIdentifier: SDK 提供的复用类别。
    /// - Returns: 背景透明的正文容器。
    func makeContentView(reuseIdentifier: String) -> UIView {
        FullScreenDemoContentView()
    }

    /// 根据完整绑定身份和十进制单元编号安装内容，无异步任务。
    /// - Parameters: view: 可复用容器；item: 块元数据；binding: 当前复用绑定；无返回值。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let content = view as? FullScreenDemoContentView else { return }
        content.beginBinding(binding)
        content.trailingSpacing = Self.trailingSpacing
        guard binding.identity == item.identity,
              let index = Int(binding.identity.unitID), units.indices.contains(index),
              units[index].identity == binding.identity else {
            content.showMessage("这一页的内容位置已失效，请重新打开阅读内容。", fontSize: settings.fontSize)
            return
        }
        let unit = units[index]
        guard item.state == .ready else {
            content.showMessage(placeholder(for: unit, state: item.state), fontSize: settings.fontSize)
            return
        }
        if isText {
            content.showText(FullScreenDemoStory.pages[unit.sourceIndex], fontSize: settings.fontSize, scrollEnabled: false)
        } else {
            do {
                try showImage(unit, in: content)
            } catch {
                content.showMessage("\(unit.title)\n\n这一页的图像暂时无法显示。", fontSize: settings.fontSize)
            }
        }
    }

    /// 释放旧绑定的文字与图片，保留工厂的有限源图缓存。
    /// - Parameters: view: 被回收的容器；binding: 需要解绑的身份；无返回值。
    func unbind(_ view: UIView, binding: PageViewBinding) {
        guard let content = view as? FullScreenDemoContentView, content.binding == binding else { return }
        content.clearContent()
    }
}

private extension FullScreenDemoContentFactory {
    /// - Parameter index: 展示索引。
    /// - Returns: 对应的不可变单元；非法索引或规划失败时抛错。
    func checkedUnit(at index: Int) throws -> FullScreenDemoUnit {
        if let planningError { throw planningError }
        guard units.indices.contains(index) else { throw FullScreenDemoContentError.invalidIndex }
        return units[index]
    }

    /// - Parameter count: 当前快照中的实际数量。
    /// - Returns: 保留设置中未知、估算或确定语义的总数。
    func total(_ count: Int) -> ReaderPageTotal {
        switch settings.paginationTotal {
        case "exact": return .exact(count)
        case "estimated": return .estimated(count)
        default: return .unknown
        }
    }

    /// - Parameter section: 从零开始的章节。
    /// - Returns: 不依赖控制器或绑定生命周期的章节身份。
    func sectionID(_ section: Int) -> String {
        "fullscreen-demo-\(settings.content)-chapter-\(section)"
    }

    /// - Parameters: unit: 展示单元；state: 宿主指定的状态。
    /// - Returns: 明确说明未就绪状态的文字。
    func placeholder(for unit: FullScreenDemoUnit, state: ContinuousContentState) -> String {
        switch state {
        case .loading: return "\(unit.title)\n\n正在载入这一页，请稍候。"
        case .failed: return "\(unit.title)\n\n这一页载入失败，正文尚未就绪。"
        case .ready: return unit.title
        }
    }

    /// - Parameters: story: 单页正文；width: 实际排版宽度。
    /// - Returns: 使用显示视图相同字体、段落与内边距得到的 TextKit 高度。
    func measuredHeight(story: FullScreenDemoStoryPage, width: CGFloat) -> CGFloat {
        measuringTextView.showStory(story, fontSize: settings.fontSize, scrollEnabled: false)
        return measuringTextView.measuredHeight(width: width)
    }

    /// - Parameters: unit: 切片单元；view: 正文容器；无返回值。
    /// - Throws: 缺少切片或 SDK 图像校验错误。
    func showImage(_ unit: FullScreenDemoUnit, in view: FullScreenDemoContentView) throws {
        guard let slice = unit.slice else { throw FullScreenDemoContentError.missingSlice }
        let cache = imageCache
        let size = sourcePixelSize
        try view.showImage(slice: slice, title: unit.title) { traits in
            cache.image(source: unit.sourceIndex, size: size, traits: traits)
        }
    }
}

private enum FullScreenDemoContentError: Error {
    case invalidIndex
    case invalidWidth
    case missingSlice
    case unsupportedContent
}

// MARK: - 正文排版与可复用容器

@MainActor
private final class FullScreenDemoPageController: UIViewController {
    private let content: UIView

    /// - Parameter content: 尚未挂载的纯正文视图。
    init(content: UIView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持归档初始化。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 安装真实正文视图；无参数及返回值。
    override func loadView() {
        view = content
    }
}

@MainActor
private final class FullScreenDemoContentView: UIView {
    private(set) var binding: PageViewBinding?
    var trailingSpacing: CGFloat = 0 { didSet { setNeedsLayout() } }
    private let textView = FullScreenDemoTextView(frame: .zero, textContainer: nil)
    private var comicView: ComicSliceView?
    private var slice: ComicPageSlice?
    private var imageTitle = ""
    private var imageProvider: ((UITraitCollection) -> UIImage)?

    /// 创建空容器；无参数。
    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        textView.isHidden = true
        addSubview(textView)
    }

    /// 不支持归档初始化。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameter binding: 新复用绑定；清理旧内容后安装，无返回值。
    func beginBinding(_ binding: PageViewBinding) {
        clearContent()
        self.binding = binding
    }

    /// - Parameters: story: 正文；fontSize: 基准字号；scrollEnabled: 是否允许页内滚动；无返回值。
    func showText(_ story: FullScreenDemoStoryPage, fontSize: Double, scrollEnabled: Bool) {
        clearImage()
        textView.isHidden = false
        textView.showStory(story, fontSize: fontSize, scrollEnabled: scrollEnabled)
        setNeedsLayout()
    }

    /// - Parameters: message: 占位文字；fontSize: 基准字号；无返回值。
    func showMessage(_ message: String, fontSize: Double) {
        clearImage()
        textView.isHidden = false
        textView.showMessage(message, fontSize: fontSize)
        setNeedsLayout()
    }

    /// - Parameters: slice: 源图切片；title: 无障碍名称；provider: 按外观取得源图的同步函数。
    /// - Throws: SDK 图像校验错误；无返回值。
    func showImage(slice: ComicPageSlice, title: String, provider: @escaping (UITraitCollection) -> UIImage) throws {
        textView.clearContent()
        textView.isHidden = true
        self.slice = slice
        imageTitle = title
        imageProvider = provider
        try refreshImage()
    }

    /// 释放文字、图像及图像提供闭包；无参数及返回值。
    func clearContent() {
        binding = nil
        clearImage()
        textView.clearContent()
        textView.isHidden = true
    }

    /// 随实际容器尺寸调整内部几何；无参数及返回值。
    override func layoutSubviews() {
        super.layoutSubviews()
        let area = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                          height: max(0, bounds.height - trailingSpacing))
        textView.frame = area
        textView.updateInsets(width: area.width)
        comicView?.frame = area
    }

    /// - Parameter previousTraitCollection: 变化前的外观；重绘源图配色，无返回值。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard imageProvider != nil,
              traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        do {
            try refreshImage()
        } catch {
            showMessage("这一页的图像暂时无法显示。", fontSize: 19)
        }
    }

    /// 清理显示中的源图引用；无参数及返回值。
    private func clearImage() {
        comicView?.removeFromSuperview()
        comicView = nil
        slice = nil
        imageProvider = nil
        imageTitle = ""
    }

    /// 使用当前外观更新真实切片；无参数及返回值，图像无效时抛错。
    private func refreshImage() throws {
        guard let imageProvider, let slice else { return }
        let next = try ComicSliceView(image: imageProvider(traitCollection), slice: slice)
        next.isAccessibilityElement = true
        next.accessibilityLabel = "\(imageTitle)，第 \(slice.index + 1) 片，共 \(slice.count) 片"
        next.accessibilityTraits = .image
        comicView?.removeFromSuperview()
        comicView = next
        addSubview(next)
        setNeedsLayout()
    }
}

/// 测量与显示共用的 TextKit 视图；不把字符数或字号估算当作内容高度。
@MainActor
private final class FullScreenDemoTextView: UITextView {
    private var story: FullScreenDemoStoryPage?
    private var message: String?
    private var baseFontSize: Double = 19
    private var layoutWidth: CGFloat = 0

    /// - Parameters: frame: 初始矩形；textContainer: 可选 TextKit 容器。
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        isOpaque = false
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        alwaysBounceVertical = false
        dataDetectorTypes = []
        contentInsetAdjustmentBehavior = .never
        contentInset = .zero
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        // 富文本在字号类别变化时统一重建，避免再次缩放已经过 UIFontMetrics 处理的字体。
        adjustsFontForContentSizeCategory = false
        accessibilityIdentifier = "fullscreen-demo-body"
    }

    /// 不支持归档初始化。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameters: story: 单页故事；fontSize: 基准字号；scrollEnabled: 是否允许内滚；无返回值。
    func showStory(_ story: FullScreenDemoStoryPage, fontSize: Double, scrollEnabled: Bool) {
        self.story = story
        message = nil
        baseFontSize = fontSize
        isScrollEnabled = scrollEnabled
        showsVerticalScrollIndicator = scrollEnabled
        rebuildText()
        setContentOffset(.zero, animated: false)
    }

    /// - Parameters: message: 未就绪状态文字；fontSize: 基准字号；无返回值。
    func showMessage(_ message: String, fontSize: Double) {
        story = nil
        self.message = message
        baseFontSize = fontSize
        isScrollEnabled = false
        showsVerticalScrollIndicator = false
        rebuildText()
        setContentOffset(.zero, animated: false)
    }

    /// - Parameter width: 实际容器宽度；窄双页按比例缩小左右留白，无返回值。
    func updateInsets(width: CGFloat) {
        let horizontal = min(24, max(0, width * 0.075))
        let inset = UIEdgeInsets(top: 14, left: horizontal, bottom: 0, right: horizontal)
        if textContainerInset != inset { textContainerInset = inset }
        if layoutWidth != width {
            layoutWidth = width
            rebuildText()
        }
    }

    /// - Parameter width: 实际排版宽度。
    /// - Returns: 同一 TextKit 视图的自然高度，已包含顶部内边距，未包含块尾间距。
    func measuredHeight(width: CGFloat) -> CGFloat {
        updateInsets(width: width)
        bounds.size.width = width
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(fitted.height)
    }

    /// 清除绑定内容和选区；无参数及返回值。
    func clearContent() {
        story = nil
        message = nil
        selectedRange = NSRange(location: 0, length: 0)
        attributedText = nil
        accessibilityLabel = nil
        setContentOffset(.zero, animated: false)
    }

    /// - Parameter previousTraitCollection: 旧字体类别和外观；同步富文本字体，无返回值。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            rebuildText()
        }
    }

    /// 按当前动态字号生成全文属性；无参数及返回值。
    private func rebuildText() {
        // 新正文先获得真实排版宽度，再构造一次富文本；避免零宽初建随后立即失效重建。
        guard layoutWidth.isFinite, layoutWidth > 0 else { return }
        let base = CGFloat(baseFontSize.isFinite && baseFontSize > 0 ? baseFontSize : 19)
        let systemCategory = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        let fontTraits = UITraitCollection(traitsFrom: [traitCollection, systemCategory])
        let body = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: base), compatibleWith: fontTraits)
        let strong = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: base, weight: .semibold), compatibleWith: fontTraits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = body.pointSize * 0.28
        paragraph.paragraphSpacing = body.pointSize * 0.7
        paragraph.lineBreakMode = .byWordWrapping
        let color = FullScreenDemoContentFactory.inkColor
        guard let story else {
            if let message {
                attributedText = NSAttributedString(string: message, attributes: [
                    .font: body, .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
            return
        }
        let titleFont = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .systemFont(ofSize: base * 1.3, weight: .semibold), compatibleWith: fontTraits
        )
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = body.pointSize * 1.05
        titleStyle.lineSpacing = body.pointSize * 0.2
        let result = NSMutableAttributedString(string: story.title + "\n", attributes: [
            .font: titleFont, .foregroundColor: color, .paragraphStyle: titleStyle
        ])
        let usableWidth = max(1, layoutWidth - textContainerInset.left - textContainerInset.right)
        let firstIndent = min(body.pointSize * 1.8, usableWidth * 0.18)
        let quoteIndent = min(body.pointSize * 0.7, usableWidth * 0.08)
        for (index, text) in story.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.setParagraphStyle(paragraph)
            style.paragraphSpacing = index == story.paragraphs.count - 1 ? 0 : paragraph.paragraphSpacing
            style.firstLineHeadIndent = firstIndent
            if index == story.quoteParagraph {
                style.firstLineHeadIndent = quoteIndent
                style.headIndent = quoteIndent
                style.tailIndent = -quoteIndent
            }
            let chunk = NSMutableAttributedString(
                string: text + (index == story.paragraphs.count - 1 ? "" : "\n"),
                attributes: [.font: body, .foregroundColor: index == story.quoteParagraph ? Self.accentColor : color,
                             .paragraphStyle: style, .kern: 0.15]
            )
            if let emphasis = story.emphasis {
                let range = (text as NSString).range(of: emphasis)
                if range.location != NSNotFound { chunk.addAttribute(.font, value: strong, range: range) }
            }
            result.append(chunk)
        }
        attributedText = result
        accessibilityLabel = nil
    }

    private static var accentColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.56, green: 0.72, blue: 0.64, alpha: 1)
                : UIColor(red: 0.25, green: 0.43, blue: 0.36, alpha: 1)
        }
    }
}

// MARK: - 底纸与有限源图缓存

@MainActor
private final class FullScreenDemoBackgroundView: UIView {
    private let wallpaper: Bool

    /// - Parameter wallpaper: 是否绘制极淡线纹。
    init(wallpaper: Bool) {
        self.wallpaper = wallpaper
        super.init(frame: .zero)
        backgroundColor = FullScreenDemoContentFactory.paperColor
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    /// 不支持归档初始化。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameter rect: UIKit 请求的绘制区域；所有几何来自当前 bounds，无返回值。
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        FullScreenDemoContentFactory.paperColor.resolvedColor(with: traitCollection).setFill()
        context.fill(bounds)
        guard wallpaper, bounds.width > 0, bounds.height > 0 else { return }
        let ink = FullScreenDemoContentFactory.inkColor.resolvedColor(with: traitCollection)
        context.setStrokeColor(ink.withAlphaComponent(0.035).cgColor)
        context.setLineWidth(0.5)
        for y in stride(from: bounds.minY, through: bounds.maxY, by: CGFloat(18)) {
            context.move(to: CGPoint(x: bounds.minX, y: y))
            context.addQuadCurve(to: CGPoint(x: bounds.maxX, y: y + 2),
                                 control: CGPoint(x: bounds.midX, y: y - 2))
        }
        context.strokePath()
    }

    /// - Parameter previousTraitCollection: 旧外观；底纸与线纹同时更新，无返回值。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { setNeedsDisplay() }
    }
}

/// 最多缓存三张源图；视图直接引用源图，不另存裁图或全书位图。
@MainActor
private final class FullScreenDemoImageCache {
    static let titles = ["溪口晨雾", "茶岭微风", "青桥晚照", "杉林雨后", "山站星光", "归途春信"]
    private var images: [String: UIImage] = [:]
    private var recency: [String] = []

    /// - Parameters: source: 源页序号；size: 精确源像素尺寸；traits: 当前外观。
    /// - Returns: 方向为 up、scale 为一的原始几何风景图。
    func image(source: Int, size: CGSize, traits: UITraitCollection) -> UIImage {
        let dark = traits.userInterfaceStyle == .dark
        let key = "\(source)-\(Int(size.width))-\(dark)"
        if let image = images[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return image
        }
        while images.count >= 3, let oldest = recency.first {
            recency.removeFirst()
            images.removeValue(forKey: oldest)
        }
        let image = drawImage(source: source, size: size, dark: dark)
        images[key] = image
        recency.append(key)
        return image
    }

    /// - Parameters: source: 源页序号；size: 整数像素尺寸；dark: 是否使用夜间配色。
    /// - Returns: 按需绘制的一张源图，标准色域避免扩展色彩像素预算。
    private func drawImage(source: Int, size: CGSize, dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let paper = dark ? UIColor(red: 0.15, green: 0.21, blue: 0.20, alpha: 1)
                         : UIColor(red: 0.86, green: 0.87, blue: 0.79, alpha: 1)
        let ink = dark ? UIColor(red: 0.74, green: 0.80, blue: 0.70, alpha: 1)
                       : UIColor(red: 0.13, green: 0.27, blue: 0.24, alpha: 1)
        let distant = dark ? UIColor(red: 0.22, green: 0.34, blue: 0.31, alpha: 1)
                           : UIColor(red: 0.54, green: 0.68, blue: 0.58, alpha: 1)
        let near = dark ? UIColor(red: 0.12, green: 0.28, blue: 0.25, alpha: 1)
                       : UIColor(red: 0.27, green: 0.49, blue: 0.41, alpha: 1)
        let warmth = dark ? UIColor(red: 0.60, green: 0.49, blue: 0.32, alpha: 1)
                         : UIColor(red: 0.79, green: 0.60, blue: 0.35, alpha: 1)
        let wide = size.width > size.height
        let columns = wide ? 2 : 1
        let rows = wide ? 3 : 6
        return renderer.image { output in
            let context = output.cgContext
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for row in 0..<rows {
                for column in 0..<columns {
                    let region = CGRect(x: CGFloat(column) * size.width / CGFloat(columns),
                                        y: CGFloat(row) * size.height / CGFloat(rows),
                                        width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
                    let panel = region.insetBy(dx: 16, dy: 12)
                    context.saveGState()
                    context.clip(to: panel)
                    distant.withAlphaComponent(0.13).setFill()
                    context.fill(panel)
                    let sun = CGRect(x: panel.minX + panel.width * (0.68 - CGFloat(source % 3) * 0.12),
                                     y: panel.minY + panel.height * 0.24, width: 38, height: 38)
                    warmth.setFill()
                    context.fillEllipse(in: sun)
                    for layer in 0..<2 {
                        let path = UIBezierPath()
                        let baseline = panel.minY + panel.height * (layer == 0 ? 0.78 : 0.94)
                        path.move(to: CGPoint(x: panel.minX - 10, y: baseline))
                        for peak in 0..<5 {
                            let x = panel.minX + panel.width * CGFloat(peak) / 4
                            let variation = CGFloat((source + row + peak * 2 + column) % 4) * 0.045
                            let y = panel.minY + panel.height * (0.43 + CGFloat(layer) * 0.18 + variation)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: panel.maxX + 10, y: panel.maxY))
                        path.addLine(to: CGPoint(x: panel.minX - 10, y: panel.maxY))
                        path.close()
                        (layer == 0 ? distant : near).setFill()
                        path.fill()
                    }
                    let river = UIBezierPath()
                    river.move(to: CGPoint(x: panel.midX, y: panel.minY + panel.height * 0.63))
                    river.addCurve(to: CGPoint(x: panel.minX + panel.width * 0.35, y: panel.maxY),
                                   controlPoint1: CGPoint(x: panel.minX + panel.width * 0.75, y: panel.minY + panel.height * 0.75),
                                   controlPoint2: CGPoint(x: panel.minX + panel.width * 0.12, y: panel.minY + panel.height * 0.83))
                    river.lineWidth = panel.width * 0.023
                    paper.withAlphaComponent(0.65).setStroke()
                    river.stroke()
                    warmth.setFill()
                    context.fill(CGRect(x: panel.midX - 28, y: panel.minY + panel.height * 0.77, width: 64, height: 6))
                    context.restoreGState()
                    let number = row * columns + column + 1
                    let side = wide ? (column == 0 ? "左" : "右") : "纵向"
                    let label = "图 \(source + 1) · 分区 \(number) · \(side)"
                    drawLabel(label, in: CGRect(x: panel.minX + 12, y: panel.minY + 45,
                                               width: panel.width - 24, height: 36), size: 25, color: ink)
                    drawLabel("y \(Int(region.minY))—\(Int(region.maxY))", in: CGRect(x: panel.minX + 12,
                              y: panel.maxY - 35, width: panel.width - 24, height: 26), size: 18, color: ink)
                }
            }
            // 四角标记直接落在源图上，宽图拆半与长图末片都能核对完整性。
            let cornerWidth: CGFloat = wide ? 240 : 205
            let cornerSize: CGFloat = wide ? 26 : 21
            drawLabel("① 左上 · \(source + 1)", in: CGRect(x: 22, y: 20, width: cornerWidth, height: 34), size: cornerSize, color: ink)
            drawLabel("② 右上 · \(source + 1)", in: CGRect(x: size.width - cornerWidth - 22, y: 20,
                      width: cornerWidth, height: 34), size: cornerSize, color: ink, alignment: .right)
            drawLabel("③ 左下 · \(source + 1)", in: CGRect(x: 22, y: size.height - 44,
                      width: cornerWidth, height: 32), size: cornerSize, color: ink)
            drawLabel("④ 右下 · \(source + 1)", in: CGRect(x: size.width - cornerWidth - 22,
                      y: size.height - 44, width: cornerWidth, height: 32), size: cornerSize, color: ink, alignment: .right)
            drawLabel(Self.titles[source], in: CGRect(x: size.width / 2 - 110, y: size.height / 2 - 25,
                      width: 220, height: 50), size: 32, color: ink, alignment: .center)
        }
    }

    /// - Parameters: text: 源图标签；rect: 源像素坐标；size: 像素字号；color: 固定配色；alignment: 对齐；无返回值。
    private func drawLabel(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor,
                           alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color, .paragraphStyle: style
        ])
    }
}

// MARK: - 长文《三國演義》导入与分页

private struct FullScreenDemoStoryPage {
    let title: String
    let paragraphs: [String]
    var quoteParagraph: Int? = nil
    var emphasis: String? = nil
}

private enum FullScreenDemoArticleLoader {
    static let title = "三國演義"
    static let fallbackTitle = "山间来信"
    private static let resourceName = "LongArticle"
    /// 单页正文字数上限，与内置短篇每页约三段的密度接近，避免页内裁切。
    private static let pageBudget = 280
    private static let longTitleBudget = 200
    private static let longTitleLength = 12
    /// 片段达到该长度后即可在句末断开；不足时并到下一句。
    private static let softLimit = 100
    private static let pieceLimit = 160
    private static let piecesPerPage = 3
    private static let quoteLimit = 80
    private static let emphasisLimit = 12

    static let pages: [FullScreenDemoStoryPage]? = load()

    /// 实际可用的正文总标题；资源不可用时回到内置短篇。
    static var resolvedTitle: String { pages == nil ? fallbackTitle : title }

    private static func load() -> [FullScreenDemoStoryPage]? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let result = paginate(text)
        return result.isEmpty ? nil : result
    }

    /// 按章节标记与句读切分长文，再装入每页不超过 `pageBudget` 字的页面。
    private static func paginate(_ text: String) -> [FullScreenDemoStoryPage] {
        var pages: [FullScreenDemoStoryPage] = []
        var chapterTitle = ""
        var chapterLabel = ""
        var chapterStarted = false
        var pageTitle = ""
        var pageLimit = pageBudget
        var pieces: [String] = []
        var used = 0

        func beginPage() {
            pageTitle = chapterStarted ? chapterLabel + "（續）" : chapterTitle
            pageLimit = pageTitle.count > longTitleLength ? longTitleBudget : pageBudget
            chapterStarted = true
            pieces.removeAll(keepingCapacity: true)
            used = 0
        }

        func flush() {
            guard !pieces.isEmpty else { return }
            pages.append(.init(title: pageTitle, paragraphs: pieces,
                               quoteParagraph: quoteIndex(in: pieces), emphasis: emphasis(in: pieces)))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("## ") {
                flush()
                chapterTitle = String(line.dropFirst(3))
                chapterLabel = chapterTitle.split(separator: "：").first.map(String.init) ?? chapterTitle
                chapterStarted = false
                beginPage()
                continue
            }
            if pageTitle.isEmpty { beginPage() }
            for piece in paragraphPieces(line) {
                if !pieces.isEmpty, pieces.count >= piecesPerPage || used + piece.count > pageLimit {
                    flush()
                    beginPage()
                }
                pieces.append(piece)
                used += piece.count
            }
        }
        flush()
        return pages
    }

    private static let terminators: Set<Character> = ["。", "！", "？", "…"]
    private static let closers: Set<Character> = ["」", "』", "”", "’", "）", ")"]
    private static let commaLike: Set<Character> = ["，", "、", "；", "：", ",", ";"]

    /// 把整段切成 `softLimit`…`pieceLimit` 字的片段：先在句末断开，超长句退到逗号类标点。
    private static func paragraphPieces(_ paragraph: String) -> [String] {
        var result: [String] = []
        var current: [Character] = []
        let characters = Array(paragraph)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            if terminators.contains(character) {
                while index < characters.count, closers.contains(characters[index]) {
                    current.append(characters[index])
                    index += 1
                }
                // 句子太短时继续累积，避免每句独占一段。
                guard current.count >= softLimit else { continue }
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
                continue
            }
            guard current.count >= pieceLimit else { continue }
            if let cut = current.lastIndex(where: { commaLike.contains($0) }), cut >= pieceLimit / 2 {
                result.append(String(current[...cut]))
                current = Array(current[(cut + 1)...])
            } else {
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 页内首个以「开头的短段按引用样式渲染。
    private static func quoteIndex(in pieces: [String]) -> Int? {
        pieces.firstIndex { $0.hasPrefix("「") && $0.count <= quoteLimit }
    }

    /// 取页内第一处「……」的内部文字作为加粗强调，保持示例的排版层次。
    private static func emphasis(in pieces: [String]) -> String? {
        for piece in pieces {
            guard let open = piece.firstIndex(of: "「"),
                  let close = piece[piece.index(after: open)...].firstIndex(of: "」") else { continue }
            let inner = String(piece[piece.index(after: open)..<close])
            if !inner.isEmpty, inner.count <= emphasisLimit { return inner }
        }
        return nil
    }
}

// MARK: - 内置原创短篇《山间来信》（长文资源缺失时的回退）

private enum FullScreenDemoStory {
    static let pages: [FullScreenDemoStoryPage] = FullScreenDemoArticleLoader.pages ?? legacyPages
    private static let legacyPages: [FullScreenDemoStoryPage] = [
        .init(title: "山间来信 · 旧邮袋", paragraphs: [
            "林澈回到青岚镇的那天，雨刚停。外婆留下的木屋贴着山脚，檐下仍挂着一只褪色的蓝邮袋。他原本只打算住三天，把旧家具归拢，再赶回城里。钥匙转动时，门后落下几粒干桂花，香气竟没有散尽。",
            "邮袋里只有一封信，信封没有邮票，收件人写着外婆的小名。林澈认得那种细而向右倾斜的字，小时候它总出现在装茶叶的纸包上。他把信放在桌边，先去烧水，却接连两次忘了往壶里添满。",
            "窗外的河水比记忆中浅，石阶露出长长一截。等水终于响了，他才拆开信。纸上说，山顶的梅树今年开得很晚，若有人经过旧观测站，请替写信的人看看，门前那把长椅是否还在。"
        ], emphasis: "门前那把长椅是否还在"),
        .init(title: "青石桥上的早晨", paragraphs: [
            "第二天，林澈拿着信去镇口买早点。青石桥旁的豆浆摊换了新棚子，掌勺的却还是阿禾。她认出他，先往碗里添了一勺糖，才问这次能住多久。林澈说不准，只把信封压在装油条的盘子底下。",
            "阿禾擦干手，低头看了看字迹。她说，前些年常有一个背帆布包的老人从山上下来，替观测站取报纸，也会到外婆屋里喝茶。后来山路塌过一次，老人来得少了，大家便以为他已经搬走。",
            "桥下有个孩子追着纸船跑，纸船碰到石头，转了半圈又顺水滑开。林澈忽然想起外婆教他折船的手势。他向阿禾借了一张镇里的旧地图，在山顶画了一个很轻的圈，像怕惊醒什么似的。"
        ]),
        .init(title: "没有门牌的地址", paragraphs: [
            "镇上的邮政代办点藏在杂货铺后面。周伯退休以后仍来帮忙，把寄往各村的信按路程分好。他看见那只蓝邮袋，伸手摸了摸缝线，说这不是邮局发的，是林澈的外婆用旧围裙改出来的。",
            "从前山里几处人家没有门牌，外婆便让信先寄到自己家。谁来赶集，她就把信捎给谁；遇到连阴雨，她还会把纸封在糖果铁盒里。林澈一直以为，檐下的邮袋只用来收他从学校寄回的成绩单。",
            "周伯翻出一本薄册子，找到观测站旁的名字：沈砚。后面没有电话号码，只有一行铅笔小字，写着沿杉树林上行，听见水声向左。他抄好地址，才发现这条路并不在昨天借来的地图上。"
        ], emphasis: "沿杉树林上行，听见水声向左"),
        .init(title: "纸上的河流", paragraphs: [
            "午后起了风，林澈把旧地图铺在桌上，用茶杯压住四角。地图上的河拐了三个弯，如今从窗口望出去，却只看得见两个。外婆在背面记着几户人家的住址，字迹有新有旧，像一条慢慢长出的支流。",
            "他沿着河岸走到旧渡口。渡船早已收起，岸边新种的柳树细得还撑不起一片阴凉。一个洗菜的婶婶告诉他，第三道河湾改了水渠，原来住在那里的人搬到坡上，门前各有一棵柿子树。",
            "回屋后，林澈没有修改旧地图，只另取一张纸，把今天走过的路画下来。他在渡口旁写上柳树，在坡顶画上柿子。那些地名忽然有了声音和气味，不再只是纸面上几个可以随手划掉的点。"
        ]),
        .init(title: "修表铺的灯", paragraphs: [
            "程叔的修表铺傍晚才亮灯，玻璃柜里摆着许多不再走动的钟。林澈送去外婆床头那只闹钟，顺便问起沈砚。程叔放下放大镜，说他曾在观测站记录雨量，退休以后，仍舍不得山上那间小屋。",
            "“你外婆替他带信，他替你外婆修屋檐，两个人都不爱欠账，结果一欠就是二十多年。前年他腿伤了，就托别人捎东西下来。至于最近的情形，我也不清楚。山里人不说难处，常把消息说得太轻。”",
            "那只闹钟换了发条，重新响起来，声音大得让两个人都笑了。林澈付钱时看见柜台角落有一叠空白明信片，便买下三张。出门后，他给城里的同事发了消息，把返程日期往后推了一周。"
        ], quoteParagraph: 1),
        .init(title: "第一封回信", paragraphs: [
            "林澈很久没有认真写过信了。第一张纸上，他只写了称呼就划掉；第二张又写得像一份办事通知。他把笔搁在窗台，看天色一点点暗下来，终于明白自己迟迟下不了笔，是不知怎样告诉对方外婆已不在了。",
            "“沈先生，来信收到了。我是林澈，小时候住在河边木屋里。外婆去年冬天走得很安静，屋檐已经修好，蓝邮袋也还在。我准备上山看看长椅。如果您方便，我想当面听您讲讲那里的梅树。”",
            "信写好以后，他没有急着封口，又添上一句：您不必为接待我做准备。夜里，闹钟在隔壁走得清清楚楚。他把信和地图放进背包，第一次觉得这间老屋并非等待清空，而是在等人坐下来。"
        ], quoteParagraph: 1, emphasis: "是在等人坐下来"),
        .init(title: "杉树下的岔路", paragraphs: [
            "上山那天，阿禾塞给林澈两个热饭团。山路开头很宽，经过最后一片菜地，便窄成泥土上的一道浅痕。他走得太快，没多久就要停下来喘气。杉树的影子一层层叠在鞋面上，露水把裤脚染深了。",
            "在第一处岔路，他没有听见水声，倒听见了鸡叫。守着茶园的老人从篱笆后探头，指他退回去，看一块长着白苔的石头。林澈依言走了几十步，才发现溪流藏在蕨叶下面，声音细得像有人轻轻翻书。",
            "他取出新画的地图，给岔路添了石头和鸡舍。笔尖停住时，一只小鸟落在近处的枝上，歪头看他。林澈收好纸，忽然不再急着赶到山顶。原来一条路的远近，也取决于有没有人肯慢慢认它。"
        ]),
        .init(title: "茶园里的空椅子", paragraphs: [
            "中午的雾从茶垄之间升起来，林澈走到一间瓦顶小屋。门口摆着三把竹椅，最旧的一把断了半边扶手。屋主人姓许，听说他去找沈砚，便请他坐下吃饭，还特地把靠近火盆的位置空了出来。",
            "许婶说，沈砚过去下山总在这里歇脚，不大讲话，却每次都把松动的竹篱重新扎好。后来腿脚不便，他托人送来一包新钉子，说下回再来修椅子。那包钉子一直放在碗柜里，纸角都磨软了。",
            "林澈吃完饭，借来锤子，把断扶手临时固定好。手艺并不漂亮，许婶试着压了两下，却说这样就很好。他临走时，她追到门边，递来一小包茶叶，让他告诉山上的人，椅子已经有人接着修了。"
        ], emphasis: "椅子已经有人接着修了"),
        .init(title: "雾中借宿", paragraphs: [
            "午后的雾越来越厚，前面的石阶只剩三四级可见。林澈依着许婶叮嘱，在护林屋前停下来。值守的姑娘叫小满，正在补一张窗纱。她看了看天，说今天不适合再往上走，空床上的被子倒是刚晒过。",
            "两人煮了一锅面，把饭团切开当作配菜。小满说自己刚调来时，总把雾当作坏天气，后来才学会辨认它的厚薄与走向。有些雾只是停在谷底，有些会把山脊一并藏起，急着穿过去反而更容易绕远。",
            "睡前，林澈把信从背包里取出，放进干燥的内袋。窗外没有星星，山里却不完全安静。水滴落在铁桶上的声音隔一会儿就响一下，像有人守着一只很慢的钟，把这个意外多出的夜晚妥善收好。"
        ]),
        .init(title: "旧观测站", paragraphs: [
            "第二天清早，小满送林澈到山脊。雾退到脚下，旧观测站露出一面泛白的墙。门前确有一把长椅，一端垫着石块，椅面却擦得很干净。梅树长在围墙外，花已经谢尽，枝头结着青得发亮的小果。",
            "沈砚比林澈想象中瘦，拄着拐杖来开门。他接过信，没有立刻拆，只问一路是否好走。听到许婶的椅子修好了，老人笑了一下，又把那包茶叶抱在膝上，仿佛接到了一件颇有分量的礼物。",
            "屋里仍摆着旧仪器，玻璃罩擦得没有灰。林澈替他烧水，背对着桌子，听见拆信的纸声很轻地停住。过了好一阵，沈砚才说，怪不得去年冬天那场雪以后，再没有人寄来用桂花熏过的纸。"
        ]),
        .init(title: "蓝皮记录本", paragraphs: [
            "午后，沈砚从柜子里搬出几本蓝皮记录簿。雨量、风向和日期排得整整齐齐，有些数字旁边还画着很小的圆圈。他说那是暴雨的日子，山下哪条路容易积水，从这些旧页里往往能找到一些来由。",
            "记录簿最后夹着一张便条，是外婆写的：河边第三户的孩子怕雷，若看见大雨要来，烦请早些捎个口信。林澈认出那第三户就是自己的家。他以为早已忘记的夏夜，忽然随着纸上的字重新亮了起来。",
            "沈砚说，天气预报后来越来越准，大家也都有了电话，可他还是习惯把每天的云记下来。林澈翻到最近一页，看见老人除了写风向，还记了一句：午后有燕子沿旧路上山，像是认得这里的门。"
        ], emphasis: "河边第三户的孩子怕雷"),
        .init(title: "屋檐下的约定", paragraphs: [
            "临走前，林澈提出把蓝皮本带下山整理。沈砚没有马上答应，先问那些不合用的旧数字会不会被丢掉。林澈想了想，说自己可以先一页页抄录，遇到看不清的地方再来问，原本仍留在站里。",
            "“我不是怕你弄坏，”老人说，“只是有些日子看起来没有什么可记，真的翻过去，又舍不得。你外婆常说，信写得长短不要紧，让人知道你今天好好吃了饭，也算是值得送一趟的消息。”",
            "林澈在长椅上坐了一会儿，把外婆的死讯说得更完整，也讲了她最后一次煮桂花茶的情形。沈砚听着，缓缓把拐杖靠到墙边。他们约好下次带新纸来，屋檐漏雨的地方，也一起想个办法。"
        ], quoteParagraph: 1),
        .init(title: "雨来之前", paragraphs: [
            "回到镇上第三天，天气预报说将有连续降雨。林澈原本准备整理记录簿，见云层压低，先去找周伯借了一辆小推车。他和阿禾把木屋门口的沟清通，又将邮袋抬高半尺，屋里散着湿泥和茶梗的气味。",
            "下午，小满打来电话，说通往观测站的近路有落石，暂时封了。沈砚已收到提醒，粮食和药都够用，只是站里的旧电话时好时坏。林澈把消息记在纸上，贴到门边，免得有人冒雨上去找他。",
            "雨到傍晚才落，先是几点，随后整个河面都起了白沫。林澈站在窗边，听见修表铺提前关门的声音。他给沈砚写了一张短笺，准备等路稳妥后再带上山：这边一切安好，您先别惦记屋檐。"
        ]),
        .init(title: "最后一盏灯", paragraphs: [
            "夜里镇上短暂停电，林澈找出外婆的煤油灯，却发现灯芯已经硬了。阿禾隔着雨敲门，送来一盏充好电的小灯。两人坐在门边等消息，谁也没有提起害怕，只轮流把快溢出的水桶搬到院子里。",
            "快到十点，小满发来平安消息，说观测站的灯还能亮着。林澈松了口气，才发觉自己一直攥着手机。阿禾说，小时候她晚归，只要看见这间屋里亮灯，就知道有人肯借一把伞，也不会先问为什么回来迟了。",
            "后来电恢复了，小灯仍留在桌上。雨声里，林澈翻到外婆账本的末页，那里记着借出去的雨伞，名字后面没有催还的日期。他合上本子，把门廊的灯打开，让它照着那段积了水、却仍能辨认的石阶。"
        ], emphasis: "也不会先问为什么回来迟了"),
        .init(title: "绕远的路", paragraphs: [
            "雨停以后，近路仍未开放。小满约了熟悉山道的维修员，从茶园背面绕行上山，林澈带着补屋顶的材料同行。这条路比原来长许多，却有缓缓的坡，不必攀过那些被水浸松的石阶。",
            "走到一处开阔地时，他们看见山下的河像一根重新拉直的线。维修员指着远处的屋顶，挨个报出人家的姓氏。林澈在地图上添了几笔，忽然发现，自己画的不是去观测站的捷径，而是沿路可以敲门的地方。",
            "中途休息，他拿出阿禾准备的饭菜。小满把一块平石擦干，当作小小的桌面。大家慢慢吃完，收净纸袋，再向山里走。背包依然沉，可林澈已不觉得绕路只是耽搁，有些相识原本就发生在多走的几步里。"
        ]),
        .init(title: "河边等消息的人", paragraphs: [
            "观测站的屋顶补好时，已经过了午后。沈砚试着站到长椅旁，把一封写给许婶的信交给林澈，又托他替周伯带一句谢意。下山的背包轻了许多，却多出几张薄纸，每一张都有一个正在等它的人。",
            "许婶收到信，没舍得立刻拆，先往众人的水壶里添了热茶。到了镇口，周伯正在桥边看水位，听说山上无事，便把雨衣叠起来夹在腋下。他问新路好不好走，说等膝盖舒服些，也想上去坐坐。",
            "林澈一一回完消息，天色才真正暗下来。他原本以为自己只是替外婆送一次回信，如今却觉得，那只邮袋连着的不止一个地址。河边有许多人各自忙着，只要知道彼此平安，手上的事便能安心继续。"
        ], emphasis: "每一张都有一个正在等它的人"),
        .init(title: "没有寄出的那封", paragraphs: [
            "整理书柜时，林澈在一本旧诗集里找到写给自己的信。信纸没有折过，开头说天气转凉，要记得加衣，后面却停在半句。他辨认了很久，才读出外婆想问他春节是否回来，又把问句轻轻划掉了。",
            "他想起那年自己忙着搬家，接电话总说过几天再聊。外婆从不责怪，只说饭要趁热吃。他坐在地板上，直到窗前的光移到了脚边，才把信放回桌面。纸上没有任何指责，反而让他不知该往哪里安放后悔。",
            "傍晚，他给母亲打了一个很长的电话，讲木屋、山路和那把长椅。母亲没有劝他别难过，只说自己下周能来看看。挂断以后，林澈把两只杯子洗净，倒扣在窗边，第一次提前为一个约定准备好了地方。"
        ]),
        .init(title: "把名字写清楚", paragraphs: [
            "母亲到镇上的那天，带来一箱旧照片。两人在桌边认人，常常认到一半便笑起来。外婆年轻时站在桥头，肩上挂着还未褪色的蓝邮袋；旁边那位拿着雨量筒的青年，眉眼间已能看出沈砚的样子。",
            "许多照片背后没有名字。林澈怕以后再无人记得，拿出软铅笔，一张张请母亲补上。遇见记不准的，他们就去问阿禾与周伯。原来那个被大家一直叫作许婶的人，名字里有个温柔的“岚”字。",
            "晚上，林澈把照片装进新纸套，写清年月和地点。他没有把模糊的部分猜着补全，而是留下一小段空白。母亲说，这样也好，等下一位记得的人来了，还能坐在这里，把剩下的话慢慢讲完。"
        ], emphasis: "等下一位记得的人来了"),
        .init(title: "晴日整理", paragraphs: [
            "接连几天都是晴天，院子里晾着洗净的窗帘。林澈把沈砚借来的两本记录簿摊在桌上，按日期逐页整理。数字旁那些看似随意的注记，比表格更让他停留：某日河水浑，某日有人送来第一筐春笋。",
            "抄到一处难认的名字，他没有自行改写，而是放了一张小纸签。午后沈砚打来电话，慢慢解释那是旧时一条溪的名字，现在只剩附近几户人还这样称呼。他说完又笑，没想到过了这么久，还有人认真问起它。",
            "林澈另备了一本册子，收下这些地方的旧称，也写上如今能找到它们的路。窗帘在风里鼓起，他抬头看见母亲坐在檐下择菜。屋子里的东西并没有减少多少，日子却开始变得宽敞起来。"
        ]),
        .init(title: "新的邮路", paragraphs: [
            "周伯提议在杂货铺留一本登记册，让愿意顺路捎信的人写下去向。林澈帮他做了封面，没有取响亮的名字，只写“山里来往”。阿禾第一个签名，说自己每周去茶园收茶，几张信纸不占篮子的地方。",
            "他们约定，只收封好的信，交到本人手里；下雨或封路便等一等，不催任何人为送信赶险路。许婶听说以后，特意送来一个能扣紧的铁盒，里面铺着干净布，说茶香重一点，也好过纸被雨打湿。",
            "登记册第一页只写了三个地址，看起来很空。周伯却满意地把它放到柜台边，压上一块光滑的石头。林澈伸手摸了摸那块石头，觉得许多可以长久做下去的事，开始时或许都不需要太热闹。"
        ], emphasis: "下雨或封路便等一等"),
        .init(title: "陌生的笔迹", paragraphs: [
            "第一封通过新邮路送来的信，收件人竟是林澈。字迹圆圆的，信封角上画着一只笨拙的燕子。他拆开才知道，是茶园那位总追纸船的孩子写来的。孩子听说他会画地图，想请他标出一条去看梅树的路。",
            "“妈妈说路太远，我要先把饭吃好，长高一点才走得动。你能不能先告诉我，山上能看见河吗？我折的纸船每次都往桥底下跑，如果它一直走，会不会有一天绕到山的另一边去？”",
            "林澈没有急着讲河流的方向，而是画了一张很小的图，把桥、茶园和梅树连起来。他在旁边写，等路干了，可以和大人一起慢慢走。最后又画了一只纸船，让它停在一处有柳树的岸边，等想象继续出发。"
        ], quoteParagraph: 1),
        .init(title: "山口重逢", paragraphs: [
            "入夏前，沈砚终于答应下山住几天。小满和维修员陪他走那条缓坡，林澈在茶园外等着。老人停下来歇脚时，先去看修好的竹椅，用手掌在扶手上按了按，说钉子的位置还可以再往里一点。",
            "许婶故意把锤子递过来，让他自己挑合适的时候修。几个人坐满了门前的椅子，茶水续了一轮又一轮。沈砚讲起从前测雨的夜晚，说最难的并非数字，而是半夜爬起来以后，总想再赖回被窝几分钟。",
            "下到山口，周伯推着车来接，阿禾站在桥另一头挥手。林澈扶老人走过青石桥，听见拐杖敲在石上的声音十分清楚。他忽然觉得，信纸上绕了很久的那些地址，此刻正一个接一个地变成可以看见的面孔。"
        ]),
        .init(title: "邮袋还在檐下", paragraphs: [
            "林澈还是要回城处理工作。他提前买了车票，把木屋的钥匙交给阿禾，约好每个月回来住几天。院子里的花交给母亲照看，登记册留在杂货铺，整理到一半的旧地图则放进柜子，等下一次继续。",
            "出发前，沈砚坐在门边，替蓝邮袋补了一处磨开的线脚。他年轻时缝过仪器套，针脚比林澈整齐得多。两个人都没有说以后一定如何，只认真核对了通信地址，把容易写错的门牌数字又描深了一遍。",
            "车开出镇口时，林澈隔着玻璃看见山脊上的云。他不再把离开想成关上一扇门。背包里装着几张新信纸，还有一小包茶叶；河边那间屋的邮袋仍在檐下，谁经过，都知道那里还有人愿意收信。"
        ], emphasis: "他不再把离开想成关上一扇门"),
        .init(title: "春天的落款", paragraphs: [
            "来年春天，林澈收到一封厚一些的信。里面没有照片，只有沈砚画的梅枝和孩子添上的纸船。许婶写茶园开了新芽，阿禾说桥边的柳树终于有了阴凉，周伯在最后提醒他，回镇时别忘了带那张尚未画完的地图。",
            "林澈读了两遍，把信放在办公室的窗边。窗外没有山，街上的车流正慢慢亮起灯。他抽出一张纸，先写今天吃过的晚饭，又写附近新开的小书店。等写完这些平常事，纸面上已经盛满了想带回去的生活。",
            "他在落款旁添上日期，没有许下盛大的愿望，只说下次来时想沿新路走一走。封口之前，他想起那年第一次拆信的黄昏，便又补了一行：我这里也到了春天。信寄出以后，他知道山里会有人把这句话读给别人听。"
        ], emphasis: "我这里也到了春天")
    ]
}
