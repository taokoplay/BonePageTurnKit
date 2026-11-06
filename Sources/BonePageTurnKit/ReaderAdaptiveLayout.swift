import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 视口四边的安全距离，单位为点；各边独立处理，不镜像另一边的留白。
public struct ReaderViewportInsets: Sendable, Equatable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    /// - Parameters: top: 上边距离；left: 左边距离；bottom: 下边距离；right: 右边距离，默认均为零。
    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// 宿主视口的水平尺寸类别，不代表设备型号或物理姿态。
public enum ReaderViewportWidthClass: Sendable, Equatable { case compact, regular, unspecified }

/// 系统保留区域；frame 已包含系统 margins，不应再次添加内边距。
public struct ReaderReservedRegion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case division, occlusion }
    public let kind: Kind
    public let frame: CGRect
    public let isActive: Bool

    /// - Parameters: kind: 分隔或遮挡；frame: 视口坐标系内的完整保留范围；isActive: 当前是否参与布局。
    public init(kind: Kind, frame: CGRect, isActive: Bool = true) {
        self.kind = kind
        self.frame = frame
        self.isActive = isActive
    }
}

/// 可在任意线程传递和解析的视口快照，所有矩形使用 bounds 的坐标系。
public struct ReaderViewportEnvironment: Sendable, Equatable {
    public let bounds: CGRect
    public let safeAreaInsets: ReaderViewportInsets
    public let widthClass: ReaderViewportWidthClass
    public let regions: [ReaderReservedRegion]

    /// - Parameters: bounds: 视图本地边界；safeAreaInsets: 四边安全距离；widthClass: 水平尺寸类别；regions: 系统保留区域。
    public init(bounds: CGRect, safeAreaInsets: ReaderViewportInsets = .init(),
                widthClass: ReaderViewportWidthClass = .unspecified, regions: [ReaderReservedRegion] = []) {
        self.bounds = bounds
        self.safeAreaInsets = safeAreaInsets
        self.widthClass = widthClass
        self.regions = regions
    }
}

/// 布局结果。双页 contentFrame 包含中间空隙，真正的两个等宽页位于空隙两侧。
public struct ReaderAdaptiveLayout: Sendable, Equatable {
    public let contentFrame: CGRect
    public let pageLayout: ReaderPageLayout
    public let axis: PageTurnAxis
    public let spreadGap: CGFloat
    public let auxiliaryFrame: CGRect?
}

/// 非有限数值、负尺寸或过多区域会被明确拒绝，不将非法矩形传递给 UIKit。
public enum ReaderAdaptiveLayoutError: Error, Sendable, Equatable {
    case invalidBounds
    case invalidInsets
    case invalidPolicy
    case invalidRegion(index: Int)
    case tooManyRegions
}

/// 根据可读页的最小尺寸解析布局；尺寸阈值不是设备断点。
public struct ReaderAdaptiveLayoutPolicy: Sendable, Equatable {
    public let prefersSpread: Bool
    public let minimumPageWidth: CGFloat
    public let minimumPageHeight: CGFloat
    public let spreadGap: CGFloat

    /// - Parameters: prefersSpread: 是否优先双页；minimumPageWidth: 单页最小正宽度；minimumPageHeight: 单页最小正高度；spreadGap: 最小非负双页间距。
    public init(prefersSpread: Bool = true, minimumPageWidth: CGFloat = 280,
                minimumPageHeight: CGFloat = 240, spreadGap: CGFloat = 0) {
        self.prefersSpread = prefersSpread
        self.minimumPageWidth = minimumPageWidth
        self.minimumPageHeight = minimumPageHeight
        self.spreadGap = spreadGap
    }

