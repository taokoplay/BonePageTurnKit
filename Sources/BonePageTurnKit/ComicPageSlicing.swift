import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 漫画源图的展示切片方式；切片始终保留原图方向。
public enum ComicSliceMode: Sendable, Equatable {
    case whole
    case splitWide
    case vertical
}

/// 切片输入错误；预算在创建切片数组之前检查。
public enum ComicSlicingError: Error, Sendable, Equatable {
    case invalidPixelSize
    case invalidMaximumHeightToWidth
    case tooManySlices(limit: Int)
}

/// 一个物理像素区域及其逻辑阅读位置，只能由切片规划器创建。
public struct ComicPageSlice: Sendable, Equatable {
    public let identity: PageItemIdentity
    public let sourceIdentity: PageItemIdentity
    public let sourcePixelRect: CGRect
    public let normalizedRect: CGRect
    /// 当前阅读顺序中的零基序号。
    public let index: Int
    public let count: Int

    // 保留精确源尺寸供绘制校验，不从归一化浮点数反推像素。
    let sourcePixelSize: CGSize
}

/// 不读取图像、不分配像素缓冲的纯值切片规划器。
public enum ComicPageSlicing {
    /// 规划完整图、横向双页或纵向长图的整数像素切片。
    /// - Parameters:
    ///   - identity: 原始展示单元的身份及版本。
    ///   - pixelSize: 每边为 1…1,000,000,000 的整数像素尺寸。
    ///   - mode: 完整、宽图拆分或纵向分片。
    ///   - readingOrder: 仅影响横向切片顺序，不镜像图像或改变物理切片身份。
    ///   - maximumHeightToWidth: 有限正数；纵向片高向下取整，最少保留一像素。
    /// - Returns: 最多 256 片，完整覆盖源图，末尾短片保留。
    /// - Throws: `ComicSlicingError`，非法输入或片数超过预算。
    public static func slices(
        for identity: PageItemIdentity,
        pixelSize: CGSize,
        mode: ComicSliceMode,
        readingOrder: ReaderReadingOrder = .leftToRight,
        maximumHeightToWidth: Double = 1.5
    ) throws -> [ComicPageSlice] {
        let dimensions = [pixelSize.width, pixelSize.height]
        guard dimensions.allSatisfy({
            $0.isFinite && $0 >= 1 && $0 <= 1_000_000_000 && $0.rounded(.down) == $0
        }) else { throw ComicSlicingError.invalidPixelSize }
        guard maximumHeightToWidth.isFinite, maximumHeightToWidth > 0 else {
            throw ComicSlicingError.invalidMaximumHeightToWidth
        }

        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let fullRect = CGRect(origin: .zero, size: pixelSize)
        let rects: [CGRect]
        switch mode {
        case .whole:
            rects = [fullRect]
        case .splitWide where width > height:
            let leftWidth = width / 2
            let left = CGRect(x: 0, y: 0, width: leftWidth, height: height)
            let right = CGRect(x: leftWidth, y: 0, width: width - leftWidth, height: height)
            rects = readingOrder == .leftToRight ? [left, right] : [right, left]
        case .splitWide:
            rects = [fullRect]
        case .vertical:
            // 先比较比例，避免极大但有限的比例在乘法时溢出。
            let sliceHeight = maximumHeightToWidth >= Double(height) / Double(width)
                ? height : max(1, Int((Double(width) * maximumHeightToWidth).rounded(.down)))
            let count = (height - 1) / sliceHeight + 1
            guard count <= 256 else { throw ComicSlicingError.tooManySlices(limit: 256) }
            rects = (0..<count).map { index in
                let y = index * sliceHeight
                return CGRect(x: 0, y: y, width: width, height: min(sliceHeight, height - y))
            }
        }

        return rects.enumerated().map { index, rect in
            // UTF-8 长度前缀使源 unitID 中的冒号、逗号或中文均不产生歧义。
            let physicalRect = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            let unitID = "comic-slice:\(identity.unitID.utf8.count):\(identity.unitID):\(physicalRect)"
            let derivedIdentity = PageItemIdentity(
                sourceID: identity.sourceID, unitID: unitID,
                contentVersion: identity.contentVersion, layoutVersion: identity.layoutVersion
            )
            return ComicPageSlice(
                identity: derivedIdentity, sourceIdentity: identity, sourcePixelRect: rect,
                normalizedRect: CGRect(x: rect.minX / pixelSize.width, y: rect.minY / pixelSize.height,
                                       width: rect.width / pixelSize.width, height: rect.height / pixelSize.height),
                index: index, count: rects.count, sourcePixelSize: pixelSize
            )
        }
    }
}
