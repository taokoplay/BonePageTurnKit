import Foundation

public enum ContinuousFillPolicyError: Error, Equatable { case invalidCoverage, invalidBudget }

/// 仅约束自动补入需求，不接管宿主解析、游标或缓存；不裁剪已接受的窗口。
public struct ContinuousFillPolicy: Sendable, Equatable {
    public let leadingViewports: Double
    public let trailingViewports: Double
    public let maximumRequests: Int
    public let maximumNoProgressResults: Int
    public let maximumAddedItems: Int
    public static let standard = ContinuousFillPolicy(standard: ())

    /// - Parameters: leadingViewports: 视口前的可读余量；trailingViewports: 视口后的可读余量，均为 0...8 屏；maximumRequests: 每方向每补屏周期自动需求上限；maximumNoProgressResults: 连续无可读进展的安装上限；maximumAddedItems: 每方向周期内累计新增块上限。
    /// - Throws: 非有限／越界余量或非正预算。
    public init(leadingViewports: Double = 1, trailingViewports: Double = 1,
                maximumRequests: Int = 16, maximumNoProgressResults: Int = 2, maximumAddedItems: Int = 256) throws {
        guard leadingViewports.isFinite, trailingViewports.isFinite,
              (0...8).contains(leadingViewports), (0...8).contains(trailingViewports) else {
            throw ContinuousFillPolicyError.invalidCoverage
        }
        guard maximumRequests > 0, maximumNoProgressResults > 0, maximumAddedItems > 0 else {
            throw ContinuousFillPolicyError.invalidBudget
        }
        self.leadingViewports = leadingViewports
        self.trailingViewports = trailingViewports
        self.maximumRequests = maximumRequests
        self.maximumNoProgressResults = maximumNoProgressResults
        self.maximumAddedItems = maximumAddedItems
    }

    private init(standard: Void) {
        leadingViewports = 1
        trailingViewports = 1
        maximumRequests = 16
        maximumNoProgressResults = 2
        maximumAddedItems = 256
    }
}

public struct ContinuousContentObstruction: Sendable, Equatable {
    public let identity: PageItemIdentity
    public let state: ContinuousContentState
}

/// 已就绪内容的几何覆盖。占位仍占布局空间，但其高度不计入可读覆盖。
public struct ContinuousReadableCoverage: Sendable, Equatable {
    public let viewportOffset: Double
    public let viewportExtent: Double
    public let visibleReadyExtent: Double
    public let contiguousReadyBefore: Double
    public let contiguousReadyFromTop: Double
    public let previousObstruction: ContinuousContentObstruction?
    public let nextObstruction: ContinuousContentObstruction?
    public var missingVisibleExtent: Double { max(0, viewportExtent - visibleReadyExtent) }
    public var coversViewport: Bool { missingVisibleExtent < 0.001 }
}

public enum ContinuousLoadTarget: Sendable, Equatable {
    /// 方向对应的窗口外内容；游标由宿主保存，不把数据页数量当作屏幕数量。
    case edge
    /// 窗口内尚未就绪的内容，优先补齐它，不跳过它预取更远的内容。
    case item(PageItemIdentity)
}

public struct ContinuousContentDemand: Sendable, Equatable {
    public let direction: PageTurnDirection
    public let target: ContinuousLoadTarget
    public let token: ContinuousUpdateToken
    public let coverage: ContinuousReadableCoverage
    public let missingReadyExtent: Double
}

public enum ContinuousFillLimit: Sendable, Equatable {
    case requestBudget
    case noReadableProgress
    case addedItemBudget
}

/// 自动需求的有界策略状态；实际 I/O 及安装所有权仍由 ContinuousLoadCoordinator 管理。
internal struct ContinuousFillController {
    private struct Counter {
        var requests = 0
        var noProgress = 0
        var addedItems = 0
        var lastDemand: ContinuousContentDemand?
        var pending: ContinuousContentDemand?
        var limit: ContinuousFillLimit?
        var reportedLimit: ContinuousFillLimit?
    }
    private var counters: [PageTurnDirection: Counter] = [:]

