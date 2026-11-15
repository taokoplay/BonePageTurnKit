import Foundation
#if canImport(CoreGraphics)
import CoreGraphics

/// 轮廓上的局部投影；宽度、透明度与偏移随纸角离开正文的高度连续变化。
struct PaperCornerShadowSample: Equatable {
    let width: CGFloat
    let opacity: CGFloat
    let offset: CGPoint
}

/// 按原 patch／材料顶点顺序只投影一次，轮廓与高度分布共用同一组点及归约结果。
fileprivate struct PaperCornerShadowProjection {
    let distance: CGFloat
    let normal: CGPoint
    let points: [CGPoint]
    let maximumDepth: CGFloat
    let rootCoordinate: CGFloat

    init?(drag: PaperCornerDrag, patches: [PaperCornerPatch]) {
        let distance = hypot(drag.translation.x, drag.translation.y)
        guard distance.isFinite, distance > 1e-7, drag.length.isFinite, drag.length > 0 else { return nil }
        let normal = CGPoint(x: -drag.translation.x / distance, y: -drag.translation.y / distance)
        var points: [CGPoint] = []
        points.reserveCapacity(patches.count * 4)
        var maximumDepth: CGFloat?, root: CGFloat?
        for patch in patches where patch.back {
            // 与 Sequence.max 相同：仅在更大时替换，保留原遍历及相等值顺序。
            if let maximum = maximumDepth {
                if maximum < patch.depth { maximumDepth = patch.depth }
            } else { maximumDepth = patch.depth }
            for source in patch.source {
                let point = source.applying(patch.transform)
                guard point.x.isFinite, point.y.isFinite else { return nil }
                points.append(point)
                let coordinate = normal.x * point.x + normal.y * point.y
                if let maximum = root {
                    if maximum < coordinate { root = coordinate }
                } else { root = coordinate }
            }
        }
        guard !points.isEmpty, let maximumDepth, maximumDepth.isFinite, maximumDepth >= 0,
              let root, root.isFinite else { return nil }
        self.distance = distance; self.normal = normal; self.points = points
        self.maximumDepth = maximumDepth; rootCoordinate = root
    }
}

/// 从折痕接触线到自由纸角的高度权重，最大抬升来自当前曲面的深度。
struct PaperCornerShadowProfile {
    let normal: CGPoint
    let rootCoordinate: CGFloat
    let tipCoordinate: CGFloat
    private let heightScale: CGFloat
    private let curvatureBlend: CGFloat
    private let fade: CGFloat

    /// - Parameters: drag: 当前抓取状态；patches: 同一帧的有序纸面。
    /// - Returns: 有效纸背对应的投影分布；平铺、零位移或非法几何返回 nil。
    init?(drag: PaperCornerDrag, patches: [PaperCornerPatch]) {
        guard let projection = PaperCornerShadowProjection(drag: drag, patches: patches) else { return nil }
        self.init(drag: drag, projection: projection)
    }

    fileprivate init?(drag: PaperCornerDrag, projection: PaperCornerShadowProjection) {
        normal = projection.normal
        let n = normal, root = projection.rootCoordinate
        let tip = n.x * drag.tip.x + n.y * drag.tip.y
        guard root.isFinite, tip.isFinite, root - tip > 1e-7 else { return nil }
        rootCoordinate = root; tipCoordinate = tip
        let endFade = min(1, max(0, (1 - drag.progress) / 0.15))
        let curvatureScale = min(1, projection.maximumDepth / max(1, drag.length * 0.12))
        // 书脊可达边界会把圆柱半径压到零；展开纸背仍需要轻量接触投影，不能随半径一起消失。
        let span = min(1, (root - tip) / max(1, drag.length * 0.5))
        let contactScale = 0.65 * span * span * (3 - 2 * span) * endFade
        let scale = max(curvatureScale, contactScale)
        heightScale = scale
        curvatureBlend = scale > 0 ? min(1, curvatureScale / scale) : 1
        fade = min(1, projection.distance / max(1, drag.length * 0.15)) * endFade
        guard fade > 0 else { return nil }
    }

