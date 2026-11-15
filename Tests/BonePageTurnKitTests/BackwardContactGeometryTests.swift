#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

/// 直接校验交互输入、实际折面与源材料投影；不以页码正确代替跟手正确。
final class BackwardContactGeometryTests: XCTestCase {
    /// - Parameters: primary: 轴向坐标；cross: 横跨坐标；axis: 分页轴。
    /// - Returns: 画布中的点。
    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    /// 无参数；两物理边、两轴、单双页及角落／中部的可达触点必须与实际回翻控制点重合。无返回值。
    func testReturningGripMatchesAbsoluteFinger() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for cross: CGFloat in [0, 422, 844] {
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                            inwardSign: sign, origin: point(sign > 0 ? 20 : 370, cross, axis: axis)))
                        let edge = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                        for fraction: CGFloat in [0.2, 0.5, 0.8] {
                            let touch = point(edge + sign * seed.length * fraction, cross, axis: axis)
                            let input = try XCTUnwrap(seed.moved(to: touch, direction: .previous))
                            let folded = try XCTUnwrap(input.foldingPresentation(direction: .previous, size: size, spread: spread))
                            XCTAssertEqual(folded.gripPosition.x, touch.x, accuracy: 1e-6)
                            XCTAssertEqual(folded.gripPosition.y, touch.y, accuracy: 1e-6)
                            let patches = PaperCornerCurlGeometry.patches(for: folded, stripCount: 64)
                            let plane = try XCTUnwrap(patches.last { $0.back })
                            let actual = folded.gripOrigin.applying(plane.transform)
                            XCTAssertEqual(actual.x, touch.x, accuracy: 1e-6, "实际材料投影不能偏移一个页宽")
                            XCTAssertEqual(actual.y, touch.y, accuracy: 1e-6)
                        }
                    }
                }
            }
        }
    }
    /// 无参数；回翻起手的首帧仍为完全折出的纸，追随经过多个中间帧后精确到达手指。无返回值。
    func testReturningPickupFollowsMaterialCoordinatesContinuously() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: 1,
                origin: point(20, 422, axis: axis)))
            let initial = try XCTUnwrap(seed.foldingPresentation(direction: .previous, size: size, spread: false))
            XCTAssertEqual(initial.progress, 1, "回翻初始仍为上一张纸完全折出")
            let input = try XCTUnwrap(seed.moved(to: point(200, 422, axis: axis)))
            let target = try XCTUnwrap(input.foldingPresentation(direction: .previous, size: size, spread: false))
            for fps in [60.0, 120.0] {
                var follower = PaperCornerDragFollower()
                follower.update(initial, followsTouch: false); follower.update(target, followsTouch: true)
                XCTAssertEqual(follower.current, initial, "新触点不能立即跳成半张已展开页")
                var last = initial.gripPosition
                var intermediate = 0
                for _ in 0..<Int(fps * 0.25) {
                    follower.advance(elapsed: 1 / fps)
                    let shown = try XCTUnwrap(follower.current)
                    if shown != initial && shown != target { intermediate += 1 }
                    XCTAssertLessThan(hypot(shown.gripPosition.x - last.x, shown.gripPosition.y - last.y), 180)
                    let reported = try XCTUnwrap(shown.interactivePresentation(direction: .previous, size: size, spread: false))
                    let roundTrip = try XCTUnwrap(reported.foldingPresentation(direction: .previous, size: size, spread: false))
                    XCTAssertEqual(roundTrip.gripPosition.x, shown.gripPosition.x, accuracy: 1e-6)
                    XCTAssertEqual(roundTrip.gripPosition.y, shown.gripPosition.y, accuracy: 1e-6)
                    last = shown.gripPosition
                }
                XCTAssertGreaterThan(intermediate, 3); XCTAssertTrue(follower.isSettled)
                XCTAssertEqual(follower.current, target)
                XCTAssertEqual(target.gripPosition, input.gripPosition)
            }
        }
    }

    /// 无参数；从显示中的任意回翻姿态完成／取消，首帧连续、终帧平铺且不残留半页跳变。无返回值。
    func testReturningReleasePreservesPoseAndEndsAtPhysicalLanding() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                        inwardSign: sign, origin: point(sign > 0 ? 20 : 370, 422, axis: axis)))
                    let edge = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                    let live = try XCTUnwrap(seed.moved(to: point(edge + sign * seed.length * 0.45, 422, axis: axis)))
                    for completed in [false, true] {
                        XCTAssertEqual(live.released(completed: completed, fraction: 0, direction: .previous), live)
                        let first = live.released(completed: completed, fraction: 1e-7, direction: .previous)
                        XCTAssertLessThan(hypot(first.gripPosition.x - live.gripPosition.x, first.gripPosition.y - live.gripPosition.y), 0.001)
                        var previous = try XCTUnwrap(live.foldingPresentation(direction: .previous, size: size, spread: spread))
                        for step in 1...100 {
                            let input = live.released(completed: completed, fraction: CGFloat(step) / 100, direction: .previous)
                            let fold = try XCTUnwrap(input.foldingPresentation(direction: .previous, size: size, spread: spread))
                            XCTAssertLessThan(hypot(fold.gripPosition.x - previous.gripPosition.x, fold.gripPosition.y - previous.gripPosition.y), 10)
                            if step == 100 {
                                XCTAssertEqual(fold.progress, completed ? 0 : 1, accuracy: 1e-8)
                                let patches = PaperCornerCurlGeometry.patches(for: fold, stripCount: 64)
                                XCTAssertTrue(patches.allSatisfy { abs($0.depth) < 1e-7 && abs($0.shade) < 1e-7 })
                            }
                            previous = fold
                        }
                    }
                }
            }
        }
    }

    /// 无参数；斜拖只在实际移动纸面上限位，不能先由未移动的另一边截掉可达触点。无返回值。
    func testReturningDiagonalUsesActualMaterialReach() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    let origin = point(sign > 0 ? 20 : 370, 422, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: spread,
                        inwardSign: sign, origin: origin))
                    let edge = axis == .horizontal ? seed.gripOrigin.x : seed.gripOrigin.y
                    for cross: CGFloat in [344, 500] {
                        let touch = point(edge + sign * 40, cross, axis: axis)
                        let input = try XCTUnwrap(seed.moved(to: touch, direction: .previous))
                        let actual = try XCTUnwrap(input.foldingPresentation(direction: .previous, size: size, spread: spread))
                        let sourcePrimary: CGFloat = sign > 0 ? 390 : 0
                        let hingePrimary: CGFloat = spread ? 195 : (sign > 0 ? 0 : 390)
                        XCTAssertEqual(actual.gripOrigin.x, point(sourcePrimary, 422, axis: axis).x, accuracy: 1e-6)
                        XCTAssertEqual(actual.gripOrigin.y, point(sourcePrimary, 422, axis: axis).y, accuracy: 1e-6)
                        XCTAssertEqual(input.gripPosition.x, actual.gripPosition.x, accuracy: 1e-6)
                        XCTAssertEqual(input.gripPosition.y, actual.gripPosition.y, accuracy: 1e-6)
                        let actualCross = axis == .horizontal ? actual.gripPosition.y : actual.gripPosition.x
                        XCTAssertGreaterThan((actualCross - 422) * (cross - 422), 0)
                        XCTAssertLessThanOrEqual(abs(actualCross - 422), abs(cross - 422) + 1e-6)
                        for edge: CGFloat in [0, 844] {
                            let hinge = point(hingePrimary, edge, axis: axis)
                            XCTAssertLessThanOrEqual(hypot(actual.gripPosition.x - hinge.x, actual.gripPosition.y - hinge.y),
                                hypot(actual.gripOrigin.x - hinge.x, actual.gripOrigin.y - hinge.y) + 1e-6)
                        }
                        if !spread {
                            XCTAssertEqual(actual.gripPosition.x, touch.x, accuracy: 1e-6)
                            XCTAssertEqual(actual.gripPosition.y, touch.y, accuracy: 1e-6)
                        }
                    }
                }
            }
        }
    }

    func testReturningAngleIntentReleasePreservesEndpointsAndCancellation() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for sign: CGFloat in [-1, 1] {
                var seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                    inwardSign: sign, origin: point(sign > 0 ? 20 : 300, 240, axis: axis)))
                seed.prefersFlatTurn = true
                let folded = try XCTUnwrap(seed.foldingPresentation(direction: .previous, size: size, spread: false))
                let start = try XCTUnwrap(folded.interactivePresentation(direction: .previous, size: size, spread: false))
                let touch = point(sign > 0 ? 200 : 120, 200, axis: axis)
                seed.trackPanAngle(to: touch)
                let intent = try XCTUnwrap(seed.moved(to: touch, direction: .previous))
                for completed in [false, true] {
                    for fraction: CGFloat in [0, 1] {
                        XCTAssertEqual(start.released(completed: completed, fraction: fraction,
                            direction: .previous, angleIntent: intent),
                            start.released(completed: completed, fraction: fraction, direction: .previous))
                    }
                    let first = start.released(completed: completed, fraction: 1e-7,
                        direction: .previous, angleIntent: intent)
                    XCTAssertLessThan(hypot(first.gripPosition.x - start.gripPosition.x,
                        first.gripPosition.y - start.gripPosition.y), 0.01)
                }
                let halfway = start.released(completed: true, fraction: 0.5,
                    direction: .previous, angleIntent: intent)
                let material = try XCTUnwrap(halfway.foldingPresentation(direction: .previous, size: size, spread: false))
                XCTAssertTrue(PaperCornerCurlGeometry.patches(for: material, stripCount: 64).contains {
                    abs($0.transform.b) > 0.01 || abs($0.transform.c) > 0.01
                })
                let nearLanding = start.released(completed: true, fraction: 1 - 1e-4,
                    direction: .previous, angleIntent: intent)
                let nearMaterial = try XCTUnwrap(nearLanding.foldingPresentation(direction: .previous,
                    size: size, spread: false))
                let foldedArea = PaperCornerCurlGeometry.patches(for: nearMaterial, stripCount: 64)
                    .filter { $0.back }.reduce(CGFloat.zero) { total, patch in
                        let polygon = patch.source
                        guard let first = polygon.first else { return total }
                        let pairs = zip(polygon, Array(polygon.dropFirst()) + [first])
                        return total + abs(pairs.reduce(CGFloat.zero) { sum, pair in
                            sum + pair.0.x * pair.1.y - pair.1.x * pair.0.y
                        }) / 2
                    }
                XCTAssertLessThan(foldedArea, nearMaterial.page.width * nearMaterial.page.height * 0.01,
                                  "落页前斜折面积应连续缩小，不能等最后一帧突然消失")
                for fraction: CGFloat in [0.2, 0.5, 0.8] {
                    XCTAssertEqual(start.released(completed: false, fraction: fraction,
                        direction: .previous, angleIntent: intent),
                        start.released(completed: false, fraction: fraction, direction: .previous))
                }
            }
        }
    }

}
#endif
