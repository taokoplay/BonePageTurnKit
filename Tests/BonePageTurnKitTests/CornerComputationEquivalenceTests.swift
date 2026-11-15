#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import Dispatch
import XCTest
@testable import BonePageTurnKit

/// 参考算法来自冻结的 smoothness-baseline-package；只共用未改动的 drag 输入。
final class CornerComputationEquivalenceTests: XCTestCase {
    func testPatchesAndShadowsMatchFrozenReferenceAcrossPoses() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390.5, height: 843.75) : CGSize(width: 843.75, height: 390.5)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for crossFraction: CGFloat in [0, 0.5, 1] {
                        let primary: CGFloat = spread ? (sign < 0 ? 292.875 : 97.625) : 195.25
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: point(primary, 843.75 * crossFraction, axis: axis)))
                        var poses: [(String, PaperCornerDrag)] = [
                            ("start", seed), ("completed", seed.released(completed: true, fraction: 1))
                        ]
                        let requests: [(progress: CGFloat, cross: CGFloat)] = [
                            (0.000001, 0), (0.45, 0), (0.35, -1_000_000), (0.7, 1_000_000), (0.99, -1_000_000)
                        ]
                        for request in requests {
                            let target = CGPoint(
                                x: seed.gripOrigin.x + (axis == .horizontal ? sign * 2 * seed.length * request.progress : request.cross),
                                y: seed.gripOrigin.y + (axis == .vertical ? sign * 2 * seed.length * request.progress : request.cross))
                            let live = try XCTUnwrap(seed.moved(to: target))
                            poses.append(("live/\(request.progress)/\(request.cross)", live))
                            if request.progress == 0.7 {
                                poses.append(("cancel-middle", live.released(completed: false, fraction: 0.5)))
                                poses.append(("complete-middle", live.released(completed: true, fraction: 0.5)))
                                XCTAssertEqual(live.released(completed: false, fraction: 0), live)
                                XCTAssertEqual(live.released(completed: true, fraction: 0), live)
                            }
                        }
                        var flat = seed
                        flat.prefersFlatTurn = true
                        let flatTarget = CGPoint(
                            x: flat.gripOrigin.x + (axis == .horizontal ? sign * flat.length * 0.8 : 30),
                            y: flat.gripOrigin.y + (axis == .vertical ? sign * flat.length * 0.8 : 30))
                        poses.append(("flat", try XCTUnwrap(flat.moved(to: flatTarget))))
                        flat.prefersFlatTurn = false
                        poses.append(("after-flat", try XCTUnwrap(flat.moved(to: flatTarget))))
                        let previous = try XCTUnwrap(seed.moved(to: point(195.25, 843.75 * crossFraction, axis: axis),
                            direction: .previous))
                        poses.append(("previous-material", try XCTUnwrap(previous.foldingPresentation(
                            direction: .previous, size: size, spread: spread))))
                        for (name, drag) in poses {
                            for count in [32, 65, 97, 128, 255, 256] {
                                assertEquivalent(drag, stripCount: count,
                                    context: "\(axis)/spread=\(spread)/sign=\(sign)/cross=\(crossFraction)/\(name)/\(count)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testEverySupportedStripCountAndRepeatedLookupMatchesReference() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 390.5, height: 843.75), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 371.25, y: 10.5)))
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 133.125, y: 207.75)))
        for count in 32...256 {
            let expected = BaselineCornerCurlGeometry.patches(for: drag, stripCount: count)
            for _ in 0..<2 {
                assertPatches(PaperCornerCurlGeometry.patches(for: drag, stripCount: count), expected,
                    context: "stripCount=\(count)")
            }
        }
        for count in [Int.min, 0, 31, 257, Int.max] {
            assertEquivalent(drag, stripCount: count, context: "invalid stripCount=\(count)")
        }
    }

    func testConcurrentAngleTableLookupsMatchReference() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 843.75, height: 390.5), axis: .vertical,
            spread: true, inwardSign: 1, origin: CGPoint(x: 421.875, y: 97.625)))
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 300.125, y: 146.4375)))
        DispatchQueue.concurrentPerform(iterations: 96) { index in
            let count = 32 + (index * 37) % 225
            self.assertPatches(PaperCornerCurlGeometry.patches(for: drag, stripCount: count),
                BaselineCornerCurlGeometry.patches(for: drag, stripCount: count), context: "concurrent/\(count)")
        }
    }

    func testVisibleFractionAndHalfBoundaryMatchReference() throws {
        let halfProgress = CGFloat(0.5) - (CGFloat.pi - 2) * 0.05
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for sign: CGFloat in [-1, 1] {
                var seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: sign, origin: point(160, 240, axis: axis)))
                seed.prefersFlatTurn = true
                for offset: CGFloat in [-0.000001, 0, 0.000001] {
                    let drag = seed.released(completed: true, fraction: halfProgress + offset)
                    for count in [32, 65, 256] {
                        let expected = try XCTUnwrap(BaselineCornerCurlGeometry.visiblePaperFraction(for: drag, stripCount: count))
                        let actual = try XCTUnwrap(PaperCornerCurlGeometry.visiblePaperFraction(for: drag, stripCount: count))
                        XCTAssertEqual(actual, expected)
                        XCTAssertEqual(actual >= 0.5, expected >= 0.5)
                        if offset < 0 { XCTAssertGreaterThan(expected, 0.5) }
                        if offset > 0 { XCTAssertLessThan(expected, 0.5) }
                    }
                }
            }
        }
    }

    func testNearFlatContactShadowMatchesReference() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390.5, height: 843.75) : CGSize(width: 843.75, height: 390.5)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for crossSign: CGFloat in [-1, 1] {
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: point(195.25, 421.875, axis: axis)))
                        let pull = seed.length * 0.7
                        let reach = pull * (2 * seed.length - pull)
                        let flatCross = crossSign * reach / (sqrt(421.875 * 421.875 + reach) + 421.875)
                        let target = CGPoint(x: seed.gripOrigin.x + (axis == .horizontal ? sign * pull : crossSign * 1_000_000),
                            y: seed.gripOrigin.y + (axis == .vertical ? sign * pull : crossSign * 1_000_000))
                        let live = try XCTUnwrap(seed.moved(to: target))
                        for factor: CGFloat in [0.999, 1] {
                            var drag = live
                            if axis == .horizontal { drag.translation.y = flatCross * factor }
                            else { drag.translation.x = flatCross * factor }
                            for count in [65, 256] {
                                assertEquivalent(drag, stripCount: count,
                                    context: "contact/\(axis)/\(spread)/\(sign)/\(crossSign)/\(factor)/\(count)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testShadowReductionMatchesReferenceForReorderedEmptyAndInvalidPatches() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 140, y: 130)))
        let patches = BaselineCornerCurlGeometry.patches(for: drag, stripCount: 65)
        let empty = BaselineCornerPatch(source: [], transform: .identity, depth: 10_000, back: true, shade: 0)
        let invalidPoint = BaselineCornerPatch(source: [CGPoint(x: CGFloat.infinity, y: 0)],
            transform: .identity, depth: 0, back: true, shade: 0)
        let invalidDepth = BaselineCornerPatch(source: [], transform: .identity, depth: .nan, back: true, shade: 0)
        let cases: [[BaselineCornerPatch]] = [
            patches, Array(patches.reversed()), patches + [empty], [empty] + patches,
            patches.filter { !$0.back }, [empty], [], patches + [invalidPoint],
            [invalidDepth] + patches, patches + [invalidDepth]
        ]
        for (index, expected) in cases.enumerated() {
            let actual = expected.map {
                PaperCornerPatch(source: $0.source, transform: $0.transform, depth: $0.depth, back: $0.back, shade: $0.shade)
            }
            assertShadow(drag, actual: actual, expected: expected, context: "shadow-input/\(index)")
        }
    }

    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    private func assertEquivalent(_ drag: PaperCornerDrag, stripCount: Int, context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let expected = BaselineCornerCurlGeometry.patches(for: drag, stripCount: stripCount)
        let actual = PaperCornerCurlGeometry.patches(for: drag, stripCount: stripCount)
        assertPatches(actual, expected, context: context, file: file, line: line)
        assertShadow(drag, actual: actual, expected: expected, context: context, file: file, line: line)
        XCTAssertEqual(PaperCornerCurlGeometry.visiblePaperFraction(for: drag, stripCount: stripCount),
            BaselineCornerCurlGeometry.visiblePaperFraction(for: drag, stripCount: stripCount), context, file: file, line: line)
    }

    private func assertPatches(_ actual: [PaperCornerPatch], _ expected: [BaselineCornerPatch], context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, context, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            let a = pair.0, b = pair.1, message = "\(context)/patch=\(index)"
            // 逐点且按原顺序精确比较；同时验证后续 scratch 复用未改写已追加的 source。
            XCTAssertEqual(a.source, b.source, message, file: file, line: line)
            XCTAssertEqual([a.transform.a, a.transform.b, a.transform.c, a.transform.d, a.transform.tx, a.transform.ty],
                [b.transform.a, b.transform.b, b.transform.c, b.transform.d, b.transform.tx, b.transform.ty],
                message, file: file, line: line)
            XCTAssertEqual(a.depth, b.depth, message, file: file, line: line)
            XCTAssertEqual(a.back, b.back, message, file: file, line: line)
            XCTAssertEqual(a.shade, b.shade, message, file: file, line: line)
        }
    }

    private func assertShadow(_ drag: PaperCornerDrag, actual: [PaperCornerPatch], expected: [BaselineCornerPatch],
                              context: String, file: StaticString = #filePath, line: UInt = #line) {
        let vertices = PaperCornerShadowGeometry.vertices(for: drag, patches: actual)
        let referenceVertices = BaselineCornerShadowGeometry.vertices(for: drag, patches: expected)
        XCTAssertEqual(vertices.map(\.point), referenceVertices.map(\.point), context, file: file, line: line)
        XCTAssertEqual(vertices.map(\.opacity), referenceVertices.map(\.opacity), context, file: file, line: line)
        let profile = PaperCornerShadowProfile(drag: drag, patches: actual)
        let reference = BaselineCornerShadowProfile(drag: drag, patches: expected)
        XCTAssertEqual(profile == nil, reference == nil, context, file: file, line: line)
        guard let profile, let reference else { return }
        XCTAssertEqual(profile.normal, reference.normal, context, file: file, line: line)
        XCTAssertEqual(profile.rootCoordinate, reference.rootCoordinate, context, file: file, line: line)
        XCTAssertEqual(profile.tipCoordinate, reference.tipCoordinate, context, file: file, line: line)
        let span = reference.rootCoordinate - reference.tipCoordinate
        for t: CGFloat in [0, 0.125, 0.5, 1] {
            let point = CGPoint(x: drag.tip.x + reference.normal.x * span * t,
                y: drag.tip.y + reference.normal.y * span * t)
            let a = profile.sample(at: point), b = reference.sample(at: point)
            XCTAssertEqual(a.width, b.width, context, file: file, line: line)
            XCTAssertEqual(a.opacity, b.opacity, context, file: file, line: line)
            XCTAssertEqual(a.offset, b.offset, context, file: file, line: line)
        }
    }
}

