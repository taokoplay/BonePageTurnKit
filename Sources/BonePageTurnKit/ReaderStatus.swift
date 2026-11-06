import Foundation

/// 书籍内容边界与加载状态。end 仅表示所供窗口结束，不能据此宣布全书完结。
public enum ReaderBoundaryState: Sendable, Equatable {
    case unknown
    case available
    case loading
    case failed
    case end
    case startOfBook
    case endOfSection(String)
    case endOfBook
    case latestAvailable
}

/// 确定总数仅针对当前内容／布局快照；连载仍可能产生新快照。
public enum ReaderPageTotal: Sendable, Equatable {
    case unknown
    case estimated(Int)
    case exact(Int)
}

/// 连续内容块与页面分别计数，宿主不能把块数冒充排版页数。
public enum ReaderCountingUnit: Sendable, Equatable {
    case layoutPage
    case sourcePage
    case contentBlock
}

public enum ReaderPaginationError: Error, Equatable {
    case invalidCurrentPage
    case invalidTotal
    case currentExceedsTotal
    case emptySectionID
}

/// 页码面向用户，从 1 开始；尚未完成排版时 current 和 total 可以未知。
public struct ReaderPageMetrics: Sendable, Equatable {
    public let current: Int?
    public let total: ReaderPageTotal
    public let unit: ReaderCountingUnit

    /// - Parameters: current: 从 1 开始的当前页／块号；total: 未知、估算或确定总数；unit: 计数口径。
    /// - Throws: 非正页码、负数总数，或当前页大于确定总数。估算总数可暂低于当前页。
    public init(current: Int?, total: ReaderPageTotal = .unknown, unit: ReaderCountingUnit = .layoutPage) throws {
        if let current, current < 1 { throw ReaderPaginationError.invalidCurrentPage }
        switch total {
        case .unknown: break
        case .estimated(let count):
            guard count >= 0 else { throw ReaderPaginationError.invalidTotal }
        case .exact(let count):
            guard count >= 0 else { throw ReaderPaginationError.invalidTotal }
            if let current, current > count { throw ReaderPaginationError.currentExceedsTotal }
        }
        self.current = current
        self.total = total
        self.unit = unit
    }

    public var isFirst: Bool { current == 1 }
    /// 只表示当前计数范围的最后一项，不等于全书完结，更不表示用户已读完。
    public var isLast: Bool {
        guard let current, case .exact(let count) = total else { return false }
        return count > 0 && current == count
    }
}

public struct ReaderSectionPagination: Sendable, Equatable {
    public let sectionID: String
    public let pages: ReaderPageMetrics

    /// - Parameters: sectionID: 稳定章节 ID；pages: 本章计数。
    /// - Throws: 空章节 ID。
    public init(sectionID: String, pages: ReaderPageMetrics) throws {
        guard !sectionID.isEmpty else { throw ReaderPaginationError.emptySectionID }
        self.sectionID = sectionID
        self.pages = pages
    }
}

/// 元数据由宿主排版或目录适配器提供，跟随 PageItemIdentity 的内容和布局版本。
public struct ReaderPagination: Sendable, Equatable {
    public let book: ReaderPageMetrics?
    public let section: ReaderSectionPagination?

    /// - Parameters: book: 全书当前快照计数，nil 为未提供；section: 本章计数，nil 为未提供。
    public init(book: ReaderPageMetrics? = nil, section: ReaderSectionPagination? = nil) {
        self.book = book
        self.section = section
    }

    /// 尺寸变化时排除旧排版页计数，独立的源页与块计数仍然有效。
    internal var excludingLayoutPages: ReaderPagination {
        ReaderPagination(book: book?.unit == .layoutPage ? nil : book,
                         section: section?.pages.unit == .layoutPage ? nil : section)
    }
}

public struct ReaderPageInfo: Sendable, Equatable {
    public let pagination: ReaderPagination
    public let before: ReaderBoundaryState
    public let after: ReaderBoundaryState

    /// - Parameters: pagination: 本页计数；before: 前向边界；after: 后向边界，最新页与全书末页应显式区分。
    public init(pagination: ReaderPagination = .init(), before: ReaderBoundaryState = .unknown,
                after: ReaderBoundaryState = .unknown) {
        self.pagination = pagination
        self.before = before
        self.after = after
    }
}

/// SDK 发布的当前阅读状态。连续模式页码取视口顶部内容，尾部状态取真实滚动边缘，两者不强行等同。
public struct ReaderStatus: Sendable, Equatable {
    public let presentationID: UUID
    public let identity: PageItemIdentity
    public let pagination: ReaderPagination
    public let before: ReaderBoundaryState
    public let after: ReaderBoundaryState

    /// - Parameters: presentationID: 当前 renderer 代际；identity: 当前页／顶部块；info: 与该身份匹配的计数与当前可达边界。
    public init(presentationID: UUID, identity: PageItemIdentity, info: ReaderPageInfo) {
        self.presentationID = presentationID
        self.identity = identity
        pagination = info.pagination
        before = info.before
        after = info.after
    }

    public var isAtBookStart: Bool { before == .startOfBook }
    public var hasReachedBookEnd: Bool { after == .endOfBook }
    public var hasReachedLatestAvailable: Bool { after == .latestAvailable }
}
