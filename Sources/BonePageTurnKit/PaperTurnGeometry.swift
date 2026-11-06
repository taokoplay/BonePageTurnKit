import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 一条纸面材料对应的规范化投影；横向沿 X，纵向沿 Y，源坐标按翻页轴递增。
struct PaperStripGeometry: Equatable {
    let index: Int
    let sourceStart: Double
    let sourceEnd: Double
    let xStart: Double
    let xEnd: Double
    /// 以页面中线为中心、横跨翻页轴向两侧各伸展的点数。
    let verticalExpansion: Double
    let depth: Double
    let isBackFace: Bool
    let shade: Double

    var minimumX: Double { min(xStart, xEnd) }
    var maximumX: Double { max(xStart, xEnd) }
}

/// 两张原始快照的整像素分配计划，不包含宿主内容、条带句柄及显示缓冲。
struct PaperSnapshotPlan: Equatable {
    let scale: Double
    let pixelWidth: Int
    let pixelHeight: Int
    var totalPixelCount: Int { pixelWidth * pixelHeight * 2 }
}

/// 翻页轴与实际画布之间的成对映射；只转换矩形和采样轴，不旋转整张文字位图。
struct PaperAxisGeometry {
    let axis: PageTurnAxis
    let length: Double
    let breadth: Double

    /// - Parameters: width: 画布点宽；height: 画布点高；axis: 翻页方向轴。
    init(width: Double, height: Double, axis: PageTurnAxis) {
        self.axis = axis
        length = axis == .horizontal ? width : height
        breadth = axis == .horizontal ? height : width
    }

    /// - Parameters: start: 沿轴起点；end: 沿轴终点；expansion: 横跨翻页轴的两侧伸展。
    /// - Returns: 保持文字原有方向的实际画布矩形。
    func rect(start: Double, end: Double, expansion: Double = 0) -> CGRect {
        let lower = min(start, end)
        let extent = abs(end - start)
        return axis == .horizontal
            ? CGRect(x: lower, y: -expansion, width: extent, height: breadth + 2 * expansion)
            : CGRect(x: -expansion, y: lower, width: breadth + 2 * expansion, height: extent)
    }
}

/// 与 UIKit 无关的纸面曲面和快照预算；所有长度均使用 Double 点坐标。
enum PaperTurnGeometry {
    private struct SurfacePoint {
        let x: Double
        let depth: Double
        let expansion: Double
        let normal: Double
    }

    /// - Parameters: progress: 逻辑进度；direction: 翻页方向。
    /// - Returns: 移动页的折弯进度；非有限输入返回 nil。
    static func movingProgress(_ progress: Double, direction: PageTurnDirection) -> Double? {
        guard progress.isFinite else { return nil }
        let value = min(1, max(0, progress))
        return direction == .previous ? 1 - value : value
    }