    /// - Parameter direction: 逻辑加载方向。
    /// - Returns: 当前自动补入暂停原因；手动任务仍可登记。
    func limit(in direction: PageTurnDirection) -> ContinuousFillLimit? { counters[direction]?.limit }

    /// 开始新的补屏周期；不触碰宿主任务。
    mutating func reset() { counters.removeAll() }

    /// - Parameters: demand: 当前几何需求；policy: 本次周期预算。
    /// - Returns: 是否可以交付新需求；同方向同令牌同目标不会重复发送。
    mutating func admit(_ demand: ContinuousContentDemand, policy: ContinuousFillPolicy) -> Bool {
        var counter = counters[demand.direction] ?? Counter()
        if let last = counter.lastDemand, last.token == demand.token, last.target == demand.target { return false }
        guard counter.limit == nil else { return false }
        if counter.noProgress >= policy.maximumNoProgressResults { counter.limit = .noReadableProgress }
        else if counter.requests >= policy.maximumRequests { counter.limit = .requestBudget }
        else if counter.addedItems >= policy.maximumAddedItems { counter.limit = .addedItemBudget }
        if counter.limit != nil { counters[demand.direction] = counter; return false }
        counter.requests += 1
        counter.lastDemand = demand
        counter.pending = demand
        counters[demand.direction] = counter
        return true
    }

    /// - Parameter direction: 查询方向。
    /// - Returns: 本周期尚未通知的限额；通知前先标记，防止同步重入重复报告。
    mutating func takeUnreportedLimit(in direction: PageTurnDirection) -> ContinuousFillLimit? {
        guard var counter = counters[direction], let limit = counter.limit, counter.reportedLimit != limit else { return nil }
        counter.reportedLimit = limit
        counters[direction] = counter
        return limit
    }

    /// 对实际安装的窗口记账；改修订号、元数据或占位高度不算可读进展。
    /// - Parameters: old: 原窗口；new: 安装窗口；token: 安装前令牌；owner: 本次票据方向，nil 为宿主直接安装；anchor: 安装前实际可见锚点。
    mutating func installed(from old: ContinuousWindow, to new: ContinuousWindow, token: ContinuousUpdateToken,
                            owner: PageTurnDirection?, anchor: ContinuousAnchor?) {
        let oldIDs = Set(old.items.map { $0.identity.unitID })
        let added = new.items.reduce(0) { $0 + (oldIDs.contains($1.identity.unitID) ? 0 : 1) }
        for direction in [PageTurnDirection.previous, .next] {
            guard var counter = counters[direction] else { continue }
            let pending = counter.pending
            let consumesDemand = pending?.token == token && (owner == nil || owner == direction)
            if pending?.token == token { counter.pending = nil }
            let baseline = consumesDemand ? old.anchor(at: pending?.coverage.viewportOffset ?? 0,
                                                       viewportExtent: pending?.coverage.viewportExtent ?? 1) : anchor
            var advanced = false
            if let baseline,
               let before = old.readyDistance(from: baseline, direction: direction),
               let after = new.readyDistance(from: baseline, direction: direction) {
                advanced = after > before + 0.001
            }
            if consumesDemand, case .item(let identity) = pending?.target,
               let replacement = new.item(withID: identity.unitID), replacement.state == .ready {
                advanced = true
            }
            if consumesDemand {
                counter.noProgress = advanced ? 0 : min(Int.max - 1, counter.noProgress) + 1
                counter.addedItems = min(Int.max - added, counter.addedItems) + added
            } else if advanced, counter.limit == .noReadableProgress {
                // 外部真实数据回填可解除无进展阻塞；请求量／新增量预算仍需新周期。
                counter.noProgress = 0
                counter.limit = nil
                counter.reportedLimit = nil
            }
            counters[direction] = counter
        }
    }
}

extension ContinuousFillController {
    /// - Parameters: direction: 宿主登记任务的方向；token: 本次窗口版本。
    /// - Returns: 最近已发出但尚未安装的需求目标；手动无对应需求时 nil。
    internal func pendingTarget(in direction: PageTurnDirection, token: ContinuousUpdateToken) -> ContinuousLoadTarget? {
        guard let pending = counters[direction]?.pending, pending.token == token else { return nil }
        return pending.target
    }
}
