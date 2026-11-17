import Foundation
#if canImport(CoreGraphics)
import CoreGraphics

/// 固定装订边的可展纸面：沿材料弧长弯曲，不以平面剪切补偿触点。
enum PaperArchGeometry {
    private static let crossProjection: CGFloat = 0.22

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
        }
        let span: CGFloat
        let end: CGFloat
        let radius: CGFloat?
        let knots: [Knot]

        private static func distance(_ a: Vector, _ b: Vector, radius: CGFloat?) -> CGFloat {
            if let radius { return 2 * radius * atan2((b - a).length, (b + a).length) }
            return (b - a).length
        }
        private static func build(span: CGFloat, end: CGFloat, radius: CGFloat?, handle: CGFloat,
                                  parameters: [CGFloat], shape: [CGFloat], unfolding: Bool) -> Build {
            let planar = parameters.map { unfolding
                ? end * $0 - handle * sin(.pi * $0) / .pi
                : end * $0 + handle * sin(2 * .pi * $0) / (2 * .pi) }
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
            return Build(points: points, distances: distances, energy: energy)
        }

        init(span: CGFloat, end: CGFloat, radius: CGFloat?, count: Int, unfolding: Bool = false) {
            self.span = span; self.end = end; self.radius = radius
            let parameters = (0...count).map { (1 - cos(.pi * CGFloat($0) / CGFloat(count))) / 2 }
            let shape = parameters.map { 64 * $0 * $0 * $0 * (1 - $0) * (1 - $0) * (1 - $0)
                * (unfolding ? 1 + 0.5 * cos(.pi * $0) : 1) }
            let slack = max(0, span - abs(end)), base = unfolding ? abs(end) : max(0, -end)
            func candidate(_ coefficient: CGFloat) -> Build {
                Self.build(span: span, end: end, radius: radius, handle: base + slack * coefficient,
                    parameters: parameters, shape: shape, unfolding: unfolding)
            }
            let result: Build
            if slack > max(1e-7, span * 1e-7) {
                // 在满足端点切线的光滑曲线族内降低弯曲能；连续拟合避免离散选型跳变。
                let a = candidate(0.1), b = candidate(0.35), c = candidate(0.6)
                let floor = max(1e-12, max(a.energy, max(b.energy, c.energy)) * 0.05)
                let curvature = max(floor, a.energy + c.energy - 2 * b.energy)
                let coefficient = min(0.68, max(0.08, 0.35 - 0.125 * (c.energy - a.energy) / curvature))
                result = candidate(coefficient)
            } else { result = candidate(0.25) }
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
                let x = end + material - span
                let value = radius.map { Vector(x: sin(x / $0), y: cos(x / $0), z: 0) }
                    ?? Vector(x: x, y: 0, z: 0)
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
        let length = horizontal ? page.width : page.height
        let breadth = horizontal ? drag.canvasSize.height : drag.canvasSize.width
        let materialSign = unfolding ? -drag.inwardSign : drag.inwardSign
        let hinge = horizontal ? (materialSign < 0 ? page.minX : page.maxX)
            : (materialSign < 0 ? page.minY : page.maxY)
        let outward = -materialSign
        let inputOrigin = horizontal ? drag.origin.x : drag.origin.y
        let originPrimary = unfolding ? hinge + outward * length : inputOrigin
        let originCross = horizontal ? drag.origin.y : drag.origin.x
        let contact = (originPrimary - hinge) * outward
        guard contact > 1e-7, contact <= length else { return .empty }
        let input = drag.archRelease?.translation ?? drag.translation
        let pull = (horizontal ? input.x : input.y) * drag.inwardSign
        // 回翻接住书脊外的纸边；短余程也必须在到达限位前完成衔接。
        let remainingPull = max(1e-7, contact - (inputOrigin - hinge) * outward)
        let engagement = unfolding ? smooth(pull / min(8, remainingPull)) : 1
        let startX = unfolding ? -contact + ((inputOrigin - hinge) * outward + pull + contact) * engagement
            : contact + (horizontal ? input.x : input.y) * outward
        let startCross = (horizontal ? input.y : input.x) * engagement
        let fraction = drag.archRelease?.fraction ?? 0
        let completed = drag.archRelease?.completed ?? false
        let unload = drag.archRelease == nil ? 0 : smooth(unfolding ? fraction : (completed ? min(1, 2 * fraction) : fraction))
        let landing = unfolding && !completed ? -contact : contact
        let endX = min(contact, max(-contact, startX + (landing - startX) * unload))
        var endCross = startCross * (1 - unload)
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
        let pad = min(12, max(0, (materialSpan - abs(projectedEnd)) / 4))
        let profile = Profile(span: max(0, materialSpan - pad), end: projectedEnd - pad,
            radius: radius, count: min(128, max(64, stripCount)), unfolding: unfolding)
        // 先展开受压弧，再绕同一装订边转动；每一步仍为可展映射或刚体转动。
        let ratio = profile.span > 1e-10 ? profile.end / profile.span : 1
        let rotationGate = smooth((ratio - 0.2) / 0.2)
        let rotation = completed && !unfolding ? .pi * smooth(fraction) * rotationGate : 0
        let cosine = cos(rotation), sine = sin(rotation)
        let contactPad = min(12, pad / 3)
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
            let worldX = x * cosine - z * sine
            let rawHeight = x * sine + z * cosine
            let height = abs(rawHeight) < 1e-10 ? 0 : rawHeight
            let primary = u == contact ? originPrimary : hinge + outward * u
            let sample = Sample(source: point(primary, v),
                point: point(hinge + outward * worldX, y - crossProjection * height),
                worldPoint: point(hinge + outward * worldX, y), height: height)
            let normalZ = bend.normal.x * sine + bend.normal.z * cosine
            return (sample, min(0.18, 0.14 * (1 - min(1, abs(normalZ))) + 0.025 * height / max(1, length)))
        }
        func unique(_ values: [CGFloat], limit: CGFloat, anchor: CGFloat) -> [CGFloat] {
            let sorted = values.filter(\.isFinite).map { value -> CGFloat in
                let bounded = min(limit, max(0, value))
                if abs(bounded - anchor) < 1e-10 { return anchor }
                return bounded
            }.sorted()
            var result: [CGFloat] = []
            for value in sorted where result.last.map({ value - $0 > 1e-9 }) ?? true { result.append(value) }
            return result
        }
        let crosses = unique([0, breadth, originCross - spread, originCross - contactPad,
                              originCross, originCross + contactPad, originCross + spread], limit: breadth, anchor: originCross)
        let columns = unique([0, contact - contactPad, contact, contact + contactPad, length], limit: length, anchor: contact)
        let maximum = radius.map { $0 * atan2(length, max(0, crossSign > 0 ? -apex : apex - breadth)) } ?? length
        let levels = unique(profile.knots.map(\.material) + [0, profile.span, materialSpan, maximum], limit: maximum, anchor: materialSpan)
        guard crosses.count > 1, columns.count > 1, levels.count > 1 else { return .empty }
        struct Key: Hashable { let x: CGFloat; let y: CGFloat }
        var samples: [Sample] = [], vertexShades: [CGFloat] = [], indices: [Key: Int] = [:]
        func vertex(_ input: CGPoint) -> Int {
            let material: CGPoint
            if unfolding {
                let epsilon = max(1e-10, length.ulp * 8)
                let u = columns.first { abs(input.x - $0) <= epsilon } ?? input.x
                let v = crosses.first { abs(input.y - $0) <= epsilon } ?? input.y
                material = CGPoint(x: u, y: v)
            } else { material = input }
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
                            for softness: CGFloat in [0.7, 1.3] {
                                for value in values {
                                    shadow.append(PaperCornerShadowVertex(point: CGPoint(
                                        x: value.point.x + value.height * 0.12 * softness,
                                        y: value.point.y + value.height * 0.16 * softness),
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
            let rootFade = smooth(u(sample) / max(6, min(24, length * 0.05)))
            let light = max(0, normal.x * 0.6 + normal.y * 0.8)
            normals.append(normal)
            widths.append((1.8 + min(5.5, height * 0.065)) * rootFade * strength * (0.7 + 0.3 * light))
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
