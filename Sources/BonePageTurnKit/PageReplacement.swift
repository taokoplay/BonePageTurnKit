import Foundation

/// 当前页重绑定事件，独立于 previous／next 翻页事务。
public struct PageReplacement: Sendable, Equatable {
    public let id: UUID
    public let previousBinding: PageViewBinding
    public let installedBinding: PageViewBinding

    /// - Parameters: previousBinding: 原内容绑定；installedBinding: 实际安装的新绑定。
    internal init(previousBinding: PageViewBinding, installedBinding: PageViewBinding) {
        id = UUID()
        self.previousBinding = previousBinding
        self.installedBinding = installedBinding
    }
}

/// 仅表示 SDK 已接受一次延期替换；终态通过 completion 交付。
public struct PageReplacementTicket: Sendable, Equatable {
    public let id: UUID
    public let expectedBinding: PageViewBinding

    /// - Parameter expectedBinding: 请求开始时的当前页绑定。
    internal init(expectedBinding: PageViewBinding) {
        id = UUID()
        self.expectedBinding = expectedBinding
    }
}

public enum PageReplacementOutcome: Sendable, Equatable {
    case installed(PageViewBinding)
    case superseded
    case cancelled
    case invalidated
    case rejected(PageTurnError)
}
