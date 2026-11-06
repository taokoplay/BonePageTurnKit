import Foundation

public enum ContinuousContentState: Sendable, Equatable { case loading, ready, failed }
/// 保留既有名称；分页与连续模式使用相同边界语义。
public typealias ContinuousBoundaryState = ReaderBoundaryState

/// 窗口只保存中性元数据；正文、图片、排版结果和任务属于宿主。
public struct ContinuousItem: Sendable, Equatable {
    public let identity: PageItemIdentity
    public let sectionID: String
    /// 从本块原点到下一块原点的最终占用高度，包含仅计算一次的跨块行／段落间隔。
    /// 不应包含固定分页的页眉页脚或填满整屏的空白；SDK 不额外叠加块间距。
    public let extent: Double
    public let reuseIdentifier: String
    public let state: ContinuousContentState
    public let pagination: ReaderPagination

    /// - Parameters: identity: 稳定身份；sectionID: 章节标识；extent: 正有限高度；reuseIdentifier: 复用类别；state: 内容状态；pagination: 宿主提供的页码与总数，不能由窗口块数推断。
    public init(identity: PageItemIdentity, sectionID: String, extent: Double,
                reuseIdentifier: String = "content", state: ContinuousContentState = .ready,
                pagination: ReaderPagination = .init()) {
        self.identity = identity
        self.sectionID = sectionID
        self.extent = extent
        self.reuseIdentifier = reuseIdentifier
        self.state = state
        self.pagination = pagination
    }
}

/// 当前布局下的展示锚点。跨重排／模式时由宿主转换为语义位置后重新解析。
public struct ContinuousAnchor: Sendable, Equatable {
    public let identity: PageItemIdentity
    public let offsetInItem: Double
    public let viewportOffset: Double

    /// - Parameters: identity: 锚点身份及版本；offsetInItem: 块内偏移；viewportOffset: 锚点相对视口顶部的距离。
    public init(identity: PageItemIdentity, offsetInItem: Double, viewportOffset: Double = 0) {
        self.identity = identity
        self.offsetInItem = offsetInItem
        self.viewportOffset = viewportOffset
    }
}

/// 不可变窗口与累计几何；UIKit 与纯逻辑测试共用同一算法。
public struct ContinuousWindow: Sendable, Equatable {
    public let items: [ContinuousItem]
    public let before: ContinuousBoundaryState
    public let after: ContinuousBoundaryState
    public let totalExtent: Double
    private let starts: [Double]
    private let indices: [String: Int]
    private let unreadyIndices: [Int]
    private let readyPrefix: [Double]

    /// 创建一致窗口，拒绝空窗口、重复 ID、非有限或非正高度。
    /// - Parameters: items: 沿内容顺序的块；before: 前边界；after: 后边界。
    /// - Throws: 无效窗口或几何错误。
    public init(items: [ContinuousItem], before: ContinuousBoundaryState = .end,
                after: ContinuousBoundaryState = .end) throws {
        guard !items.isEmpty else { throw PageTurnError.invalidWindow }
        var starts: [Double] = []
        var indices: [String: Int] = [:]
        var total: Double = 0
        var unreadyIndices: [Int] = []
        var readyPrefix: [Double] = [0]
        for (index, item) in items.enumerated() {
            let id = item.identity.unitID
            guard indices[id] == nil else { throw PageTurnError.duplicateUnitID(id) }
            guard item.extent.isFinite, item.extent > 0, (total + item.extent).isFinite,
                  total + item.extent > total else { throw PageTurnError.invalidExtent(id) }
            indices[id] = index
            starts.append(total)
            if item.state != .ready { unreadyIndices.append(index) }
            total += item.extent
            readyPrefix.append((readyPrefix.last ?? 0) + (item.state == .ready ? item.extent : 0))
        }
        self.items = items
        self.before = before
        self.after = after
        self.starts = starts
        self.indices = indices
        self.unreadyIndices = unreadyIndices
        self.readyPrefix = readyPrefix
        totalExtent = total
    }

    /// - Parameter unitID: 展示单元 ID。
    /// - Returns: 单元的内容坐标；不存在则 nil。
    public func origin(of unitID: String) -> Double? {
        indices[unitID].map { starts[$0] }
    }

