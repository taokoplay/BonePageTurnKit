#if canImport(UIKit)
import UIKit
import XCTest
#if canImport(MetalKit)
import MetalKit
#endif
@testable import BonePageTurnKit

/// 材料坐标与真实投影的约束回归；不以旧 arch 条带波形作为参考答案。
@MainActor
final class ArchContactConstraintTests: XCTestCase {
    private let axes: [PageTurnAxis] = [.horizontal, .vertical]
    private let directions: [PageTurnDirection] = [.next, .previous]
    private let orders: [ReaderReadingOrder] = [.leftToRight, .rightToLeft]
    private let epsilon: CGFloat = 0.0001

    private struct MaterialSample {
        let source: CGPoint
        let point: CGPoint
        let worldPoint: CGPoint
        let height: CGFloat
    }

    private struct Surface {
        let direction: PageTurnDirection
        let materialPage: CGRect
        let materialContact: CGPoint
        let patches: [PaperCornerPatch]
        let shades: [[CGFloat]]
        let shadow: [PaperCornerShadowVertex]
        let samples: [MaterialSample]
    }

    private struct SourceKey: Hashable {
        let x: CGFloat
        let y: CGFloat
        init(_ point: CGPoint) { x = point.x; y = point.y }
    }

    private func canvas(_ axis: PageTurnAxis) -> CGSize {
        axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
    }

    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    private func primary(_ point: CGPoint, axis: PageTurnAxis) -> CGFloat {
        axis == .horizontal ? point.x : point.y
    }

    private func cross(_ point: CGPoint, axis: PageTurnAxis) -> CGFloat {
        axis == .horizontal ? point.y : point.x
    }

    private func origin(axis: PageTurnAxis, spread: Bool, sign: CGFloat, cross: CGFloat = 240) -> CGPoint {
        let coordinate: CGFloat = spread ? (sign < 0 ? 280 : 40) : (sign < 0 ? 240 : 80)
        return point(coordinate, cross, axis: axis)
    }

    private func spine(axis: PageTurnAxis, spread: Bool, sign: CGFloat) -> CGFloat {
        spread ? 160 : (sign < 0 ? 0 : 320)
    }

    private func surface(_ drag: PaperCornerDrag, direction: PageTurnDirection,
                         order: ReaderReadingOrder = .leftToRight, strips: Int = 96) -> Surface {
        let mesh = PaperArchGeometry.mesh(for: drag, direction: direction, stripCount: strips, readingOrder: order)
        let materialPage = PaperArchGeometry.materialPage(for: drag, direction: direction)
        let materialContact = direction == .previous
            ? point(drag.axis == .horizontal
                ? (drag.inwardSign > 0 ? materialPage.maxX : materialPage.minX)
                : (drag.inwardSign > 0 ? materialPage.maxY : materialPage.minY),
                cross(drag.origin, axis: drag.axis), axis: drag.axis)
            : drag.origin
        return Surface(direction: direction, materialPage: materialPage, materialContact: materialContact,
            patches: mesh.patches, shades: mesh.shades, shadow: mesh.shadow, samples: mesh.samples.map {
                MaterialSample(source: $0.source, point: $0.point, worldPoint: $0.worldPoint, height: $0.height)
            })
    }

