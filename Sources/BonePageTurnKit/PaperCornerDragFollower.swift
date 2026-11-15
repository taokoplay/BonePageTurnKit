import Foundation
#if canImport(CoreGraphics)
import CoreGraphics

/// 原生纸面从当前已提交姿态连续翻向最新触点；逻辑输入与提交判定独立。
struct PaperCornerDragFollower {
    static let animationDuration: TimeInterval = 0.18
    static let maximumFrameStep: TimeInterval = 1.0 / 30

    private(set) var current: PaperCornerDrag?
    private var target: PaperCornerDrag?
    private var start: PaperCornerDrag?
    private var elapsed: TimeInterval = 0
    private var followsTouch = false

    var isSettled: Bool { current == target }

    /// - Parameters: drag: 最新逻辑目标；followsTouch: 拖动重定向动画，收尾直接使用自身的计时姿态。
    /// - Returns: 无返回值；同一手势只改变目标，不移动当前纸面，也不重播过时触点。
    mutating func update(_ drag: PaperCornerDrag, followsTouch: Bool) {
        let unchanged = self.followsTouch == followsTouch && target == drag
        target = drag; self.followsTouch = followsTouch
        guard followsTouch, let previous = current,
              previous.page == drag.page, previous.axis == drag.axis,
              previous.origin == drag.origin, previous.inwardSign == drag.inwardSign else {
            current = drag; start = drag; elapsed = Self.animationDuration; return
        }
        guard !unchanged else { return }
        start = previous; elapsed = 0
    }

    /// - Parameter elapsed: 可见帧推进秒数；非法值忽略，长停顿单帧至多推进三十分之一秒。
    /// - Returns: 无返回值；沿用既有三次 ease-out，从当前姿态经过中间帧准确到达目标。
    mutating func advance(elapsed: TimeInterval) {
        guard followsTouch, elapsed.isFinite, elapsed > 0, !isSettled,
              let start, let target else { return }
        self.elapsed = min(Self.animationDuration, self.elapsed + min(elapsed, Self.maximumFrameStep))
        let t = CGFloat(self.elapsed / Self.animationDuration)
        let remainder = 1 - t
        let fraction = 1 - remainder * remainder * remainder
        if self.elapsed >= Self.animationDuration { current = target; return }
        let point = CGPoint(x: start.gripPosition.x + (target.gripPosition.x - start.gripPosition.x) * fraction,
                            y: start.gripPosition.y + (target.gripPosition.y - start.gripPosition.y) * fraction)
        current = target.moved(to: point) ?? current
    }

    /// 无参数；清空姿态与重定向进度，不持有时钟、视图或纹理。无返回值。
    mutating func reset() { current = nil; target = nil; start = nil; elapsed = 0; followsTouch = false }
}
#endif
