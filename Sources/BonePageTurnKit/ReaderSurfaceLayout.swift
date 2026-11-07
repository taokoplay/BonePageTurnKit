import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 阅读外壳中随翻页运动的范围；各模式共享正文和装饰的布局坐标。
public enum ReaderSurfaceMotion: Sendable, Equatable {
    /// 仅正文运动，页眉、页脚和背景固定。
    case contentOnly
    /// 正文、页眉和页脚一起运动，背景固定。
    case contentAndChrome
    /// 整页运动，包括背景。
    case wholePage
}

/// 阅读外壳的输入、展示和交互错误，由几何模型及宿主容器共用。
public enum ReaderSurfaceError: Error, Equatable {
    case invalidMetrics
    case invalidBounds
    case invalidReadingFrame
    case invalidController
    case invalidDecoration
    case unsupportedPresentation
    case interactionInProgress
    case inactive
}

/// 页眉、页脚、正文间距和内边距；均以点为单位，不包含宿主已处理的安全区。
public struct ReaderSurfaceMetrics: Sendable, Equatable {
    public let headerHeight: CGFloat
    public let footerHeight: CGFloat
    public let headerGap: CGFloat
    public let footerGap: CGFloat
    public let bodyInsets: ReaderViewportInsets

    /// - Parameters: headerHeight: 页眉高度；footerHeight: 页脚高度；headerGap: 页眉与正文的间距；footerGap: 正文与页脚的间距；bodyInsets: 正文四边内边距。
    public init(headerHeight: CGFloat = 0, footerHeight: CGFloat = 0,
                headerGap: CGFloat = 0, footerGap: CGFloat = 0,
                bodyInsets: ReaderViewportInsets = .init()) {
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.headerGap = headerGap
        self.footerGap = footerGap
        self.bodyInsets = bodyInsets
    }

    /// 无参数及返回值；校验全部高度、间距和内边距，不预先累加这些值。
    /// - Throws: 任一数值非有限或小于零时抛出 `ReaderSurfaceError.invalidMetrics`。
    public func validate() throws {
        guard [headerHeight, footerHeight, headerGap, footerGap].allSatisfy({ $0.isFinite && $0 >= 0 }),
              [bodyInsets.top, bodyInsets.left, bodyInsets.bottom, bodyInsets.right]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ReaderSurfaceError.invalidMetrics
        }
    }
}

/// 同一坐标系中的阅读外壳几何；背景始终覆盖宿主的完整边界。
public struct ReaderSurfaceLayout: Sendable, Equatable {
    public let backgroundFrame: CGRect
    public let readingFrame: CGRect
    public let rendererFrame: CGRect
    public let bodyFrame: CGRect
    public let headerFrame: CGRect?
    public let footerFrame: CGRect?
    public let motion: ReaderSurfaceMotion

    /// 只保存传入值，便于宿主保存经过 UIKit 坐标转换的结果，不执行校验或重新布局。
    /// - Parameters: backgroundFrame: 背景；readingFrame: 阅读区域；rendererFrame: 翻页渲染区域；bodyFrame: 正文；headerFrame: 可选页眉；footerFrame: 可选页脚；motion: 运动范围。
    public init(backgroundFrame: CGRect, readingFrame: CGRect, rendererFrame: CGRect,
                bodyFrame: CGRect, headerFrame: CGRect?, footerFrame: CGRect?,
                motion: ReaderSurfaceMotion) {
        self.backgroundFrame = backgroundFrame
        self.readingFrame = readingFrame
        self.rendererFrame = rendererFrame
        self.bodyFrame = bodyFrame
        self.headerFrame = headerFrame
        self.footerFrame = footerFrame
        self.motion = motion
    }
}

