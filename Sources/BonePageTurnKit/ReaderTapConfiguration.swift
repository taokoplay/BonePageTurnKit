import Foundation

/// 点击分区只表达阅读交互意图，中心区域的具体业务由宿主决定。
public enum ReaderTapAction: Sendable, Equatable {
    case previous
    case next
    case center
    case ignored
}

/// 点击分区参数必须有限、有序且位于归一化范围内。
public enum ReaderTapConfigurationError: Error, Sendable, Equatable {
    case invalidRegions
}

/// 沿分页轴划分上一页、中心和下一页区域，允许任一区域为空。
public struct ReaderTapConfiguration: Sendable, Equatable {
    public let previousEnd: Double
    public let nextStart: Double

    /// - Parameters: previousEnd: 上一页区域的开区间终点；nextStart: 下一页区域的闭区间起点。
    /// - Throws: 参数非有限，或不满足 0 ≤ previousEnd ≤ nextStart ≤ 1。
    public init(previousEnd: Double = 1.0 / 3, nextStart: Double = 2.0 / 3) throws {
        guard previousEnd.isFinite, nextStart.isFinite,
              0 <= previousEnd, previousEnd <= nextStart, nextStart <= 1 else {
            throw ReaderTapConfigurationError.invalidRegions
        }
        self.previousEnd = previousEnd
        self.nextStart = nextStart
    }

    /// - Parameter fraction: 沿分页轴从最小端起算的归一化位置。
    /// - Returns: 对应分区意图；非有限或越界位置忽略。即使 nextStart 为 1，端点 1 仍属于下一页。
    public func action(at fraction: Double) -> ReaderTapAction {
        guard fraction.isFinite, (0...1).contains(fraction) else { return .ignored }
        if fraction < previousEnd { return .previous }
        if fraction < nextStart { return .center }
        return .next
    }
}
