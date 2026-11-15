#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

/// 只检查材料守恒、触点约束和几何对称性，可在 macOS 上执行。
final class CornerCurlGeometryTests: XCTestCase {
    /// 无参数；横纵、正反材料和单双页均按完整画布中线判断，不误用纸张半页或按下点。无返回值。
    func testGripMidpointUsesCanvasCoordinatesInBothDirections() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for direction in [PageTurnDirection.next, .previous] {
                        let origin = point(sign < 0 ? 192 : 128, 240, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: origin))
                        for offset: CGFloat in [-1, 0, 1] {
                            let target = point(160 + sign * offset, 240, axis: axis)
                            let live = try XCTUnwrap(seed.moved(to: target, direction: direction))
                            assertPoint(live.gripPosition, target)
                            XCTAssertEqual(live.hasReachedCanvasMidpoint, offset >= 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 几何断言

    /// - Parameters: a: 第一个点；b: 第二个点。
    /// - Returns: 两点间的欧氏距离。
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// - Parameter polygon: 按边界顺序排列的材料顶点。
    /// - Returns: 鞋带公式计算的无符号面积，与切片实现无关。
    private func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        return abs(polygon.indices.reduce(CGFloat.zero) { sum, index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }

    /// - Parameters: actual: 实际点；expected: 期望点；accuracy: 误差；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值。
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }

    /// - Parameters: actual: 实际多边形；expected: 等价顶点集合；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；不要求镜像后的顶点绕序相同。
    private func assertVertices(_ actual: [CGPoint], _ expected: [CGPoint],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for point in expected {
            XCTAssertTrue(actual.contains { distance($0, point) < 1e-6 },
                          "缺少材料或投影顶点 \(point)", file: file, line: line)
        }
    }

    /// - Parameters: patches: 被测纸面；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；验证全部几何、阴影和变换分量均有限。
    private func assertFinite(_ patches: [PaperCornerPatch],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(patches.isEmpty, file: file, line: line)
        for patch in patches {
            let t = patch.transform
            let values = [t.a, t.b, t.c, t.d, t.tx, t.ty, patch.depth, patch.shade]
                + (patch.source + patch.projected).flatMap { [$0.x, $0.y] }
            XCTAssertTrue(values.allSatisfy { $0.isFinite }, file: file, line: line)
            XCTAssertGreaterThanOrEqual(patch.depth, 0, file: file, line: line)
            XCTAssertTrue((0...1).contains(patch.shade), file: file, line: line)
            XCTAssertGreaterThanOrEqual(patch.source.count, 3, file: file, line: line)
        }
    }

    /// - Parameters: drag: 抓取状态；patches: 材料切片；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；从包含真实纸角的材料面验证触点投影。
    private func assertTip(_ drag: PaperCornerDrag, patches: [PaperCornerPatch],
                           file: StaticString = #filePath, line: UInt = #line) {
        let tolerance = max(1e-6, max(drag.page.width, drag.page.height) * 1e-9)
        let containing = patches.filter { patch in
            patch.source.contains { distance($0, drag.corner) <= tolerance }
        }
        XCTAssertFalse(containing.isEmpty, "纸角材料不得遗漏", file: file, line: line)
        for patch in containing {
            assertPoint(drag.corner.applying(patch.transform), drag.tip,
                        accuracy: tolerance, file: file, line: line)
        }
    }

    /// - Parameters: a: 边起点；b: 边终点；rect: 原纸页范围。
    /// - Returns: 是否为原始纸页的外边，而非两块材料之间的接缝。
    private func isOuterEdge(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        let epsilon: CGFloat = 1e-6
        return [rect.minX, rect.maxX].contains { abs(a.x - $0) < epsilon && abs(b.x - $0) < epsilon }
            || [rect.minY, rect.maxY].contains { abs(a.y - $0) < epsilon && abs(b.y - $0) < epsilon }
    }

    /// - Parameters: patches: 切片；rect: 原纸页范围。
    /// - Returns: 无返回值；每条非外边必须由另一片共享，且投影后的整条边连续。
    private func assertSharedEdges(_ patches: [PaperCornerPatch], rect: CGRect) {
        var seams = 0
        for (index, patch) in patches.enumerated() {
            for vertex in patch.source.indices {
                let a = patch.source[vertex]
                let b = patch.source[(vertex + 1) % patch.source.count]
                guard distance(a, b) > 1e-6, !isOuterEdge(a, b, rect: rect) else { continue }
                let neighbors = patches.enumerated().filter { otherIndex, other in
                    otherIndex != index
                        && other.source.contains { distance($0, a) < 1e-6 }
                        && other.source.contains { distance($0, b) < 1e-6 }
                }
                XCTAssertEqual(neighbors.count, 1, "材料内边应且只应由另一片共享")
                for (_, neighbor) in neighbors {
                    for point in [a, b, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)] {
                        assertPoint(point.applying(patch.transform), point.applying(neighbor.transform))
                    }
                }
                seams += 1
            }
        }
        XCTAssertGreaterThan(seams, 0, "中间帧应包含实际卷曲接缝")
    }

    /// - Parameters: primary: 轴向坐标；cross: 横跨轴坐标；axis: 翻页轴。
    /// - Returns: 画布内的实际点。
    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    /// 无参数；可达范围内纸面跟手点直接对齐输入坐标，不叠加按下位置到页边的固定偏移。无返回值。
    func testPaperContactMatchesAbsoluteFingerCoordinates() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for spread in [false, true] {
                let length: CGFloat = spread ? 160 : 320
                for sign: CGFloat in [-1, 1] {
                    let minimum: CGFloat = spread && sign < 0 ? 160 : 0
                    let edge = sign < 0 ? minimum + length : minimum
                    for fraction: CGFloat in [0.1, 0.5, 0.9] {
                        let origin = point(minimum + length * 0.55, 480 * fraction, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread, inwardSign: sign, origin: origin))
                        for pull: CGFloat in [0.25, 0.5, 0.8] {
                            for cross: CGFloat in [-0.02, 0, 0.02] {
                                let touch = point(edge + sign * length * pull, 480 * fraction + length * cross, axis: axis)
                                let live = try XCTUnwrap(seed.moved(to: touch))
                                assertPoint(live.gripPosition, touch)
                                let patches = PaperCornerCurlGeometry.patches(for: live, stripCount: 64)
                                assertFinite(patches); assertTip(live, patches: patches)
                                let back = try XCTUnwrap(patches.last { $0.back })
                                assertPoint(live.gripOrigin.applying(back.transform), touch)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 无参数；大斜拖的自由页边必须经过真实圆弧，不能在可达边界退化成直线。无返回值。
    func testLargeDiagonalDragKeepsRolledOuterEdge() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for crossSign: CGFloat in [-1, 1] {
                        for middle in [false, true] {
                            let origin = point(195, middle ? 422 : (crossSign > 0 ? 0 : 844), axis: axis)
                            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                                inwardSign: sign, origin: origin))
                            let edge = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                            let cross = axis == .horizontal ? seed.gripOrigin.y : seed.gripOrigin.x
                            for pull: CGFloat in [0.35, 0.7, 0.9] {
                                let drag = try XCTUnwrap(seed.moved(to: point(edge + sign * seed.length * pull,
                                    cross + crossSign * 1_000_000, axis: axis)))
                                let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
                                let maximumDepth = try XCTUnwrap(patches.map(\.depth).max())
                                XCTAssertGreaterThan(maximumDepth, seed.length * 0.02,
                                    "交互斜拖必须保留实际卷曲高度，不能只用阴影掩盖平折")
                                var outerEdges = [[(source: CGFloat, projected: CGPoint)]](repeating: [], count: 4)
                                for patch in patches where patch.depth > 1e-7 && patch.depth < maximumDepth - 1e-7 {
                                    for source in patch.source {
                                        let boundaries = [abs(source.x - seed.page.minX), abs(source.x - seed.page.maxX),
                                            abs(source.y - seed.page.minY), abs(source.y - seed.page.maxY)]
                                        for edgeIndex in 0..<4 where boundaries[edgeIndex] < 1e-6 {
                                            let position = edgeIndex < 2 ? source.y : source.x
                                            if !outerEdges[edgeIndex].contains(where: { abs($0.source - position) < 1e-6 }) {
                                                outerEdges[edgeIndex].append((position, source.applying(patch.transform)))
                                            }
                                        }
                                    }
                                }
                                var maximumSag: CGFloat = 0, curvedEdgeCount = 0
                                for var samples in outerEdges {
                                    samples.sort { $0.source < $1.source }
                                    guard let first = samples.first?.projected, let last = samples.last?.projected else { continue }
                                    let chord = distance(first, last)
                                    let chordX = last.x - first.x, chordY = last.y - first.y
                                    var sag: CGFloat = 0
                                    for sample in samples {
                                        let offsetX = sample.projected.x - first.x
                                        let offsetY = sample.projected.y - first.y
                                        let crossProduct = chordX * offsetY - chordY * offsetX
                                        sag = max(sag, abs(crossProduct) / max(1e-7, chord))
                                    }
                                    if sag > maximumSag { maximumSag = sag; curvedEdgeCount = samples.count }
                                }
                                XCTAssertGreaterThan(curvedEdgeCount, 12, "外轮廓须包含完整圆弧，折痕允许由侧边连续移到底边")
                                XCTAssertGreaterThan(maximumSag, seed.length * 0.002, "纸边必须实际偏离直线，而非仅增加细分数")
                                if middle, !spread, pull == 0.7 {
                                    let freeEdge = axis == .horizontal ? (sign < 0 ? 1 : 0) : (sign < 0 ? 3 : 2)
                                    XCTAssertGreaterThan(outerEdges[freeEdge].count, 12, "参考图对应的自由侧边必须实际卷曲")
                                }
                                assertFinite(patches); assertTip(drag, patches: patches)
                                XCTAssertEqual(patches.reduce(CGFloat.zero) { $0 + area($1.source) },
                                    seed.page.width * seed.page.height, accuracy: 1e-4)
                                let back = try XCTUnwrap(patches.last { $0.back })
                                assertPoint(drag.gripOrigin.applying(back.transform), drag.gripPosition)
                                let hinge = sign < 0 ? edge - seed.length : edge + seed.length
                                for anchor in [point(hinge, 0, axis: axis), point(hinge, 844, axis: axis)] {
                                    let owners = patches.filter { $0.source.contains { distance($0, anchor) < 1e-6 } }
                                    XCTAssertFalse(owners.isEmpty)
                                    for owner in owners { assertPoint(anchor.applying(owner.transform), anchor) }
                                }
                                if pull == 0.7 { assertSharedEdges(patches, rect: seed.page) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 无参数；接近新的带弧可达界线及两种收尾时，控制点和卷曲高度连续变化。无返回值。
    func testRolledReachRemainsContinuousThroughClampAndRelease() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: sign, origin: point(195, 422, axis: axis)))
                    let edge = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                    let boundary = try XCTUnwrap(seed.moved(to: point(edge + sign * 273,
                        422 + crossSign * 1_000_000, axis: axis)))
                    let boundaryCross = axis == .horizontal ? boundary.translation.y : boundary.translation.x
                    var previous: (drag: PaperCornerDrag, depth: CGFloat)?
                    for scale: CGFloat in [0.99998, 0.99999, 1, 1.00001, 1.00002] {
                        let drag = try XCTUnwrap(seed.moved(to: point(edge + sign * 273,
                            422 + boundaryCross * scale, axis: axis)))
                        XCTAssertEqual(try XCTUnwrap(drag.moved(to: drag.gripPosition)), drag,
                            "已约束的位置再次输入不能逐帧漂移")
                        let depth = try XCTUnwrap(PaperCornerCurlGeometry.patches(for: drag, stripCount: 128).map(\.depth).max())
                        XCTAssertGreaterThan(depth, 10)
                        if let previous {
                            XCTAssertLessThan(distance(previous.drag.gripPosition, drag.gripPosition), 0.01)
                            XCTAssertLessThan(abs(previous.depth - depth), 0.01)
                        }
                        previous = (drag, depth)
                    }
                    for completed in [false, true] {
                        XCTAssertEqual(boundary.released(completed: completed, fraction: 0), boundary)
                        var previous = boundary
                        for step in 1...100 {
                            let frame = boundary.released(completed: completed, fraction: CGFloat(step) / 100)
                            let patches = PaperCornerCurlGeometry.patches(for: frame, stripCount: 64)
                            assertFinite(patches); assertTip(frame, patches: patches)
                            XCTAssertLessThan(distance(previous.gripPosition, frame.gripPosition), 10)
                            let depth = try XCTUnwrap(patches.map(\.depth).max())
                            if step < 100 { XCTAssertGreaterThan(depth, 1e-6) }
                            else { XCTAssertEqual(depth, 0, accuracy: 1e-7) }
                            previous = frame
                        }
                    }
                }
            }
        }
    }

    // MARK: - 对称性及二维变化

    /// 无参数；中段抓取在同一主轴距离下应随正反横轴位移改变折向，书脊和材料保持完整。无返回值。
    func testMiddleStartsFollowCrossAxisOnBothAxes() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for crossFraction: CGFloat in [0.35, 0.5, 0.65] {
                        let primary: CGFloat = spread ? (sign < 0 ? 240 : 80) : 160
                        let cross = 480 * crossFraction
                        let origin = point(primary, cross, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread, inwardSign: sign, origin: origin))
                        let displacement = seed.length * 0.6
                        let gripPrimary = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                        let crossDisplacement = seed.length * 0.1
                        let straight = try XCTUnwrap(seed.moved(to: point(gripPrimary + sign * displacement, cross, axis: axis)))
                        let down = try XCTUnwrap(straight.moved(to: point(gripPrimary + sign * displacement, cross + crossDisplacement, axis: axis)))
                        let up = try XCTUnwrap(down.moved(to: point(gripPrimary + sign * displacement, cross - crossDisplacement, axis: axis)))
                        let again = try XCTUnwrap(up.moved(to: point(gripPrimary + sign * displacement, cross + crossDisplacement, axis: axis)))
                        XCTAssertEqual(again, down, "中途换向仍以最初按下点计算，不能累积偏移")
                        assertPoint(straight.translation, point(sign * displacement, 0, axis: axis))
                        assertPoint(down.translation, point(sign * displacement, crossDisplacement, axis: axis))
                        assertPoint(up.translation, point(sign * displacement, -crossDisplacement, axis: axis))
                        let hinge = sign < 0 ? (axis == .horizontal ? seed.page.minX : seed.page.minY)
                            : (axis == .horizontal ? seed.page.maxX : seed.page.maxY)
                        let anchors = [point(hinge, 0, axis: axis), point(hinge, 480, axis: axis)]
                        for drag in [down, up] {
                            XCTAssertEqual(drag.origin, origin)
                            XCTAssertEqual(drag.progress, straight.progress)
                            let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 64)
                            assertFinite(patches); assertTip(drag, patches: patches)
                            let back = try XCTUnwrap(patches.last { $0.back })
                            assertPoint(drag.gripOrigin.applying(back.transform), drag.gripPosition)
                            for anchor in anchors {
                                XCTAssertLessThanOrEqual(distance(drag.gripPosition, anchor), distance(drag.gripOrigin, anchor) + 1e-6)
                            }
                            XCTAssertEqual(patches.reduce(CGFloat.zero) { $0 + area($1.source) }, seed.page.width * seed.page.height, accuracy: 1e-4)
                            for completed in [false, true] {
                                for fraction: CGFloat in [0, 0.5, 1] {
                                    let frame = drag.released(completed: completed, fraction: fraction)
                                    let pieces = PaperCornerCurlGeometry.patches(for: frame, stripCount: 64)
                                    assertFinite(pieces)
                                    for anchor in anchors {
                                        let owners = pieces.filter { $0.source.contains { distance($0, anchor) < 1e-6 } }
                                        XCTAssertFalse(owners.isEmpty)
                                        for owner in owners { assertPoint(anchor.applying(owner.transform), anchor) }
                                    }
                                }
                            }
                        }
                        XCTAssertNotEqual(PaperCornerCurlGeometry.patches(for: down, stripCount: 64).map(\.projected),
                            PaperCornerCurlGeometry.patches(for: up, stripCount: 64).map(\.projected))
                    }
                }
            }
        }
    }


    /// 无参数；中部大幅横移受到两端书脊距离限制，实际抓取材料仍对应受约束的触点。无返回值。
    func testMiddleLargeCrossMovesKeepBothHingesReachable() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let primary: CGFloat = spread ? (sign < 0 ? 240 : 80) : 160
                    let origin = point(primary, 240, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread, inwardSign: sign, origin: origin))
                    let hinge = sign < 0 ? (axis == .horizontal ? seed.page.minX : seed.page.minY)
                        : (axis == .horizontal ? seed.page.maxX : seed.page.maxY)
                    let anchors = [point(hinge, 0, axis: axis), point(hinge, 480, axis: axis)]
                    let gripPrimary = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                    for progress: CGFloat in [0.01, 0.25, 0.8, 0.99] {
                        for crossSign: CGFloat in [-1, 1] {
                            let drag = try XCTUnwrap(seed.moved(to: point(gripPrimary + sign * 2 * seed.length * progress,
                                240 + crossSign * 1_000_000, axis: axis)))
                            let cross = axis == .horizontal ? drag.translation.y : drag.translation.x
                            XCTAssertGreaterThan(cross * crossSign, 0)
                            XCTAssertLessThanOrEqual(abs(cross), 240)
                            for completed in [false, true] {
                                for fraction: CGFloat in [0, 0.5, 1] {
                                    let frame = drag.released(completed: completed, fraction: fraction)
                                    let patches = PaperCornerCurlGeometry.patches(for: frame, stripCount: 64)
                                    assertFinite(patches); assertTip(frame, patches: patches)
                                    for anchor in anchors {
                                        XCTAssertLessThanOrEqual(distance(frame.gripPosition, anchor), distance(frame.gripOrigin, anchor) + 1e-6)
                                        let owners = patches.filter { $0.source.contains { distance($0, anchor) < 1e-6 } }
                                        XCTAssertFalse(owners.isEmpty)
                                        for owner in owners { assertPoint(anchor.applying(owner.transform), anchor) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 无参数；四角镜像及横纵轴交换应保持同一张纸的材料、深度和投影关系。无返回值。
    func testFourCornersAndBothAxesPreserveMirroredSurface() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        let live = try XCTUnwrap(seed.moved(to: CGPoint(x: 130, y: 130)))
        let reference = PaperCornerCurlGeometry.patches(for: live, stripCount: 64)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for mirrorPrimary in [false, true] {
                for mirrorCross in [false, true] {
                    let map: (CGPoint) -> CGPoint = { value in
                        let x = mirrorPrimary ? 320 - value.x : value.x
                        let y = mirrorCross ? 480 - value.y : value.y
                        return axis == .horizontal ? CGPoint(x: x, y: y) : CGPoint(x: y, y: x)
                    }
                    let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                    let mirrored = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: mirrorPrimary ? 1 : -1, origin: map(seed.origin)))
                    let moved = try XCTUnwrap(mirrored.moved(to: map(CGPoint(x: 130, y: 130))))
                    assertPoint(moved.corner, map(seed.corner))
                    assertPoint(moved.tip, map(live.tip))
                    XCTAssertEqual(moved.progress, live.progress, accuracy: 1e-9)
                    let actual = PaperCornerCurlGeometry.patches(for: moved, stripCount: 64)
                    assertFinite(actual)
                    XCTAssertEqual(actual.count, reference.count)
                    for (a, b) in zip(actual, reference) {
                        assertVertices(a.source, b.source.map(map))
                        assertVertices(a.projected, b.projected.map(map))
                        XCTAssertEqual(a.depth, b.depth, accuracy: 1e-6)
                        XCTAssertEqual(a.shade, b.shade, accuracy: 1e-6)
                        XCTAssertEqual(a.back, b.back)
                    }
                }
            }
        }
    }

    /// 无参数；同一主轴距离下改变横轴触点必须改变实际纸面，而非仅改变名义状态。无返回值。
    func testSamePrimaryDifferentCrossProducesDifferentFiniteGeometry() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                inwardSign: -1, origin: point(300, 20, axis: axis)))
            let shallow = try XCTUnwrap(seed.moved(to: point(130, 45, axis: axis)))
            let diagonal = try XCTUnwrap(seed.moved(to: point(130, 180, axis: axis)))
            XCTAssertEqual(shallow.progress, diagonal.progress)
            let a = PaperCornerCurlGeometry.patches(for: shallow, stripCount: 64)
            let b = PaperCornerCurlGeometry.patches(for: diagonal, stripCount: 64)
            assertFinite(a)
            assertFinite(b)
            assertTip(shallow, patches: a)
            assertTip(diagonal, patches: b)
            XCTAssertNotEqual(a.map(\.projected), b.map(\.projected))
            XCTAssertTrue(b.contains { abs($0.transform.b) > 0.01 || abs($0.transform.c) > 0.01 })
            XCTAssertTrue(b.contains { $0.back })
            XCTAssertTrue(b.contains { !$0.back })
        }
    }

    /// 无参数；不同按下位置到达相同绝对触点时，纸面控制点与材料投影保持一致。无返回值。
    func testAbsoluteContactIsStableAcrossSuccessiveMoves() throws {
        let size = CGSize(width: 320, height: 480)
        let a = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: false,
            inwardSign: -1, origin: CGPoint(x: 290, y: 30)))
        let b = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: false,
            inwardSign: -1, origin: CGPoint(x: 260, y: 60)))
        let first = try XCTUnwrap(a.moved(to: CGPoint(x: 240, y: 70)))
        let second = try XCTUnwrap(first.moved(to: CGPoint(x: 150, y: 130)))
        let equivalent = try XCTUnwrap(b.moved(to: CGPoint(x: 150, y: 130)))
        XCTAssertEqual(second.origin, a.origin)
        assertPoint(second.translation, CGPoint(x: -170, y: 130))
        assertPoint(second.tip, CGPoint(x: 150, y: 130))
        XCTAssertEqual(second.translation, equivalent.translation)
        XCTAssertEqual(second.tip, equivalent.tip)
        let patches = PaperCornerCurlGeometry.patches(for: second, stripCount: 64)
        assertTip(second, patches: patches)
        XCTAssertEqual(patches.map(\.projected),
                       PaperCornerCurlGeometry.patches(for: equivalent, stripCount: 64).map(\.projected))
    }

    // MARK: - 材料守恒及端点

    /// 无参数；两轴、单双页、两方向及不同精度下，材料面积完整且每条内边投影连续。无返回值。
    func testMaterialAreaAndSharedBoundariesRemainComplete() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                        inwardSign: sign, origin: point(sign < 0 ? 308 : 12, 18, axis: axis)))
                    for progress: CGFloat in [0.04, 0.45, 0.94] {
                        let primary = (axis == .horizontal ? seed.origin.x : seed.origin.y) + sign * 2 * seed.length * progress
                        let live = try XCTUnwrap(seed.moved(to: point(primary, 98, axis: axis)))
                        for count in [32, 65, 256] {
                            let patches = PaperCornerCurlGeometry.patches(for: live, stripCount: count)
                            assertFinite(patches)
                            assertTip(live, patches: patches)
                            XCTAssertEqual(patches.reduce(CGFloat.zero) { $0 + area($1.source) },
                                           seed.page.width * seed.page.height, accuracy: 1e-5)
                            for patch in patches {
                                XCTAssertGreaterThan(area(patch.source), 0)
                                for vertex in patch.source {
                                    XCTAssertTrue(seed.page.insetBy(dx: -1e-6, dy: -1e-6).contains(vertex))
                                }
                            }
                            for pair in zip(patches, patches.dropFirst()) {
                                XCTAssertLessThanOrEqual(pair.0.depth, pair.1.depth)
                            }
                            assertSharedEdges(patches, rect: seed.page)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；release 从实时纸面连续出发，取消与完成都以零深度、零阴影的整张平面结束。无返回值。
    func testReleaseStartsWithoutJumpAndEndsFlat() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for farCross in [false, true] {
                        let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                        let origin = point(sign < 0 ? 300 : 20, farCross ? 460 : 20, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: origin))
                        let live = try XCTUnwrap(seed.moved(to: CGPoint(
                            x: origin.x + (axis == .horizontal ? sign * seed.length * 0.7 : (farCross ? -90 : 90)),
                            y: origin.y + (axis == .vertical ? sign * seed.length * 0.7 : (farCross ? -90 : 90)))))
                        for completed in [false, true] {
                            XCTAssertEqual(live.released(completed: completed, fraction: 0), live)
                            let first = live.released(completed: completed, fraction: 1e-6)
                            XCTAssertLessThan(distance(first.tip, live.tip), 0.001)
                            let end = live.released(completed: completed, fraction: 1)
                            XCTAssertEqual(end.progress, completed ? 1 : 0)
                            let expected = completed
                                ? point(sign * 2 * seed.length, 0, axis: axis) : .zero
                            assertPoint(end.translation, expected)
                            let final = PaperCornerCurlGeometry.patches(for: end, stripCount: 64)
                            assertFinite(final)
                            assertTip(end, patches: final)
                            let landing = completed
                                ? seed.page.offsetBy(dx: axis == .horizontal ? sign * seed.length : 0,
                                                     dy: axis == .vertical ? sign * seed.length : 0)
                                : seed.page
                            XCTAssertEqual(final.reduce(CGFloat.zero) { $0 + area($1.projected) },
                                           seed.page.width * seed.page.height, accuracy: 1e-5)
                            for patch in final {
                                XCTAssertEqual(patch.depth, 0, accuracy: 1e-9)
                                XCTAssertEqual(patch.shade, 0, accuracy: 1e-9)
                                XCTAssertEqual(patch.back, completed)
                                let t = patch.transform
                                XCTAssertEqual(abs(t.a * t.d - t.b * t.c), 1, accuracy: 1e-9)
                                for projected in patch.projected {
                                    XCTAssertTrue(landing.insetBy(dx: -1e-6, dy: -1e-6).contains(projected))
                                }
                            }
                            var previousDistance = distance(live.tip, end.tip)
                            for fraction: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.99] {
                                let frame = live.released(completed: completed, fraction: fraction)
                                let remaining = distance(frame.tip, end.tip)
                                XCTAssertLessThan(remaining, previousDistance)
                                previousDistance = remaining
                                let patches = PaperCornerCurlGeometry.patches(for: frame, stripCount: 64)
                                assertFinite(patches)
                                assertTip(frame, patches: patches)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 无参数；中央书脊选择物理起始半页，进度按半页计算，终点覆盖另一半页。无返回值。
    func testSpreadPlansOnlyThePhysicalStartingHalfOnBothAxes() throws {
        let size = CGSize(width: 320, height: 480)
        let cases: [(PageTurnAxis, CGFloat, CGRect, CGPoint)] = [
            (.horizontal, -1, CGRect(x: 160, y: 0, width: 160, height: 480), CGPoint(x: 320, y: 0)),
            (.horizontal, 1, CGRect(x: 0, y: 0, width: 160, height: 480), .zero),
            (.vertical, -1, CGRect(x: 0, y: 240, width: 320, height: 240), CGPoint(x: 0, y: 480)),
            (.vertical, 1, CGRect(x: 0, y: 0, width: 320, height: 240), .zero)
        ]
        for (axis, sign, expectedPage, expectedCorner) in cases {
            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: true,
                inwardSign: sign, origin: CGPoint(x: 20, y: 20)))
            let single = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                inwardSign: sign, origin: seed.origin))
            XCTAssertEqual(seed.page, expectedPage)
            XCTAssertEqual(seed.corner, expectedCorner)
            XCTAssertEqual(seed.length, single.length / 2)
            let target = CGPoint(x: seed.gripOrigin.x + (axis == .horizontal ? sign * seed.length : 0),
                                 y: seed.gripOrigin.y + (axis == .vertical ? sign * seed.length : 0))
            XCTAssertEqual(try XCTUnwrap(seed.moved(to: target)).progress, 0.5)
            XCTAssertEqual(try XCTUnwrap(single.moved(to: target)).progress, 0.25)
        }
    }

    /// 大幅斜拖不得从装订边撕开；两轴、单双页、各角以及回弹中保持书脊投影不动。
    func testHingeStaysFixedDuringDiagonalDragAndRelease() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for bottom in [false, true] {
                        let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                        let origin = point(sign < 0 ? 300 : 20, bottom ? 460 : 20, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread, inwardSign: sign, origin: origin))
                        let hingePrimary: CGFloat = axis == .horizontal
                            ? (sign < 0 ? seed.page.minX : seed.page.maxX)
                            : (sign < 0 ? seed.page.minY : seed.page.maxY)
                        let anchors = [point(hingePrimary, 0, axis: axis), point(hingePrimary, 480, axis: axis)]
                        for progress: CGFloat in [0.05, 0.3125, 0.65, 0.95] {
                            let moved = try XCTUnwrap(seed.moved(to: point(
                                (sign < 0 ? 300 : 20) + sign * seed.length * 2 * progress,
                                (bottom ? 460 : 20) + (bottom ? -250 : 250), axis: axis)))
                            let adjacent = point(hingePrimary, bottom ? 480 : 0, axis: axis)
                            XCTAssertLessThanOrEqual(distance(moved.tip, adjacent), seed.length + 1e-6)
                            for completed in [false, true] {
                                for fraction: CGFloat in [0, 0.1, 0.5, 0.9, 1] {
                                    let frame = moved.released(completed: completed, fraction: fraction)
                                    let patches = PaperCornerCurlGeometry.patches(for: frame, stripCount: 64)
                                    assertTip(frame, patches: patches)
                                    for anchor in anchors {
                                        let owners = patches.filter { patch in patch.source.contains { distance($0, anchor) < 1e-6 } }
                                        XCTAssertFalse(owners.isEmpty)
                                        for owner in owners { assertPoint(anchor.applying(owner.transform), anchor) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 边界输入

    /// 无参数；非法画布、起点、符号和条带精度在生成几何前被拒绝。无返回值。
    func testInvalidSizesOriginsSignsAndStripCountsAreRejected() throws {
        let size = CGSize(width: 320, height: 480)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for invalid: CGFloat in [0, -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude, 10_000_001] {
                for badSize in [CGSize(width: invalid, height: 480), CGSize(width: 320, height: invalid)] {
                    XCTAssertNil(PaperCornerDrag(size: badSize, axis: axis, spread: false,
                                                inwardSign: -1, origin: .zero))
                }
            }
            let invalidOrigins = [CGPoint(x: -1, y: 20), CGPoint(x: 321, y: 20),
                CGPoint(x: 20, y: -1), CGPoint(x: 20, y: 481),
                CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity)]
            for origin in invalidOrigins {
                XCTAssertNil(PaperCornerDrag(size: size, axis: axis, spread: true, inwardSign: -1, origin: origin))
            }
            for sign: CGFloat in [0, -2, 2, .nan, .infinity] {
                XCTAssertNil(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: sign, origin: .zero))
            }
            for origin in [CGPoint.zero, CGPoint(x: 320, y: 480)] {
                XCTAssertNotNil(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: -1, origin: origin))
            }
        }
        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        let live = try XCTUnwrap(seed.moved(to: CGPoint(x: 160, y: 90)))
        for count in [Int.min, -1, 0, 31, 257, Int.max] {
            XCTAssertTrue(PaperCornerCurlGeometry.patches(for: live, stripCount: count).isEmpty)
        }
    }

    /// 无参数；任意有限拖动被钳制到材料范围，NaN/Infinity 不产生替代状态。无返回值。
    func testExtremeMovesClampAndNonfiniteMovesAreIgnored() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for sign: CGFloat in [-1, 1] {
                for farCross in [false, true] {
                    let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: sign, origin: point(sign < 0 ? 300 : 20, farCross ? 460 : 20, axis: axis)))
                    let extreme = try XCTUnwrap(seed.moved(to: point(sign * CGFloat.greatestFiniteMagnitude,
                        (farCross ? -1 : 1) * CGFloat.greatestFiniteMagnitude, axis: axis)))
                    XCTAssertEqual(extreme.progress, 1)
                    assertPoint(extreme.translation, point(sign * 640, 0, axis: axis))
                    assertFinite(PaperCornerCurlGeometry.patches(for: extreme, stripCount: 256))
                    let outward = try XCTUnwrap(seed.moved(to: point(-sign * 1e6, farCross ? 1e6 : -1e6, axis: axis)))
                    XCTAssertEqual(outward.translation, .zero)
                    XCTAssertEqual(outward.progress, 0)
                    for value: CGFloat in [.nan, .infinity, -.infinity] {
                        XCTAssertNil(extreme.moved(to: CGPoint(x: value, y: 100)))
                        XCTAssertNil(extreme.moved(to: CGPoint(x: 100, y: value)))
                    }
                    XCTAssertEqual(seed.translation, .zero)
                }
            }
        }
    }

    /// 无参数；release 的非法比例保留实时状态，有限越界比例仅收敛到既定端点。无返回值。
    func testReleaseFractionsIgnoreNonfiniteAndClampFiniteValues() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: true, inwardSign: -1, origin: CGPoint(x: 300, y: 460)))
        let live = try XCTUnwrap(seed.moved(to: CGPoint(x: 180, y: 320)))
        for completed in [false, true] {
            for invalid: CGFloat in [.nan, .infinity, -.infinity] {
                XCTAssertEqual(live.released(completed: completed, fraction: invalid), live)
            }
            XCTAssertEqual(live.released(completed: completed, fraction: -10), live)
            XCTAssertEqual(live.released(completed: completed, fraction: 10),
                           live.released(completed: completed, fraction: 1))
        }
    }

    /// 无参数；支持范围内的微小、狭长及最大画布在各精度下均不生成非有限投影。无返回值。
    func testSupportedExtremeSizesKeepTipAndProjectionFinite() throws {
        for size in [CGSize(width: 0.1, height: 0.2), CGSize(width: 1, height: 10_000_000),
                     CGSize(width: 10_000_000, height: 1), CGSize(width: 10_000_000, height: 10_000_000)] {
            for axis in [PageTurnAxis.horizontal, .vertical] {
                let origin = CGPoint(x: size.width * 0.9, y: size.height * 0.9)
                let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: -1, origin: origin))
                let live = try XCTUnwrap(seed.moved(to: CGPoint(x: origin.x - size.width * 0.4,
                                                               y: origin.y - size.height * 0.3)))
                for count in [32, 33, 128, 256] {
                    let patches = PaperCornerCurlGeometry.patches(for: live, stripCount: count)
                    assertFinite(patches)
                    assertTip(live, patches: patches)
                }
            }
        }
    }
}
#endif
