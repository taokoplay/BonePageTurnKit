import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 缩放容器的纯数值几何；不依赖 UIKit，支持在 macOS 验证布局和旋转锚点。
struct ReaderZoomGeometry: Equatable {
    let contentSize: CGSize
    let viewportSize: CGSize
    let minimumScale: CGFloat
    let maximumScale: CGFloat

    /// - Parameter size: 待校验的逻辑尺寸。
    /// - Returns: 是否处于有限、正数且可安全用于 UI 几何的范围。
    static func isValidSize(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && $0 >= 1e-9 && $0 <= 1e9 }
    }

    /// - Parameter factor: 相对最小倍率的最大放大倍数。
    /// - Returns: 是否处于可表示且有界的放大范围。
    static func isValidMaximumFactor(_ factor: CGFloat) -> Bool {
        factor.isFinite && factor >= 1 && factor <= 1e6
    }

    /// - Parameters: contentSize: 固定内容尺寸；viewportSize: 可见区域；fitsWidth: 是否适配宽度；maximumFactor: 最大相对倍率。
    /// - Returns: 非法尺寸或倍率返回 nil。
    init?(contentSize: CGSize, viewportSize: CGSize, fitsWidth: Bool, maximumFactor: CGFloat) {
        guard Self.isValidSize(contentSize), Self.isValidSize(viewportSize),
              Self.isValidMaximumFactor(maximumFactor) else { return nil }
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        let widthScale = viewportSize.width / contentSize.width
        minimumScale = fitsWidth ? widthScale : min(widthScale, viewportSize.height / contentSize.height)
        maximumScale = minimumScale * maximumFactor
    }

    /// - Parameter scale: UIScrollView 的实际缩放比例。
    /// - Returns: 放大后的内容尺寸。
    func scaledSize(at scale: CGFloat) -> CGSize {
        CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }

    /// - Parameter scale: 实际缩放比例。
    /// - Returns: 小内容居中所需的水平、垂直对称留白。
    func padding(at scale: CGFloat) -> CGPoint {
        let size = scaledSize(at: scale)
        return CGPoint(x: max(0, (viewportSize.width - size.width) / 2),
                       y: max(0, (viewportSize.height - size.height) / 2))
    }

    /// - Parameters: offset: 当前滚动偏移；scale: 实际缩放比例。
    /// - Returns: 可见中心在固定内容中的归一化位置，回弹范围会被钳制。
    func normalizedCenter(offset: CGPoint, scale: CGFloat) -> CGPoint {
        let size = scaledSize(at: scale)
        return CGPoint(x: min(1, max(0, (offset.x + viewportSize.width / 2) / size.width)),
                       y: min(1, max(0, (offset.y + viewportSize.height / 2) / size.height)))
    }

    /// - Parameters: normalizedCenter: 希望显示的归一化中心；scale: 实际缩放比例。
    /// - Returns: 使目标居中的合法偏移，边缘受滚动范围限制。
    func offset(for normalizedCenter: CGPoint, scale: CGFloat) -> CGPoint {
        let size = scaledSize(at: scale)
        let inset = padding(at: scale)
        let x = normalizedCenter.x * size.width - viewportSize.width / 2
        let y = normalizedCenter.y * size.height - viewportSize.height / 2
        return CGPoint(x: min(max(-inset.x, x), max(-inset.x, size.width - viewportSize.width + inset.x)),
                       y: min(max(-inset.y, y), max(-inset.y, size.height - viewportSize.height + inset.y)))
    }

    /// - Parameter scale: 初始缩放比例。
    /// - Returns: 顶部开始阅读的中心，小于可见区域的内容自然居中。
    func initialCenter(at scale: CGFloat) -> CGPoint {
        let size = scaledSize(at: scale)
        return CGPoint(x: 0.5, y: min(0.5, viewportSize.height / (2 * size.height)))
    }
}