// 以下是冻结基线的必要类型与算法的重命名拷贝；不调用优化后的裁剪、角度表、排序或阴影归约。
private struct BaselineCornerPatch {
    let source: [CGPoint]
    let transform: CGAffineTransform
    let depth: CGFloat
    let back: Bool
    let shade: CGFloat
    var projected: [CGPoint] { source.map { $0.applying(transform) } }
}

private enum BaselineCornerCurlGeometry {
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

    static func preferredRadius(length: CGFloat, pull: CGFloat, distance: CGFloat) -> CGFloat {
        let fade = min(1, max(0, (1 - pull / (2 * length)) / 0.15))
        let radius = min(length * 0.10, distance * 0.12) * fade
        return min(radius, max(0, 2 * length - pull) * 0.9 / .pi)
    }

    static func patches(for drag: PaperCornerDrag, stripCount: Int) -> [BaselineCornerPatch] {
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
        let pull = drag.progress * 2 * drag.length
        let radius = min(preferredRadius(length: drag.length, pull: pull, distance: distance), clearance * 2 / .pi)
        let arcLength = CGFloat.pi * radius
        let crease = (gripValue + tipValue - arcLength) / 2
        let values = polygon.map(coordinate)
        guard let lower = values.min(), let upper = values.max() else { return [] }
        var result: [BaselineCornerPatch] = []
        result.reserveCapacity(stripCount + 2)

        func append(from a: CGFloat, to b: CGFloat, projectedA: CGFloat, projectedB: CGFloat,
                    depth: CGFloat, back: Bool, shade: CGFloat) {
            guard b - a > 1e-8 else { return }
            let clipped = clip(clip(polygon, normal: normal, boundary: a, keepLower: false),
                               normal: normal, boundary: b, keepLower: true)
            guard clipped.count >= 3 else { return }
            let slope = (projectedB - projectedA) / (b - a)
            guard abs(slope) > 1e-10 else { return }
            let shift = projectedA - slope * a
            let dx = (slope - 1) * normal.x, dy = (slope - 1) * normal.y
            let transform = CGAffineTransform(a: 1 + dx * normal.x, b: dy * normal.x,
                                              c: dx * normal.y, d: 1 + dy * normal.y,
                                              tx: shift * normal.x, ty: shift * normal.y)
            result.append(.init(source: clipped, transform: transform, depth: depth, back: back, shade: shade))
        }
        let flatEnd = min(upper, crease)
        append(from: lower, to: flatEnd, projectedA: lower, projectedB: flatEnd, depth: 0, back: false, shade: 0)
        if radius > 1e-8 {
            let count = stripCount / 2 * 2
            for index in 0..<count {
                let theta0 = CGFloat.pi * CGFloat(index) / CGFloat(count)
                let theta1 = CGFloat.pi * CGFloat(index + 1) / CGFloat(count)
                let middle = (theta0 + theta1) / 2
                let depth = radius * (1 - cos(middle))
                append(from: crease + radius * theta0, to: crease + radius * theta1,
                       projectedA: crease + radius * sin(theta0), projectedB: crease + radius * sin(theta1),
                       depth: depth, back: middle > .pi / 2,
                       shade: 0.20 * (1 - abs(cos(middle))) + 0.025 * depth / drag.length)
            }
        }
        let backStart = max(lower, crease + arcLength)
        append(from: backStart, to: upper, projectedA: 2 * crease + arcLength - backStart,
               projectedB: 2 * crease + arcLength - upper, depth: 2 * radius, back: true, shade: 0.025 * 2 * radius / drag.length)
        return result.enumerated().sorted {
            $0.element.depth == $1.element.depth ? $0.offset < $1.offset : $0.element.depth < $1.element.depth
        }.map(\.element)
    }