    /// - Parameters: offset: 内容偏移；viewportExtent: 视口高度。
    /// - Returns: 去掉回弹后的合法偏移。
    public func clampedOffset(_ offset: Double, viewportExtent: Double) -> Double {
        guard offset.isFinite, viewportExtent.isFinite, viewportExtent > 0 else { return 0 }
        return min(max(0, offset), max(0, totalExtent - viewportExtent))
    }

    /// - Parameters: offset: 内容偏移；viewportExtent: 视口高度。
    /// - Returns: 视口顶部的有效锚点；无有效视口时 nil。
    public func anchor(at offset: Double, viewportExtent: Double) -> ContinuousAnchor? {
        guard offset.isFinite, viewportExtent.isFinite, viewportExtent > 0 else { return nil }
        let position = clampedOffset(offset, viewportExtent: viewportExtent)
        let index = index(containing: position)
        return ContinuousAnchor(identity: items[index].identity, offsetInItem: position - starts[index])
    }

    /// 校验不依赖视口的锚点身份与几何，允许首次布局前准备安装。
    /// - Parameter anchor: 将要恢复的当前布局锚点。
    /// - Throws: 身份、版本或块内位置不合法。
    public func validate(_ anchor: ContinuousAnchor) throws {
        guard let index = indices[anchor.identity.unitID], items[index].identity == anchor.identity,
              anchor.offsetInItem.isFinite, anchor.offsetInItem >= 0,
              anchor.offsetInItem < items[index].extent,
              anchor.viewportOffset.isFinite, anchor.viewportOffset >= 0 else {
            throw PageTurnError.anchorUnavailable
        }
    }

    /// 只有相同身份与版本才允许复用像素偏移；边缘会受到可滚动范围约束。
    /// - Parameters: anchor: 本布局的锚点；viewportExtent: 视口高度。
    /// - Returns: 恢复后的内容偏移。
    /// - Throws: 锚点缺失、版本不符、块内偏移越界或非法几何。
    public func offset(for anchor: ContinuousAnchor, viewportExtent: Double) throws -> Double {
        try validate(anchor)
        guard let index = indices[anchor.identity.unitID],
              viewportExtent.isFinite, viewportExtent > 0, anchor.viewportOffset < viewportExtent else {
            throw PageTurnError.anchorUnavailable
        }
        return clampedOffset(starts[index] + anchor.offsetInItem - anchor.viewportOffset,
                             viewportExtent: viewportExtent)
    }

    /// 检查旧结果及同版本 ready 内容的状态倒退；调用方另校验窗口请求令牌。
    /// - Parameter previous: 当前已安装窗口。
    /// - Throws: 同 ID 的源变化、版本倒退或 ready 被同版本占位／错误覆盖。
    public func validateReplacement(of previous: ContinuousWindow) throws {
        for item in items {
            guard let oldIndex = previous.indices[item.identity.unitID] else { continue }
            let old = previous.items[oldIndex]
            guard old.identity.sourceID == item.identity.sourceID,
                  item.identity.contentVersion >= old.identity.contentVersion,
                  item.identity.layoutVersion >= old.identity.layoutVersion else {
                throw PageTurnError.staleContent(item.identity.unitID)
            }
            if item.identity == old.identity, old.state == .ready, item.state != .ready {
                throw PageTurnError.staleContent(item.identity.unitID)
            }
        }
    }

