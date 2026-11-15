import Foundation
#if canImport(CoreGraphics)
import CoreGraphics

/// 一次触点卷页的材料范围及抓取偏移；只保存值，不持有视图。
struct PaperCornerDrag: Equatable {
    let page: CGRect
    let canvasSize: CGSize
    private(set) var hasContact = false
    let axis: PageTurnAxis
    let origin: CGPoint
    private(set) var corner: CGPoint
    let inwardSign: CGFloat
    var translation: CGPoint = .zero
    /// 横拖起步先按整页平翻；出现明确横跨位移后允许继续跟随滑动角度。
    var prefersFlatTurn = false {
        didSet { if prefersFlatTurn { preservesGrabHeight = true } }
    }
    /// 曾按整边抓取的手势转向后仍保留原抓取高度，避免突然重新锚定到纸角。
    private var preservesGrabHeight = false

    /// 小幅手抖保持平翻；越过该距离后，本次手势持续采用真实二维触点。
    mutating func trackPanAngle(to point: CGPoint) {
        guard prefersFlatTurn, point.x.isFinite, point.y.isFinite else { return }
        let cross = axis == .horizontal ? point.y - origin.y : point.x - origin.x
        if abs(cross) > 8 { prefersFlatTurn = false }
    }

    /// 起手已主要沿翻页轴移动时选择整页平翻；仅有微小位移时用速度辅助判定。
    static func isFlatGesture(translation: CGPoint, velocity: CGPoint, axis: PageTurnAxis) -> Bool {
        guard translation.x.isFinite, translation.y.isFinite,
              velocity.x.isFinite, velocity.y.isFinite else { return false }
        let motion = max(abs(translation.x), abs(translation.y)) >= 4 ? translation : velocity
        let primary = abs(axis == .horizontal ? motion.x : motion.y)
        let cross = abs(axis == .horizontal ? motion.y : motion.x)
        return primary > 0 && primary >= cross * 2
    }

    var length: CGFloat { axis == .horizontal ? page.width : page.height }
    var progress: CGFloat {
        let primary = axis == .horizontal ? translation.x : translation.y
        return min(1, max(0, primary * inwardSign / (2 * length)))
    }

    /// 手指从原按下点实际移动的进度，独立于按下位置对应的初始折起程度。
    var gestureProgress: CGFloat {
        let primary = axis == .horizontal ? gripPosition.x - origin.x : gripPosition.y - origin.y
        return min(1, max(0, primary * inwardSign / (2 * length)))
    }
    /// 抓取点沿本次物理翻页方向到达画布中线；独立于手指从按下点累计的距离。
    var hasReachedCanvasMidpoint: Bool {
        let primary = axis == .horizontal ? gripPosition.x : gripPosition.y
        let midpoint = (axis == .horizontal ? canvasSize.width : canvasSize.height) / 2
        return (primary - midpoint) * inwardSign >= 0
    }

    /// 默认按横轴边缘抓角；手指主要沿翻页轴平移时由手势层打开 `prefersFlatTurn`，改为整页平翻。
    private var locksCorner: Bool {
        guard !prefersFlatTurn && !preservesGrabHeight else { return false }
        let cross = axis == .horizontal ? origin.y : origin.x
        let start = axis == .horizontal ? page.minY : page.minX
        let extent = axis == .horizontal ? page.height : page.width
        return cross < start + extent * 0.25 || cross > start + extent * 0.75
    }

    /// 材料上的抓取基准；中段保留实际抓取高度，角落仍锚定原始纸角。
    var gripOrigin: CGPoint {
        guard !locksCorner else { return corner }
        return axis == .horizontal ? CGPoint(x: corner.x, y: origin.y) : CGPoint(x: origin.x, y: corner.y)
    }
    var gripPosition: CGPoint { CGPoint(x: gripOrigin.x + translation.x, y: gripOrigin.y + translation.y) }