    private static func clip(_ polygon: [CGPoint], normal: CGPoint, boundary: CGFloat, keepLower: Bool) -> [CGPoint] {
        guard var previous = polygon.last else { return [] }
        var result: [CGPoint] = []
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
        return result
    }
}

private struct BaselineCornerShadowSample: Equatable {
    let width: CGFloat
    let opacity: CGFloat
    let offset: CGPoint
}

private struct BaselineCornerShadowProfile {
    let normal: CGPoint
    let rootCoordinate: CGFloat
    let tipCoordinate: CGFloat
    private let heightScale: CGFloat
    private let curvatureBlend: CGFloat
    private let fade: CGFloat

    init?(drag: PaperCornerDrag, patches: [BaselineCornerPatch]) {
        let distance = hypot(drag.translation.x, drag.translation.y)
        guard distance.isFinite, distance > 1e-7, drag.length.isFinite, drag.length > 0 else { return nil }
        let back = patches.filter(\.back)
        let points = back.flatMap(\.projected)
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let maximumDepth = back.map(\.depth).max(), maximumDepth.isFinite, maximumDepth >= 0 else { return nil }
        normal = CGPoint(x: -drag.translation.x / distance, y: -drag.translation.y / distance)
        let n = normal
        guard let root = points.map({ n.x * $0.x + n.y * $0.y }).max() else { return nil }
        let tip = n.x * drag.tip.x + n.y * drag.tip.y
        guard root.isFinite, tip.isFinite, root - tip > 1e-7 else { return nil }
        rootCoordinate = root; tipCoordinate = tip
        let endFade = min(1, max(0, (1 - drag.progress) / 0.15))
        let curvatureScale = min(1, maximumDepth / max(1, drag.length * 0.12))
        let span = min(1, (root - tip) / max(1, drag.length * 0.5))
        let contactScale = 0.65 * span * span * (3 - 2 * span) * endFade
        let scale = max(curvatureScale, contactScale)
        heightScale = scale
        curvatureBlend = scale > 0 ? min(1, curvatureScale / scale) : 1
        fade = min(1, distance / max(1, drag.length * 0.15)) * endFade
        guard fade > 0 else { return nil }
    }

