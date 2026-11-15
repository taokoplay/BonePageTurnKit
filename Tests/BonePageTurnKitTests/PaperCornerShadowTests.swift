#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

final class PaperCornerShadowTests: XCTestCase {
    /// 无参数；大幅斜折受书脊约束而近乎平折时，纸背仍须保留可见、由根部到自由边增强的接触投影。无返回值。
    func testLargeDiagonalFlatLimitRetainsContactShadow() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
            }
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: sign, origin: point(195, 422)))
                    let edge: CGFloat = sign < 0 ? 390 : 0
                    for pull: CGFloat in [0.35, 0.7, 0.9] {
                        var drag = try XCTUnwrap(seed.moved(to: point(edge + sign * 390 * pull, 422 + crossSign * 1_000_000)))
                        // 内部平折状态独立构造；交互拖动现在为卷曲弧长保留空间。
                        let reach = 390 * 390 * pull * (2 - pull)
                        let cross = crossSign * reach / (sqrt(422 * 422 + reach) + 422)
                        if axis == .horizontal { drag.translation.y = cross } else { drag.translation.x = cross }
                        let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
                        XCTAssertLessThan(try XCTUnwrap(patches.filter(\.back).map(\.depth).max()), 1e-5,
                            "此用例必须真实到达曲面深度退化的书脊边界")
                        let profile = try XCTUnwrap(PaperCornerShadowProfile(drag: drag, patches: patches))
                        let tip = profile.sample(at: drag.tip)
                        XCTAssertGreaterThan(tip.width, 4, "大块纸背不能因圆柱半径为零而失去全部投影")
                        XCTAssertGreaterThan(tip.opacity, 0.08)
                        let span = profile.rootCoordinate - profile.tipCoordinate
                        let root = CGPoint(x: drag.tip.x + profile.normal.x * span, y: drag.tip.y + profile.normal.y * span)
                        let near = profile.sample(at: root)
                        XCTAssertLessThan(near.width, 1); XCTAssertLessThan(near.opacity, 0.03)
                        XCTAssertFalse(PaperCornerShadowGeometry.vertices(for: drag, patches: patches).isEmpty)
                    }
                }
            }
        }
    }

    /// 无参数；接近可达边界的连续角度变化不能导致投影突然消失。无返回值。
    func testContactShadowStaysContinuousNearFlatBoundary() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 390, height: 844), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 195, y: 422)))
        let reach: CGFloat = 273 * (780 - 273)
        let flatCross = reach / (sqrt(422 * 422 + reach) + 422)
        var previous: PaperCornerShadowSample?
        for fraction: CGFloat in [0.96, 0.98, 0.995, 1, 1.0001] {
            var drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 117, y: 1_000_000)))
            drag.translation.y = flatCross * min(1, fraction)
            let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
            let profile = try XCTUnwrap(PaperCornerShadowProfile(drag: drag, patches: patches))
            let sample = profile.sample(at: drag.tip)
            XCTAssertGreaterThan(sample.opacity, 0.08)
            if let previous {
                XCTAssertLessThan(abs(sample.opacity - previous.opacity), 0.03)
                XCTAssertLessThan(abs(sample.width - previous.width), 2)
            }
            previous = sample
        }
    }

    /// 折痕附近的窄浅投影到纸角宽深投影连续增加，四角和两轴一致。
    func testHeightProfileTapersContinuouslyFromFoldToTip() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for sign: CGFloat in [-1, 1] {
                for far in [false, true] {
                    let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                    func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
                    }
                    let origin = point(sign < 0 ? 300 : 20, far ? 460 : 20)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: sign, origin: origin))
                    let drag = try XCTUnwrap(seed.moved(to: point((sign < 0 ? 300 : 20) + sign * 140, (far ? 460 : 20) + (far ? -120 : 120))))
                    let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
                    let profile = try XCTUnwrap(PaperCornerShadowProfile(drag: drag, patches: patches))
                    let span = profile.rootCoordinate - profile.tipCoordinate
                    let root = CGPoint(x: drag.tip.x + profile.normal.x * span, y: drag.tip.y + profile.normal.y * span)
                    let near = profile.sample(at: root), tip = profile.sample(at: drag.tip)
                    XCTAssertLessThan(near.width, 1); XCTAssertLessThan(near.opacity, 0.03)
                    XCTAssertGreaterThan(tip.width, 10); XCTAssertGreaterThan(tip.opacity, 0.18)
                    var previous = near
                    for index in 1...100 {
                        let t = CGFloat(index) / 100
                        let point = CGPoint(x: root.x + (drag.tip.x - root.x) * t, y: root.y + (drag.tip.y - root.y) * t)
                        let sample = profile.sample(at: point)
                        XCTAssertGreaterThanOrEqual(sample.width + 1e-8, previous.width)
                        XCTAssertGreaterThanOrEqual(sample.opacity + 1e-8, previous.opacity)
                        XCTAssertLessThan(sample.width - previous.width, 0.5)
                        XCTAssertLessThan(sample.opacity - previous.opacity, 0.01)
                        previous = sample
                    }
                    XCTAssertEqual(previous.width, tip.width, accuracy: 1e-6)
                }
            }
        }
    }

    /// 投影网格有限、透明度合法，完全平铺或取消后不生成投影。
    func testShadowMeshIsBoundedAndDisappearsAtEndpoints() throws {
        for spread in [false, true] {
            let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 640, height: 480), axis: .horizontal,
                spread: spread, inwardSign: -1, origin: CGPoint(x: 620, y: 20)))
            XCTAssertTrue(PaperCornerShadowGeometry.vertices(for: seed,
                patches: PaperCornerCurlGeometry.patches(for: seed, stripCount: 128)).isEmpty)
            for progress: CGFloat in [0.01, 0.2, 0.5, 0.8, 0.99] {
                let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 620 - 2 * seed.length * progress, y: 130)))
                let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 256)
                let vertices = PaperCornerShadowGeometry.vertices(for: drag, patches: patches)
                XCTAssertEqual(vertices.count % 3, 0); XCTAssertLessThan(vertices.count, 4096)
                for vertex in vertices {
                    XCTAssertTrue(vertex.point.x.isFinite && vertex.point.y.isFinite)
                    XCTAssertTrue(vertex.opacity.isFinite && (0...0.3).contains(vertex.opacity))
                }
                for completed in [false, true] {
                    let end = drag.released(completed: completed, fraction: 1)
                    XCTAssertTrue(PaperCornerShadowGeometry.vertices(for: end,
                        patches: PaperCornerCurlGeometry.patches(for: end, stripCount: 256)).isEmpty)
                }
            }
        }
    }
}
#endif
