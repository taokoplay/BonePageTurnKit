import Foundation

/// 中央双页的纸张材料始终从书脊到外缘编号，正反面分别采样当前页和目标页。
/// 纵向阅读按上、下排布；阅读顺序只改变横向书册的左右物理位置。
enum PaperSpreadGeometry {
    private struct SurfacePoint {
        let x: Double
        let depth: Double
        let normal: Double
    }

    /// - Parameters: axis: 翻页轴；readingOrder: 横向书册阅读顺序。
    /// - Returns: 正面是否位于最小端半页；横向 RTL 为左页，其余为右页或下页。
    static func frontIsMinimum(axis: PageTurnAxis, readingOrder: ReaderReadingOrder) -> Bool {
        axis == .horizontal && readingOrder == .rightToLeft
    }

    /// 中线是固定铰链，任何时刻都不会将整张跨页沿边缘平移出场。
    /// - Parameters:
    ///   - width: 实际画布点宽。
    ///   - height: 实际画布点高。
    ///   - progress: 逻辑进度；有限值钳制到 0...1。
    ///   - effect: 圆弧卷页或弹性拱页。
    ///   - direction: previous 使用同一材料曲面的反向时间。
    ///   - axis: 横向或纵向；纵向几何长度对应实际高度。
    ///   - readingOrder: 横向左右阅读顺序。
    ///   - stripCount: 请求条数，范围 32...256。
    ///   - sourcePixelLength: 单个半页沿翻页轴的像素数。
    /// - Returns: 按书脊到外缘排列的条带；非法配置返回空数组。
    static func strips(width: Double, height: Double, progress: Double,
                       effect: PageTurnEffect, direction: PageTurnDirection,
                       axis: PageTurnAxis, readingOrder: ReaderReadingOrder,
                       stripCount: Int, sourcePixelLength: Int? = nil) -> [PaperStripGeometry] {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double.greatestFiniteMagnitude / 16,
              height <= Double.greatestFiniteMagnitude / 16,
              (32...256).contains(stripCount), effect == .curl || effect == .arch,
              let t = PaperTurnGeometry.movingProgress(progress, direction: direction) else { return [] }
        if let pixels = sourcePixelLength, !(1...2048).contains(pixels) { return [] }
        let layout = PaperAxisGeometry(width: width, height: height, axis: axis)
        let half = layout.length / 2
        let sign = frontIsMinimum(axis: axis, readingOrder: readingOrder) ? -1.0 : 1.0
        let count = min(stripCount, sourcePixelLength ?? stripCount)
        guard half > 0 else { return [] }
        var result: [PaperStripGeometry] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let lower: Double
            let upper: Double
            if let pixels = sourcePixelLength {
                lower = Double(index * pixels / count) / Double(pixels)
                upper = Double((index + 1) * pixels / count) / Double(pixels)
            } else {
                lower = Double(index) / Double(count)
                upper = Double(index + 1) / Double(count)
            }
            let a = point(q: lower, half: half, t: t, effect: effect)
            let b = point(q: upper, half: half, t: t, effect: effect)
            let middle = point(q: (lower + upper) / 2, half: half, t: t, effect: effect)
            let relief = middle.depth / half
            let shade = effect == .curl
                ? 0.20 * (1 - abs(middle.normal)) + 0.045 * relief
                : 0.08 * (1 - abs(middle.normal)) + 0.06 * relief
            result.append(PaperStripGeometry(
                index: index, sourceStart: lower * half, sourceEnd: upper * half,
                xStart: half + sign * a.x, xEnd: half + sign * b.x,
                verticalExpansion: layout.breadth * relief * (effect == .curl ? 0.04 : 0.07),
                depth: middle.depth, isBackFace: middle.normal < 0,
                shade: min(0.27, max(0, shade))
            ))
        }
        return result
    }

    /// - Parameters: q: 从书脊到外缘的材料比例；half: 单页长度；t: 已钳制进度；effect: 曲面类型。
    /// - Returns: 铰链局部坐标、朝向观察者的深度和正面法向；端点严格平铺。
    private static func point(q: Double, half: Double, t: Double, effect: PageTurnEffect) -> SurfacePoint {
        if t == 0 { return SurfacePoint(x: q * half, depth: 0, normal: 1) }
        if t == 1 { return SurfacePoint(x: -q * half, depth: 0, normal: -1) }
        let angle = .pi * t
        if effect == .curl {
            // 对沿材料线性变化的切线角积分，圆弧原点始终落在铰链。
            let bend = 1.1 * sin(angle) * sin(angle)
            let start = angle - bend
            let sweep = 2 * bend
            guard sweep > 1e-10 else {
                return SurfacePoint(x: q * half * cos(angle), depth: q * half * sin(angle), normal: cos(angle))
            }
            let theta = start + sweep * q
            // 中点形式避免接近端点时两个三角函数相减造成消减误差。
            let chord = 2 * half * sin(sweep * q / 2) / sweep
            return SurfacePoint(x: chord * cos(start + sweep * q / 2),
                                depth: chord * sin(start + sweep * q / 2), normal: cos(theta))
        }
        // 拱页在旋转纸面上叠加正弦弹性弓形；两端无额外位移，书脊固定。
        let bow = 0.20 * sin(angle)
        let wave = bow * sin(.pi * q)
        let slope = bow * .pi * cos(.pi * q)
        let tangentX = cos(angle) - slope * sin(angle)
        let tangentZ = sin(angle) + slope * cos(angle)
        return SurfacePoint(x: half * (q * cos(angle) - wave * sin(angle)),
                            depth: half * (q * sin(angle) + wave * cos(angle)),
                            normal: tangentX / hypot(tangentX, tangentZ))
    }
}