    func sample(at point: CGPoint) -> BaselineCornerShadowSample {
        guard point.x.isFinite, point.y.isFinite else { return .init(width: 0, opacity: 0, offset: .zero) }
        let position = normal.x * point.x + normal.y * point.y
        let t = min(1, max(0, (rootCoordinate - position) / (rootCoordinate - tipCoordinate)))
        let curvedHeight = t * t * (3 - 2 * t)
        let contactT = min(1, t * 8)
        let contactHeight = contactT * contactT * (3 - 2 * contactT)
        let height = (curvedHeight * curvatureBlend + contactHeight * (1 - curvatureBlend)) * heightScale
        let width = (0.45 + 17.5 * height) * fade
        let opacity = (0.015 + 0.245 * height) * fade
        return .init(width: width, opacity: opacity, offset: CGPoint(x: 0, y: width * 0.18))
    }
}

private struct BaselineCornerShadowVertex {
    let point: CGPoint
    let opacity: CGFloat
}

private enum BaselineCornerShadowGeometry {
    static func vertices(for drag: PaperCornerDrag, patches: [BaselineCornerPatch]) -> [BaselineCornerShadowVertex] {
        guard let profile = BaselineCornerShadowProfile(drag: drag, patches: patches) else { return [] }
        let hull = convexHull(patches.filter(\.back).flatMap(\.projected))
        guard hull.count >= 3 else { return [] }
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
        var inner: [BaselineCornerShadowVertex] = [], outer: [BaselineCornerShadowVertex] = []
        inner.reserveCapacity(outline.count); outer.reserveCapacity(outline.count)
        for i in outline.indices {
            let point = outline[i], prev = outline[(i + outline.count - 1) % outline.count], next = outline[(i + 1) % outline.count]
            let lenA = max(1e-6, hypot(point.x - prev.x, point.y - prev.y))
            let lenB = max(1e-6, hypot(next.x - point.x, next.y - point.y))
            let a = CGPoint(x: (point.y - prev.y) / lenA, y: -(point.x - prev.x) / lenA)
            let b = CGPoint(x: (next.y - point.y) / lenB, y: -(next.x - point.x) / lenB)
            let divisor = max(0.5, 1 + a.x * b.x + a.y * b.y)
            let local = profile.sample(at: point)
            inner.append(.init(point: point, opacity: local.opacity))
            outer.append(.init(point: CGPoint(x: point.x + local.offset.x + (a.x + b.x) * local.width / divisor,
                                              y: point.y + local.offset.y + (a.y + b.y) * local.width / divisor), opacity: 0))
        }
        var result: [BaselineCornerShadowVertex] = []
        result.reserveCapacity((3 * outline.count - 2) * 3)
        for i in 1..<(inner.count - 1) { result.append(contentsOf: [inner[0], inner[i], inner[i + 1]]) }
        for i in inner.indices {
            let j = (i + 1) % inner.count
            result.append(contentsOf: [inner[i], inner[j], outer[j], inner[i], outer[j], outer[i]])
        }
        return result
    }

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
