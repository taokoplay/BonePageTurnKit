import Foundation
#if canImport(CoreGraphics)

/// 原生卷页收尾按已提交帧推进；没有首帧时不消耗动画时间，卡顿不积成一次大跳。
struct PaperReleaseFrameGate {
    let waitsForGPU: Bool
    private var lastSubmissionCount: Int
    private var hasSubmittedStart: Bool
    private var accumulated: TimeInterval = 0

    /// - Parameters: waitsForGPU: 原生 Metal 触点收尾是否等待显示提交；submittedFrameCount: 收尾开始时的成功提交数。
    init(waitsForGPU: Bool, submittedFrameCount: Int) {
        self.waitsForGPU = waitsForGPU
        lastSubmissionCount = submittedFrameCount
        hasSubmittedStart = submittedFrameCount > 0
    }

    /// - Parameters: elapsed: 驱动帧间时间；submittedFrameCount: 当前成功提交数。
    /// - Returns: 可以推进的动画时间；未取得下一张实际提交帧时为 nil。标量与离屏驱动保留原 0.1 秒上限。
    mutating func step(elapsed: TimeInterval, submittedFrameCount: Int, framesExhausted: Bool = false) -> TimeInterval? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        guard waitsForGPU else { return min(elapsed, 0.1) }
        let maximum = PaperCornerDragFollower.maximumFrameStep
        if hasSubmittedStart { accumulated = min(maximum, accumulated + min(elapsed, maximum)) }
        if framesExhausted, hasSubmittedStart {
            // 只为已经显示且暂时空闲的当前姿态放行一步；下一次更新仍继续等 GPU。
            lastSubmissionCount = submittedFrameCount
            let result = accumulated
            accumulated = 0
            return result
        }
        guard submittedFrameCount > lastSubmissionCount else { return nil }
        lastSubmissionCount = submittedFrameCount
        if !hasSubmittedStart {
            hasSubmittedStart = true
            accumulated = min(elapsed, maximum)
        }
        let result = accumulated
        accumulated = 0
        return result
    }
}
#endif
