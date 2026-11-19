import Foundation
#if canImport(CoreGraphics)
import CoreGraphics

/// 固定装订边的可展纸面：沿材料弧长弯曲，不以平面剪切补偿触点。
enum PaperArchGeometry {
    private static let crossProjection: CGFloat = 0.22
    private static let shadowOffset = CGPoint(x: 0.12, y: 0.16)
    private static let shadowSoftness: [CGFloat] = [0.7, 1.3]
    private static let edgeShadowBaseWidth: CGFloat = 1.8
    private static let edgeShadowHeightSlope: CGFloat = 0.065

    struct Sample {
        let source: CGPoint
        let point: CGPoint
        let worldPoint: CGPoint
        let height: CGFloat
    }
    struct Mesh {
        let patches: [PaperCornerPatch]
        let shades: [[CGFloat]]
        let shadow: [PaperCornerShadowVertex]
        let samples: [Sample]
        static let empty = Mesh(patches: [], shades: [], shadow: [], samples: [])
    }

    private struct Vector {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
        static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        static func * (a: Self, b: CGFloat) -> Self { Self(x: a.x * b, y: a.y * b, z: a.z * b) }
        var length: CGFloat { sqrt(x * x + y * y + z * z) }
        var unit: Self { length > 1e-24 ? self * (1 / length) : Self(x: 0, y: 0, z: 1) }
        func dot(_ b: Self) -> CGFloat { x * b.x + y * b.y + z * b.z }
        func cross(_ b: Self) -> Self {
            Self(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x)
        }
    }

    /// 圆柱使用单位速率平面曲线；圆锥使用单位速率球面曲线。
    /// 相邻球面节点按大圆插值，因此每一条带是原材料平面的刚性转动。
    private struct Profile {
        struct Knot {
            let material: CGFloat
            let value: Vector
            let normal: Vector
        }
        private struct Build {
            let points: [Vector]
            let distances: [CGFloat]
            let energy: CGFloat
            let amplitude: CGFloat
        }
        let span: CGFloat
        let end: CGFloat
        let radius: CGFloat?
        let knots: [Knot]
        private var freePanel: Panel?
        private var flatTailHeight: CGFloat = 0
        /// 圆弯后水平纸段的高度；按住时为零，完成回卷时由两段圆弧的共同切线决定。
        /// 书脊到指腹的拱腹与指腹外平贴段共用一条材料坐标；完成收尾时平贴段暂时抬成低矮上层形成回卷。
        init(slidingLength length: CGFloat, contact: CGFloat, distance: CGFloat, finish: CGFloat, count: Int) {
            let bendLength = max(1e-6, min(contact, length))
            let tailLength = max(0, length - bendLength)
            let flatBlend = smooth(finish / 0.86)
            let baseFlatLength = distance < 0
                ? min(bendLength * 0.18, -distance * 0.45) * smooth(finish / 0.14) : 0
            let flatLength = distance < 0
                ? max(baseFlatLength, min(bendLength * 0.72, -distance * 1.35 * flatBlend)) : 0
            let bentSpan = max(1e-6, bendLength - flatLength)
            let bent = Profile(span: bentSpan, end: distance + flatLength, radius: nil,
                count: max(32, count), unfolding: false, pressure: 1)
            let requestedTailHeight = min(12, contact * 0.1) * smooth(finish) * (1 - smooth(finish))
            // 用短弧抬起外侧纸段，随后沿同一切线平贴；限制抬升速率使每个节点保持单位材料弧长。
            let tailHeight = tailLength > 1e-8 ? min(requestedTailHeight, tailLength * 0.06) : 0
            var nodes: [Knot] = [Knot(material: 0, value: Vector(x: 0, y: 0, z: 0),
                normal: Vector(x: 0, y: 0, z: 1))]
            if flatLength > 1e-8 {
                nodes.append(Knot(material: flatLength, value: Vector(x: -flatLength, y: 0, z: 0),
                    normal: Vector(x: 0, y: 0, z: 1)))
            }
            nodes += bent.knots.dropFirst().map { knot in
                Knot(material: flatLength + knot.material,
                    value: Vector(x: knot.value.x - flatLength, y: knot.value.y, z: knot.value.z),
                    normal: knot.normal)
            }
            let tailCount = max(12, count / 3)
            if tailLength > 1e-8 {
                let tailStep = tailLength / CGFloat(tailCount)
                var previous = nodes.last?.value ?? Vector(x: distance, y: 0, z: 0)
                for index in 1...tailCount {
                    let t = CGFloat(index) / CGFloat(tailCount)
                    let height = tailHeight * smooth(min(1, t / 0.1))
                    let rise = height - previous.z
                    let horizontal = sqrt(max(0, tailStep * tailStep - rise * rise))
                    let value = Vector(x: previous.x + horizontal, y: 0, z: height)
                    let normal = Vector(x: -rise, y: 0, z: horizontal).unit
                    nodes.append(Knot(material: bendLength + tailLength * t, value: value, normal: normal))
                    previous = value
                }
            }
            self.span = length; self.end = distance; self.radius = nil; self.knots = nodes
            let tailEnd = nodes.last?.value ?? bent.knots.last?.value ?? Vector(x: distance, y: 0, z: 0)
            freePanel = Panel(p: tailEnd, t: Vector(x: 1, y: 0, z: 0), n: Vector(x: 0, y: 0, z: 1))
            flatTailHeight = tailHeight
        }

        /// 圆柱沿直线推进，圆锥沿单位球的大圆推进；每段保持材料长度和横向度量。
        private struct Panel {
            var p: Vector
            var t = Vector(x: 1, y: 0, z: 0)
            var n = Vector(x: 0, y: 0, z: 1)