    /// 自由纸角的实际投影；中段抓取时与抓取基准分开，供轮廓投影使用。
    var tip: CGPoint {
        guard !locksCorner else { return CGPoint(x: corner.x + translation.x, y: corner.y + translation.y) }
        let distance = hypot(translation.x, translation.y)
        guard distance > 1e-7 else { return corner }
        let normal = CGPoint(x: -translation.x / distance, y: -translation.y / distance)
        let shift = 2 * (normal.x * (gripOrigin.x - corner.x) + normal.y * (gripOrigin.y - corner.y)) - distance
        return CGPoint(x: corner.x + shift * normal.x, y: corner.y + shift * normal.y)
    }

    /// - Parameters: size: 零原点画布；axis: 翻页轴；spread: 中央双页；inwardSign: 当前逻辑方向的物理符号；origin: 画布内按下位置。
    /// - Returns: 从当前物理边初始化；角落起拖锁角，中段起拖随移动选择折向，非法输入返回 nil。
    init?(size: CGSize, axis: PageTurnAxis, spread: Bool, inwardSign: CGFloat, origin: CGPoint) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 1e7, size.height <= 1e7,
              origin.x.isFinite, origin.y.isFinite,
              (0...size.width).contains(origin.x), (0...size.height).contains(origin.y),
              inwardSign == -1 || inwardSign == 1 else { return nil }
        self.axis = axis; self.origin = origin; self.inwardSign = inwardSign; self.canvasSize = size
        let entire = CGRect(origin: .zero, size: size)
        let fromMaximum = inwardSign < 0
        if spread, axis == .horizontal {
            page = CGRect(x: fromMaximum ? size.width / 2 : 0, y: 0, width: size.width / 2, height: size.height)
        } else if spread {
            page = CGRect(x: 0, y: fromMaximum ? size.height / 2 : 0, width: size.width, height: size.height / 2)
        } else { page = entire }
        corner = axis == .horizontal
            ? CGPoint(x: fromMaximum ? page.maxX : page.minX, y: origin.y < page.midY ? page.minY : page.maxY)
            : CGPoint(x: origin.x < page.midX ? page.minX : page.maxX, y: fromMaximum ? page.maxY : page.minY)
    }

    /// - Parameter point: 当前画布绝对触点；可达范围内直接对齐纸面控制点，不叠加起始偏移或跟随缓动。
    /// - Returns: 受书脊可达范围约束的新状态；非法值返回 nil。
    func moved(to point: CGPoint, direction: PageTurnDirection = .next) -> Self? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        // 已选择平翻的手势只沿主轴推进，手指的轻微上下／左右抖动不再倾斜折痕。
        let point = prefersFlatTurn ? (axis == .horizontal
            ? CGPoint(x: point.x, y: origin.y) : CGPoint(x: origin.x, y: point.y)) : point
        if direction == .previous {
            // 回翻只由正在展开的材料限位，不能先被交互侧的另一组书脊距离截掉触点。
            let reflected = axis == .horizontal
                ? CGPoint(x: canvasSize.width - origin.x, y: origin.y)
                : CGPoint(x: origin.x, y: canvasSize.height - origin.y)
            guard var material = Self(size: canvasSize, axis: axis, spread: page.size != canvasSize,
                inwardSign: -inwardSign, origin: reflected) else { return nil }
            material.prefersFlatTurn = prefersFlatTurn
            material.preservesGrabHeight = preservesGrabHeight
            guard let folded = material.moved(to: point) else { return nil }
            return folded.interactivePresentation(direction: .previous, size: canvasSize, spread: page.size != canvasSize)
        }
        if point == gripPosition { var contacted = self; contacted.hasContact = true; return contacted }
        let dx = point.x - gripOrigin.x, dy = point.y - gripOrigin.y
        guard dx.isFinite, dy.isFinite else { return nil }
        var next = self
        next.hasContact = true
        let primary = axis == .horizontal ? dx : dy
        let pull = min(2 * length, max(0, primary * inwardSign))
        if axis == .horizontal {
            next.translation.x = inwardSign * pull
            let atCorner = locksCorner
            // 中段直拖时两角产生相同纸面；离开零横移后按移动方向折起相应纸角。
            if !atCorner, dy != 0 { next.corner.y = dy > 0 ? page.minY : page.maxY }
            // 纸角只能到达以相邻书脊端点为圆心、页宽为半径的圆盘；约束与松手线性路径相容。
            let fromHinge = length - abs(next.translation.x)
            let crossLimit = min(page.height, sqrt(max(0, length * length - fromHinge * fromHinge)))
            if atCorner {
                next.translation.y = next.corner.y == page.minY ? min(crossLimit, max(0, dy)) : max(-crossLimit, min(0, dy))
            } else {
                next.translation.y = Self.boundedMiddleCross(dy, origin: origin.y - page.minY, extent: page.height,
                    reach: max(0, length * length - fromHinge * fromHinge))
            }
        } else {
            next.translation.y = inwardSign * pull
            let atCorner = locksCorner
            if !atCorner, dx != 0 { next.corner.x = dx > 0 ? page.minX : page.maxX }
            let fromHinge = length - abs(next.translation.y)
            let crossLimit = min(page.width, sqrt(max(0, length * length - fromHinge * fromHinge)))
            if atCorner {
                next.translation.x = next.corner.x == page.minX ? min(crossLimit, max(0, dx)) : max(-crossLimit, min(0, dx))
            } else {
                next.translation.x = Self.boundedMiddleCross(dx, origin: origin.x - page.minX, extent: page.width,
                    reach: max(0, length * length - fromHinge * fromHinge))
            }
        }
        let cross = axis == .horizontal ? next.translation.y : next.translation.x
        let crossOrigin = axis == .horizontal ? next.gripOrigin.y - page.minY : next.gripOrigin.x - page.minX
        let extent = axis == .horizontal ? page.height : page.width
        let curvedCross = Self.boundedCurvedCross(cross, pull: pull, length: length,
            origin: crossOrigin, extent: extent)
        if axis == .horizontal { next.translation.y = curvedCross }
        else { next.translation.x = curvedCross }
        return next
    }

    /// - Parameters: value: 已满足平折距离的横轴位移；pull: 向内主轴距离；length: 页宽；origin: 抓取横坐标；extent: 横轴全长。
    /// - Returns: 为圆柱展开弧长保留空间的横移；普通可达触点保持原值，越界时连续限位。
    private static func boundedCurvedCross(_ value: CGFloat, pull: CGFloat, length: CGFloat,
                                           origin: CGFloat, extent: CGFloat) -> CGFloat {
        guard value != 0, pull > 0, pull < 2 * length else { return 0 }
        let magnitude = abs(value)
        let hingeOffset = value > 0 ? origin : extent - origin
        let reach = pull * (2 * length - pull)
        /// 平折的距离预算还必须覆盖圆柱弧，确保折痕不越过任一书脊端点。
        func hasRoom(_ cross: CGFloat) -> Bool {
            let distance = hypot(pull, cross)
            let radius = PaperCornerCurlGeometry.preferredRadius(length: length, pull: pull, distance: distance)
            return reach - cross * (cross + 2 * hingeOffset) >= .pi * radius * distance
        }
        guard !hasRoom(magnitude) else { return value }
        var lower: CGFloat = 0, upper = magnitude
        // 单调约束有唯一界线；固定上限的二分不分配对象，也不影响原生动画时序。
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            if hasRoom(middle) { lower = middle } else { upper = middle }
        }
        return value > 0 ? lower : -lower
    }

    /// - Parameters: value: 横轴位移；origin: 中部抓取高度；extent: 纸面横轴长度；reach: 主轴向内移动释放的距离平方。
    /// - Returns: 保持两端书脊距离上限的位移；有理化计算避免微小移动时相减损失精度。
    private static func boundedMiddleCross(_ value: CGFloat, origin: CGFloat, extent: CGFloat, reach: CGFloat) -> CGFloat {
        guard reach > 0 else { return 0 }
        let opposite = extent - origin
        let positive = min(opposite, reach / (sqrt(origin * origin + reach) + origin))
        let negative = min(origin, reach / (sqrt(opposite * opposite + reach) + opposite))
        return min(positive, max(-negative, value))
    }

    /// - Parameters: direction: 逻辑方向；size: 整个画布；spread: 是否为中央双页。
    /// - Returns: 实际材料折面；回翻直接使用触点坐标，未接触的起始帧保持上一张纸完全折出。
    func foldingPresentation(direction: PageTurnDirection, size: CGSize, spread: Bool) -> Self? {
        guard direction == .previous else { return self }
        let reflectedOrigin = axis == .horizontal
            ? CGPoint(x: size.width - origin.x, y: origin.y)
            : CGPoint(x: origin.x, y: size.height - origin.y)
        guard var folding = Self(size: size, axis: axis, spread: spread,
            inwardSign: -inwardSign, origin: reflectedOrigin) else { return nil }
        folding.prefersFlatTurn = prefersFlatTurn
        folding.preservesGrabHeight = preservesGrabHeight
        guard hasContact else { return folding.released(completed: true, fraction: 1) }
        return folding.moved(to: gripPosition)
    }

    /// - Parameters: direction: 原交互逻辑方向；size: 画布；spread: 是否双页。
    /// - Returns: 从已显示的材料姿态还原交互坐标；回翻起手或取消可位于画布外，不能再钳制到页边。
    func interactivePresentation(direction: PageTurnDirection, size: CGSize, spread: Bool) -> Self? {
        guard direction == .previous else { return self }
        let reflectedOrigin = axis == .horizontal
            ? CGPoint(x: size.width - origin.x, y: origin.y)
            : CGPoint(x: origin.x, y: size.height - origin.y)
        guard var seed = Self(size: size, axis: axis, spread: spread,
            inwardSign: -inwardSign, origin: reflectedOrigin) else { return nil }
        seed.prefersFlatTurn = prefersFlatTurn
        seed.preservesGrabHeight = preservesGrabHeight
        guard var input = seed.moved(to: gripPosition) else { return nil }
        input.translation = CGPoint(x: gripPosition.x - input.gripOrigin.x, y: gripPosition.y - input.gripOrigin.y)
        return input
    }

    /// - Parameters: completed: 完成或取消；fraction: 收尾比例；direction: 逻辑方向，默认保留正翻几何接口。
    /// - Returns: 从当前已显示触点连续收敛的姿态；回翻完成到对侧页边，取消退回画布外。
    func released(completed: Bool, fraction: CGFloat, direction: PageTurnDirection = .next) -> Self {
        guard fraction.isFinite else { return self }
        let t = min(1, max(0, fraction))
        let end: CGPoint
        if direction == .previous {
            let extent = axis == .horizontal ? canvasSize.width : canvasSize.height
            let primaryOrigin = axis == .horizontal ? gripOrigin.x : gripOrigin.y
            let landing = extent - primaryOrigin
            let endPrimary = landing - primaryOrigin - (completed ? 0 : inwardSign * 2 * length)
            end = axis == .horizontal ? CGPoint(x: endPrimary, y: 0) : CGPoint(x: 0, y: endPrimary)
        } else {
            end = !completed ? .zero : (axis == .horizontal
                ? CGPoint(x: inwardSign * 2 * length, y: 0) : CGPoint(x: 0, y: inwardSign * 2 * length))
        }
        var next = self
        next.translation = CGPoint(x: translation.x + (end.x - translation.x) * t,
                                   y: translation.y + (end.y - translation.y) * t)
        return next
    }

    /// 快速松手时仍经过最后手势的斜向意图，起点、落点和时间参数保持原收尾定义。
    func released(completed: Bool, fraction: CGFloat, direction: PageTurnDirection,
                  angleIntent: Self?) -> Self {
        let base = released(completed: completed, fraction: fraction, direction: direction)
        guard completed, fraction.isFinite, let intent = angleIntent,
              intent.axis == axis, intent.page == page, intent.canvasSize == canvasSize,
              intent.origin == origin, intent.inwardSign == inwardSign,
              !intent.prefersFlatTurn else { return base }
        let t = min(1, max(0, fraction))
        guard t > 0, t < 1 else { return base }
        let end = released(completed: true, fraction: 1, direction: direction).gripPosition
        let startCross = axis == .horizontal ? gripPosition.y : gripPosition.x
        let endCross = axis == .horizontal ? end.y : end.x
        let intentCross = axis == .horizontal ? intent.gripPosition.y : intent.gripPosition.x
        guard abs(intentCross - endCross) > 8, abs(intentCross - startCross) > 8 else { return base }
        let remainder = 1 - t
        // 补偿在首尾平滑归零，保持原端点的运动方向，避免临近落页仍残留大块斜折。
        let baseCross = axis == .horizontal ? base.gripPosition.y : base.gripPosition.x
        let weight = 16 * t * t * remainder * remainder
        let cross = baseCross + (intentCross - (startCross + endCross) / 2) * weight
        var point = base.gripPosition
        if axis == .horizontal { point.y = cross } else { point.x = cross }
        var directed = base
        directed.prefersFlatTurn = false
        return directed.moved(to: point, direction: direction) ?? base
    }

}

