#if canImport(UIKit)
import UIKit
import CoreText
import BonePageTurnKit

/// 仅供接缝验收的有界章节排版；原始 CTLine 不因分块而对子串重新排版。
/// 图片附件和异步渲染不在此 fixture 的覆盖范围内。
@MainActor
final class ContinuousTypographyFixture {
    enum FixtureError: Error { case invalidInput, incompleteFrame, invalidPartition, missingPosition }

    // MARK: - 原始章节行与分块几何

    struct Line {
        let index: Int
        let ctLine: CTLine
        let range: NSRange
        let coreTextOrigin: CGPoint
        let baseline: CGPoint
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
        let inkBounds: CGRect
        let paintBounds: CGRect
        let startsParagraph: Bool
        let endsParagraph: Bool
    }

    struct Block {
        let item: ContinuousItem
        let lineIndices: Range<Int>
        let origin: CGFloat
    }

    let text: NSAttributedString
    let frame: CTFrame
    let width: CGFloat
    let lines: [Line]
    let height: CGFloat
    let layoutVersion: UInt64
    private let sectionID = "typography-chapter"

    /// - Parameters: width: 所有块统一的外宽；fontSize: 正文字号；lineSpacing: 行距；paragraphSpacing: 段后距；paragraphSpacingBefore: 段前距；repetitions: 有界正文重复次数；layoutVersion: 宿主布局版本。
    /// - Throws: 参数无效或有限 CTFrame 未容纳完整章节。
    init(width: CGFloat = 300, fontSize: CGFloat = 17.25, lineSpacing: CGFloat = 4.375,
         paragraphSpacing: CGFloat = 12.625, paragraphSpacingBefore: CGFloat = 5.125,
         repetitions: Int = 3, layoutVersion: UInt64 = 1) throws {
        guard width > 80, width.isFinite, fontSize > 0, fontSize.isFinite,
              (1...30).contains(repetitions) else { throw FixtureError.invalidInput }
        let text = Self.styledText(fontSize: fontSize, lineSpacing: lineSpacing,
                                   paragraphSpacing: paragraphSpacing,
                                   paragraphSpacingBefore: paragraphSpacingBefore, repetitions: repetitions)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var fitted = CFRange()
        let maximumHeight: CGFloat = 100_000
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: text.length), nil,
            CGSize(width: width - 24, height: maximumHeight), &fitted)
        let frameHeight = ceil(suggested.height) + fontSize * 4 + 32
        guard fitted.length == text.length, frameHeight < maximumHeight else { throw FixtureError.incompleteFrame }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width - 24, height: frameHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location == 0, visible.length == text.length,
              let ctLines = CTFrameGetLines(frame) as? [CTLine], !ctLines.isEmpty else {
            throw FixtureError.incompleteFrame
        }
        var origins = Array(repeating: CGPoint.zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let source = text.string as NSString
        var lines: [Line] = []
        var consumed = 0
        for (index, line) in ctLines.enumerated() {
            let range = CTLineGetStringRange(line)
            guard range.location == consumed, range.length > 0 else { throw FixtureError.incompleteFrame }
            consumed += range.length
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let baseline = CGPoint(x: 12 + origins[index].x, y: 8 + frameHeight - origins[index].y)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let ink = CGRect(x: baseline.x + glyphs.minX, y: baseline.y - glyphs.maxY,
                             width: glyphs.width, height: glyphs.height)
            let typographic = CGRect(x: baseline.x, y: baseline.y - ascent,
                                     width: advance, height: ascent + descent)
            // 彩色 emoji 可能没有字形路径；排版边界也参与绘制范围，避免遗漏其位图字形。
            let paint = glyphs.isNull || glyphs.isEmpty ? typographic : typographic.union(ink)
            lines.append(Line(index: index, ctLine: line,
                              range: NSRange(location: range.location, length: range.length),
                              coreTextOrigin: origins[index], baseline: baseline,
                              ascent: ascent, descent: descent, leading: leading,
                              inkBounds: ink, paintBounds: paint,
                              startsParagraph: range.location == 0 || source.character(at: range.location - 1) == 10,
                              endsParagraph: consumed == source.length || source.character(at: consumed - 1) == 10))
        }
        guard consumed == text.length else { throw FixtureError.incompleteFrame }
        self.text = text
        self.frame = frame
        self.width = width
        self.lines = lines
        self.height = (lines.map { $0.paintBounds.maxY }.max() ?? 0) + 8
        self.layoutVersion = layoutVersion
    }

    /// - Parameter lineCounts: 循环使用的完整行数，例如 [2, 3] 表示交替按两行、三行分块。
    /// - Returns: 原点与高度均保留小数；跨块间距已包含在相邻首行基线差中。
    /// - Throws: 空分组或非正行数。
    func blocks(lineCounts: [Int]) throws -> [Block] {
        guard !lineCounts.isEmpty, lineCounts.allSatisfy({ $0 > 0 }), let first = lines.first else {
            throw FixtureError.invalidPartition
        }
        var ranges: [Range<Int>] = []
        var cursor = 0
        while cursor < lines.count {
            let end = cursor + min(lineCounts[ranges.count % lineCounts.count], lines.count - cursor)
            ranges.append(cursor..<end)
            cursor = end
        }
        return ranges.enumerated().map { index, range in
            // 固定首基线偏移使所有非末块 extent 恰为相邻块首行全局基线之差。
            let origin = lines[range.lowerBound].baseline.y - first.baseline.y
            let end = index + 1 < ranges.count
                ? lines[ranges[index + 1].lowerBound].baseline.y - first.baseline.y : height
            let identity = PageItemIdentity(sourceID: sectionID, unitID: "typography-\(index)",
                                            contentVersion: 1, layoutVersion: layoutVersion)
            return Block(item: ContinuousItem(identity: identity, sectionID: sectionID,
                                               extent: Double(end - origin), reuseIdentifier: "ct-lines"),
                         lineIndices: range, origin: origin)
        }
    }

    /// - Parameters: position: 原文 UTF-16 位置；blocks: 当前布局分块；viewportOffset: 期望的屏幕基线位置。
    /// - Returns: 由原文字位置重新解析的本布局行锚点。
    /// - Throws: 文字位置不属于当前布局，或要求的屏幕位置无法用合法块内坐标表示。
    func anchor(atUTF16 position: Int, in blocks: [Block], viewportOffset: CGFloat) throws -> ContinuousAnchor {
        guard let line = lines.first(where: { NSLocationInRange(position, $0.range) }),
              let block = blocks.first(where: { $0.lineIndices.contains(line.index) }) else {
            throw FixtureError.missingPosition
        }
        let baselineOffset = Double(line.baseline.y - block.origin)
        // 字形允许超出占用容器；锚点必须留在 extent 内，并同步补偿屏幕偏移。
        let offset = min(max(0, baselineOffset), block.item.extent.nextDown)
        let screenOffset = Double(viewportOffset) - (baselineOffset - offset)
        guard screenOffset >= 0, screenOffset.isFinite else { throw FixtureError.missingPosition }
        return ContinuousAnchor(identity: block.item.identity, offsetInItem: offset, viewportOffset: screenOffset)
    }

    // MARK: - 原创富文本

    /// - Parameters: fontSize: 正文字号；lineSpacing: 行距；paragraphSpacing: 段后距；paragraphSpacingBefore: 段前距；repetitions: 段落组数。
    /// - Returns: 含原创中文、拉丁文、混合字号、粗体、引用底色和 emoji 的统一富文本。
    private static func styledText(fontSize: CGFloat, lineSpacing: CGFloat, paragraphSpacing: CGFloat,
                                   paragraphSpacingBefore: CGFloat, repetitions: Int) -> NSAttributedString {
        let paragraphs = [
            "清晨，河边的小书亭刚亮起灯。阿禾把昨夜写下的地图摊在桌上，沿着铅笔画出的弯道读下去。远处的电车轻轻转弯，窗上的光像一串没有落款的短句。她圈起重点词语，又在旁边写下 River 3.5，准备带着这份记录走到桥的另一端。🙂🌿",
            "“桥下的水不会替我们记住每一次停步。”老人说完，仍慢慢整理手里的旧书。引用里的留白保留着声音的节奏；同一段文字跨过视图边界时，缩进、底色和字形都应沿着原来的行继续。",
            "午后的纸页上有一个大字标记，也有细小注记。雨点在玻璃上留下不同大小的圆圈，gyp 与中文并排，像两种步伐走在同一条街上。阿禾合上笔记本，把尚未写完的话留给下一盏路灯。"
        ]
        let body = (0..<repetitions).flatMap { _ in paragraphs }.joined(separator: "\n")
            + "\n晚风收起最后一页，远处还亮着一扇窗。末行保留向下伸展的 gyp"
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = fontSize * 2
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        let result = NSMutableAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor(white: 0.12, alpha: 1),
            .paragraphStyle: style
        ])
        let source = body as NSString
        // 枚举所有重复片段；样式作用于整章，再交给同一个 framesetter。
        let variants: [(String, [NSAttributedString.Key: Any])] = [
            ("重点词语", [.font: UIFont.boldSystemFont(ofSize: fontSize)]),
            ("大字标记", [.font: UIFont.boldSystemFont(ofSize: fontSize + 7.375)]),
            ("细小注记", [.font: UIFont.systemFont(ofSize: max(7, fontSize - 3.125))]),
            ("River 3.5", [.font: UIFont.monospacedSystemFont(ofSize: fontSize + 1.625, weight: .medium)])
        ]
        for (fragment, attributes) in variants {
            var cursor = 0
            while cursor < source.length {
                let range = source.range(of: fragment, range: NSRange(location: cursor, length: source.length - cursor))
                guard range.location != NSNotFound else { break }
                result.addAttributes(attributes, range: range)
                cursor = NSMaxRange(range)
            }
        }
        let quote = NSMutableParagraphStyle()
        quote.headIndent = 14
        quote.firstLineHeadIndent = 30
        quote.tailIndent = -10
        quote.lineSpacing = lineSpacing
        quote.paragraphSpacing = paragraphSpacing
        quote.paragraphSpacingBefore = paragraphSpacingBefore
        var cursor = 0
        while cursor < source.length {
            let range = source.paragraphRange(for: NSRange(location: cursor, length: 0))
            if source.substring(with: range).hasPrefix("“") {
                result.addAttributes([.paragraphStyle: quote,
                                      .backgroundColor: UIColor(red: 0.85, green: 0.94, blue: 0.93, alpha: 1)], range: range)
            }
            cursor = NSMaxRange(range)
        }
        return result
    }
}