            mutating func advance(_ step: CGFloat, sphere: Bool, cosine: CGFloat, sine: CGFloat) {
                if sphere {
                    let old = p
                    p = old * cosine + t * sine
                    t = t * cosine - old * sine
                } else { p = p + t * step }
            }

            mutating func bend(cosine: CGFloat, sine: CGFloat) {
                let old = t
                t = old * cosine + n * sine
                n = n * cosine - old * sine
            }
        }

        /// 装订端到指腹保留一段宽圆弧；指腹及外缘沿末端切面延续，而非在中缝逐列折返。
        init(bookSpan: CGFloat, gripEnd: CGFloat, pad: CGFloat, radius: CGFloat?, count: Int, carry: CGFloat) {
            let body = bookSpan - pad
            let pressed = body * (1 - carry)
            let pressedEnd = pressed - (bookSpan - gripEnd) * (1 - carry * carry)
            let arc = body * carry
            let bendCount = max(8, Int((CGFloat(count) * carry).rounded()))
            let step = arc / CGFloat(bendCount)
            let azimuth = radius.map { pressedEnd / $0 } ?? 0
            let ca0 = cos(azimuth), sa0 = sin(azimuth)
            func afterPress(_ v: Vector, position: Bool) -> Vector {
                if radius == nil { return Vector(x: v.x + (position ? pressedEnd : 0), y: v.y, z: v.z) }
                return Vector(x: ca0 * v.x + sa0 * v.y, y: ca0 * v.y - sa0 * v.x, z: v.z)
            }
            let sphere = radius != nil, angle = radius.map { step / $0 } ?? 0
            let cs = cos(angle), sn = sin(angle)
            let start = Panel(p: Vector(x: 0, y: sphere ? 1 : 0, z: 0))
            func trace(_ turn: CGFloat, visit: (Int, Panel) -> Void) -> Panel {
                var frame = start
                let delta = turn / CGFloat(bendCount - 1), c = cos(delta), s = sin(delta)
                visit(0, frame)
                for i in 1...bendCount {
                    frame.advance(step, sphere: sphere, cosine: cs, sine: sn)
                    if i < bendCount { frame.bend(cosine: c, sine: s) }
                    visit(i, frame)
                }
                return frame
            }
            let padAngle = radius.map { pad / $0 } ?? 0
            let segment = Vector(x: sin(angle + padAngle), y: cos(angle + padAngle), z: 0)
            let sa = sin(angle / 2), ca = cos(angle / 2)
            func grip(_ turn: CGFloat) -> Vector {
                let halfStep = turn / (2 * CGFloat(bendCount - 1))
                if !sphere {
                    // 等长线段的方向为等差角；求和直接给出弧端与平直指腹端点。
                    let chord = halfStep == 0 ? arc : step * sin(CGFloat(bendCount) * halfStep) / sin(halfStep)
                    return Vector(x: chord * cos(turn / 2) + pad * cos(turn), y: 0,
                        z: chord * sin(turn / 2) + pad * sin(turn))
                }
                // 球面条带每步同一局部旋转；其四元数的 count-1 次幂作用于最后一段。
                let sb = sin(halfStep), cb = cos(halfStep)
                let axis = Vector(x: -sa * sb, y: -ca * sb, z: -sa * cb)
                let norm = axis.length
                guard norm > 0 else { return segment }
                let halfAngle = CGFloat(bendCount - 1) * atan2(norm, ca * cb)
                let v = axis * (sin(halfAngle) / norm), offset = v.cross(segment) * 2
                return segment + offset * cos(halfAngle) + v.cross(offset)
            }
            var lo: CGFloat = 0, hi: CGFloat = .pi
            if bookSpan - gripEnd > bookSpan * 1e-13 {
                for _ in 0..<38 {
                    let mid = (lo + hi) / 2, end = afterPress(grip(mid), position: true)
                    let chord = hypot(end.x, end.z)
                    let reach = radius.map { $0 * atan2(chord, end.y) } ?? chord
                    if reach > gripEnd { lo = mid } else { hi = mid }
                }
            } else { hi = 0 }
            let turn = (lo + hi) / 2, end = afterPress(grip(turn), position: true)
            let heading = atan2(end.z, end.x), c = cos(heading), s = sin(heading)
            func align(_ v: Vector) -> Vector { Vector(x: c * v.x + s * v.z, y: v.y, z: c * v.z - s * v.x) }
            var nodes: [Knot] = []
            if pressed > 0 {
                let dome = Profile(span: pressed, end: pressedEnd, radius: radius, count: max(16, count - bendCount))
                nodes.reserveCapacity(dome.knots.count + bendCount)
                for k in dome.knots.dropLast() {
                    nodes.append(Knot(material: k.material, value: align(k.value), normal: align(k.normal)))
                }
            }
            let last = trace(turn) { i, frame in
                nodes.append(Knot(material: pressed + arc * CGFloat(i) / CGFloat(bendCount),
                    value: align(afterPress(frame.p, position: true)), normal: align(afterPress(frame.n, position: false))))
            }
            self.span = body; self.end = gripEnd; self.radius = radius; self.knots = nodes
            freePanel = Panel(p: align(afterPress(last.p, position: true)), t: align(afterPress(last.t, position: false)),
                n: align(afterPress(last.n, position: false)))
        }