public extension ReaderSurfaceMetrics {
    /// - Parameters: bounds: 背景完整边界；readingFrame: 宿主提供的阅读区域，默认等于 bounds，必须完整位于其中；motion: 随翻页运动的范围。
    /// - Returns: 保留原点和小数精度的布局；可用空间不足时逐步钳制，启用的装饰仍保留零高度槽位。
    /// - Throws: `ReaderSurfaceError.invalidMetrics`、`invalidBounds` 或 `invalidReadingFrame`。
    func layout(in bounds: CGRect, readingFrame: CGRect? = nil,
                motion: ReaderSurfaceMotion = .contentOnly) throws -> ReaderSurfaceLayout {
        try validate()
        guard isValid(bounds) else { throw ReaderSurfaceError.invalidBounds }
        let reading = readingFrame ?? bounds
        guard isValid(reading), reading.minX >= bounds.minX, reading.minY >= bounds.minY,
              reading.maxX <= bounds.maxX, reading.maxY <= bounds.maxY else {
            throw ReaderSurfaceError.invalidReadingFrame
        }

        var vertical = ReaderSurfaceSpan(origin: reading.origin.y, length: reading.height)
        let header = vertical.consumeLeading(headerHeight)
        let footer = vertical.consumeTrailing(footerHeight)
        let headerFrame = headerHeight > 0
            ? CGRect(x: reading.origin.x, y: header.origin, width: reading.width, height: header.length) : nil
        let footerFrame = footerHeight > 0
            ? CGRect(x: reading.origin.x, y: footer.origin, width: reading.width, height: footer.length) : nil

        // 先分配两端装饰，再消耗间距；关闭的槽位不占用对应间距。
        if headerHeight > 0 { vertical.consumeLeading(headerGap) }
        if footerHeight > 0 { vertical.consumeTrailing(footerGap) }
        vertical.consumeLeading(CGFloat(bodyInsets.top))
        vertical.consumeTrailing(CGFloat(bodyInsets.bottom))
        var horizontal = ReaderSurfaceSpan(origin: reading.origin.x, length: reading.width)
        horizontal.consumeLeading(CGFloat(bodyInsets.left))
        horizontal.consumeTrailing(CGFloat(bodyInsets.right))
        let body = CGRect(x: horizontal.origin, y: vertical.origin,
                          width: horizontal.length, height: vertical.length)

        let renderer: CGRect
        switch motion {
        case .contentOnly: renderer = body
        case .contentAndChrome: renderer = reading
        case .wholePage: renderer = bounds
        }
        return ReaderSurfaceLayout(backgroundFrame: bounds, readingFrame: reading, rendererFrame: renderer,
                                   bodyFrame: body, headerFrame: headerFrame, footerFrame: footerFrame, motion: motion)
    }
}

// MARK: - 边界校验和逐边消耗

private extension ReaderSurfaceMetrics {
    /// - Parameter frame: 原始输入矩形。
    /// - Returns: 原点、尺寸和端点均有限，且原始宽高非负；明确拒绝无限及空值哨兵矩形。
    func isValid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.size.width >= 0 && frame.size.height >= 0 &&
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
             frame.origin.x + frame.size.width, frame.origin.y + frame.size.height].allSatisfy(\.isFinite)
    }
}

/// 单轴剩余空间；每次消耗后保留有限端点，避免装饰和边距相加溢出。
private struct ReaderSurfaceSpan {
    private(set) var origin: CGFloat
    private(set) var length: CGFloat
    private var end: CGFloat

    /// - Parameters: origin: 已校验的起点；length: 非负长度，起点加长度必须有限。
    init(origin: CGFloat, length: CGFloat) {
        self.origin = origin
        self.length = length
        self.end = origin + length
    }

    /// - Parameter requested: 从起点消耗的非负长度。
    /// - Returns: 实际消耗区间的原点和长度；剩余区间不越过原端点。
    @discardableResult
    mutating func consumeLeading(_ requested: CGFloat) -> (origin: CGFloat, length: CGFloat) {
        let amount = min(requested, length)
        let previousOrigin = origin
        origin = min(end, origin + amount)
        length = containedLength(length - amount, from: origin, to: end)
        return (previousOrigin, amount)
    }

    /// - Parameter requested: 从终点消耗的非负长度。
    /// - Returns: 实际消耗区间的原点和长度；终点回退时不会越过剩余起点。
    @discardableResult
    mutating func consumeTrailing(_ requested: CGFloat) -> (origin: CGFloat, length: CGFloat) {
        let amount = min(requested, length)
        let previousEnd = end
        end = max(origin, end - amount)
        length = containedLength(length - amount, from: origin, to: end)
        return (end, containedLength(amount, from: end, to: previousEnd))
    }

    /// - Parameters: proposed: 候选非负长度；start: 起点；limit: 不可越过的终点。
    /// - Returns: 不越界的长度；仅在浮点重组超出边界时修正表示误差，不按点或像素取整。
    private func containedLength(_ proposed: CGFloat, from start: CGFloat, to limit: CGFloat) -> CGFloat {
        guard start + proposed > limit else { return proposed }
        var result = max(0, limit - start)
        if start + result > limit { result = result.nextDown }
        return min(proposed, result)
    }
}