/// SDK 只排列外层容器；宿主为原始字形安排本地坐标和足够大的透明绘制子视图。
@MainActor
final class ContinuousTypographyBlockView: UIView {
    let canvas = ContinuousTypographyCanvas()
    private(set) var fixture: ContinuousTypographyFixture?
    private(set) var block: ContinuousTypographyFixture.Block?

    /// - Parameter frame: SDK 将设置的占用矩形。
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isOpaque = false
        backgroundColor = .clear
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用显式初始化") }

    /// - Parameters: fixture: 完整章节布局；block: 当前绑定的完整行分组。
    func configure(fixture: ContinuousTypographyFixture, block: ContinuousTypographyFixture.Block) {
        self.fixture = fixture
        self.block = block
        canvas.lines = Array(fixture.lines[block.lineIndices])
        let top = min(0, (canvas.lines.map { $0.paintBounds.minY }.min() ?? block.origin) - block.origin - 1)
        let bottom = max(CGFloat(block.item.extent),
                         (canvas.lines.map { $0.paintBounds.maxY }.max() ?? block.origin) - block.origin + 1)
        canvas.frame = CGRect(x: 0, y: top, width: fixture.width, height: bottom - top)
        canvas.globalOriginY = block.origin + top
        canvas.drawnRanges = []
        canvas.drawnBaselines = []
        canvas.setNeedsDisplay()
    }