        private static func distance(_ a: Vector, _ b: Vector, radius: CGFloat?) -> CGFloat {
            if let radius { return 2 * radius * atan2((b - a).length, (b + a).length) }
            return (b - a).length
        }
        private static func build(span: CGFloat, end: CGFloat, radius: CGFloat?, handle: CGFloat, skew: CGFloat,
                                  parameters: [CGFloat], shape: [CGFloat], unfolding: Bool) -> Build {
            let planar = parameters.map { t -> CGFloat in
                if unfolding { return end * t - handle * sin(.pi * t) / .pi }
                let inverse = 1 - t
                let shoulder = t * t * t * inverse * inverse * inverse
                // 保留两侧正确的材料次序：过书脊后使用负向拱面，避免左页出现交叉。
                if end < 0 {
                    return end * t + handle * sin(2 * .pi * t) / (2 * .pi) - skew * 64 * shoulder
                }
                return end * t + handle * 32 * shoulder * (2 * t - 1) - skew * 64 * shoulder
            }
            func value(_ index: Int, amplitude: CGFloat) -> Vector {
                let height = amplitude * shape[index]
                if let radius {
                    let phi = planar[index] / radius, beta = height / radius
                    return Vector(x: sin(phi) * cos(beta), y: cos(phi) * cos(beta), z: sin(beta))
                }
                return Vector(x: planar[index], y: 0, z: height)
            }
            func arcLength(_ amplitude: CGFloat) -> CGFloat {
                var previous = value(0, amplitude: amplitude), length: CGFloat = 0
                for index in 1..<parameters.count {
                    let current = value(index, amplitude: amplitude)
                    length += distance(previous, current, radius: radius); previous = current
                }
                return length
            }
            var amplitude: CGFloat = 0
            if span - arcLength(0) > max(1e-10, span * 1e-10) {
                var lower: CGFloat = 0, upper = span / 2
                for _ in 0..<24 {
                    let middle = (lower + upper) / 2
                    if arcLength(middle) < span { lower = middle } else { upper = middle }
                }
                amplitude = (lower + upper) / 2
            }
            let points = parameters.indices.map { value($0, amplitude: amplitude) }
            var distances: [CGFloat] = [0], normals: [Vector] = []
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                distances.append(distances.last! + distance(a, b, radius: radius))
                normals.append(radius != nil ? a.cross(b).unit * -1
                    : Vector(x: a.z - b.z, y: 0, z: b.x - a.x).unit)
            }
            var energy: CGFloat = 0
            for index in 1..<normals.count {
                let a = normals[index - 1], b = normals[index]
                let angle = atan2(a.cross(b).length, a.dot(b))
                let step = (distances[index + 1] - distances[index - 1]) / 2
                if step > span * 1e-12 { energy += angle * angle / step }
            }
            return Build(points: points, distances: distances, energy: energy, amplitude: amplitude)
        }

        init(span: CGFloat, end: CGFloat, radius: CGFloat?, count: Int, unfolding: Bool = false, pressure: CGFloat = 1) {
            self.span = span; self.end = end; self.radius = radius
            let parameters = (0...count).map { (1 - cos(.pi * CGFloat($0) / CGFloat(count))) / 2 }
            let compression = unfolding || span <= 1e-12 ? 0 : smooth(1 - max(0, end / span))
            // 将曲率稍微分散到拱肩，拱顶偏向翻页侧；两端位置和切线仍保持原约束。
            let shape = parameters.map { 64 * $0 * $0 * $0 * (1 - $0) * (1 - $0) * (1 - $0)
                * (unfolding ? 1 + 0.5 * cos(.pi * $0) : 1 + 0.7 * compression * (2 * $0 - 1) * (2 * $0 - 1)) }
            let slack = max(0, span - abs(end)), base = unfolding ? abs(end) : max(0, -end)
            let skew = 0.05 * slack * compression * pressure
            let bindingBlend = unfolding ? 1 : smooth(abs(end) / max(1e-12, span * 0.025))
            func candidate(_ coefficient: CGFloat) -> Build {
                let handle = unfolding ? base + slack * coefficient : base + slack * coefficient * pressure * bindingBlend
                return Self.build(span: span, end: end, radius: radius, handle: handle, skew: skew,
                    parameters: parameters, shape: shape, unfolding: unfolding)
            }
            let coefficient: CGFloat
            if slack > max(1e-7, span * 1e-7) {
                // 在满足端点切线的光滑曲线族内降低弯曲能；连续拟合避免离散选型跳变。
                let a = candidate(0.1), b = candidate(0.35), c = candidate(0.6)
                let floor = max(1e-12, max(a.energy, max(b.energy, c.energy)) * 0.05)
                let curvature = max(floor, a.energy + c.energy - 2 * b.energy)
                coefficient = min(0.68, max(0.08, 0.35 - 0.125 * (c.energy - a.energy) / curvature))
            } else { coefficient = 0.25 }
            var result = candidate(coefficient)
            let available = slack * pressure * bindingBlend
            if !unfolding, end > 0, available > 1e-10 {
                // 顶弧保持圆润；端点在书脊重合时连续进入零厚度纸张的折叠极限。
                let desiredTangent = sqrt(max(0, span * 0.025 * bindingBlend * bindingBlend
                    * result.amplitude * (24 - 5.6 * compression)))
                let minimum = (desiredTangent - end) / available
                if minimum > coefficient { result = candidate(min(0.68, minimum)) }
            }
            let total = result.distances.last ?? 0
            var panels: [Vector] = []
            for index in 1..<result.points.count {
                let a = result.points[index - 1], b = result.points[index]
                panels.append(radius != nil ? a.cross(b).unit * -1
                    : Vector(x: a.z - b.z, y: 0, z: b.x - a.x).unit)
            }
            knots = result.points.indices.map { index in
                let before = panels[max(0, index - 1)], after = panels[min(panels.count - 1, index)]
                return Knot(material: total > 0 ? result.distances[index] * span / total : span * parameters[index],
                    value: result.points[index], normal: (before + after).unit)
            }
        }