/// 局部材料多边形及其线性投影；圆柱弧按有限数量切片，平面部分只采样一次。
struct PaperCornerPatch {
    let source: [CGPoint]
    let transform: CGAffineTransform
    let depth: CGFloat
    let back: Bool
    let shade: CGFloat
    var projected: [CGPoint] { source.map { $0.applying(transform) } }
}

/// 可旋转折痕的圆柱纸面；纸角的投影严格跟随经过约束的触点偏移。
enum PaperCornerCurlGeometry {
    private struct StripAngles {
        let theta0: CGFloat
        let theta1: CGFloat
        let sine0: CGFloat
        let sine1: CGFloat
        let middleCosine: CGFloat
        let back: Bool
    }

    /// 每种实际偶数细分只计算一次；数组发布后保持不可变，纯几何调用不依赖主线程。
    private final class StripAngleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [Int: [StripAngles]] = [:]

        func angles(for count: Int) -> [StripAngles] {
            lock.lock()
            defer { lock.unlock() }
            if let table = tables[count] { return table }
            let table = (0..<count).map { index -> StripAngles in
                // 保留原先的 CGFloat 乘除及中点运算顺序，不用递推角度或 Double 表。
                let theta0 = CGFloat.pi * CGFloat(index) / CGFloat(count)
                let theta1 = CGFloat.pi * CGFloat(index + 1) / CGFloat(count)
                let middle = (theta0 + theta1) / 2
                return StripAngles(theta0: theta0, theta1: theta1,
                    sine0: sin(theta0), sine1: sin(theta1),
                    middleCosine: cos(middle), back: middle > .pi / 2)
            }
            tables[count] = table
            return table
        }
    }

    private static let stripAngleCache = StripAngleCache()

    /// 单页材料在画布内的实际投影占比，仅供松手判定；不修改曲面、不读回 GPU。
    /// 正面切片的投影互不重叠；落在原纸面矩形内的背片投影已包含在正面投影内。
    static func visiblePaperFraction(for drag: PaperCornerDrag, stripCount: Int) -> CGFloat? {
        let canvas = CGRect(origin: .zero, size: drag.canvasSize)
        let total = canvas.width * canvas.height
        guard drag.page == canvas, total.isFinite, total > 0, (32...256).contains(stripCount) else { return nil }
        var area: CGFloat = 0
        for patch in patches(for: drag, stripCount: stripCount) where !patch.back {
            var polygon = patch.projected
            polygon = clip(polygon, normal: CGPoint(x: 1, y: 0), boundary: 0, keepLower: false)
            polygon = clip(polygon, normal: CGPoint(x: 1, y: 0), boundary: canvas.width, keepLower: true)
            polygon = clip(polygon, normal: CGPoint(x: 0, y: 1), boundary: 0, keepLower: false)
            polygon = clip(polygon, normal: CGPoint(x: 0, y: 1), boundary: canvas.height, keepLower: true)
            guard polygon.count >= 3, let origin = polygon.first else { continue }
            for index in 1..<(polygon.count - 1) {
                let a = polygon[index], b = polygon[index + 1]
                area += abs((a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)) / 2
            }
        }
        return min(1, max(0, area / total))
    }

    /// - Parameters: length: 翻页轴页长；pull: 主轴向内位移；distance: 完整二维抓取距离。
    /// - Returns: 输入限位与曲面投影共用的目标半径；落页前留出横向转动余量，两个端点归零。
    static func preferredRadius(length: CGFloat, pull: CGFloat, distance: CGFloat) -> CGFloat {
        let fade = min(1, max(0, (1 - pull / (2 * length)) / 0.15))
        let radius = min(length * 0.10, distance * 0.12) * fade
        // 靠近落页时最多使用九成书脊间距，避免可达横移提前被压成零。
        return min(radius, max(0, 2 * length - pull) * 0.9 / .pi)
    }

    /// - Parameters: drag: 当前抓取状态；stripCount: 圆柱精度。返回按深度由远到近排列的纸面，无位图分配。
    static func patches(for drag: PaperCornerDrag, stripCount: Int) -> [PaperCornerPatch] {
        guard (32...256).contains(stripCount) else { return [] }
        let rect = drag.page
        let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let distance = hypot(drag.translation.x, drag.translation.y)
        guard distance > 1e-7 else {
            return [.init(source: polygon, transform: .identity, depth: 0, back: false, shade: 0)]
        }
        let normal = CGPoint(x: -drag.translation.x / distance, y: -drag.translation.y / distance)
        let coordinate: (CGPoint) -> CGFloat = { normal.x * $0.x + normal.y * $0.y }
        let gripValue = coordinate(drag.gripOrigin), tipValue = coordinate(drag.gripPosition)
        let hinge: [CGPoint]
        if drag.axis == .horizontal {
            let x = drag.inwardSign < 0 ? rect.minX : rect.maxX
            hinge = [CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)]
        } else {
            let y = drag.inwardSign < 0 ? rect.minY : rect.maxY
            hinge = [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
        }
        let hingeLimit = hinge.map(coordinate).max() ?? 0
        let clearance = max(0, (gripValue + tipValue) / 2 - hingeLimit)
        // 交互触点已为弧长限位；内部平折及收尾仍受书脊约束，不能用半径下限撕开装订边。
        let pull = drag.progress * 2 * drag.length
        let radius = min(preferredRadius(length: drag.length, pull: pull, distance: distance), clearance * 2 / .pi)
        let arcLength = CGFloat.pi * radius
        let crease = (gripValue + tipValue - arcLength) / 2
        let values = polygon.map(coordinate)
        guard let lower = values.min(), let upper = values.max() else { return [] }
        var result: [PaperCornerPatch] = []
        result.reserveCapacity(stripCount + 2)
        // 凸矩形经两次半平面裁切至多六点；缓冲只在本次计算内复用。
        var lowerScratch: [CGPoint] = [], upperScratch: [CGPoint] = []
        lowerScratch.reserveCapacity(8); upperScratch.reserveCapacity(8)

        /// 在原图材料坐标中裁切，再以同一仿射映射投影；保持相邻边界严格一致。
        func append(from a: CGFloat, to b: CGFloat, projectedA: CGFloat, projectedB: CGFloat,
                    depth: CGFloat, back: Bool, shade: CGFloat) {
            guard b - a > 1e-8 else { return }
            clip(polygon, normal: normal, boundary: a, keepLower: false, into: &lowerScratch)
            clip(lowerScratch, normal: normal, boundary: b, keepLower: true, into: &upperScratch)
            guard upperScratch.count >= 3 else { return }
            let slope = (projectedB - projectedA) / (b - a)
            guard abs(slope) > 1e-10 else { return }
            let shift = projectedA - slope * a
            let dx = (slope - 1) * normal.x, dy = (slope - 1) * normal.y
            let transform = CGAffineTransform(a: 1 + dx * normal.x, b: dy * normal.x,
                                              c: dx * normal.y, d: 1 + dy * normal.y,
                                              tx: shift * normal.x, ty: shift * normal.y)
            // 独立复制至多六个点，避免与可复用 scratch 共用存储。
            var source: [CGPoint] = []
            source.reserveCapacity(upperScratch.count)
            for point in upperScratch { source.append(point) }
            result.append(.init(source: source, transform: transform, depth: depth, back: back, shade: shade))
        }
        let flatEnd = min(upper, crease)
        append(from: lower, to: flatEnd, projectedA: lower, projectedB: flatEnd, depth: 0, back: false, shade: 0)
        if radius > 1e-8 {
            // 偶数细分保证正反面的分界恰好落在 π/2，不跨越零法向制作一条材料。
            let count = stripCount / 2 * 2
            for angles in stripAngleCache.angles(for: count) {
                let depth = radius * (1 - angles.middleCosine)
                append(from: crease + radius * angles.theta0, to: crease + radius * angles.theta1,
                       projectedA: crease + radius * angles.sine0, projectedB: crease + radius * angles.sine1,
                       depth: depth, back: angles.back,
                       shade: 0.20 * (1 - abs(angles.middleCosine)) + 0.025 * depth / drag.length)
            }
        }
        let backStart = max(lower, crease + arcLength)
        append(from: backStart, to: upper, projectedA: 2 * crease + arcLength - backStart,
               projectedB: 2 * crease + arcLength - upper, depth: 2 * radius, back: true, shade: 0.025 * 2 * radius / drag.length)
        // 深度依次为 0、r * (1 - cos(中点角))、2r；直接保留追加顺序也保留同深度顺序。
        return result
    }

    /// - Parameters: polygon: 凸材料多边形；normal: 单位折痕法向；boundary: 投影界线；keepLower: 保留哪侧。
    /// - Returns: 半平面裁切后的多边形，不插入非有限交点。
    private static func clip(_ polygon: [CGPoint], normal: CGPoint, boundary: CGFloat, keepLower: Bool) -> [CGPoint] {
        var result: [CGPoint] = []
        clip(polygon, normal: normal, boundary: boundary, keepLower: keepLower, into: &result)
        return result
    }

    /// 与返回数组版本使用相同的交点运算及顶点顺序；调用方提供独立的输出缓冲。
    private static func clip(_ polygon: [CGPoint], normal: CGPoint, boundary: CGFloat, keepLower: Bool,
                             into result: inout [CGPoint]) {
        result.removeAll(keepingCapacity: true)
        guard var previous = polygon.last else { return }
        var previousDistance = normal.x * previous.x + normal.y * previous.y - boundary
        for current in polygon {
            let distance = normal.x * current.x + normal.y * current.y - boundary
            let wasInside = keepLower ? previousDistance <= 0 : previousDistance >= 0
            let isInside = keepLower ? distance <= 0 : distance >= 0
            if wasInside != isInside {
                let ratio = previousDistance / (previousDistance - distance)
                result.append(CGPoint(x: previous.x + (current.x - previous.x) * ratio,
                                      y: previous.y + (current.y - previous.y) * ratio))
            }
            if isInside { result.append(current) }
            previous = current; previousDistance = distance
        }
    }
}
#endif