    /// - Parameter line: 章节原始行。
    /// - Returns: 经真实绘制子视图坐标转换后的块内基线位置。
    func localBaseline(for line: ContinuousTypographyFixture.Line) -> CGPoint {
        canvas.convert(CGPoint(x: line.baseline.x, y: line.baseline.y - canvas.globalOriginY), to: self)
    }
}

@MainActor
final class ContinuousTypographyCanvas: UIView {
    var lines: [ContinuousTypographyFixture.Line] = []
    var globalOriginY: CGFloat = 0
    var drawnRanges: [NSRange] = []
    var drawnBaselines: [CGPoint] = []

    /// - Parameter frame: 足以容纳字形与引用底色的绘制范围。
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        contentScaleFactor = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用显式初始化") }

    /// - Parameter rect: UIKit 请求重绘的范围；每次绘制保留完整 CTLine 的字形与原始行位置。
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawnRanges = []
        drawnBaselines = []
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        for line in lines {
            let local = CGPoint(x: line.baseline.x, y: line.baseline.y - globalOriginY)
            let baseline = CGPoint(x: local.x, y: bounds.height - local.y)
            // CTLineDraw 不负责 NSBackgroundColor；宿主在相同 run 几何上画引用底色。
            if let runs = CTLineGetGlyphRuns(line.ctLine) as? [CTRun] {
                for run in runs {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let color = attributes[NSAttributedString.Key.backgroundColor.rawValue] as? UIColor else { continue }
                    let range = CTRunGetStringRange(run)
                    let start = CTLineGetOffsetForStringIndex(line.ctLine, range.location, nil)
                    let end = CTLineGetOffsetForStringIndex(line.ctLine, range.location + range.length, nil)
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: baseline.x + min(start, end), y: baseline.y - line.descent,
                                        width: abs(end - start), height: line.ascent + line.descent))
                }
            }
            context.textPosition = baseline
            CTLineDraw(line.ctLine, context)
            drawnRanges.append(line.range)
            drawnBaselines.append(local)
        }
        context.restoreGState()
    }
}