        func sample(_ material: CGFloat) -> (value: Vector, normal: Vector) {
            if material >= span {
                if var panel = freePanel {
                    let extra = material - span, angle = radius.map { extra / $0 } ?? 0
                    panel.advance(extra, sphere: radius != nil, cosine: cos(angle), sine: sin(angle))
                    return (panel.p, panel.n)
                }
                let x = end + material - span
                let value = radius.map { Vector(x: sin(x / $0), y: cos(x / $0), z: 0) }
                    ?? Vector(x: x, y: 0, z: flatTailHeight)
                return (value, Vector(x: 0, y: 0, z: 1))
            }
            guard material > 0, span > 1e-12 else { return (knots[0].value, knots[0].normal) }
            var low = 0, high = knots.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if knots[middle].material <= material { low = middle } else { high = middle }
            }
            let a = knots[low], b = knots[high]
            let step = b.material - a.material
            let t = step > 1e-15 ? (material - a.material) / step : 0
            let value: Vector
            if radius != nil {
                let angle = 2 * atan2((b.value - a.value).length, (b.value + a.value).length)
                if angle > 1e-12 {
                    value = (a.value * (sin((1 - t) * angle) / sin(angle))
                        + b.value * (sin(t * angle) / sin(angle))).unit
                } else { value = (a.value * (1 - t) + b.value * t).unit }
            } else { value = a.value * (1 - t) + b.value * t }
            return (value, (a.normal * (1 - t) + b.normal * t).unit)
        }
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }

    private static func carryFraction(contact: CGFloat, distance: CGFloat) -> CGFloat {
        smooth((0.72 - distance / contact) / 0.62)
    }

    /// 先把位移交给受压纸腹，再把一部分材料弧长交给外侧宽弧；两段共用指腹和原书脊。
    static func spreadTurnReach(contact: CGFloat, signedDistance: CGFloat) -> CGFloat {
        let distance = min(contact, max(-contact, signedDistance))
        let carry = carryFraction(contact: contact, distance: distance)
        let r = distance / contact
        let chord = contact * (1 - 0.095 * (1 - r * r))
        return distance + (chord - distance) * carry
    }

    private static func edgeShadowRootLength(_ length: CGFloat) -> CGFloat {
        max(6, min(24, length * 0.05))
    }

    /// 单页正翻的可见终点包含底页投影；侧立时纸面消失，但阴影仍可能留在视口内。
    static func visibleCompletionFraction(length: CGFloat) -> CGFloat {
        guard length.isFinite, length > 0 else { return 1 }
        let castSlope = max(shadowOffset.x, shadowOffset.y) * (shadowSoftness.max() ?? 0)
        // smooth(r)/r = 3r - 2r² 的最大值为 9/8，界定根部柔边宽度与材料距离的比例。
        let edgeSlope = edgeShadowBaseWidth * 1.125 / edgeShadowRootLength(length) + edgeShadowHeightSlope
        let angle = max(.pi / 2 + atan(castSlope), acos(-min(1, edgeSlope))) / .pi
        var lower: CGFloat = 0.5, upper: CGFloat = 1
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if smooth(middle) < angle { lower = middle } else { upper = middle }
        }
        return upper
    }

    /// 回翻展开的是对侧上一张纸；双页的材料半页也随之对调。
    static func materialPage(for drag: PaperCornerDrag, direction: PageTurnDirection) -> CGRect {
        guard direction == .previous else { return drag.page }
        return drag.axis == .horizontal
            ? CGRect(x: drag.canvasSize.width - drag.page.maxX, y: drag.page.minY, width: drag.page.width, height: drag.page.height)
            : CGRect(x: drag.page.minX, y: drag.canvasSize.height - drag.page.maxY, width: drag.page.width, height: drag.page.height)
    }

    static func mesh(for drag: PaperCornerDrag, direction: PageTurnDirection, stripCount: Int,
                     readingOrder: ReaderReadingOrder = .leftToRight) -> Mesh {
        guard drag.effect == .arch, (32...256).contains(stripCount),
              drag.translation.x.isFinite, drag.translation.y.isFinite,
              drag.archContactStrength.isFinite else { return .empty }
        let horizontal = drag.axis == .horizontal
        let unfolding = direction == .previous
        let page = materialPage(for: drag, direction: direction)
        let wholeSheet = page.size != drag.canvasSize
        let sliding = drag.slidesOuterPaperFlat
        let looseReturn = unfolding && !wholeSheet
        let length = horizontal ? page.width : page.height
        let breadth = horizontal ? drag.canvasSize.height : drag.canvasSize.width
        let materialSign = unfolding ? -drag.inwardSign : drag.inwardSign
        let hinge = horizontal ? (materialSign < 0 ? page.minX : page.maxX)
            : (materialSign < 0 ? page.minY : page.maxY)
        let outward = -materialSign
        let inputOrigin = horizontal ? drag.origin.x : drag.origin.y
        // 双页回翻时材料已平铺在对侧，指下的材料点是按下点关于原书脊的镜像。
        let originPrimary = looseReturn ? hinge + outward * length : (unfolding ? 2 * hinge - inputOrigin : inputOrigin)
        let originCross = horizontal ? drag.origin.y : drag.origin.x
        let contact = (originPrimary - hinge) * outward
        guard contact > 1e-7, contact <= length else { return .empty }
        let input = drag.archRelease?.translation ?? drag.translation
        let pull = (horizontal ? input.x : input.y) * drag.inwardSign
        // 回翻接住书脊外的纸边；短余程也必须在到达限位前完成衔接。
        let remainingPull = max(1e-7, contact - (inputOrigin - hinge) * outward)
        let engagement = looseReturn ? smooth(pull / min(8, remainingPull)) : 1
        let startX = looseReturn ? -contact + ((inputOrigin - hinge) * outward + pull + contact) * engagement
            : (inputOrigin - hinge) * outward + (horizontal ? input.x : input.y) * outward
        let startCross = (horizontal ? input.y : input.x) * engagement
        let fraction = drag.archRelease?.fraction ?? 0
        let completed = drag.archRelease?.completed ?? false
        let tipping = completed && !unfolding
        let coupled = tipping && !wholeSheet ? smooth(startX / max(1, contact * 0.08)) : 0
        let desiredRotation: CGFloat, endX: CGFloat, pressure: CGFloat
        var endCross: CGFloat
        var perspective: CGFloat = 0
        var carry: CGFloat = 0
        var finish: CGFloat = 0
        if sliding {
            let held = min(contact, max(-contact, contact - pull))
            if completed {
                let releasePhase = min(1, max(0, fraction / 0.9))
                let rollingTarget = -0.9 * contact
                let handoff = smooth((fraction - 0.9) / 0.1)
                if fraction < 0.9 {
                    endX = held + (rollingTarget - held) * releasePhase
                } else {
                    endX = rollingTarget + (contact - rollingTarget) * handoff
                }
                let rollPhase = smooth((fraction - 0.52) / 0.36)
                finish = max(handoff, min(0.86, rollPhase * 0.86))
            } else { endX = held + (contact - held) * smooth(fraction) }
            desiredRotation = 0; pressure = 1; endCross = startCross
        } else if wholeSheet {
            let phase = smooth(fraction)
            let start = min(1, max(-1, startX / contact))
            let distance: CGFloat
            if phase == 0 { distance = startX }
            else if completed || unfolding {
                let angle = acos(start)
                let landingAngle: CGFloat = completed == unfolding ? 0 : .pi
                distance = contact * cos(angle + (landingAngle - angle) * phase)
            } else { distance = startX + (contact - startX) * phase }
            endX = spreadTurnReach(contact: contact, signedDistance: distance)
            let ratio = min(1, abs(distance / contact))
            carry = carryFraction(contact: contact, distance: distance)
            perspective = carry * (1 - ratio * ratio) / (5 * length)
            // 相机在书脊正上方。反解弦的转角，透视抬升纸边而不让指腹偏离屏幕触点。
            let k = distance * perspective
            desiredRotation = atan(k) + acos(min(1, max(-1, distance / (endX * hypot(1, k)))))
            pressure = 1
            endCross = startCross * (1 - phase)
        } else {
            desiredRotation = tipping ? .pi * smooth(fraction) : 0
            var unload = drag.archRelease == nil ? 0
                : smooth(unfolding ? fraction : (completed ? min(1, 2 * fraction) : fraction))
            if coupled > 0 {
                // D·cos(θ) 保持已提交纸边的位置，随后继续向翻页侧移动，避免先向原页回开。
                let cosine = cos(desiredRotation)
                let distance = cosine > 0 ? min(contact, startX / max(1e-12, cosine)) : contact
                let release = contact - startX > 1e-10 ? (distance - startX) / (contact - startX) : 1
                unload += (min(1, max(0, release)) - unload) * coupled
            }
            let landing = unfolding && !completed ? -contact : contact
            endX = min(contact, max(-contact, startX + (landing - startX) * unload))
            endCross = startCross * (1 - unload)
            pressure = 1 - coupled * sin(min(.pi / 2, desiredRotation))
        }
        let capacity = max(0, (contact - endX) * (contact + endX))
        let fixedDistance = endCross >= 0 ? originCross : breadth - originCross
        let denominator = sqrt(fixedDistance * fixedDistance + capacity) + fixedDistance
        let maximumCross = denominator > 0 ? capacity / denominator : 0
        endCross = min(maximumCross, max(-maximumCross, endCross))
        let cone = abs(endCross) > 1e-7
        let crossSign: CGFloat = endCross >= 0 ? 1 : -1
        let apex = cone ? originCross + (endCross * endCross - capacity) / (2 * endCross) : 0
        let radialCross = cone ? crossSign * (originCross - apex) : 0
        let radius: CGFloat? = cone ? hypot(contact, radialCross) : nil
        let materialSpan = radius.map { $0 * atan2(contact, radialCross) } ?? contact
        let projectedEnd = radius.map { $0 * atan2(endX, crossSign * (originCross + endCross - apex)) } ?? endX
        let maximumPad = min(12, max(0, (materialSpan - abs(projectedEnd)) / 4))
        // 书脊近邻的接触区连续收窄，避免弧段端点先于手指跨过固定材料边。
        let pressurePad = looseReturn ? maximumPad : maximumPad * smooth(abs(projectedEnd) / max(1e-12, 2 * maximumPad))
        let pad = pressurePad + (min(12, materialSpan * 0.12) - pressurePad) * carry
        let maximum = radius.map { $0 * atan2(length, max(0, crossSign > 0 ? -apex : apex - breadth)) } ?? length
        let count = min(128, max(64, stripCount))
        let profile = sliding ? Profile(slidingLength: length, contact: contact, distance: endX, finish: finish, count: count)
            : carry > 1e-8 ? Profile(bookSpan: materialSpan, gripEnd: projectedEnd, pad: pad,
            radius: radius, count: count, carry: carry)
            : Profile(span: max(0, materialSpan - pad), end: projectedEnd - pad,
                radius: radius, count: count, unfolding: looseReturn, pressure: pressure)
        let ratio = profile.span > 1e-10 ? profile.end / profile.span : 1
        let rotationGate = smooth((ratio - 0.2) / 0.2)
        // 节点间是直线或大圆弧；限制最高极角即可让整张纸始终位于底页之上。
        let maximumElevation = profile.knots.reduce(CGFloat(0)) { maximum, knot in
            max(maximum, atan2(knot.value.z, knot.value.x))
        }
        let safeRotation = max(0, .pi - maximumElevation)
        let rotation = min(safeRotation, wholeSheet ? desiredRotation
            : desiredRotation * (coupled + (1 - coupled) * rotationGate))
        let cosine = cos(rotation), sine = sin(rotation)
        // 亚像素接触区不再额外切成面积趋零的小格；真实触点仍作为材料边界保留。
        let contactPad = pad < max(1e-4, length * 1e-7) ? 0 : min(12, pad / 3)
        let spread = min(breadth, max(48, breadth * 0.45))
        func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
        }
        func coordinate(_ u: CGFloat, _ v: CGFloat) -> CGFloat {
            radius.map { $0 * atan2(u, crossSign * (v - apex)) } ?? u
        }
        func field(_ u: CGFloat, _ v: CGFloat) -> (sample: Sample, shade: CGFloat) {
            let s = coordinate(u, v), bend = profile.sample(s)
            let x: CGFloat, y: CGFloat, z: CGFloat
            if radius != nil {
                let rCross = crossSign * (v - apex), radial = hypot(u, rCross)
                x = radial * bend.value.x; z = radial * bend.value.z
                // 用球面角的差角恒等式求横移，避免由近乎相等的大坐标反推微小位移。
                let cosElevation = hypot(bend.value.x, bend.value.y)
                let phi = atan2(bend.value.x, bend.value.y), theta = atan2(u, rCross)
                let deltaCosine = -bend.value.z * bend.value.z * (bend.value.y / cosElevation) / (1 + cosElevation)
                    - 2 * sin((phi + theta) / 2) * sin((phi - theta) / 2)
                y = v + crossSign * radial * deltaCosine
            } else { x = bend.value.x; y = v; z = bend.value.z }
            let finalLanding = completed && fraction >= 1 - 1e-4
            let reflectedSheet = sliding && (unfolding ? !finalLanding : finalLanding)
            let worldX = (x * cosine - z * sine) * (reflectedSheet ? -1 : 1)
            let rawHeight = x * sine + z * cosine
            let height = abs(rawHeight) < 1e-10 ? 0 : rawHeight
            let primary = u == contact ? originPrimary : hinge + outward * u
            let magnification = 1 / (1 - perspective * height)
            let cameraCross = originCross + endCross
            let projectedCross = wholeSheet ? y + (y - cameraCross) * (magnification - 1) - crossProjection * (1 - carry) * z
                : y - crossProjection * height
            let sample = Sample(source: point(primary, v),
                point: point(hinge + outward * worldX * magnification, projectedCross),
                worldPoint: point(hinge + outward * worldX, y), height: height)
            let normalZ = bend.normal.x * sine + bend.normal.z * cosine
            return (sample, min(0.18, 0.14 * (1 - min(1, abs(normalZ))) + 0.025 * height / max(1, length)))
        }
        func unique(_ values: [CGFloat], limit: CGFloat, anchor: CGFloat) -> [CGFloat] {
            let sorted = values.filter(\.isFinite).map { value -> CGFloat in
                let bounded = min(limit, max(0, value))
                if abs(bounded - anchor) <= 1e-9 { return anchor }
                return bounded
            }.sorted()
            var result: [CGFloat] = []
            for value in sorted where result.last.map({ value - $0 > 1e-9 }) ?? true { result.append(value) }
            return result
        }
        let crosses = unique([0, breadth, originCross - spread, originCross - contactPad,
                              originCross, originCross + contactPad, originCross + spread], limit: breadth, anchor: originCross)
        let columns = unique([0, contact - contactPad, contact, contact + contactPad, length], limit: length, anchor: contact)
        let tailLevels: [CGFloat] = carry > 1e-8 && maximum > materialSpan ? (1..<12).map {
            materialSpan + (maximum - materialSpan) * CGFloat($0) / 12
        } : []
        let levels = unique(profile.knots.map(\.material) + [0, profile.span, materialSpan, maximum] + tailLevels,
            limit: maximum, anchor: materialSpan)
        guard crosses.count > 1, columns.count > 1, levels.count > 1 else { return .empty }
        struct Key: Hashable { let x: CGFloat; let y: CGFloat }
        var samples: [Sample] = [], vertexShades: [CGFloat] = [], indices: [Key: Int] = [:]
        func vertex(_ input: CGPoint) -> Int {
            // 裁剪与近重合材料线均对齐真实锚点，避免 diagnostics 有触点而实际三角形漏掉它。
            let epsilon = max(1e-9, length.ulp * 8)
            let u = columns.first { abs(input.x - $0) <= epsilon } ?? input.x
            let v = crosses.first { abs(input.y - $0) <= epsilon } ?? input.y
            let material = CGPoint(x: u, y: v)
            let value = field(material.x, material.y)
            let key = Key(x: value.sample.source.x, y: value.sample.source.y)
            if let index = indices[key] { return index }
            let index = samples.count
            indices[key] = index; samples.append(value.sample); vertexShades.append(value.shade)
            return index
        }
        var primary = (0...stripCount).map { length * CGFloat($0) / CGFloat(stripCount) }
        primary += columns
        primary += levels.map { s -> CGFloat in
            radius.map { tan(s / $0) * radialCross } ?? s
        }
        primary = unique(primary, limit: length, anchor: contact)
        for v in crosses { for u in primary { _ = vertex(CGPoint(x: u, y: v)) } }
        func clipped(_ polygon: [CGPoint], signedDistance: (CGPoint) -> CGFloat) -> [CGPoint] {
            guard var previous = polygon.last else { return [] }
            var previousDistance = signedDistance(previous), result: [CGPoint] = []
            for current in polygon {
                let distance = signedDistance(current)
                if (distance >= 0) != (previousDistance >= 0) {
                    let t = previousDistance / (previousDistance - distance)
                    result.append(CGPoint(x: previous.x + (current.x - previous.x) * t,
                        y: previous.y + (current.y - previous.y) * t))
                }
                if distance >= 0 { result.append(current) }
                previous = current; previousDistance = distance
            }
            var clean: [CGPoint] = []
            for p in result where clean.last.map({ hypot(p.x - $0.x, p.y - $0.y) > 1e-9 }) ?? true { clean.append(p) }
            if clean.count > 1, let a = clean.first, let b = clean.last, hypot(a.x - b.x, a.y - b.y) < 1e-9 { clean.removeLast() }
            return clean
        }
        var patches: [PaperCornerPatch] = [], shades: [[CGFloat]] = [], shadow: [PaperCornerShadowVertex] = []
        patches.reserveCapacity(levels.count * crosses.count * 2)
        shades.reserveCapacity(levels.count * crosses.count * 2)
        shadow.reserveCapacity(levels.count * crosses.count * 12)
        for band in 0..<(levels.count - 1) {
            let low = levels[band], high = levels[band + 1]
            let lowCos = radius.map { cos(low / $0) } ?? 1, lowSin = radius.map { sin(low / $0) } ?? 0
            let highCos = radius.map { cos(high / $0) } ?? 1, highSin = radius.map { sin(high / $0) } ?? 0
            func boundary(_ p: CGPoint, cosine: CGFloat, sine: CGFloat, value: CGFloat) -> CGFloat {
                radius != nil ? p.x * cosine - crossSign * (p.y - apex) * sine : p.x - value
            }
            for row in 0..<(crosses.count - 1) {
                for column in 0..<(columns.count - 1) {
                    let rectangle = [CGPoint(x: columns[column], y: crosses[row]),
                        CGPoint(x: columns[column + 1], y: crosses[row]),
                        CGPoint(x: columns[column + 1], y: crosses[row + 1]),
                        CGPoint(x: columns[column], y: crosses[row + 1])]
                    let polygon = clipped(clipped(rectangle) { boundary($0, cosine: lowCos, sine: lowSin, value: low) }) {
                        -boundary($0, cosine: highCos, sine: highSin, value: high)
                    }
                    guard polygon.count > 2 else { continue }
                    let ids = polygon.map(vertex)
                    for corner in 1..<(ids.count - 1) {
                        let triangle = [ids[0], ids[corner], ids[corner + 1]]
                        let values = triangle.map { samples[$0] }
                        let sourceArea = signedArea(values.map(\.source))
                        guard abs(sourceArea) > 1e-9 else { continue }
                        guard let transform = projection(values[0].source, values[1].source, values[2].source,
                            onto: values[0].point, values[1].point, values[2].point) else { return .empty }
                        let colors = triangle.map { vertexShades[$0] }
                        let depth = values.reduce(0) { $0 + $1.height } / 3
                        patches.append(PaperCornerPatch(source: values.map(\.source), transform: transform, depth: depth,
                            back: sourceArea * signedArea(values.map(\.point)) < 0, shade: colors.reduce(0, +) / 3))
                        shades.append(colors)
                        if values.contains(where: { $0.height > 1e-6 }) {
                            for softness in shadowSoftness {
                                for value in values {
                                    shadow.append(PaperCornerShadowVertex(point: CGPoint(
                                        x: value.point.x + value.height * shadowOffset.x * softness,
                                        y: value.point.y + value.height * shadowOffset.y * softness),
                                        opacity: 0.055 * value.height / (value.height + 16)))
                                }
                            }
                        }
                    }
                }
            }
        }
        appendEdgeShadow(to: &shadow, samples: samples, horizontal: horizontal, hinge: hinge,
            outward: outward, length: length, breadth: breadth) { field($0, $1).sample.point }
        let order = patches.indices.sorted { patches[$0].depth == patches[$1].depth ? $0 < $1 : patches[$0].depth < patches[$1].depth }
        return Mesh(patches: order.map { patches[$0] }, shades: order.map { shades[$0] }, shadow: shadow, samples: samples)
    }

    /// 三条自由边共用连续柔边带，贴边较深、外侧透明；装订边与落平姿态不增加描边。
    private static func appendEdgeShadow(to shadow: inout [PaperCornerShadowVertex], samples: [Sample],
                                         horizontal: Bool, hinge: CGFloat, outward: CGFloat,
                                         length: CGFloat, breadth: CGFloat,
                                         interior: (CGFloat, CGFloat) -> CGPoint) {
        let peak = samples.reduce(CGFloat.zero) { max($0, $1.height) }
        let strength = smooth(peak / max(1, length * 0.04))
        guard strength > 1e-6 else { return }
        let epsilon = max(1e-8, max(length.ulp, breadth.ulp) * 8)
        func u(_ sample: Sample) -> CGFloat { ((horizontal ? sample.source.x : sample.source.y) - hinge) * outward }
        func v(_ sample: Sample) -> CGFloat { horizontal ? sample.source.y : sample.source.x }
        func world(_ sample: Sample) -> Vector {
            Vector(x: sample.worldPoint.x, y: sample.worldPoint.y, z: sample.height)
        }
        func simplified(_ edge: [Sample]) -> [Sample] {
            var points: [Sample] = []
            for sample in edge {
                if let last = points.last, hypot(last.source.x - sample.source.x, last.source.y - sample.source.y) <= epsilon { continue }
                while points.count > 1 {
                    let a = world(points[points.count - 2]), b = world(points[points.count - 1]), c = world(sample)
                    let line = c - a, squared = line.dot(line)
                    guard squared > 1e-18 else { break }
                    let t = (b - a).dot(line) / squared
                    let error = b - a - line * t
                    guard t >= 0, t <= 1, error.dot(error) <= 1e-10 else { break }
                    points.removeLast()
                }
                points.append(sample)
            }
            // 包含诊断采样时仍严格控制最坏顶点预算，保留每条边的两个角点。
            if points.count > 129 {
                return (0...128).map { points[Int((CGFloat($0) * CGFloat(points.count - 1) / 128).rounded())] }
            }
            return points
        }
        let edges = [
            samples.filter { abs(v($0)) <= epsilon }.sorted { u($0) < u($1) },
            samples.filter { abs(u($0) - length) <= epsilon }.sorted { v($0) < v($1) },
            samples.filter { abs(v($0) - breadth) <= epsilon }.sorted { u($0) > u($1) }
        ]
        var outline: [Sample] = []
        for edge in edges {
            for point in simplified(edge) {
                if let last = outline.last, hypot(last.source.x - point.source.x, last.source.y - point.source.y) <= epsilon { continue }
                outline.append(point)
            }
        }
        guard outline.count > 1 else { return }
        var normals: [CGPoint] = [], widths: [CGFloat] = [], opacities: [CGFloat] = []
        normals.reserveCapacity(outline.count); widths.reserveCapacity(outline.count); opacities.reserveCapacity(outline.count)
        let inset = min(1, min(length, breadth) * 0.1)
        for index in outline.indices {
            let sample = outline[index], a = outline[max(0, index - 1)].point, b = outline[min(outline.count - 1, index + 1)].point
            let inside = interior(min(length - inset, max(inset, u(sample))), min(breadth - inset, max(inset, v(sample))))
            let tangent = CGPoint(x: b.x - a.x, y: b.y - a.y), distance = hypot(b.x - a.x, b.y - a.y)
            var normal = distance > 1e-9 ? CGPoint(x: -tangent.y / distance, y: tangent.x / distance) : .zero
            if normal.x * (inside.x - sample.point.x) + normal.y * (inside.y - sample.point.y) > 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
            let height = max(0, sample.height)
            let rootFade = smooth(u(sample) / edgeShadowRootLength(length))
            let light = max(0, normal.x * 0.6 + normal.y * 0.8)
            normals.append(normal)
            widths.append((edgeShadowBaseWidth + min(5.5, height * edgeShadowHeightSlope)) * rootFade * strength * (0.7 + 0.3 * light))
            opacities.append((0.16 + 0.06 * height / (height + 20)) * rootFade * strength * (0.65 + 0.35 * light))
        }
        let stops: [CGFloat] = [0, 0.18, 0.5, 1], fades: [CGFloat] = [1, 0.68, 0.2, 0]
        shadow.reserveCapacity(shadow.count + (outline.count - 1) * 18)
        func vertex(_ index: Int, _ ring: Int) -> PaperCornerShadowVertex {
            let point = outline[index].point, offset = widths[index] * stops[ring]
            return PaperCornerShadowVertex(point: CGPoint(x: point.x + normals[index].x * offset,
                y: point.y + normals[index].y * offset), opacity: opacities[index] * fades[ring])
        }
        for index in 0..<(outline.count - 1) {
            guard hypot(outline[index + 1].point.x - outline[index].point.x,
                        outline[index + 1].point.y - outline[index].point.y) > 1e-8 else { continue }
            for ring in 0..<3 {
                let a = vertex(index, ring), b = vertex(index + 1, ring)
                let c = vertex(index + 1, ring + 1), d = vertex(index, ring + 1)
                shadow.append(contentsOf: [a, b, c, a, c, d])
            }
        }
    }

    static func patches(for drag: PaperCornerDrag, direction: PageTurnDirection, stripCount: Int,
                        readingOrder: ReaderReadingOrder = .leftToRight) -> [PaperCornerPatch] {
        mesh(for: drag, direction: direction, stripCount: stripCount, readingOrder: readingOrder).patches
    }
    static func shadowVertices(for drag: PaperCornerDrag, direction: PageTurnDirection) -> [PaperCornerShadowVertex] {
        mesh(for: drag, direction: direction, stripCount: 64).shadow
    }
    private static func signedArea(_ points: [CGPoint]) -> CGFloat {
        let a = points[0], b = points[1], c = points[2]
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func projection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint,
                                   onto p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGAffineTransform? {
        let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - a.x, y: c.y - a.y)
        let x = CGPoint(x: q.x - p.x, y: q.y - p.y), y = CGPoint(x: r.x - p.x, y: r.y - p.y)
        let determinant = u.x * v.y - u.y * v.x
        guard determinant.isFinite, determinant != 0 else { return nil }
        let aa = (x.x * v.y - y.x * u.y) / determinant, bb = (x.y * v.y - y.y * u.y) / determinant
        let cc = (y.x * u.x - x.x * v.x) / determinant, dd = (y.y * u.x - x.y * v.x) / determinant
        let tx = p.x - aa * a.x - cc * a.y, ty = p.y - bb * a.x - dd * a.y
        guard [aa, bb, cc, dd, tx, ty].allSatisfy(\.isFinite) else { return nil }
        return CGAffineTransform(a: aa, b: bb, c: cc, d: dd, tx: tx, ty: ty)
    }
}
#endif
