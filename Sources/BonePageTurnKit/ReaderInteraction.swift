import Foundation

/// 连续自动阅读的实际运行状态；暂停保留用户意图，等待不会冒充全书结束。
public enum ContinuousAutomaticReadingState: Sendable, Equatable {
    case stopped
    case running
    case paused
    case waiting(ReaderBoundaryState)
    case finished(ReaderBoundaryState)
}

public enum ContinuousAutomaticReadingError: Error, Equatable {
    /// 速度必须为有限值，范围 (0, 2000] point/s。
    case invalidSpeed
}

/// 可取消退出的会话凭据；只能由容器创建，旧退出回调不能结束新会话。
public struct ReaderExitToken: Sendable, Equatable {
    let id: UUID
    internal init() { id = UUID() }
}

/// 分页自动阅读状态；running 表示本页计时，turning 表示已开始的翻页事务。
public enum PagedAutomaticReadingState: Sendable, Equatable {
    case stopped
    case running
    case paused
    case turning
    case waiting(ReaderBoundaryState)
    case finished(ReaderBoundaryState)
}

public enum PagedAutomaticReadingError: Error, Equatable {
    /// 每页停留时间必须为有限的 0.1...3600 秒，不包括动画时间。
    case invalidInterval
}