    /// - Parameter environment: 使用同一本地坐标系的视口快照，最多包含 64 个保留区域。
    /// - Returns: 正文、单双页和辅助区域；阅读手势轴保持 horizontal，完全遮挡时返回空单页。
    /// - Throws: `ReaderAdaptiveLayoutError`，包括无效的策略、边界、安全距离或区域。
    public func layout(for environment: ReaderViewportEnvironment) throws -> ReaderAdaptiveLayout {
        try validate(environment)
        let safe = safeFrame(in: environment)
        guard safe.width > 0, safe.height > 0 else { return single(empty(at: safe.origin)) }

        // 先检查与 bounds、安全区的交集；保留原始遮挡边坐标，裁剪时不会因浮点重组缩小保留范围。
        let active = environment.regions.compactMap { region -> ReaderReservedRegion? in
            guard region.isActive, intersection(region.frame, environment.bounds) != nil,
                  intersection(region.frame, safe) != nil else { return nil }
            return region
        }
        let divisions = active.filter { $0.kind == .division }.sorted { lhs, rhs in
            let leftSpan = divisionSpan(lhs.frame, in: safe)
            let rightSpan = divisionSpan(rhs.frame, in: safe)
            if leftSpan != rightSpan { return leftSpan > rightSpan }
            return framePrecedes(lhs.frame, rhs.frame)
        }
        guard let division = divisions.first else {
            let content = largestRectangle(in: safe, avoiding: active.map(\.frame))
            let canSpread = environment.widthClass == .regular && prefersSpread &&
                content.width >= spreadGap && (content.width - spreadGap) / 2 >= minimumPageWidth &&
                content.height >= minimumPageHeight
            if canSpread {
                let center = content.minX + content.width / 2
                if let spread = symmetricLayout(center: center, top: content.minY, bottom: content.maxY,
                                                left: .init(lower: content.minX, upper: center),
                                                right: .init(lower: center, upper: content.maxX)) { return spread }
            }
            return single(content)
        }

        // 主折痕切分整个安全区；其他折痕也作为遮挡，避免正文跨越第二条分隔。
        let obstructions = active.map(\.frame)
        if division.frame.height > division.frame.width {
            let left = containedRectangle(x: safe.minX, y: safe.minY,
                                          right: max(safe.minX, division.frame.minX), bottom: safe.maxY)
            let right = containedRectangle(x: min(safe.maxX, division.frame.maxX), y: safe.minY,
                                           right: safe.maxX, bottom: safe.maxY)
            if environment.widthClass == .regular, prefersSpread,
               let spread = bookLayout(left: left, right: right, crease: division.frame, avoiding: obstructions, in: safe) {
                return spread
            }
            let a = largestRectangle(in: left, avoiding: obstructions, prefersReadable: true)
            let b = largestRectangle(in: right, avoiding: obstructions, prefersReadable: true)
            if isReadable(a) != isReadable(b) { return single(isReadable(a) ? a : b) }
            return single(isLarger(b, than: a, in: safe) ? b : a)
        }

        let top = containedRectangle(x: safe.minX, y: safe.minY, right: safe.maxX, bottom: max(safe.minY, division.frame.minY))
        let bottom = containedRectangle(x: safe.minX, y: min(safe.maxY, division.frame.maxY), right: safe.maxX, bottom: safe.maxY)
        let auxiliary = largestRectangle(in: bottom, avoiding: obstructions)
        return single(largestRectangle(in: top, avoiding: obstructions),
                      auxiliary: auxiliary.isEmpty ? nil : auxiliary)
    }
}

// MARK: - 校验和基础矩形