@MainActor
final class ContinuousTypographyProvider: ContinuousContentProvider {
    private struct Entry {
        let fixture: ContinuousTypographyFixture
        let block: ContinuousTypographyFixture.Block
    }
    private var entries: [PageItemIdentity: Entry] = [:]
    private(set) var views: [String: ContinuousTypographyBlockView] = [:]
    private(set) var bindings: [String: PageViewBinding] = [:]
    private(set) var createdViewCount = 0

    /// - Parameters: fixture: 可与旧版本同时保留的布局；blocks: 该版本全部分块。
    func register(_ fixture: ContinuousTypographyFixture, blocks: [ContinuousTypographyFixture.Block]) {
        for block in blocks { entries[block.item.identity] = Entry(fixture: fixture, block: block) }
    }

    /// - Parameter reuseIdentifier: SDK 请求的视图类别。
    /// - Returns: 可独立绘制原始 CTLine 的透明块容器。
    func makeContentView(reuseIdentifier: String) -> UIView {
        createdViewCount += 1
        return ContinuousTypographyBlockView(frame: .zero)
    }

    /// - Parameters: view: 新建或复用容器；item: 当前块元数据；binding: SDK 当前绑定。
    func bind(_ view: UIView, to item: ContinuousItem, binding: PageViewBinding) {
        guard let view = view as? ContinuousTypographyBlockView, let entry = entries[item.identity] else { return }
        views[item.identity.unitID] = view
        bindings[item.identity.unitID] = binding
        view.configure(fixture: entry.fixture, block: entry.block)
    }

    /// - Parameters: view: 已离屏容器；binding: 失效绑定。
    func unbind(_ view: UIView, binding: PageViewBinding) {
        guard bindings[binding.identity.unitID] == binding else { return }
        views.removeValue(forKey: binding.identity.unitID)
        bindings.removeValue(forKey: binding.identity.unitID)
    }
}
#endif