    /// 先按总像素和最长边缩小，再向下取整，渲染器据此创建精确大小的像素画布。
    /// - Parameters: width: 点宽；height: 点高；displayScale: 屏幕倍率上限；maximumSnapshotPixels: 两图像素总预算。
    /// - Returns: 最长边不超过 4096、总像素不超预算的计划；非法或无法采样的尺寸返回 nil。
    static func snapshotPlan(width: Double, height: Double, displayScale: Double,
                             maximumSnapshotPixels: Int) -> PaperSnapshotPlan? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              displayScale.isFinite, displayScale > 0,
              (65_536...16_777_216).contains(maximumSnapshotPixels) else { return nil }
        var scale = min(displayScale, 4096 / max(width, height))
        // 先限制最长边，避免直接计算极大点尺寸的面积产生溢出。
        let initialWidth = width * scale
        let initialHeight = height * scale
        let initialPixels = initialWidth * initialHeight * 2
        if initialPixels > Double(maximumSnapshotPixels) {
            scale *= sqrt(Double(maximumSnapshotPixels) / initialPixels)
        }
        let scaledWidth = floor(width * scale)
        let scaledHeight = floor(height * scale)
        guard scale.isFinite, scale > 0,
              scaledWidth >= 1, scaledHeight >= 1,
              scaledWidth <= 4096, scaledHeight <= 4096 else { return nil }
        let plan = PaperSnapshotPlan(scale: scale, pixelWidth: Int(scaledWidth), pixelHeight: Int(scaledHeight))
        guard plan.totalPixelCount <= maximumSnapshotPixels else { return nil }
        return plan
    }

    /// 将材料按源像素边界划分；极窄快照减少实际条数，保证每个像素只归属一个条带。
    /// - Parameters:
    ///   - width: 页面点宽。
    ///   - height: 页面点高。
    ///   - progress: 逻辑进度，有限值钳制到 0...1。
    ///   - effect: curl 或 arch。
    ///   - direction: 下一页移出当前页，上一页移入目标页。
    ///   - spine: automatic 等价于 minimum；center 无曲面定义。
    ///   - stripCount: 请求条数，范围 32...256。
    ///   - sourcePixelWidth: 可选的源像素宽度，与预裁条带边界完全一致。
    /// - Returns: 按源条带索引排列的几何；不支持或非法输入返回空数组。
    static func strips(width: Double, height: Double, progress: Double,
                       effect: PageTurnEffect, direction: PageTurnDirection,
                       spine: PageSpinePlacement, stripCount: Int,
                       sourcePixelWidth: Int? = nil) -> [PaperStripGeometry] {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double.greatestFiniteMagnitude / 16,
              height <= Double.greatestFiniteMagnitude / 16,
              (32...256).contains(stripCount),
              effect == .curl || effect == .arch,
              spine != .center,
              let t = movingProgress(progress, direction: direction) else { return [] }
        if let pixels = sourcePixelWidth, !(1...4096).contains(pixels) { return [] }
        let count = min(stripCount, sourcePixelWidth ?? stripCount)
        let mirrored = spine == .maximum
        var result: [PaperStripGeometry] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let lower: Double
            let upper: Double
            if let pixels = sourcePixelWidth {
                lower = Double(index * pixels / count) / Double(pixels)
                upper = Double((index + 1) * pixels / count) / Double(pixels)
            } else {
                lower = Double(index) / Double(count)
                upper = Double(index + 1) / Double(count)
            }
            let sourceStart = lower * width
            let sourceEnd = upper * width
            let u0 = mirrored ? width - sourceStart : sourceStart
            let u1 = mirrored ? width - sourceEnd : sourceEnd
            let a = point(u: u0, width: width, height: height, t: t, effect: effect)
            let b = point(u: u1, width: width, height: height, t: t, effect: effect)
            let middle = point(u: (u0 + u1) / 2, width: width, height: height, t: t, effect: effect)
            let x0 = mirrored ? width - a.x : a.x
            let x1 = mirrored ? width - b.x : b.x
            let shade = effect == .curl
                ? 0.19 * (1 - abs(middle.normal)) + 0.035 * middle.depth / width
                : min(0.13, 0.035 * sin(.pi * t) + middle.expansion / height * 1.5)
            guard x0.isFinite, x1.isFinite, middle.expansion.isFinite,
                  middle.depth.isFinite, shade.isFinite else { return [] }
            result.append(PaperStripGeometry(
                index: index, sourceStart: sourceStart, sourceEnd: sourceEnd,
                xStart: x0, xEnd: x1, verticalExpansion: middle.expansion,
                depth: middle.depth, isBackFace: middle.normal < 0,
                shade: min(0.25, max(0, shade))
            ))
        }
        return result
    }

    /// - Parameters: u: 沿书脊的材料距离；width: 点宽；height: 点高；t: 已校验的折弯进度；effect: 纸面类型。
    /// - Returns: 局部书脊坐标中的曲面位置、深度、纵向投影和正面法向。
    private static func point(u: Double, width: Double, height: Double,
                              t: Double, effect: PageTurnEffect) -> SurfacePoint {
        if effect == .arch {
            let rawFold = 0.85 * t
            let fold = min(rawFold, 0.2)
            let visible = 1 - fold
            let q = u / width
            let aspect = width / height
            // 等价于旧 metrics 的 H * fold * rawFold * imageAspect，避免中间值溢出。
            let waveBase = max(0, width * fold * rawFold - (aspect - 1) / 2)
            let phase = (q - t) * .pi * 2
            // 最外侧 5.5% 材料平顺地收束到受力边，不把边缘一并拉成波浪。
            let edge = min(1, max(0, (1 - q) / 0.055))
            let contact = edge * edge * (3 - 2 * edge)
            let wave = waveBase * fold * (sin(phase) + 1.1 + 1.5 * sin(.pi * q)) * contact
            return SurfacePoint(x: (q * visible - rawFold) * width,
                                depth: wave / height * width, expansion: wave, normal: 1)
        }

        let foldStart = width * (1 - t)
        guard u > foldStart else { return SurfacePoint(x: u, depth: 0, expansion: 0, normal: 1) }
        let radius = 0.14 * width * sin(.pi * t)
        // 完全翻过时半径为零，材料从书脊向外平铺在背面。
        guard radius > width * 1e-12 else {
            return SurfacePoint(x: 2 * foldStart - u, depth: 0, expansion: 0, normal: -1)
        }
        let theta = (u - foldStart) / radius
        let x: Double
        let depth: Double
        let normal: Double
        if theta < .pi {
            x = foldStart + radius * sin(theta)
            depth = radius * (1 - cos(theta))
            normal = cos(theta)
        } else {
            x = foldStart - (u - foldStart - .pi * radius)
            depth = 2 * radius
            normal = -1
        }
        return SurfacePoint(x: x, depth: depth, expansion: height * (0.12 * depth / width), normal: normal)
    }
}