    /// - Parameter point: 已投影纸背轮廓上的点。
    /// - Returns: 根部窄浅、纸角宽深的局部阴影，不改变纸背材质。
    func sample(at point: CGPoint) -> PaperCornerShadowSample {
        guard point.x.isFinite, point.y.isFinite else { return .init(width: 0, opacity: 0, offset: .zero) }
        let position = normal.x * point.x + normal.y * point.y
        let t = min(1, max(0, (rootCoordinate - position) / (rootCoordinate - tipCoordinate)))
        let curvedHeight = t * t * (3 - 2 * t)
        // 接近平折时，接触带应覆盖可见自由边，不因离屏纸角把整段边缘压成极淡细线。
        let contactT = min(1, t * 8)
        let contactHeight = contactT * contactT * (3 - 2 * contactT)
        let height = (curvedHeight * curvatureBlend + contactHeight * (1 - curvatureBlend)) * heightScale
        let width = (0.45 + 17.5 * height) * fade
        let opacity = (0.015 + 0.245 * height) * fade
        return .init(width: width, opacity: opacity, offset: CGPoint(x: 0, y: width * 0.18))
    }
}

/// 有界投影三角形顶点；同一组几何供 Metal 与软件参考使用。
struct PaperCornerShadowVertex {
    let point: CGPoint
    let opacity: CGFloat
}

enum PaperCornerShadowGeometry {
    /// - Parameters: drag: 当前抓取；patches: 当前纸面。
    /// - Returns: 连续三顶点组成三角形，透明度在边上和带宽内同时渐变；不分配位图。
    static func vertices(for drag: PaperCornerDrag, patches: [PaperCornerPatch]) -> [PaperCornerShadowVertex] {
        guard let projection = PaperCornerShadowProjection(drag: drag, patches: patches),
              let profile = PaperCornerShadowProfile(drag: drag, projection: projection) else { return [] }
        let hull = convexHull(projection.points)
        guard hull.count >= 3 else { return [] }
        // 长边按局部高度变化细分，避免只用折痕和纸角顶点把渐变带插值为近似等宽。
        let span = profile.rootCoordinate - profile.tipCoordinate
        var outline: [CGPoint] = []
        outline.reserveCapacity(hull.count + 32)
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let variation = abs(profile.normal.x * (b.x - a.x) + profile.normal.y * (b.y - a.y)) / span
            let count = max(1, min(16, Int(ceil(min(1, variation) * 16))))
            for step in 0..<count {
                let t = CGFloat(step) / CGFloat(count)
                outline.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        var inner: [PaperCornerShadowVertex] = [], outer: [PaperCornerShadowVertex] = []
        inner.reserveCapacity(outline.count); outer.reserveCapacity(outline.count)
        for i in outline.indices {
            let point = outline[i], prev = outline[(i + outline.count - 1) % outline.count], next = outline[(i + 1) % outline.count]
            let lenA = max(1e-6, hypot(point.x - prev.x, point.y - prev.y))
            let lenB = max(1e-6, hypot(next.x - point.x, next.y - point.y))
            let a = CGPoint(x: (point.y - prev.y) / lenA, y: -(point.x - prev.x) / lenA)
            let b = CGPoint(x: (next.y - point.y) / lenB, y: -(next.x - point.x) / lenB)
            let divisor = max(0.5, 1 + a.x * b.x + a.y * b.y)
            let local = profile.sample(at: point)
            // 内轮廓保留凸性；局部偏移只用于外羽化带，避免内扇形在长边交叠产生色点。
            inner.append(.init(point: point, opacity: local.opacity))
            outer.append(.init(point: CGPoint(x: point.x + local.offset.x + (a.x + b.x) * local.width / divisor,
                                              y: point.y + local.offset.y + (a.y + b.y) * local.width / divisor), opacity: 0))
        }
        var result: [PaperCornerShadowVertex] = []
        result.reserveCapacity((3 * outline.count - 2) * 3)
        for i in 1..<(inner.count - 1) { result.append(contentsOf: [inner[0], inner[i], inner[i + 1]]) }
        for i in inner.indices {
            let j = (i + 1) % inner.count
            result.append(contentsOf: [inner[i], inner[j], outer[j], inner[i], outer[j], outer[i]])
        }
        return result
    }

    /// - Parameter points: 纸背投影点。
    /// - Returns: 有序凸轮廓，合并共线片段，避免沿内部材料接缝叠加投影。
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 1e-7 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 1e-7 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast(); return lower + upper
    }
}
#endif