    private func assertPoint(_ actual: CGPoint, equals expected: CGPoint, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: epsilon, context, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: epsilon, context, file: file, line: line)
    }

    private func assertFinite(_ mesh: Surface, _ context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for sample in mesh.samples {
            XCTAssertTrue([sample.source.x, sample.source.y, sample.point.x, sample.point.y,
                sample.worldPoint.x, sample.worldPoint.y, sample.height].allSatisfy(\.isFinite), context, file: file, line: line)
            XCTAssertGreaterThanOrEqual(sample.height, -epsilon, "\(context): paper crossed the bottom page", file: file, line: line)
        }
        XCTAssertEqual(mesh.patches.count, mesh.shades.count, context, file: file, line: line)
        var sharedShades: [SourceKey: CGFloat] = [:]
        for (patchIndex, patch) in mesh.patches.enumerated() {
            guard mesh.shades.indices.contains(patchIndex) else { continue }
            let shades = mesh.shades[patchIndex]
            XCTAssertEqual(patch.source.count, shades.count, context, file: file, line: line)
            for (source, shade) in zip(patch.source, shades) {
                XCTAssertTrue(shade.isFinite && (0...0.18).contains(shade), context, file: file, line: line)
                let key = SourceKey(source)
                if let previous = sharedShades[key] {
                    XCTAssertEqual(shade, previous, "\(context): shared material vertex has a lighting seam", file: file, line: line)
                } else { sharedShades[key] = shade }
            }
            XCTAssertGreaterThanOrEqual(patch.source.count, 3, context, file: file, line: line)
            XCTAssertTrue((patch.source + patch.projected).allSatisfy { $0.x.isFinite && $0.y.isFinite },
                          context, file: file, line: line)
            let t = patch.transform
            XCTAssertTrue([t.a, t.b, t.c, t.d, t.tx, t.ty, patch.depth, patch.shade].allSatisfy(\.isFinite),
                          context, file: file, line: line)
        }
        for vertex in mesh.shadow {
            XCTAssertTrue([vertex.point.x, vertex.point.y, vertex.opacity].allSatisfy(\.isFinite), context, file: file, line: line)
            XCTAssertTrue((0...1).contains(vertex.opacity), context, file: file, line: line)
        }
    }

    private func contact(_ mesh: Surface, origin: CGPoint, touch: CGPoint, context: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> MaterialSample {
        let materialOrigin = mesh.direction == .previous ? mesh.materialContact : origin
        let sample = try XCTUnwrap(mesh.samples.first { $0.source == materialOrigin },
                                   "\(context): mesh must explicitly contain the material contact", file: file, line: line)
        assertPoint(sample.point, equals: touch, context, file: file, line: line)
        XCTAssertEqual(sample.height, 0, accuracy: epsilon, context, file: file, line: line)
        // 检查交给绘制器的三角形，避免 samples 正确而实际投影仍漂移。
        let incident = mesh.patches.filter { $0.source.contains(materialOrigin) }
        XCTAssertFalse(incident.isEmpty, "\(context): contact must be a rendered mesh vertex", file: file, line: line)
        for patch in incident {
            assertPoint(materialOrigin.applying(patch.transform), equals: touch, context, file: file, line: line)
        }
        return sample
    }

    private func assertPinnedSpine(_ mesh: Surface, drag: PaperCornerDrag, context: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let axis = drag.axis
        let materialSign = mesh.direction == .previous ? -drag.inwardSign : drag.inwardSign
        let hinge = axis == .horizontal
            ? (materialSign < 0 ? mesh.materialPage.minX : mesh.materialPage.maxX)
            : (materialSign < 0 ? mesh.materialPage.minY : mesh.materialPage.maxY)
        let fixed = mesh.samples.filter { abs(primary($0.source, axis: axis) - hinge) <= 1e-8 }
        XCTAssertGreaterThanOrEqual(fixed.count, 3, "\(context): missing original material spine", file: file, line: line)
        for sample in fixed {
            assertPoint(sample.point, equals: sample.source, context, file: file, line: line)
            assertPoint(sample.worldPoint, equals: sample.source, context, file: file, line: line)
            XCTAssertEqual(sample.height, 0, accuracy: epsilon, context, file: file, line: line)
        }
    }

    private func fiber(_ mesh: Surface, through origin: CGPoint, axis: PageTurnAxis) -> [MaterialSample] {
        let row = mesh.samples.filter { abs(cross($0.source, axis: axis) - cross(origin, axis: axis)) <= epsilon }
            .sorted { primary($0.source, axis: axis) < primary($1.source, axis: axis) }
        var unique: [MaterialSample] = []
        for sample in row {
            if let last = unique.last, abs(primary(last.source, axis: axis) - primary(sample.source, axis: axis)) <= epsilon { continue }
            unique.append(sample)
        }
        return unique
    }

    private func lengths(_ samples: [MaterialSample]) -> (material: CGFloat, projected3D: CGFloat) {
        var material: CGFloat = 0, projected: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            material += hypot(b.source.x - a.source.x, b.source.y - a.source.y)
            let dx = b.worldPoint.x - a.worldPoint.x, dy = b.worldPoint.y - a.worldPoint.y, dz = b.height - a.height
            projected += sqrt(dx * dx + dy * dy + dz * dz)
        }
        return (material, projected)
    }

    private func physicalMetric(_ mesh: Surface, patches: [PaperCornerPatch]? = nil) throws
        -> (scale: CGFloat, angle: CGFloat, count: Int, area: CGFloat) {
        let samples = Dictionary(uniqueKeysWithValues: mesh.samples.map { (SourceKey($0.source), $0) })
        var scale: CGFloat = 0, angle: CGFloat = 0, count = 0, area: CGFloat = 0
        for patch in patches ?? mesh.patches {
            let a = try XCTUnwrap(samples[SourceKey(patch.source[0])])
            let b = try XCTUnwrap(samples[SourceKey(patch.source[1])])
            let c = try XCTUnwrap(samples[SourceKey(patch.source[2])])
            let ux = b.source.x - a.source.x, uy = b.source.y - a.source.y
            let vx = c.source.x - a.source.x, vy = c.source.y - a.source.y
            let det = ux * vy - uy * vx
            area += abs(det) / 2
            guard abs(det) > 1e-5 else { continue }
            let dx = [b.worldPoint.x - a.worldPoint.x, b.worldPoint.y - a.worldPoint.y, b.height - a.height]
            let dy = [c.worldPoint.x - a.worldPoint.x, c.worldPoint.y - a.worldPoint.y, c.height - a.height]
            var e: CGFloat = 0, f: CGFloat = 0, g: CGFloat = 0
            for k in 0..<3 {
                let x = (dx[k] * vy - dy[k] * uy) / det, y = (dy[k] * ux - dx[k] * vx) / det
                e += x * x; f += x * y; g += y * y
            }
            let radius = hypot(e - g, 2 * f)
            scale = max(scale, max(abs(sqrt(max(0, (e + g - radius) / 2)) - 1),
                abs(sqrt(max(0, (e + g + radius) / 2)) - 1)))
            angle = max(angle, abs(acos(min(1, max(-1, f / sqrt(e * g)))) - .pi / 2))
            count += 1
        }
        return (scale, angle, count, area)
    }

    func testMaterialContactAndFixedSpineArchMatrix() throws {
        let pulls: [(CGFloat, CGFloat)] = [(48, -20), (48, 20), (80, -35), (80, 35)]
        for axis in axes {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for direction in directions {
                        for order in orders {
                            for height: CGFloat in [96, 240, 384] {
                                let source = origin(axis: axis, spread: spread, sign: sign, cross: height)
                                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: spread,
                                    inwardSign: sign, origin: source, effect: .arch))
                                for (pull, across) in pulls {
                                    let touch = point(primary(source, axis: axis) + sign * pull, height + across, axis: axis)
                                    let live = try XCTUnwrap(seed.moved(to: touch, direction: direction))
                                    let mesh = surface(live, direction: direction, order: order)
                                    let context = "\(axis)/spread=\(spread)/\(sign)/\(direction)/\(order)/h=\(height)/\(pull),\(across)"
                                    XCTAssertFalse(mesh.patches.isEmpty, context)
                                    assertFinite(mesh, context)
                                    _ = try contact(mesh, origin: source, touch: live.gripPosition, context: context)
                                    let hinge = spine(axis: axis, spread: spread, sign: direction == .previous ? -sign : sign)
                                    let materialSource = mesh.materialContact
                                    let materialOutward = direction == .previous ? sign : -sign
                                    assertPinnedSpine(mesh, drag: live, context: context)

                                    // 回翻抓的是自由边，主轴只检查纸内一侧；横轴两侧仍须有有限零高度指腹。
                                    for alongPrimary in [true, false] {
                                        for side: CGFloat in [-1, 1] {
                                            if direction == .previous && alongPrimary && side == sign { continue }
                                            let neighbors = mesh.samples.filter { sample in
                                                let dp = primary(sample.source, axis: axis) - primary(materialSource, axis: axis)
                                                let dc = cross(sample.source, axis: axis) - height
                                                return alongPrimary ? (abs(dc) <= epsilon && dp * side > epsilon)
                                                    : (abs(dp) <= epsilon && dc * side > epsilon)
                                            }
                                            let neighbor = try XCTUnwrap(neighbors.min {
                                                hypot($0.source.x - materialSource.x, $0.source.y - materialSource.y)
                                                    < hypot($1.source.x - materialSource.x, $1.source.y - materialSource.y)
                                            }, context)
                                            XCTAssertLessThanOrEqual(hypot(neighbor.source.x - materialSource.x, neighbor.source.y - materialSource.y),
                                                                     12 + epsilon, "\(context): missing finite finger pad")
                                            XCTAssertEqual(neighbor.height, 0, accuracy: epsilon, "\(context): peak under the finger pad")
                                        }
                                    }
                                    let materialSpan = direction == .previous ? live.length
                                        : (primary(source, axis: axis) - hinge) * -sign
                                    let interior = fiber(mesh, through: materialSource, axis: axis).filter {
                                        let u = (primary($0.source, axis: axis) - hinge) * materialOutward
                                        return u > epsilon && u < materialSpan - epsilon
                                    }
                                    let peak = try XCTUnwrap(interior.max { $0.height < $1.height }, context)
                                    XCTAssertGreaterThan(peak.height, 0.5, "\(context): supported paper must bow between spine and finger")
                                    XCTAssertLessThanOrEqual(peak.height, materialSpan / 2 + epsilon, context)
                                    if direction == .previous {
                                        XCTAssertLessThanOrEqual(abs(primary(peak.worldPoint, axis: axis) - hinge), materialSpan + epsilon,
                                            "\(context): returning paper must stay within its full material reach of the binding")
                                    } else {
                                        XCTAssertGreaterThanOrEqual(primary(peak.point, axis: axis), min(hinge, primary(live.gripPosition, axis: axis)) - epsilon, context)
                                        XCTAssertLessThanOrEqual(primary(peak.point, axis: axis), max(hinge, primary(live.gripPosition, axis: axis)) + epsilon, context)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testSpineCrossingAndShortSpanKeepVisibleGeometryContinuous() throws {
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                let source = origin(axis: axis, spread: false, sign: sign)
                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 80, 240, axis: axis)))
                let freeEdge = point(sign < 0 ? 320 : 0, 240, axis: axis)
                let before = surface(live.released(completed: true, fraction: 2.0 / 3 - 0.00001), direction: .next)
                let after = surface(live.released(completed: true, fraction: 2.0 / 3 + 0.00001), direction: .next)
                let a = try XCTUnwrap(before.samples.first { $0.source == freeEdge })
                let b = try XCTUnwrap(after.samples.first { $0.source == freeEdge })
                XCTAssertLessThan(hypot(a.point.x - b.point.x, a.point.y - b.point.y), 0.1, "跨书脊不能翻侧跳变")
                XCTAssertLessThan(abs(a.height - b.height), 0.1)
                let hinge = spine(axis: axis, spread: false, sign: sign)
                let heldA = try XCTUnwrap(seed.moved(to: point(hinge - sign * 0.0001, 240, axis: axis)))
                let heldB = try XCTUnwrap(seed.moved(to: point(hinge + sign * 0.0001, 240, axis: axis)))
                let ca = try XCTUnwrap(surface(heldA, direction: .next).samples.first { $0.source == freeEdge })
                let cb = try XCTUnwrap(surface(heldB, direction: .next).samples.first { $0.source == freeEdge })
                XCTAssertLessThan(hypot(ca.point.x - cb.point.x, ca.point.y - cb.point.y), 0.01)
                let nearSpine = point(sign < 0 ? 8 : 312, 240, axis: axis)
                let short = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                    inwardSign: sign, origin: nearSpine, effect: .arch))
                let bent = try XCTUnwrap(short.moved(to: point(primary(nearSpine, axis: axis) + sign * 4, 240, axis: axis)))
                let mesh = surface(bent, direction: .next, strips: 32)
                XCTAssertGreaterThan(mesh.samples.map(\.height).max() ?? 0, 0.1, "短受力段也必须在实际网格中弓起")
                XCTAssertTrue(mesh.patches.contains { $0.depth > 0.1 })
                let dense = surface(live, direction: .next, strips: 256)
                let vertexCount = dense.patches.reduce(0) { $0 + $1.source.count } + dense.shadow.count + 12
                XCTAssertLessThanOrEqual(vertexCount, 32_768)
            }
        }
    }

    func testSpreadRejectsWrongHalfAndSpineBeforeRequestingNeighbor() throws {
        for axis in axes {
            for order in orders {
                let firstController = UIViewController(), secondController = UIViewController()
                let first = PageContent(identity: .init(sourceID: "contact-half", unitID: "first"), controller: firstController)
                let second = PageContent(identity: .init(sourceID: "contact-half", unitID: "second"), controller: secondController)
                let spread = try PageSpreadViewController(first: first, second: second, axis: axis, readingOrder: order)
                let initial = PageContent(identity: .init(sourceID: "contact-half", unitID: "current"), controller: spread)
                let reader = try PagedReaderViewController(page: initial, configuration: .init(
                    presentation: .paged(effect: .arch, axis: axis), layout: .spread, readingOrder: order))
                defer { reader.invalidate() }
                reader.loadViewIfNeeded(); reader.view.frame = CGRect(origin: .zero, size: canvas(axis))
                reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                var requests = 0
                reader.pageProvider = { _, _ in requests += 1; return .waiting }
                for direction in directions {
                    let forward: CGFloat = axis == .horizontal && order == .rightToLeft ? 1 : -1
                    let sign = direction == .next ? forward : -forward
                    for primary in [CGFloat(sign < 0 ? 80 : 240), 160] {
                        XCTAssertThrowsError(try reader.beginInteractiveTurn(direction, at: point(primary, 240, axis: axis))) {
                            XCTAssertEqual($0 as? PageTurnError, .invalidInteractionPoint)
                        }
                    }
                }
                XCTAssertEqual(requests, 0)
                XCTAssertFalse(reader.isTransitioning); XCTAssertNil(reader.activePaperView)
                XCTAssertEqual(reader.children.count, 1)
            }
        }
    }

    func testInteriorGrabRegressionProjectsAt160InsteadOf124() throws {
        let source = CGPoint(x: 240, y: 240), touch = CGPoint(x: 160, y: 240)
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: source, effect: .arch))
        let live = try XCTUnwrap(seed.moved(to: touch))
        let mesh = surface(live, direction: .next)
        let sample = try contact(mesh, origin: source, touch: touch, context: "320x480 / interior grab / left 80pt")
        XCTAssertEqual(sample.point.x, 160, accuracy: epsilon)
        XCTAssertGreaterThan(abs(sample.point.x - 124), 30, "The former strip projection must not remain the material contact")
        assertFinite(mesh, "interior grab regression")
    }

    func testCenterFiberPreservesLengthAndReversePullReducesArchHeight() throws {
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                let source = origin(axis: axis, spread: false, sign: sign)
                let hinge = spine(axis: axis, spread: false, sign: sign)
                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                let loaded = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 80, 240, axis: axis)))
                let reversed = try XCTUnwrap(loaded.moved(to: point(primary(source, axis: axis) + sign * 24, 240, axis: axis)))
                let loadedMesh = surface(loaded, direction: .next, strips: 128)
                let reversedMesh = surface(reversed, direction: .next, strips: 128)
                for (name, drag, mesh) in [("loaded", loaded, loadedMesh), ("reverse", reversed, reversedMesh)] {
                    let context = "\(axis)/\(sign)/\(name)"
                    assertFinite(mesh, context)
                    assertPinnedSpine(mesh, drag: drag, context: context)
                    let center = fiber(mesh, through: source, axis: axis)
                    XCTAssertGreaterThan(center.count, 12, context)
                    let full = lengths(center)
                    XCTAssertEqual(full.material, 320, accuracy: epsilon, "\(context): sample the entire material fiber")
                    // 用观察投影前的真实三维纸面验收弧长，书脊到原抓取点的材料段保持连接。
                    XCTAssertEqual(full.projected3D, full.material, accuracy: full.material * 0.01, context)
                    let range = min(hinge, primary(source, axis: axis))...max(hinge, primary(source, axis: axis))
                    let compressed = lengths(center.filter { range.contains(primary($0.source, axis: axis)) })
                    XCTAssertGreaterThan(compressed.material, 200, context)
                    XCTAssertEqual(compressed.projected3D, compressed.material, accuracy: compressed.material * 0.01, context)
                }
                let high = try XCTUnwrap(fiber(loadedMesh, through: source, axis: axis).map(\.height).max())
                let low = try XCTUnwrap(fiber(reversedMesh, through: source, axis: axis).map(\.height).max())
                XCTAssertGreaterThan(high, 1)
                XCTAssertLessThan(low, high - 0.1, "\(axis)/\(sign): reversing toward the origin must unload the arch")
            }
        }
    }

    func testReleaseMeshIsContinuousAndContactPressureDecaysToFreeSheet() throws {
        for axis in axes {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for direction in directions {
                        let source = origin(axis: axis, spread: spread, sign: sign)
                        let hinge = spine(axis: axis, spread: spread, sign: direction == .previous ? -sign : sign)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: spread,
                            inwardSign: sign, origin: source, effect: .arch))
                        let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 80, 264, axis: axis), direction: direction))
                        let held = surface(live, direction: direction)
                        XCTAssertEqual(live.archContactStrength, 1, accuracy: epsilon)
                        for completed in [false, true] {
                            let context = "\(axis)/spread=\(spread)/\(sign)/\(direction)/completed=\(completed)"
                            let zero = live.released(completed: completed, fraction: 0, direction: direction)
                            XCTAssertEqual(zero, live, "\(context): release fraction zero must preserve the submitted pose")
                            let zeroMesh = surface(zero, direction: direction)
                            XCTAssertEqual(zeroMesh.samples.map(\.source), held.samples.map(\.source), context)
                            XCTAssertEqual(zeroMesh.samples.map(\.point), held.samples.map(\.point), context)
                            XCTAssertEqual(zeroMesh.samples.map(\.height), held.samples.map(\.height), context)
                            XCTAssertEqual(zeroMesh.patches.map(\.projected), held.patches.map(\.projected), context)

                            let tiny = live.released(completed: completed, fraction: 0.00001, direction: direction)
                            let tinyMesh = surface(tiny, direction: direction)
                            var reference: [SourceKey: MaterialSample] = [:]
                            for sample in held.samples { reference[SourceKey(sample.source)] = sample }
                            var maximumChange: CGFloat = 0, matched = 0
                            for sample in tinyMesh.samples {
                                guard let old = reference[SourceKey(sample.source)] else { continue }
                                let dx = sample.point.x - old.point.x, dy = sample.point.y - old.point.y, dz = sample.height - old.height
                                maximumChange = max(maximumChange, sqrt(dx * dx + dy * dy + dz * dz)); matched += 1
                            }
                            XCTAssertGreaterThan(matched, 8, "\(context): compare shared real material samples")
                            XCTAssertLessThan(maximumChange, 1, "\(context): a tiny release step must not jump the actual surface")
                            XCTAssertEqual(tiny.archContactStrength, live.archContactStrength, accuracy: 0.001, context)
                            var lastStrength = live.archContactStrength
                            for fraction: CGFloat in [0.00001, 0.1, 0.35, 0.7, 0.95, 0.99999, 1] {
                                let pose = live.released(completed: completed, fraction: fraction, direction: direction)
                                let mesh = surface(pose, direction: direction)
                                XCTAssertTrue((0...1).contains(pose.archContactStrength), context)
                                XCTAssertLessThanOrEqual(pose.archContactStrength, lastStrength + epsilon, context)
                                lastStrength = pose.archContactStrength
                                assertFinite(mesh, "\(context)/f=\(fraction)")
                                assertPinnedSpine(mesh, drag: pose, context: context)
                                XCTAssertLessThanOrEqual(mesh.samples.map(\.height).max() ?? 0, pose.length + epsilon,
                                    "\(context): bounded material must not create an exploding free arch")
                                let releasedContact = try XCTUnwrap(mesh.samples.first { $0.source == mesh.materialContact }, context)
                                if completed && fraction == 0.35 {
                                    let dx = releasedContact.point.x - pose.gripPosition.x
                                    let dy = releasedContact.point.y - pose.gripPosition.y
                                    XCTAssertGreaterThan(sqrt(dx * dx + dy * dy + releasedContact.height * releasedContact.height),
                                        0.5, "\(context): release must actually unload the finger constraint")
                                }
                                if completed && fraction == 0.99999 {
                                    if direction == .previous {
                                        for sample in mesh.samples {
                                            XCTAssertLessThanOrEqual(hypot(sample.point.x - sample.source.x, sample.point.y - sample.source.y), 0.01,
                                                "\(context): returning sheet must approach its upright source page")
                                            XCTAssertLessThanOrEqual(hypot(sample.worldPoint.x - sample.source.x, sample.worldPoint.y - sample.source.y), 0.01, context)
                                            XCTAssertLessThanOrEqual(sample.height, 0.01, context)
                                        }
                                    } else {
                                        let values = mesh.samples.map { primary($0.point, axis: axis) }
                                        let pageMin = axis == .horizontal ? pose.page.minX : pose.page.minY
                                        let pageMax = axis == .horizontal ? pose.page.maxX : pose.page.maxY
                                        let visibleWidth = max(0, min(pageMax, values.max() ?? 0) - max(pageMin, values.min() ?? 0))
                                        XCTAssertLessThanOrEqual(visibleWidth, 0.01,
                                            "\(context): original turning half must clear before landing; a spread sheet may occupy the opposite half")
                                    }
                                }
                                if fraction == 1 {
                                    XCTAssertEqual(pose.archContactStrength, 0, accuracy: epsilon, context)
                                    XCTAssertTrue(mesh.samples.allSatisfy { abs($0.height) <= epsilon }, "\(context): endpoint must be flat")
                                    if direction == .previous {
                                        for sample in mesh.samples {
                                            let expected = completed ? sample.source
                                                : point(2 * hinge - primary(sample.source, axis: axis), cross(sample.source, axis: axis), axis: axis)
                                            assertPoint(sample.point, equals: expected, context)
                                            assertPoint(sample.worldPoint, equals: expected, context)
                                        }
                                    } else if completed {
                                        let landing = try XCTUnwrap(mesh.samples.first { $0.source == source }, context)
                                        XCTAssertLessThanOrEqual((primary(landing.point, axis: axis) - hinge)
                                            * (primary(source, axis: axis) - hinge), epsilon, "\(context): free sheet must turn past the spine")
                                    } else {
                                        for sample in mesh.samples { assertPoint(sample.point, equals: sample.source, context) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testBoundSpineArchHasContinuousPrintedLinesAtPhoneAspectRatio() throws {
        var maximumSpineDrift: CGFloat = 0, maximumWidthScaleError: CGFloat = 0, maximumLineBow: CGFloat = 0
        var checked = 0
        for axis in axes {
            let size = CGSize(width: 390, height: 844)
            let extent = axis == .horizontal ? size.width : size.height
            let breadth = axis == .horizontal ? size.height : size.width
            for spread in [false, true] {
                let length = spread ? extent / 2 : extent
                for sign: CGFloat in [-1, 1] {
                    let hinge = spread ? extent / 2 : (sign < 0 ? 0 : extent)
                    for contactFraction: CGFloat in [0.32, 0.82, 1] {
                        let distance = length * contactFraction
                        let source = point(hinge - sign * distance, breadth * 0.61, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: source, effect: .arch))
                        for pullFraction: CGFloat in [0, 0.05, 0.15, 0.32, 0.46, 0.7, 0.9] {
                            let touch = point(primary(source, axis: axis) + sign * distance * pullFraction,
                                              cross(source, axis: axis), axis: axis)
                            let live = try XCTUnwrap(seed.moved(to: touch))
                            let mesh = surface(live, direction: .next, strips: 128)
                            let context = "\(axis)/\(spread)/\(sign)/contact=\(contactFraction)/pull=\(pullFraction)"
                            XCTAssertFalse(mesh.patches.isEmpty, context)
                            assertFinite(mesh, context)
                            assertPinnedSpine(mesh, drag: live, context: context)
                            _ = try contact(mesh, origin: source, touch: live.gripPosition, context: context)
                            let originalSpine = mesh.samples.filter { abs(primary($0.source, axis: axis) - hinge) < epsilon }
                            for sample in originalSpine {
                                maximumSpineDrift = max(maximumSpineDrift, hypot(sample.point.x - sample.source.x, sample.point.y - sample.source.y))
                            }
                            let peak = mesh.samples.map(\.height).max() ?? 0
                            XCTAssertLessThanOrEqual(peak, distance / 2 + epsilon, context)
                            let center = fiber(mesh, through: source, axis: axis)
                            let full = lengths(center)
                            XCTAssertEqual(full.projected3D, full.material, accuracy: full.material * 0.01, context)
                            let bow = center.map { abs(cross($0.point, axis: axis) - cross($0.source, axis: axis)) }.max() ?? 0
                            maximumLineBow = max(maximumLineBow, bow)
                            if pullFraction > 0 {
                                XCTAssertGreaterThan(peak, 0, context)
                                XCTAssertGreaterThan(bow, distance * 0.01,
                                    "\(context): reference paper lines must visibly bow, not stay straight on a compressed panel")
                            } else {
                                for sample in mesh.samples { assertPoint(sample.point, equals: sample.source, context) }
                            }
                            XCTAssertLessThanOrEqual(bow, distance * 0.12, "\(context): keep the observation angle gentle")
                            for patch in mesh.patches {
                                let t = patch.transform
                                let widthScale = axis == .horizontal ? hypot(t.c, t.d) : hypot(t.a, t.b)
                                maximumWidthScaleError = max(maximumWidthScaleError, abs(widthScale - 1))
                                if pullFraction <= 0.46 {
                                    XCTAssertFalse(patch.back, "\(context): moderate pressure forms a front-facing arch")
                                }
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        print("ARCH_REFERENCE_METRICS spineDrift=\(maximumSpineDrift) widthScaleError=\(maximumWidthScaleError) lineBow=\(maximumLineBow) poses=\(checked)")
        XCTAssertEqual(checked, 168)
        XCTAssertLessThanOrEqual(maximumSpineDrift, epsilon)
        XCTAssertLessThanOrEqual(maximumWidthScaleError, 0.0001, "Shared material generators must not fan toward the finger")
    }

    func testInteriorGrabRespectsFixedSpineMaterialReach() throws {
        for axis in axes {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let hinge = spine(axis: axis, spread: spread, sign: sign)
                    let length: CGFloat = spread ? 160 : 320
                    let distance = length * 0.1
                    let source = point(hinge - sign * distance, 240, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: spread,
                        inwardSign: sign, origin: source, effect: .arch))
                    let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * length * 1.5, 264, axis: axis)))
                    XCTAssertEqual(primary(live.translation, axis: axis), sign * 2 * distance, accuracy: epsilon)
                    XCTAssertEqual(cross(live.translation, axis: axis), 0, accuracy: epsilon)
                    let mesh = surface(live, direction: .next)
                    assertFinite(mesh, "bound interior grab")
                    assertPinnedSpine(mesh, drag: live, context: "bound interior grab")
                    _ = try contact(mesh, origin: source, touch: live.gripPosition, context: "bound interior grab")
                }
            }
        }
    }

    func testDefaultCurlStillMatchesExplicitCurlRenderedPatches() throws {
        for axis in axes {
            for direction in directions {
                let source = origin(axis: axis, spread: false, sign: -1)
                let defaultSeed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false, inwardSign: -1, origin: source))
                let explicitSeed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                    inwardSign: -1, origin: source, effect: .curl))
                let touch = point(160, 264, axis: axis)
                let implicit = try XCTUnwrap(defaultSeed.moved(to: touch, direction: direction))
                let explicit = try XCTUnwrap(explicitSeed.moved(to: touch, direction: direction))
                for fraction: CGFloat in [0, 0.4, 1] {
                    let a = try XCTUnwrap(implicit.released(completed: true, fraction: fraction, direction: direction)
                        .foldingPresentation(direction: direction, size: canvas(axis), spread: false))
                    let b = try XCTUnwrap(explicit.released(completed: true, fraction: fraction, direction: direction)
                        .foldingPresentation(direction: direction, size: canvas(axis), spread: false))
                    let actual = PaperCornerCurlGeometry.patches(for: a, stripCount: 64)
                    let expected = PaperCornerCurlGeometry.patches(for: b, stripCount: 64)
                    XCTAssertFalse(actual.isEmpty)
                    XCTAssertEqual(actual.map(\.source), expected.map(\.source))
                    XCTAssertEqual(actual.map(\.projected), expected.map(\.projected))
                    XCTAssertEqual(actual.map(\.depth), expected.map(\.depth))
                    XCTAssertEqual(actual.map(\.back), expected.map(\.back))
                    XCTAssertEqual(actual.map(\.shade), expected.map(\.shade))
                }
            }
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func green(in rect: CGRect) -> (count: Int, centroid: CGPoint, bounds: CGRect)? {
            let x0 = max(0, Int(floor(rect.minX))), x1 = min(width, Int(ceil(rect.maxX)))
            let y0 = max(0, Int(floor(rect.minY))), y1 = min(height, Int(ceil(rect.maxY)))
            guard x1 > x0, y1 > y0 else { return nil }
            var count = 0, sumX: CGFloat = 0, sumY: CGFloat = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let offset = (y * width + x) * 4
                    let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                    guard g > 90, g > r + 60, g > b + 60 else { continue }
                    count += 1; sumX += CGFloat(x) + 0.5; sumY += CGFloat(y) + 0.5
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard count > 0 else { return nil }
            return (count, CGPoint(x: sumX / CGFloat(count), y: sumY / CGFloat(count)),
                    CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }

        func changedFraction(from other: Raster, tolerance: Int = 10) -> Double {
            guard width == other.width, height == other.height else { return 1 }
            var changed = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if (0..<3).contains(where: { abs(Int(bytes[offset + $0]) - Int(other.bytes[offset + $0])) > tolerance }) { changed += 1 }
            }
            return Double(changed) / Double(width * height)
        }
    }

    private func raster(_ image: UIImage) throws -> Raster {
        let source = try XCTUnwrap(image.cgImage)
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        // 与现有 Metal 读回一致：CGImage 的行顺序已经对应 UIKit 顶部坐标。
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let data = try XCTUnwrap(context.makeImage()?.dataProvider?.data)
        return Raster(width: source.width, height: source.height, bytes: [UInt8](data as Data))
    }

    private func page(size: CGSize, target: Bool, marker: CGPoint? = nil, details: Bool = false) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = .light; view.backgroundColor = target ? .magenta : .white
        if let marker {
            let mark = UIView(frame: CGRect(x: marker.x - 3, y: marker.y - 3, width: 6, height: 6))
            mark.backgroundColor = .green; view.addSubview(mark)
        }
        if details {
            let fixtures: [(CGRect, UIColor)] = [
                (CGRect(x: 11, y: 17, width: 41, height: 27), target ? .cyan : .blue),
                (CGRect(x: size.width - 83, y: 29, width: 63, height: 19), target ? .yellow : .red),
                (CGRect(x: 31, y: size.height - 67, width: 25, height: 49), target ? .blue : .yellow),
                (CGRect(x: size.width - 53, y: size.height - 39, width: 31, height: 21), target ? .red : .cyan)
            ]
            for (frame, color) in fixtures {
                let block = UIView(frame: frame); block.backgroundColor = color; view.addSubview(block)
            }
        }
        view.layoutIfNeeded(); return view
    }

    private func capture(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
    }

    private func paper(current: UIView, target: UIView, axis: PageTurnAxis, spread: Bool,
                       sign: CGFloat, direction: PageTurnDirection, order: ReaderReadingOrder = .leftToRight) throws -> PaperTransitionView {
        let size = current.bounds.size
        let bindingSign = direction == .previous ? -sign : sign
        return try PaperTransitionView(currentView: current, targetView: target, effect: .arch, direction: direction,
            spine: spread ? .center : (bindingSign < 0 ? .minimum : .maximum),
            options: .init(maximumSnapshotPixels: Int(size.width * size.height) * 2, stripCount: 96),
            axis: axis, readingOrder: order, cornerDriven: true)
    }

    private func attachGallery(_ samples: [(String, UIImage)]) {
        guard !samples.isEmpty else { return }
        let columns = 4, cell = CGSize(width: 136, height: 128)
        let rows = (samples.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * cell.width, height: CGFloat(rows) * cell.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for (index, sample) in samples.enumerated() {
                let x = CGFloat(index % columns) * cell.width, y = CGFloat(index / columns) * cell.height
                (sample.0 as NSString).draw(in: CGRect(x: x + 4, y: y + 2, width: cell.width - 8, height: 28),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
                sample.1.draw(in: CGRect(x: x + 20, y: y + 30, width: 96, height: 96))
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "arch-material-contact-metal-gallery"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testGPUContactMarkerTracksTurningMaterialWithoutMagnification() throws {
        #if canImport(MetalKit)
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "Requires an actual Metal device")
        var gallery: [(String, UIImage)] = []
        defer { attachGallery(gallery) }
        for axis in axes {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let source = origin(axis: axis, spread: spread, sign: sign)
                    for direction in directions {
                        let extent = axis == .horizontal ? canvas(axis).width : canvas(axis).height
                        let materialMarker = direction == .previous
                            ? point(sign > 0 ? extent : 0, cross(source, axis: axis), axis: axis) : source
                        let current = page(size: canvas(axis), target: false, marker: direction == .next ? source : nil)
                        let target = page(size: canvas(axis), target: true, marker: direction == .previous ? materialMarker : nil)
                        let renderer = try paper(current: current, target: target, axis: axis, spread: spread, sign: sign, direction: direction)
                        defer { renderer.invalidateResources() }
                        XCTAssertTrue(renderer.usesMetalCornerRendering)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: spread,
                            inwardSign: sign, origin: source, effect: .arch))
                        for across: CGFloat in [-20, 20] {
                            let requested = point(primary(source, axis: axis) + sign * 64, 240 + across, axis: axis)
                            let live = try XCTUnwrap(seed.moved(to: requested, direction: direction))
                            let touch = live.gripPosition
                            let mesh = surface(live, direction: direction)
                            _ = try contact(mesh, origin: source, touch: touch, context: "GPU input mesh")
                            renderer.update(progress: live.progress, cornerDrag: live)
                            let image = try XCTUnwrap(renderer.cornerGPUImage(scale: 1))
                            let pixels = try raster(image)
                            XCTAssertEqual(pixels.width, Int(canvas(axis).width)); XCTAssertEqual(pixels.height, Int(canvas(axis).height))
                            let context = "\(axis)/\(spread ? "spread" : "single")/\(direction)/sign=\(sign)/cross=\(across)"
                            if across < 0 {
                                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: touch.x - 24, y: touch.y - 24, width: 48, height: 48)))
                                gallery.append(("\(axis) \(spread ? "2p" : "1p") \(direction) \(Int(sign))", UIImage(cgImage: crop)))
                            }
                            let roi = CGRect(x: touch.x - 14, y: touch.y - 14, width: 28, height: 28)
                            if direction == .previous, spread, pixels.green(in: roi) == nil {
                                // 折在对侧的纸背可能真实挡住指腹；以投影三角形验证遮挡，不能强行把标记画到最上层。
                                let cover = try XCTUnwrap(mesh.patches.last { patch in
                                    let a = patch.projected[0], b = patch.projected[1], c = patch.projected[2]
                                    let det = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                                    guard abs(det) > 1e-10 else { return false }
                                    let u = ((touch.x - a.x) * (c.y - a.y) - (touch.y - a.y) * (c.x - a.x)) / det
                                    let v = ((b.x - a.x) * (touch.y - a.y) - (b.y - a.y) * (touch.x - a.x)) / det
                                    return u >= -1e-8 && v >= -1e-8 && u + v <= 1 + 1e-8
                                }, context)
                                XCTAssertFalse(cover.source.contains(mesh.materialContact), context)
                                XCTAssertTrue(cover.back, "Only an actually occluding paper back can hide this front-face marker")
                                XCTAssertGreaterThan(cover.depth, 1, context)
                                XCTAssertNil(pixels.green(in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)), context)
                                let offset = (Int(touch.y) * pixels.width + Int(touch.x)) * 4
                                let rgb = pixels.bytes[offset..<(offset + 3)].map(Int.init)
                                XCTAssertLessThan((rgb.max() ?? 255) - (rgb.min() ?? 0), 3, "Spread paper back samples the white current page")
                                XCTAssertGreaterThan(rgb.min() ?? 0, 180, context)
                                let landing = live.released(completed: true, fraction: 1, direction: .previous)
                                renderer.update(progress: 1, cornerDrag: landing)
                                let landed = try raster(XCTUnwrap(renderer.cornerGPUImage(scale: 1)))
                                let visible = try XCTUnwrap(landed.green(in: CGRect(x: 0, y: 0, width: landed.width, height: landed.height)), context)
                                XCTAssertGreaterThanOrEqual(visible.count, 12, "The SAME clipped material marker must reappear after unfolding")
                                XCTAssertLessThanOrEqual(visible.count, 24, "Unfolding must not enlarge or duplicate the clipped marker")
                                XCTAssertLessThanOrEqual(visible.bounds.width, 6, context)
                                XCTAssertLessThanOrEqual(visible.bounds.height, 6, context)
                                continue
                            }
                            let local = try XCTUnwrap(pixels.green(in: roi), "\(context): turning-page green marker missing at touch")
                            var expectedCenter = touch
                            var maximumCount = 64
                            var maximumWidth: CGFloat = 9, maximumHeight: CGFloat = 9
                            if direction == .previous {
                                // 自由边截掉 6pt 标记的一半；用有限平坦指腹的刚体投影验收剩下的 3x6pt。
                                let footprint = CGRect(x: materialMarker.x - 3, y: materialMarker.y - 3, width: 6, height: 6)
                                    .intersection(mesh.materialPage)
                                XCTAssertEqual(footprint.width * footprint.height, 18, accuracy: epsilon, context)
                                let heights = Dictionary(uniqueKeysWithValues: mesh.samples.map { (SourceKey($0.source), $0.height) })
                                let pad = try XCTUnwrap(mesh.patches.first { patch in
                                    patch.source.contains(mesh.materialContact)
                                        && patch.source.allSatisfy { heights[SourceKey($0)] == 0 }
                                }, "\(context): marker needs a finite flat material pad")
                                expectedCenter = CGPoint(x: footprint.midX, y: footprint.midY).applying(pad.transform)
                                let projected = footprint.applying(pad.transform)
                                maximumCount = Int(ceil(footprint.width * footprint.height)) + 6
                                maximumWidth = ceil(projected.width) + 1
                                maximumHeight = ceil(projected.height) + 1
                            }
                            XCTAssertLessThanOrEqual(hypot(local.centroid.x - expectedCenter.x, local.centroid.y - expectedCenter.y), 2.25, context)
                            XCTAssertGreaterThanOrEqual(local.count, 12, "\(context): marker must have visible area")
                            XCTAssertLessThanOrEqual(local.count, maximumCount, "\(context): clipped material marker must not inflate")
                            XCTAssertLessThanOrEqual(local.bounds.width, maximumWidth, context)
                            XCTAssertLessThanOrEqual(local.bounds.height, maximumHeight, context)
                            let all = try XCTUnwrap(pixels.green(in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)), context)
                            XCTAssertEqual(all.count, local.count, "\(context): no duplicate or enlarged green material outside the contact ROI")
                        }
                    }
                }
            }
        }
        #else
        throw XCTSkip("MetalKit is unavailable")
        #endif
    }

    func testGPUInitialAndReleasedEndpointsMatchWholePages() throws {
        #if canImport(MetalKit)
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "Requires an actual Metal device")
        for axis in axes {
            for spread in [false, true] {
                for order in orders {
                    for direction in directions {
                        let forward: CGFloat = axis == .horizontal && order == .rightToLeft ? 1 : -1
                        let sign = direction == .next ? forward : -forward
                        let source = origin(axis: axis, spread: spread, sign: sign)
                        let current = page(size: canvas(axis), target: false, marker: source, details: true)
                        let target = page(size: canvas(axis), target: true, details: true)
                        let flatCurrent = try raster(capture(current)), flatTarget = try raster(capture(target))
                        let renderer = try paper(current: current, target: target, axis: axis, spread: spread,
                            sign: sign, direction: direction, order: order)
                        defer { renderer.invalidateResources() }
                        XCTAssertTrue(renderer.usesMetalCornerRendering)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: spread,
                            inwardSign: sign, origin: source, effect: .arch))
                        let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 64, 264, axis: axis), direction: direction))
                        let endpoints: [(String, PaperCornerDrag, Raster)] = [
                            ("initial", seed, flatCurrent),
                            ("cancel", live.released(completed: false, fraction: 1, direction: direction), flatCurrent),
                            ("nearCancel", live.released(completed: false, fraction: 0.99999, direction: direction), flatCurrent),
                            ("nearComplete", live.released(completed: true, fraction: 0.99999, direction: direction), flatTarget),
                            ("complete", live.released(completed: true, fraction: 1, direction: direction), flatTarget)
                        ]
                        for (name, pose, expected) in endpoints {
                            assertFinite(surface(pose, direction: direction, order: order), "\(name) endpoint mesh")
                            renderer.update(progress: pose.progress, cornerDrag: pose)
                            let actual = try raster(XCTUnwrap(renderer.cornerGPUImage(scale: 1)))
                            let context = "\(axis)/spread=\(spread)/\(order)/\(direction)/\(name)"
                            XCTAssertEqual(actual.width, expected.width, context); XCTAssertEqual(actual.height, expected.height, context)
                            XCTAssertLessThan(actual.changedFraction(from: expected), 0.005,
                                              "\(context): output must be the complete, upright current/target page, including both spread halves")
                        }
                    }
                }
            }
        }
        #else
        throw XCTSkip("MetalKit is unavailable")
        #endif
    }

    func testTransverseMaterialWidthDoesNotPinchAroundContact() throws {
        var maximumScale: CGFloat = 0, maximumAngle: CGFloat = 0, checked = 0
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let coordinate: CGFloat = spread ? (sign < 0 ? 350 : 40) : (sign < 0 ? 320 : 70)
                    for height: CGFloat in [100, 422, 744] {
                        let source = point(coordinate, height, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: source, effect: .arch))
                        let live = try XCTUnwrap(seed.moved(to: point(coordinate + sign * 80, height + 35, axis: axis)))
                        for fraction: CGFloat in [0, 0.2, 0.6, 1] {
                            let pose = live.released(completed: true, fraction: fraction)
                            let mesh = surface(pose, direction: .next), metric = try physicalMetric(mesh)
                            XCTAssertGreaterThan(metric.count, 10)
                            maximumScale = max(maximumScale, metric.scale)
                            maximumAngle = max(maximumAngle, metric.angle); checked += metric.count
                            XCTAssertEqual(metric.area, pose.page.width * pose.page.height,
                                accuracy: pose.page.width * pose.page.height * 1e-7, "The isometric mesh must cover the complete source sheet")
                            XCTAssertLessThanOrEqual(mesh.patches.count * 3 + mesh.shadow.count, 32_768)
                        }
                    }
                }
            }
        }
        print("ARCH_MATERIAL_MATRIX scaleError=\(maximumScale) angleError=\(maximumAngle) triangles=\(checked)")
        XCTAssertGreaterThan(checked, 8_000)
        XCTAssertLessThanOrEqual(maximumScale, 0.005, "Every rendered triangle must retain both material dimensions")
        XCTAssertLessThanOrEqual(maximumAngle, 0.005, "Material right angles cannot be sheared to fake diagonal tracking")
    }

    func testPreviousReturningSheetPreservesMaterialMetricAndOriginalBindingMatrix() throws {
        var checked = 0
        for axis in axes {
            let size = canvas(axis)
            let extent = axis == .horizontal ? size.width : size.height
            let breadth = axis == .horizontal ? size.height : size.width
            for spread in [false, true] {
                let length = spread ? extent / 2 : extent
                for sign: CGFloat in [-1, 1] {
                    // 独立物理参考：单页仍绑在原书脊，双页的上一张材料在交互半页的对侧。
                    let bookHinge = spread ? extent / 2 : (sign > 0 ? 0 : extent)
                    let materialMinimum = spread && sign > 0 ? extent / 2 : 0
                    let expectedPage = axis == .horizontal
                        ? CGRect(x: materialMinimum, y: 0, width: length, height: breadth)
                        : CGRect(x: 0, y: materialMinimum, width: breadth, height: length)
                    let source = origin(axis: axis, spread: spread, sign: sign)
                    let materialContact = point(bookHinge + sign * length, cross(source, axis: axis), axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                        inwardSign: sign, origin: source, effect: .arch))
                    let folded = surface(seed, direction: .previous)
                    XCTAssertFalse(folded.patches.isEmpty)
                    for sample in folded.samples {
                        let expected = point(2 * bookHinge - primary(sample.source, axis: axis), cross(sample.source, axis: axis), axis: axis)
                        assertPoint(sample.point, equals: expected, "previous sheet starts folded around the original binding")
                        assertPoint(sample.worldPoint, equals: expected, "initial previous material reflection")
                        XCTAssertEqual(sample.height, 0, accuracy: epsilon)
                    }
                    for across: CGFloat in [-35, 35] {
                        for pull: CGFloat in [48, 80] {
                            let requested = point(primary(source, axis: axis) + sign * pull, cross(source, axis: axis) + across, axis: axis)
                            let live = try XCTUnwrap(seed.moved(to: requested, direction: .previous))
                            assertPoint(live.origin, equals: source, "previous logical origin must stay unchanged")
                            assertPoint(live.gripOrigin, equals: source, "previous logical grip origin must stay unchanged")
                            for completed in [false, true] {
                                for fraction: CGFloat in [0, 0.00001, 0.2, 0.6, 0.99999, 1] {
                                    let pose = live.released(completed: completed, fraction: fraction, direction: .previous)
                                    let mesh = surface(pose, direction: .previous)
                                    let context = "previous/\(axis)/spread=\(spread)/sign=\(sign)/pull=\(pull),\(across)/completed=\(completed)/f=\(fraction)"
                                    assertFinite(mesh, context)
                                    XCTAssertEqual(mesh.materialPage, expectedPage, context)
                                    assertPoint(mesh.materialContact, equals: materialContact, context)
                                    let metric = try physicalMetric(mesh)
                                    XCTAssertGreaterThan(metric.count, 10, context)
                                    XCTAssertLessThanOrEqual(metric.scale, 0.005, "\(context): BOTH triangle singular values must stay at unit scale")
                                    XCTAssertLessThanOrEqual(metric.angle, 0.005, "\(context): material right angles must survive returning and release")
                                    XCTAssertEqual(metric.area, length * breadth, accuracy: length * breadth * 1e-7,
                                        "\(context): triangles must cover exactly the complete previous source sheet")
                                    let vertexCount = mesh.patches.reduce(0) { $0 + $1.source.count } + mesh.shadow.count + 12
                                    XCTAssertLessThanOrEqual(vertexCount, 32_768, context)
                                    checked += metric.count
                                    for sample in mesh.samples {
                                        XCTAssertGreaterThanOrEqual(sample.source.x, expectedPage.minX - epsilon, context)
                                        XCTAssertLessThanOrEqual(sample.source.x, expectedPage.maxX + epsilon, context)
                                        XCTAssertGreaterThanOrEqual(sample.source.y, expectedPage.minY - epsilon, context)
                                        XCTAssertLessThanOrEqual(sample.source.y, expectedPage.maxY + epsilon, context)
                                        XCTAssertGreaterThanOrEqual(sample.height, 0, context)
                                    }
                                    let binding = mesh.samples.filter { abs(primary($0.source, axis: axis) - bookHinge) <= 1e-8 }
                                    XCTAssertGreaterThanOrEqual(binding.count, 3, "\(context): original binding must exist in the rendered material")
                                    for sample in binding {
                                        assertPoint(sample.point, equals: sample.source, context)
                                        assertPoint(sample.worldPoint, equals: sample.source, context)
                                        XCTAssertEqual(sample.height, 0, accuracy: epsilon, context)
                                    }
                                    for patch in mesh.patches {
                                        for vertex in patch.source where abs(primary(vertex, axis: axis) - bookHinge) <= 1e-8 {
                                            assertPoint(vertex.applying(patch.transform), equals: vertex,
                                                "\(context): rendered triangles must preserve the same original binding")
                                        }
                                    }
                                    if fraction == 0 {
                                        let held = try contact(mesh, origin: source, touch: live.gripPosition, context: context)
                                        assertPoint(held.source, equals: materialContact, context)
                                        assertPoint(held.worldPoint, equals: live.gripPosition, context)
                                        for end: CGFloat in [0, breadth] {
                                            let fixed = point(bookHinge, end, axis: axis)
                                            XCTAssertLessThanOrEqual(hypot(held.worldPoint.x - fixed.x, held.worldPoint.y - fixed.y),
                                                hypot(materialContact.x - fixed.x, materialContact.y - fixed.y) + epsilon, context)
                                        }
                                    }
                                    if fraction >= 0.99999 {
                                        for sample in mesh.samples {
                                            let expected = completed ? sample.source
                                                : point(2 * bookHinge - primary(sample.source, axis: axis), cross(sample.source, axis: axis), axis: axis)
                                            if fraction == 1 {
                                                assertPoint(sample.point, equals: expected, context)
                                                assertPoint(sample.worldPoint, equals: expected, context)
                                                XCTAssertEqual(sample.height, 0, accuracy: epsilon, context)
                                            } else {
                                                let dx = sample.worldPoint.x - expected.x, dy = sample.worldPoint.y - expected.y
                                                XCTAssertLessThanOrEqual(sqrt(dx * dx + dy * dy + sample.height * sample.height), 0.01,
                                                    "\(context): near endpoint must approach identity on completion or binding reflection on cancel")
                                                XCTAssertLessThanOrEqual(hypot(sample.point.x - expected.x, sample.point.y - expected.y), 0.01, context)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 8_000, "The previous matrix must check actual rendered triangle Jacobians")
    }

    func testReferenceVideoPinsOriginalMaterialSpine() throws {
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            let source = point(320, 422, axis: axis)
            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                inwardSign: -1, origin: source, effect: .arch))
            let drag = try XCTUnwrap(seed.moved(to: point(320 - 390 * 0.32, 447, axis: axis)))
            let mesh = surface(drag, direction: .next)
            let originalSpine = mesh.samples.filter { abs(primary($0.source, axis: axis)) < epsilon }
            XCTAssertGreaterThanOrEqual(originalSpine.count, 3)
            let drift = originalSpine.map { hypot($0.point.x - $0.source.x, $0.point.y - $0.source.y) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(drift, epsilon,
                "Reference IMG_6185.MOV: the SAME bound paper edge must stay fixed; material cannot slide across it")
        }
    }

    func testFullRadiusDiagonalDoesNotCollapsePaperOntoSpine() throws {
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let hinge: CGFloat = sign < 0 ? 0 : 320
                    let source = point(hinge - sign * 240, crossSign < 0 ? 360 : 120, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                        inwardSign: sign, origin: source, effect: .arch))
                    let requested = point(hinge, cross(source, axis: axis) + crossSign * 240, axis: axis)
                    let drag = try XCTUnwrap(seed.moved(to: requested))
                    XCTAssertEqual(primary(drag.gripPosition, axis: axis), hinge, accuracy: epsilon)
                    let reachableCross: CGFloat = sqrt(120 * 120 + 238 * 238) - 120
                    XCTAssertEqual(cross(drag.translation, axis: axis), crossSign * reachableCross, accuracy: epsilon,
                        "The bend reserve and BOTH fixed binding endpoints constrain the diagonal reach")
                    let mesh = surface(drag, direction: .next, strips: 128)
                    assertPinnedSpine(mesh, drag: drag, context: "full-radius diagonal")
                    _ = try contact(mesh, origin: source, touch: drag.gripPosition, context: "full-radius diagonal")
                    let bySource = Dictionary(uniqueKeysWithValues: mesh.samples.map { (SourceKey($0.source), $0) })
                    var total: CGFloat = 0, collapsed: CGFloat = 0, minimumRatio = CGFloat.infinity
                    for patch in mesh.patches {
                        let a = try XCTUnwrap(bySource[SourceKey(patch.source[0])])
                        let b = try XCTUnwrap(bySource[SourceKey(patch.source[1])])
                        let c = try XCTUnwrap(bySource[SourceKey(patch.source[2])])
                        let ux = b.worldPoint.x - a.worldPoint.x, uy = b.worldPoint.y - a.worldPoint.y, uz = b.height - a.height
                        let vx = c.worldPoint.x - a.worldPoint.x, vy = c.worldPoint.y - a.worldPoint.y, vz = c.height - a.height
                        let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
                        let sourceArea = abs((b.source.x - a.source.x) * (c.source.y - a.source.y)
                            - (b.source.y - a.source.y) * (c.source.x - a.source.x))
                        let ratio = sqrt(nx * nx + ny * ny + nz * nz) / sourceArea
                        XCTAssertTrue(ratio.isFinite)
                        total += sourceArea
                        minimumRatio = min(minimumRatio, ratio)
                        if ratio < 0.00001 { collapsed += sourceArea }
                    }
                    XCTAssertGreaterThan(total, 0)
                    XCTAssertEqual(collapsed / total, 0, accuracy: 1e-8,
                        "Bound spine and exact contact alone cannot excuse a sheet collapsed into a line")
                    XCTAssertGreaterThan(minimumRatio, 0.00001)
                }
            }
        }
    }
    func testContactBendTangentSettlesSmoothlyIntoFlatPad() throws {
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                let source = origin(axis: axis, spread: false, sign: sign)
                let hinge = spine(axis: axis, spread: false, sign: sign)
                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                for pull: CGFloat in [80, 140] {
                    let drag = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * pull, 240, axis: axis)))
                    let mesh = surface(drag, direction: .next, strips: 256)
                    let row = fiber(mesh, through: source, axis: axis).sorted {
                        (primary($0.source, axis: axis) - hinge) * -sign < (primary($1.source, axis: axis) - hinge) * -sign
                    }
                    let lastBent = try XCTUnwrap(row.lastIndex { $0.height > epsilon })
                    XCTAssertLessThan(lastBent + 1, row.count)
                    let a = row[lastBent], b = row[lastBent + 1]
                    let tangent = atan2(abs(b.height - a.height), hypot(b.worldPoint.x - a.worldPoint.x, b.worldPoint.y - a.worldPoint.y))
                    XCTAssertLessThan(tangent, 0.2, "Bending must settle into the finger pad without a sharp tangent change")
                }
            }
        }
    }

    func testDiagonalArchRotatesBendingAxisInsteadOfTranslatingWholeSheet() throws {
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for sign: CGFloat in [-1, 1] {
                let hinge: CGFloat = sign < 0 ? 0 : 390
                let source = point(hinge - sign * 320, 422, axis: axis)
                let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                for across: CGFloat in [-40, 40] {
                    let drag = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 140,
                        422 + across, axis: axis)))
                    let mesh = surface(drag, direction: .next, strips: 128)
                    assertPinnedSpine(mesh, drag: drag, context: "oblique bending axis")
                    _ = try contact(mesh, origin: source, touch: drag.gripPosition, context: "oblique contact")
                    let rows = Dictionary(grouping: mesh.samples, by: { cross($0.source, axis: axis) })
                    let completeRows = rows.values.filter { row in
                        let coordinates = row.map { primary($0.source, axis: axis) }
                        return (coordinates.max() ?? 0) - (coordinates.min() ?? 0) > 389
                    }
                    let peaks = completeRows.compactMap { $0.max { $0.height < $1.height } }.filter { $0.height > 1 }
                    XCTAssertGreaterThanOrEqual(peaks.count, 4)
                    let meanX = peaks.reduce(CGFloat.zero) { $0 + primary($1.worldPoint, axis: axis) * -sign } / CGFloat(peaks.count)
                    let meanY = peaks.reduce(CGFloat.zero) { $0 + cross($1.worldPoint, axis: axis) } / CGFloat(peaks.count)
                    let numerator = peaks.reduce(CGFloat.zero) { sum, sample in
                        sum + (primary(sample.worldPoint, axis: axis) * -sign - meanX)
                            * (cross(sample.worldPoint, axis: axis) - meanY)
                    }
                    let denominator = peaks.reduce(CGFloat.zero) { sum, sample in
                        let dy = cross(sample.worldPoint, axis: axis) - meanY
                        return sum + dy * dy
                    }
                    let slope = numerator / denominator
                    XCTAssertGreaterThan(slope * (across < 0 ? -1 : 1), 0.01,
                        "The physical arch ridge must tilt with cross-axis drag, not stay vertical while the sheet slides")
                }
            }
        }
    }
    func testObliqueBendingStaysContinuousAfterCrossingSpine() throws {
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let hinge: CGFloat = sign < 0 ? 0 : 320
                    let height: CGFloat = crossSign > 0 ? 1 : 479
                    let source = point(hinge - sign * 240, height, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: canvas(axis), axis: axis, spread: false,
                        inwardSign: sign, origin: source, effect: .arch))
                    for pair: (CGFloat, CGFloat, CGFloat, CGFloat) in [(300, 15.076, 300, 15.078), (239.999, 15, 240.001, 15)] {
                        let a = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * pair.0,
                            height + crossSign * pair.1, axis: axis)))
                        let b = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * pair.2,
                            height + crossSign * pair.3, axis: axis)))
                        let first = surface(a, direction: .next), second = surface(b, direction: .next)
                        let lookup = Dictionary(uniqueKeysWithValues: first.samples.map { (SourceKey($0.source), $0) })
                        var maximum: CGFloat = 0, shared = 0
                        for sample in second.samples {
                            guard let before = lookup[SourceKey(sample.source)] else { continue }
                            let dx = sample.worldPoint.x - before.worldPoint.x, dy = sample.worldPoint.y - before.worldPoint.y
                            let dz = sample.height - before.height
                            maximum = max(maximum, sqrt(dx * dx + dy * dy + dz * dz)); shared += 1
                        }
                        XCTAssertGreaterThan(shared, 100)
                        XCTAssertLessThan(maximum, 0.2, "A 0.002pt diagonal change across the spine must not switch the entire bending frame")
                    }
                }
            }
        }
    }

    func testFlatRegionsRemainRigidInsteadOfRipplingLikeCloth() throws {
        var worst: CGFloat = 0
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for sign: CGFloat in [-1, 1] {
                let hinge: CGFloat = sign < 0 ? 0 : 390
                let source = point(hinge - sign * 320, 422, axis: axis)
                let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                for pull: CGFloat in [80, 140, 180] {
                    for across: CGFloat in [-40, 40] {
                        let drag = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * pull,
                            422 + across, axis: axis)))
                        let mesh = surface(drag, direction: .next, strips: 128)
                        let flat = mesh.samples.filter { $0.height == 0 }
                        XCTAssertGreaterThan(flat.count, 8)
                        let heights = Dictionary(uniqueKeysWithValues: mesh.samples.map { (SourceKey($0.source), $0.height) })
                        let flatPatches = mesh.patches.filter { patch in patch.source.allSatisfy { heights[SourceKey($0)] == 0 } }
                        let metric = try physicalMetric(mesh, patches: flatPatches)
                        XCTAssertGreaterThan(metric.count, 4)
                        worst = max(worst, max(metric.scale, metric.angle))
                        XCTAssertLessThanOrEqual(metric.scale, epsilon, "A flat paper region may rotate rigidly but cannot stretch")
                        XCTAssertLessThanOrEqual(metric.angle, epsilon, "Flat text cannot inherit cloth-like shear")
                    }
                }
            }
        }
        print("ARCH_RIGID_FLAT_METRICS maximumMetricError=\(worst)")
    }

    func testRenderedPaperPreservesBothMaterialScalesAndRightAngles() throws {
        var scaleError: CGFloat = 0, angleError: CGFloat = 0, checked = 0
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for sign: CGFloat in [-1, 1] {
                let source = point(sign < 0 ? 320 : 70, 422, axis: axis)
                let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: sign, origin: source, effect: .arch))
                for pull: (CGFloat, CGFloat) in [(78, 40), (140, -40), (180, 0)] {
                    let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * pull.0,
                        422 + pull.1, axis: axis)))
                    for fraction: CGFloat in [0, 0.35, 0.7] {
                        let mesh = surface(live.released(completed: true, fraction: fraction), direction: .next)
                        let samples = Dictionary(uniqueKeysWithValues: mesh.samples.map { (SourceKey($0.source), $0) })
                        for patch in mesh.patches {
                            let a = try XCTUnwrap(samples[SourceKey(patch.source[0])])
                            let b = try XCTUnwrap(samples[SourceKey(patch.source[1])])
                            let c = try XCTUnwrap(samples[SourceKey(patch.source[2])])
                            let ux = b.source.x - a.source.x, uy = b.source.y - a.source.y
                            let vx = c.source.x - a.source.x, vy = c.source.y - a.source.y
                            let det = ux * vy - uy * vx
                            guard abs(det) > 1e-5 else { continue }
                            let dx = [b.worldPoint.x - a.worldPoint.x, b.worldPoint.y - a.worldPoint.y, b.height - a.height]
                            let dy = [c.worldPoint.x - a.worldPoint.x, c.worldPoint.y - a.worldPoint.y, c.height - a.height]
                            var e: CGFloat = 0, f: CGFloat = 0, g: CGFloat = 0
                            for k in 0..<3 {
                                let x = (dx[k] * vy - dy[k] * uy) / det
                                let y = (dy[k] * ux - dx[k] * vx) / det
                                e += x * x; f += x * y; g += y * y
                            }
                            let radius = hypot(e - g, 2 * f)
                            let small = sqrt(max(0, (e + g - radius) / 2)), large = sqrt(max(0, (e + g + radius) / 2))
                            scaleError = max(scaleError, max(abs(small - 1), abs(large - 1)))
                            angleError = max(angleError, abs(acos(min(1, max(-1, f / sqrt(e * g)))) - .pi / 2))
                            checked += 1
                        }
                    }
                }
            }
        }
        print("ARCH_PHYSICAL_METRIC scaleError=\(scaleError) angleError=\(angleError) triangles=\(checked)")
        XCTAssertGreaterThan(checked, 10_000)
        XCTAssertLessThanOrEqual(scaleError, 0.005, "Both material singular values must stay at unit scale in 3D")
        XCTAssertLessThanOrEqual(angleError, 0.005, "Paper cannot shear its material right angles into skewed text")
    }

    func testGripReachRespectsBothFixedSpineEndpoints() throws {
        var excess: CGFloat = 0
        for axis in axes {
            for sign: CGFloat in [-1, 1] {
                let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
                for spread in [false, true] {
                    let hinge: CGFloat = spread ? 195 : (sign < 0 ? 0 : 390)
                    let source = point(hinge - sign * (spread ? 155 : 320), 744, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                        inwardSign: sign, origin: source, effect: .arch))
                    let live = try XCTUnwrap(seed.moved(to: point(primary(source, axis: axis) + sign * 80, 779, axis: axis)))
                    for end: CGFloat in [0, 844] {
                        let fixed = point(hinge, end, axis: axis)
                        let materialDistance = hypot(source.x - fixed.x, source.y - fixed.y)
                        let contactDistance = hypot(live.gripPosition.x - fixed.x, live.gripPosition.y - fixed.y)
                        excess = max(excess, contactDistance - materialDistance)
                    }
                }
            }
        }
        print("ARCH_SPINE_REACH excess=\(excess)")
        XCTAssertLessThanOrEqual(excess, epsilon, "A fixed binding constrains distance to EVERY bound material point, not just the point beside the finger")
    }

    func testAheadOfDisplayAngleIntentKeepsPhysicalArchRelease() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 240, y: 240), effect: .arch))
        let displayed = try XCTUnwrap(seed.moved(to: CGPoint(x: 160, y: 240)))
        let intent = try XCTUnwrap(seed.moved(to: CGPoint(x: 100, y: 300)))
        for fraction: CGFloat in [0, 0.00001, 0.2, 0.5, 0.9, 1] {
            let base = displayed.released(completed: true, fraction: fraction)
            let actual = displayed.released(completed: true, fraction: fraction, direction: .next, angleIntent: intent)
            XCTAssertEqual(actual, base, "Curl angle compensation cannot clear the developable arch release trajectory")
            let mesh = surface(actual, direction: .next)
            XCTAssertFalse(mesh.patches.isEmpty)
            if fraction == 0.5 { XCTAssertGreaterThan(mesh.samples.map(\.height).max() ?? 0, 100) }
        }
    }

    func testNearFlatLargeCanvasKeepsCompleteIsometricSourceCoverage() throws {
        let extent: CGFloat = 8_388_608
        let origin = CGPoint(x: extent, y: 0.01)
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: extent, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: origin, effect: .arch))
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: extent - CGFloat(pow(2.0, -29)), y: 0.176)))
        let mesh = surface(drag, direction: .next)
        let metric = try physicalMetric(mesh)
        assertPinnedSpine(mesh, drag: drag, context: "large canvas / tiny drag")
        XCTAssertEqual(metric.area, extent * 480, accuracy: extent * 480 * 1e-8,
            "Cancellation in the cone apex formula must not discard a strip of source paper")
        XCTAssertLessThanOrEqual(metric.scale, 0.005)
        XCTAssertLessThanOrEqual(metric.angle, 0.005)
    }
}
#endif