private extension ReaderAdaptiveLayoutPolicy {
    /// - Parameter environment: 待解析快照；无返回值，发现非法输入时抛出对应错误。
    func validate(_ environment: ReaderViewportEnvironment) throws {
        guard minimumPageWidth.isFinite, minimumPageWidth > 0,
              minimumPageHeight.isFinite, minimumPageHeight > 0,
              spreadGap.isFinite, spreadGap >= 0 else { throw ReaderAdaptiveLayoutError.invalidPolicy }
        guard isValid(environment.bounds) else { throw ReaderAdaptiveLayoutError.invalidBounds }
        let insets = environment.safeAreaInsets
        guard [insets.top, insets.left, insets.bottom, insets.right].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ReaderAdaptiveLayoutError.invalidInsets
        }
        guard environment.regions.count <= 64 else { throw ReaderAdaptiveLayoutError.tooManyRegions }
        for (index, region) in environment.regions.enumerated() where !isValid(region.frame) {
            throw ReaderAdaptiveLayoutError.invalidRegion(index: index)
        }
    }

    /// - Parameter frame: 待检查矩形；返回原始宽高非负且四边均可有限表示的判定。
    func isValid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite &&
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
             frame.origin.x + frame.size.width, frame.origin.y + frame.size.height].allSatisfy(\.isFinite) &&
            frame.size.width >= 0 && frame.size.height >= 0
    }

    /// - Parameter environment: 已校验快照；返回逐边钳制后的安全区，避免边距相加溢出。
    func safeFrame(in environment: ReaderViewportEnvironment) -> CGRect {
        let bounds = environment.bounds
        let insets = environment.safeAreaInsets
        let left = min(CGFloat(insets.left), bounds.width)
        let top = min(CGFloat(insets.top), bounds.height)
        let width = bounds.width - left
        let height = bounds.height - top
        return containedRectangle(x: bounds.minX + left, y: bounds.minY + top,
                                  right: max(bounds.minX + left, bounds.maxX - min(CGFloat(insets.right), width)),
                                  bottom: max(bounds.minY + top, bounds.maxY - min(CGFloat(insets.bottom), height)))
    }

    /// - Parameters: a: 第一矩形；b: 第二矩形；返回正面积交集，边缘相接或空矩形返回 nil。
    func intersection(_ a: CGRect, _ b: CGRect) -> CGRect? {
        let x = max(a.minX, b.minX)
        let y = max(a.minY, b.minY)
        let right = min(a.maxX, b.maxX)
        let bottom = min(a.maxY, b.maxY)
        guard right > x, bottom > y else { return nil }
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    /// - Parameters: x: 左边；y: 上边；right: 右边；bottom: 下边；返回不会因浮点加法越过指定边界的矩形。
    func containedRectangle(x: CGFloat, y: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        var width = max(0, right - x)
        var height = max(0, bottom - y)
        // 只修正一个浮点表示步长，不按点或像素取整，也不丢弃奇数宽度的半像素。
        if x + width > right { width = width.nextDown }
        if y + height > bottom { height = height.nextDown }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// - Parameter origin: 安全区内的锚点；返回保留该原点的零尺寸矩形。
    func empty(at origin: CGPoint) -> CGRect { CGRect(origin: origin, size: .zero) }

    /// - Parameters: frame: 正文区域；auxiliary: 可选辅助区域；返回水平手势的单页结果。
    func single(_ frame: CGRect, auxiliary: CGRect? = nil) -> ReaderAdaptiveLayout {
        .init(contentFrame: frame, pageLayout: .single, axis: .horizontal, spreadGap: 0, auxiliaryFrame: auxiliary)
    }

    /// - Parameter frame: 候选单页；返回其是否达到配置的最小可读尺寸。
    func isReadable(_ frame: CGRect) -> Bool {
        frame.width >= minimumPageWidth && frame.height >= minimumPageHeight
    }

    /// - Parameters: candidate: 候选； current: 已选区域；bounds: 二者共同所在范围；返回面积是否更大。
    func isLarger(_ candidate: CGRect, than current: CGRect, in bounds: CGRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0, !candidate.isEmpty else { return false }
        guard !current.isEmpty else { return true }
        // 分别比较指数与有效数字，面积既不溢出，也不因过小而下溢为零。
        let a = candidate.width.significand * candidate.height.significand
        let b = current.width.significand * current.height.significand
        let aExponent = candidate.width.exponent + candidate.height.exponent + a.exponent
        let bExponent = current.width.exponent + current.height.exponent + b.exponent
        return aExponent == bExponent ? a.significand > b.significand : aExponent > bExponent
    }

    /// - Parameters: frame: 分隔区域；safe: 安全区；返回主轴在安全区内的覆盖比例。
    func divisionSpan(_ frame: CGRect, in safe: CGRect) -> CGFloat {
        guard let clipped = intersection(frame, safe) else { return 0 }
        return frame.height > frame.width ? clipped.height / safe.height : clipped.width / safe.width
    }

    /// - Parameters: lhs: 第一矩形；rhs: 第二矩形；返回稳定的坐标排序，避免输入区域顺序影响布局。
    func framePrecedes(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let left = [lhs.minX, lhs.minY, lhs.width, lhs.height]
        let right = [rhs.minX, rhs.minY, rhs.width, rhs.height]
        return left.lexicographicallyPrecedes(right)
    }
}

// MARK: - 四边裁剪候选

private extension ReaderAdaptiveLayoutPolicy {
    struct Interval {
        let lower: CGFloat
        let upper: CGFloat
    }

    /// - Parameters: bounds: 待裁剪范围；obstructions: 遮挡矩形；返回有交集且按左边排序的遮挡，实际四边在候选扫描时裁剪。
    func clippedObstructions(in bounds: CGRect, avoiding obstructions: [CGRect]) -> [CGRect] {
        obstructions.filter { intersection($0, bounds) != nil }.sorted { framePrecedes($0, $1) }
    }

    /// - Parameters: bounds: 候选范围；obstructions: 已裁剪遮挡；返回所有可能的上、下裁剪边。
    func verticalEdges(in bounds: CGRect, avoiding obstructions: [CGRect]) -> [CGFloat] {
        Array(Set([bounds.minY, bounds.maxY] + obstructions.flatMap {
            [max(bounds.minY, $0.minY), min(bounds.maxY, $0.maxY)]
        })).sorted()
    }

    /// - Parameters: bounds: 横向范围；top: 上裁剪边；bottom: 下裁剪边；obstructions: 按左边排序的遮挡。
    /// - Returns: 此高度带内所有不重叠的横向区间，左右边来自遮挡或视口四边。
    func freeIntervals(in bounds: CGRect, top: CGFloat, bottom: CGFloat, avoiding obstructions: [CGRect]) -> [Interval] {
        guard bounds.width > 0, bottom > top else { return [] }
        var cursor = bounds.minX
        var result: [Interval] = []
        for region in obstructions where region.minY < bottom && region.maxY > top {
            let lower = max(bounds.minX, region.minX)
            let upper = min(bounds.maxX, region.maxX)
            guard upper > lower else { continue }
            if lower > cursor { result.append(.init(lower: cursor, upper: lower)) }
            cursor = max(cursor, upper)
            if cursor >= bounds.maxX { break }
        }
        if cursor < bounds.maxX { result.append(.init(lower: cursor, upper: bounds.maxX)) }
        return result
    }

    /// - Parameters: bounds: 待裁剪范围；obstructions: 所有遮挡；prefersReadable: 存在可读候选时是否优先它。
    /// - Returns: 从遮挡四边切出的最大不重叠矩形；同时枚举上下边，避免逐个贪心裁剪丢失可用空间。
    func largestRectangle(in bounds: CGRect, avoiding obstructions: [CGRect], prefersReadable: Bool = false) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return empty(at: bounds.origin) }
        let clipped = clippedObstructions(in: bounds, avoiding: obstructions)
        guard !clipped.isEmpty else { return bounds }
        let edges = verticalEdges(in: bounds, avoiding: clipped)
        var best = empty(at: bounds.origin)
        var readable = best
        for topIndex in 0..<(edges.count - 1) {
            for bottomIndex in (topIndex + 1)..<edges.count {
                let top = edges[topIndex]
                let bottom = edges[bottomIndex]
                for interval in freeIntervals(in: bounds, top: top, bottom: bottom, avoiding: clipped) {
                    let candidate = containedRectangle(x: interval.lower, y: top, right: interval.upper, bottom: bottom)
                    if isLarger(candidate, than: best, in: bounds) { best = candidate }
                    if prefersReadable, isReadable(candidate), isLarger(candidate, than: readable, in: bounds) { readable = candidate }
                }
            }
        }
        return prefersReadable && !readable.isEmpty ? readable : best
    }

    /// - Parameters: left: 折痕左侧；right: 折痕右侧；crease: 真实折痕；obstructions: 所有遮挡；safe: 安全区。
    /// - Returns: 在共同高度带内围绕真实折痕中心对称的最大可读双页，没有可行候选时返回 nil。
    func bookLayout(left: CGRect, right: CGRect, crease: CGRect, avoiding obstructions: [CGRect], in safe: CGRect) -> ReaderAdaptiveLayout? {
        guard isReadable(left), isReadable(right) else { return nil }
        let clipped = clippedObstructions(in: safe, avoiding: obstructions)
        let edges = verticalEdges(in: safe, avoiding: clipped)
        let center = crease.minX + crease.width / 2
        var best: ReaderAdaptiveLayout?
        var bestPage = empty(at: safe.origin)
        for topIndex in 0..<(edges.count - 1) {
            for bottomIndex in (topIndex + 1)..<edges.count {
                let top = edges[topIndex]
                let bottom = edges[bottomIndex]
                guard bottom - top >= minimumPageHeight else { continue }
                // 距折痕中心由近到远排列，两侧区间求交即可得到等宽页，无需取整或镜像安全边距。
                let leftIntervals = Array(freeIntervals(in: left, top: top, bottom: bottom, avoiding: clipped).reversed())
                let rightIntervals = freeIntervals(in: right, top: top, bottom: bottom, avoiding: clipped)
                var a = 0
                var b = 0
                while a < leftIntervals.count, b < rightIntervals.count {
                    let l = leftIntervals[a]
                    let r = rightIntervals[b]
                    if let candidate = symmetricLayout(center: center, top: top, bottom: bottom, left: l, right: r) {
                        let page = CGRect(x: 0, y: 0, width: (candidate.contentFrame.width - candidate.spreadGap) / 2,
                                          height: candidate.contentFrame.height)
                        if isLarger(page, than: bestPage, in: safe) { bestPage = page; best = candidate }
                    }
                    if center - l.lower <= r.upper - center { a += 1 } else { b += 1 }
                }
            }
        }
        return best
    }

    /// - Parameters: center: 真实分隔中心；top: 共用上边；bottom: 共用下边；left: 左侧空区；right: 右侧空区。
    /// - Returns: 保持等宽及对称的可读双页；用有限次浮点修正确保实际页边不穿过遮挡。
    func symmetricLayout(center: CGFloat, top: CGFloat, bottom: CGFloat, left: Interval, right: Interval) -> ReaderAdaptiveLayout? {
        var inner = max(center - left.upper, right.lower - center, spreadGap / 2)
        var outer = min(center - left.lower, right.upper - center)
        let height = containedRectangle(x: 0, y: top, right: 0, bottom: bottom).height
        guard height >= minimumPageHeight else { return nil }
        for _ in 0..<4 {
            let pageWidth = outer - inner
            guard pageWidth >= minimumPageWidth, outer <= CGFloat.greatestFiniteMagnitude / 2 else { return nil }
            let content = CGRect(x: center - outer, y: top, width: outer * 2, height: height)
            let gap = inner * 2
            let rightStart = content.minX + pageWidth + gap
            let outerExcess = max(left.lower - content.minX, rightStart + pageWidth - right.upper,
                                  content.maxX - right.upper, 0)
            if outerExcess > 0 { outer = (outer - outerExcess).nextDown; continue }
            let innerExcess = max(content.minX + pageWidth - left.upper, right.lower - rightStart, 0)
            if innerExcess > 0 { inner = (inner + innerExcess).nextUp; continue }
            return .init(contentFrame: content, pageLayout: .spread, axis: .horizontal, spreadGap: gap, auxiliaryFrame: nil)
        }
        return nil
    }
}