    /// 从窗口几何构造阅读状态；连续页码采用顶部可读块，只有滚动到真实边缘才报告最新／末尾。
    /// - Parameters: offset: 当前内容偏移；viewportExtent: 实际视口高度；presentationID: renderer 代际。
    /// - Returns: 未完成内容不提供虚假页码，回弹期间不宣布到达书籍边界。
    public func readingStatus(at offset: Double, viewportExtent: Double, presentationID: UUID) -> ReaderStatus? {
        guard let anchor = anchor(at: offset, viewportExtent: viewportExtent),
              let first = indices[anchor.identity.unitID] else { return nil }
        let clamped = clampedOffset(offset, viewportExtent: viewportExtent)
        let inBounds = abs(clamped - offset) < 0.5
        let leading: ReaderBoundaryState = inBounds && clamped < 0.5 ? before : .available
        let last = items[items.count - 1]
        let trailing: ReaderBoundaryState
        if inBounds, totalExtent - clamped - viewportExtent < 0.5 {
            switch last.state {
            case .loading: trailing = .loading
            case .failed: trailing = .failed
            case .ready: trailing = after
            }
        } else {
            trailing = .available
        }
        return ReaderStatus(presentationID: presentationID, identity: anchor.identity,
                            info: .init(pagination: items[first].state == .ready ? items[first].pagination : .init(),
                                        before: leading, after: trailing))
    }

    /// - Parameter unitID: 稳定展示单元 ID。
    /// - Returns: 当前窗口元数据；不存在时 nil，不读取宿主内容缓存。
    public func item(withID unitID: String) -> ContinuousItem? { indices[unitID].map { items[$0] } }

    /// 查询实际可读覆盖，未就绪内容占布局空间但不贡献可读高度。
    /// - Parameters: offset: 当前内容偏移；viewportExtent: 正文视口高度。
    /// - Returns: 当前覆盖与最近的阻塞块；非法视口返回 nil。查询复杂度 O(log n)。
    public func readableCoverage(at offset: Double, viewportExtent: Double) -> ContinuousReadableCoverage? {
        guard offset.isFinite, viewportExtent.isFinite, viewportExtent > 0 else { return nil }
        let top = clampedOffset(offset, viewportExtent: viewportExtent)
        let span = readySpan(at: top)
        let visible = readyIntegral(at: min(totalExtent, top + viewportExtent)) - readyIntegral(at: top)
        return ContinuousReadableCoverage(viewportOffset: top, viewportExtent: viewportExtent,
                                          visibleReadyExtent: visible, contiguousReadyBefore: span.before,
                                          contiguousReadyFromTop: span.after,
                                          previousObstruction: span.previous.map { .init(identity: items[$0].identity, state: items[$0].state) },
                                          nextObstruction: span.next.map { .init(identity: items[$0].identity, state: items[$0].state) })
    }

    /// 按可读高度提出需求，优先填补当前视口内缺口；失败块等待显式重试，不自动反复拉取。
    /// - Parameters: offset: 内容偏移；viewportExtent: 实际高度；token: 当前安装版本；policy: 目标前后可读余量。
    /// - Returns: 最多两个方向的需求；视口内有占位时优先且只返回该占位需求。
    public func contentDemands(at offset: Double, viewportExtent: Double, token: ContinuousUpdateToken,
                               policy: ContinuousFillPolicy = .standard) -> [ContinuousContentDemand] {
        guard let coverage = readableCoverage(at: offset, viewportExtent: viewportExtent) else { return [] }
        let forwardMissing = max(0, viewportExtent * (1 + policy.trailingViewports) - coverage.contiguousReadyFromTop)
        func demand(_ direction: PageTurnDirection, missing: Double,
                    obstruction: ContinuousContentObstruction?, boundary: ReaderBoundaryState) -> ContinuousContentDemand? {
            guard missing > 0.001 else { return nil }
            let target: ContinuousLoadTarget
            if let obstruction {
                guard obstruction.state == .loading else { return nil }
                target = .item(obstruction.identity)
            } else {
                guard boundary == .available else { return nil }
                target = .edge
            }
            return .init(direction: direction, target: target, token: token,
                         coverage: coverage, missingReadyExtent: missing)
        }
        let next = demand(.next, missing: forwardMissing, obstruction: coverage.nextObstruction, boundary: after)
        // 不为已有占位继续向更远处扩窗；一屏不足时优先向后补，再考虑向前补。
        if coverage.contiguousReadyFromTop < viewportExtent - 0.001,
           coverage.nextObstruction != nil || next != nil { return next.map { [$0] } ?? [] }
        let visibleFallback = next == nil && coverage.nextObstruction == nil ? coverage.missingVisibleExtent : 0
        let backwardMissing = max(0, viewportExtent * policy.leadingViewports + visibleFallback - coverage.contiguousReadyBefore)
        let previous = demand(.previous, missing: backwardMissing, obstruction: coverage.previousObstruction, boundary: before)
        if let next, let previous, next.target == previous.target, case .item = next.target { return [next] }
        return [previous, next].compactMap { $0 }
    }

