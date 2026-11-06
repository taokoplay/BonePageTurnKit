import Foundation

/// 内容阅读顺序由宿主显式选择，不从系统界面 RTL 推断；纵向布局始终从上到下。
public enum ReaderReadingOrder: Sendable, Equatable { case leftToRight, rightToLeft }

/// 一个分页展示单元承载单页或两个真实子页；与翻页效果、轴向分别配置。
public enum ReaderPageLayout: Sendable, Equatable { case single, spread }

public enum ReaderSpreadError: Error, Equatable { case invalidPageCount, indexOutOfBounds }

/// 双页中的逻辑先后页索引；nil 表示封面旁或书尾的真实空白位置，不占源页码。
public struct ReaderSpreadIndices: Sendable, Equatable {
    public let first: Int?
    public let second: Int?
}

/// 只负责源页索引分组，不解析或加载内容。用按需查询避免为长书分配整组数组。
public struct ReaderSpreadLayout: Sendable, Equatable {
    public let pageCount: Int
    public let firstPageIsCover: Bool
    public var spreadCount: Int {
        if pageCount == 0 { return 0 }
        if firstPageIsCover { return 1 + (pageCount - 1) / 2 + (pageCount - 1) % 2 }
        return pageCount / 2 + pageCount % 2
    }

    /// - Parameters: pageCount: 非负源页总数；firstPageIsCover: 封面放逻辑第二侧，另一侧留白。
    /// - Throws: 页数为负。
    public init(pageCount: Int, firstPageIsCover: Bool = true) throws {
        guard pageCount >= 0 else { throw ReaderSpreadError.invalidPageCount }
        self.pageCount = pageCount
        self.firstPageIsCover = firstPageIsCover
    }

    /// - Parameter index: 从零开始的双页组索引。
    /// - Returns: 一组源页索引，未配对的书尾第二侧为空。
    /// - Throws: 不在组数范围内。
    public func spread(at index: Int) throws -> ReaderSpreadIndices {
        guard index >= 0, index < spreadCount else { throw ReaderSpreadError.indexOutOfBounds }
        if firstPageIsCover, index == 0 { return .init(first: nil, second: 0) }
        let first = firstPageIsCover ? (index - 1) * 2 + 1 : index * 2
        return .init(first: first, second: first < pageCount - 1 ? first + 1 : nil)
    }

    /// - Parameter page: 从零开始的源页索引。
    /// - Returns: 包含该源页的双页组索引；切换单双页时宿主可借此保持源位置。
    /// - Throws: 源页索引越界。
    public func spreadIndex(containingPage page: Int) throws -> Int {
        guard page >= 0, page < pageCount else { throw ReaderSpreadError.indexOutOfBounds }
        if firstPageIsCover { return page == 0 ? 0 : 1 + (page - 1) / 2 }
        return page / 2
    }
}
