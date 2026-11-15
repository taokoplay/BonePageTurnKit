import Foundation

/// 一次翻页的诊断快照。帧率来自回调时间；屏幕上限与申请值不代表实际呈现帧率。
public struct PageTurnAnimationDiagnostic: Sendable {
    public enum Event: String, Sendable {
        case began, prepared, queued, releaseStarted, frame, waitingForFrame, finished
    }

    public enum EndReason: String, Sendable {
        case completed, cancelled, handoff, suspended, viewportChanged
        case applicationInactive, offscreen, invalidated, snapshotFailure, memoryWarning
        case unanimated, reducedMotion
    }

    public let sequence: Int
    public let transitionID: UUID
    public let timestamp: TimeInterval
    public let event: Event
    public let endReason: EndReason?
    public let effect: PageTurnEffect
    public let direction: PageTurnDirection
    public let progress: Double
    public let queueDepth: Int
    /// 自事务开始到当前的墙钟时间，包括页面准备、拖动与收尾。
    public let wallElapsed: TimeInterval
    /// 当前收尾的计划时长及已推进时间；尚未松手时为 nil。
    public let duration: TimeInterval?
    public let animationElapsed: TimeInterval?
    public let startProgress: Double?
    public let targetProgress: Double?
    public let durationScale: Double
    public let curve: String
    /// 请求更新纸面的次数，区别于 GPU 提交和实际呈现次数。
    public let updateCount: Int
    public let gpuSubmissionCount: Int
    /// 仅真机 Metal 呈现回调可用；模拟器或软件路径为 nil。
    public let gpuPresentationCount: Int?
    public let gpuPresentedFramesPerSecond: Double?
    public let maximumFramesPerSecond: Int
    public let requestedFramesPerSecond: Int?
    public let preparationDuration: TimeInterval?
    public let snapshotPixels: Int
    public let frameCPUTime: TimeInterval?
    public let waitingForFinalFrame: Bool

    /// 控制台和复制日志共用同一格式，不包含正文、标题或业务数据。
    public var logLine: String {
        func milliseconds(_ value: TimeInterval?) -> String {
            value.map { String(format: "%.1fms", $0 * 1_000) } ?? "-"
        }
        let reason = endReason?.rawValue ?? "-"
        let fps = gpuPresentedFramesPerSecond.map { String(format: "%.1f", $0) } ?? "unavailable"
        return "[PageTurn \(transitionID.uuidString.prefix(8)) #\(sequence)] \(event.rawValue) "
            + "effect=\(effect) direction=\(direction) progress=\(String(format: "%.3f", progress)) "
            + "duration=\(milliseconds(duration)) elapsed=\(milliseconds(animationElapsed)) wall=\(milliseconds(wallElapsed)) "
            + "from=\(startProgress.map { String(format: "%.3f", $0) } ?? "-") "
            + "to=\(targetProgress.map { String(format: "%.3f", $0) } ?? "-") "
            + "scale=\(String(format: "%.2f", durationScale)) curve=\(curve) queue=\(queueDepth) "
            + "updates=\(updateCount) submitted=\(gpuSubmissionCount) presented=\(gpuPresentationCount.map(String.init) ?? "-") "
            + "gpuFPS=\(fps) screenMax=\(maximumFramesPerSecond) requested=\(requestedFramesPerSecond.map(String.init) ?? "-") "
            + "prepare=\(milliseconds(preparationDuration)) pixels=\(snapshotPixels) cpu=\(milliseconds(frameCPUTime)) "
            + "finalWait=\(waitingForFinalFrame) reason=\(reason)"
    }
}

/// 帧间隔统计采用屏幕当前申请的预算，120Hz 对应约 8.33ms。
/// 仅用于诊断展示，不改变动画推进。
public struct ReaderFrameRateSummary: Sendable {
    public let sampleCount: Int
    public let framesPerSecond: Double?
    public let averageMilliseconds: Double?
    public let p95Milliseconds: Double?
    public let maximumMilliseconds: Double?
    public let overBudgetCount: Int
    public let estimatedMissedFrames: Int

    public init(intervals: [TimeInterval], targetFramesPerSecond: Int) {
        let valid = intervals.filter { $0.isFinite && $0 > 0 }
        sampleCount = valid.count
        guard !valid.isEmpty else {
            framesPerSecond = nil; averageMilliseconds = nil
            p95Milliseconds = nil; maximumMilliseconds = nil
            overBudgetCount = 0; estimatedMissedFrames = 0
            return
        }
        let sorted = valid.sorted()
        let average = valid.reduce(0, +) / Double(valid.count)
        framesPerSecond = 1 / average
        averageMilliseconds = average * 1_000
        p95Milliseconds = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))] * 1_000
        maximumMilliseconds = (sorted.last ?? 0) * 1_000
        let budget = 1 / Double(min(1_000, max(1, targetFramesPerSecond)))
        overBudgetCount = valid.filter { $0 > budget * 1.5 }.count
        estimatedMissedFrames = valid.reduce(0) { total, interval in
            // 微小调度抖动不算丢帧；约两倍预算的间隔记为少一帧。
            total + max(0, Int((min(interval, 10) / budget).rounded()) - 1)
        }
    }
}

/// 一整次翻页的累计帧统计；不丢弃早期尖峰，也不保存无界的逐帧数组。
public struct ReaderFrameRateTotals: Sendable {
    public let targetFramesPerSecond: Int
    public private(set) var sampleCount = 0
    public private(set) var overBudgetCount = 0
    public private(set) var estimatedMissedFrames = 0
    private var totalInterval: TimeInterval = 0
    private var maximumInterval: TimeInterval = 0

    public init(targetFramesPerSecond: Int) {
        self.targetFramesPerSecond = min(1_000, max(1, targetFramesPerSecond))
    }

    public var framesPerSecond: Double? { sampleCount > 0 ? Double(sampleCount) / totalInterval : nil }
    public var averageMilliseconds: Double? { sampleCount > 0 ? totalInterval / Double(sampleCount) * 1_000 : nil }
    public var maximumMilliseconds: Double? { sampleCount > 0 ? maximumInterval * 1_000 : nil }

    public mutating func record(_ interval: TimeInterval) {
        guard interval.isFinite, interval > 0, interval < Double.greatestFiniteMagnitude / 1_000,
              (totalInterval + interval).isFinite else { return }
        sampleCount += 1
        totalInterval += interval
        maximumInterval = max(maximumInterval, interval)
        let budget = 1 / Double(targetFramesPerSecond)
        if interval > budget * 1.5 { overBudgetCount += 1 }
        estimatedMissedFrames += max(0, Int((min(interval, 10) / budget).rounded()) - 1)
    }
}
