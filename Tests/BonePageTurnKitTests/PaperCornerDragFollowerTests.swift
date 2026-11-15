#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

final class PaperCornerDragFollowerTests: XCTestCase {
    /// 无参数；返回同一角落、两个可达控制点，避免时间测试依赖 UIKit。
    private func poses() throws -> (PaperCornerDrag, PaperCornerDrag) {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        return (try XCTUnwrap(seed.moved(to: CGPoint(x: 250, y: 70))),
                try XCTUnwrap(seed.moved(to: CGPoint(x: 180, y: 100))))
    }

    /// 无参数；相同实际推进时间下，60Hz 与 120Hz 的追随位置一致。无返回值。
    func testFollowUsesElapsedTimeRatherThanFrameCount() throws {
        let (start, target) = try poses()
        var sixty = PaperCornerDragFollower(), oneTwenty = PaperCornerDragFollower()
        sixty.update(start, followsTouch: true); sixty.update(target, followsTouch: true)
        oneTwenty.update(start, followsTouch: true); oneTwenty.update(target, followsTouch: true)
        for _ in 0..<3 { sixty.advance(elapsed: 1.0 / 60) }
        for _ in 0..<6 { oneTwenty.advance(elapsed: 1.0 / 120) }
        let a = try XCTUnwrap(sixty.current), b = try XCTUnwrap(oneTwenty.current)
        XCTAssertEqual(a.gripPosition.x, b.gripPosition.x, accuracy: 1e-6)
        XCTAssertEqual(a.gripPosition.y, b.gripPosition.y, accuracy: 1e-6)
        XCTAssertFalse(sixty.isSettled)
    }

    /// 无参数；大幅新目标也不能瞬移，必须经过中间姿态；再换方向时从当前值继续。无返回值。
    func testRetargetNeverJumpsAndTraversesIntermediatePoses() throws {
        let (start, target) = try poses(); var follower = PaperCornerDragFollower()
        follower.update(start, followsTouch: true); follower.update(target, followsTouch: true)
        XCTAssertEqual(follower.current, start, "更新目标不能先强制追到目标附近")
        follower.advance(elapsed: 1.0 / 60)
        let middle = try XCTUnwrap(follower.current)
        XCTAssertNotEqual(middle, start); XCTAssertNotEqual(middle, target)
        let total = hypot(start.gripPosition.x - target.gripPosition.x, start.gripPosition.y - target.gripPosition.y)
        let moved = hypot(middle.gripPosition.x - start.gripPosition.x, middle.gripPosition.y - start.gripPosition.y)
        XCTAssertGreaterThan(moved, 0); XCTAssertLessThan(moved, total * 0.6)
        let redirected = try XCTUnwrap(target.moved(to: CGPoint(x: 260, y: 160)))
        follower.update(redirected, followsTouch: true)
        XCTAssertEqual(follower.current, middle, "重定向不能跳回起角或跳到新目标")
        for _ in 0..<12 { follower.advance(elapsed: 1.0 / 60) }
        XCTAssertTrue(follower.isSettled); XCTAssertEqual(follower.current, redirected)
    }

    /// 无参数；布局重复给出同一触点不会重启动画，停手后应有限时间到达。无返回值。
    func testRepeatedIdenticalTargetsDoNotRestartAnimation() throws {
        let (start, target) = try poses(); var follower = PaperCornerDragFollower()
        follower.update(start, followsTouch: true); follower.update(target, followsTouch: true)
        for _ in 0..<20 {
            follower.update(target, followsTouch: true)
            follower.advance(elapsed: 0.01)
        }
        XCTAssertEqual(follower.current, target); XCTAssertTrue(follower.isSettled)
    }

    /// 无参数；收尾直接对齐，新会话与清理不会保留旧纸面。无返回值。
    func testDirectPhaseAndNewSessionDiscardOldSmoothing() throws {
        let (start, target) = try poses(); var follower = PaperCornerDragFollower()
        follower.update(start, followsTouch: true); follower.update(target, followsTouch: true)
        let release = target.released(completed: true, fraction: 0.2)
        follower.update(release, followsTouch: false)
        XCTAssertEqual(follower.current, release); XCTAssertTrue(follower.isSettled)
        let otherSeed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: 1, origin: CGPoint(x: 20, y: 460)))
        let other = try XCTUnwrap(otherSeed.moved(to: CGPoint(x: 120, y: 360)))
        follower.update(other, followsTouch: true)
        XCTAssertEqual(follower.current, other)
        follower.reset(); XCTAssertNil(follower.current); XCTAssertTrue(follower.isSettled)
    }

    /// 无参数；非法时间不推进，长停顿不能一次追完，后续可见帧继续到达目标。无返回值。
    func testInvalidElapsedIsIgnoredAndLongStallDoesNotTeleport() throws {
        let (start, target) = try poses(); var follower = PaperCornerDragFollower()
        follower.update(start, followsTouch: true); follower.update(target, followsTouch: true)
        for elapsed in [0, -1, Double.nan, Double.infinity] { follower.advance(elapsed: elapsed) }
        XCTAssertEqual(follower.current, start)
        follower.advance(elapsed: 10)
        XCTAssertNotEqual(follower.current, target)
        for _ in 0..<6 { follower.advance(elapsed: 1.0 / 30) }
        XCTAssertEqual(follower.current, target); XCTAssertTrue(follower.isSettled)
    }
}
#endif