    /// - Parameters: anchor: 安装前锚点；direction: 要比较的读取方向。
    /// - Returns: 相对同一稳定位置的连续可读距离；不能解析相同身份时 nil。
    internal func readyDistance(from anchor: ContinuousAnchor, direction: PageTurnDirection) -> Double? {
        guard let index = indices[anchor.identity.unitID], items[index].identity == anchor.identity,
              anchor.offsetInItem >= 0, anchor.offsetInItem < items[index].extent else { return nil }
        let span = readySpan(at: starts[index] + anchor.offsetInItem)
        return direction == .previous ? span.before : span.after
    }

    /// - Parameter position: 当前有效内容坐标。
    /// - Returns: 两侧连续 ready 距离及最近未就绪单元索引。
    private func readySpan(at position: Double) -> (before: Double, after: Double, previous: Int?, next: Int?) {
        let current = index(containing: position)
        let nextSlot = unreadyLowerBound(current)
        let next = nextSlot < unreadyIndices.count ? unreadyIndices[nextSlot] : nil
        let priorIndex = position > starts[current] ? current : current - 1
        let priorSlot = unreadyLowerBound(priorIndex + 1) - 1
        let previous = priorSlot >= 0 ? unreadyIndices[priorSlot] : nil
        let lower = previous.map { starts[$0] + items[$0].extent } ?? 0
        let upper = next.map { starts[$0] } ?? totalExtent
        return (max(0, position - lower), max(0, upper - position), previous, next)
    }

    /// - Parameter itemIndex: 当前布局索引。
    /// - Returns: 第一个大于等于该索引的未就绪条目位置。
    private func unreadyLowerBound(_ itemIndex: Int) -> Int {
        var lower = 0
        var upper = unreadyIndices.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if unreadyIndices[middle] < itemIndex { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    /// - Parameter position: 内容坐标，超出范围钳制。
    /// - Returns: 原点到该位置的 ready 高度积分。
    private func readyIntegral(at position: Double) -> Double {
        let point = min(totalExtent, max(0, position))
        let index = index(containing: point)
        return readyPrefix[index] + (items[index].state == .ready ? point - starts[index] : 0)
    }

    /// 自动阅读只能推进已就绪的连续区间，不越过窗口内未完成的内容。
    /// - Parameters: offset: 当前偏移；viewportExtent: 实际视口高度。
    /// - Returns: 可到达的最大偏移及在那里等待／结束的原因；查询复杂度 O(log n)。
    internal func automaticReadingLimit(at offset: Double, viewportExtent: Double) -> (offset: Double, boundary: ReaderBoundaryState) {
        let current = clampedOffset(offset, viewportExtent: viewportExtent)
        let first = index(containing: current)
        var low = 0
        var high = unreadyIndices.count
        while low < high {
            let middle = (low + high) / 2
            if unreadyIndices[middle] < first { low = middle + 1 } else { high = middle }
        }
        if low < unreadyIndices.count {
            let blocked = unreadyIndices[low]
            return (max(current, starts[blocked] - viewportExtent), items[blocked].state == .loading ? .loading : .failed)
        }
        return (max(0, totalExtent - viewportExtent), after)
    }

    /// - Parameters: lower: 内容区间下界；upper: 内容区间上界。
    /// - Returns: 与区间相交的索引；可见之外的视图无需创建。
    public func indices(intersecting lower: Double, _ upper: Double) -> Range<Int> {
        guard lower.isFinite, upper.isFinite, upper > lower, upper > 0, lower < totalExtent else { return 0..<0 }
        let first = index(containing: max(0, lower))
        var end = index(containing: min(totalExtent, upper))
        if starts[end] < upper { end += 1 }
        return first..<max(first, end)
    }

    /// - Parameter position: 内容坐标。
    /// - Returns: 半开区间中包含该坐标的单元索引。
    private func index(containing position: Double) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= position { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
