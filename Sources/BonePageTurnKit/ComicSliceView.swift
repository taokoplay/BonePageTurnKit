#if canImport(UIKit)
import UIKit

/// 显示层拒绝隐式方向修正、无法核实像素尺寸的图像及源尺寸不匹配。
public enum ComicSliceViewError: Error, Sendable, Equatable {
    case imageMustBeUpright
    case imagePixelsUnavailable
    case sourcePixelSizeMismatch
}

/// 直接绘制宿主提供的原图；不生成裁剪位图或持有额外整图缓存。
@MainActor
public final class ComicSliceView: UIView {
    public let slice: ComicPageSlice
    public let image: UIImage

    /// 以源像素为基准的自然尺寸；宿主可等比调整实际显示尺寸。
    public var preferredContentSize: CGSize { slice.sourcePixelRect.size }

    /// 创建可等比显示的物理切片。
    /// - Parameters:
    ///   - image: 方向为 `.up`、具有 CGImage 像素的宿主原图；scale 不影响像素校验。
    ///   - slice: 此原图的规划结果。
    /// - Throws: `ComicSliceViewError`；不在容器内重新解码或修正方向。
    public init(image: UIImage, slice: ComicPageSlice) throws {
        guard image.imageOrientation == .up else { throw ComicSliceViewError.imageMustBeUpright }
        guard let pixels = image.cgImage else { throw ComicSliceViewError.imagePixelsUnavailable }
        guard CGSize(width: pixels.width, height: pixels.height) == slice.sourcePixelSize else {
            throw ComicSliceViewError.sourcePixelSizeMismatch
        }
        self.image = image
        self.slice = slice
        super.init(frame: CGRect(origin: .zero, size: slice.sourcePixelRect.size))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
    }

    /// 不支持归档构造；请使用包含原图及切片的初始化器。
    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// 绘制当前切片；参数为 UIKit 提供的重绘区域，无返回值。
    public override func draw(_ rect: CGRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        let source = slice.sourcePixelRect
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let displayed = CGSize(width: source.width * scale, height: source.height * scale)
        let destination = CGRect(x: bounds.midX - displayed.width / 2,
                                 y: bounds.midY - displayed.height / 2,
                                 width: displayed.width, height: displayed.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: destination)
        image.draw(in: CGRect(x: destination.minX - source.minX * scale,
                              y: destination.minY - source.minY * scale,
                              width: slice.sourcePixelSize.width * scale,
                              height: slice.sourcePixelSize.height * scale))
    }
}
#endif
