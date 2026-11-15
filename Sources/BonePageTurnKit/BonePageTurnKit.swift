import Foundation

/// 动画效果与几何轴独立；可构造不代表后端已支持。
public enum PageTurnEffect: Sendable, Equatable { case none, slide, cover, curl, arch }
public enum PageTurnAxis: Sendable, Equatable { case horizontal, vertical }
public enum PageTurnDirection: Sendable, Hashable { case previous, next }
public enum PageSpinePlacement: Sendable, Equatable { case automatic, minimum, center, maximum }
public enum PageTurnPresentation: Sendable, Equatable {
    case paged(effect: PageTurnEffect, axis: PageTurnAxis)
    case continuous(axis: PageTurnAxis)
}

public enum PageTurnError: Error, Equatable {
    case unsupportedPresentation
    case unsupportedSpine
    case wrongPresentation
    case invalidWindow
    case duplicateUnitID(String)
    case invalidExtent(String)
    case staleContent(String)
    case anchorUnavailable
    case stalePresentation
    case staleWindow
    case interactionInProgress
    case invalidPageController
    case inactive
    case invalidPaperOptions
    case snapshotUnavailable
    case unsupportedLayout
    case invalidPageLayout
    case invalidInteractionPoint
}

public struct PageTurnConfiguration: Sendable, Equatable {
    public let presentation: PageTurnPresentation
    public let spine: PageSpinePlacement
    public let layout: ReaderPageLayout
    public let readingOrder: ReaderReadingOrder

    public let paper: PaperRenderingOptions
    public let cover: CoverRenderingOptions
    /// 创建配置值；安装前调用 validate()，失败时不修改当前展示。
    /// - Parameters: presentation: 展示方式；spine: 纸张书脊；paper: 快照预算；layout: 单页或双页；readingOrder: 显式内容顺序；cover: 覆盖翻页的瞬时圆角与阴影。
    public init(presentation: PageTurnPresentation, spine: PageSpinePlacement = .automatic,
                paper: PaperRenderingOptions = .standard, layout: ReaderPageLayout = .single,
                readingOrder: ReaderReadingOrder = .leftToRight, cover: CoverRenderingOptions = .standard) {
        self.presentation = presentation
        self.spine = spine
        self.paper = paper
        self.layout = layout
        self.readingOrder = readingOrder
        self.cover = cover
    }

    /// 校验实际支持的效果、轴向与单双页配置；双页纸张使用中央书脊。
    /// - Throws: 不支持的展示、书脊、纸张预算或 CoverRenderingError 装饰参数错误。
    public func validate() throws {
        guard Self.supportedPresentations.contains(presentation) else {
            throw PageTurnError.unsupportedPresentation
        }
        if case .continuous = presentation, layout != .single { throw PageTurnError.unsupportedLayout }
        guard Self.supportedSpines(for: presentation, layout: layout).contains(spine) else { throw PageTurnError.unsupportedSpine }
        try paper.validate()
        try cover.validate()
    }

    public static let supportedPresentations: [PageTurnPresentation] = [
        .paged(effect: .none, axis: .horizontal),
        .paged(effect: .none, axis: .vertical),
        .paged(effect: .cover, axis: .horizontal),
        .paged(effect: .slide, axis: .horizontal),
        .paged(effect: .slide, axis: .vertical),
        .paged(effect: .curl, axis: .horizontal),
        .paged(effect: .curl, axis: .vertical),
        .paged(effect: .arch, axis: .horizontal),
        .paged(effect: .arch, axis: .vertical),
        .continuous(axis: .vertical)
    ]

    /// - Parameters: presentation: 展示模式；layout: 单页或双页，连续只接受单页配置。
    /// - Returns: 实际可执行的书脊列表。
    public static func supportedSpines(for presentation: PageTurnPresentation,
                                      layout: ReaderPageLayout = .single) -> [PageSpinePlacement] {
        guard supportedPresentations.contains(presentation) else { return [] }
        switch presentation {
        case .paged(effect: .curl, axis: _), .paged(effect: .arch, axis: _):
            return layout == .spread ? [.automatic, .center] : [.automatic, .minimum, .maximum]
        case .continuous: return layout == .single ? [.automatic] : []
        default: return [.automatic]
        }
    }

    /// automatic 在双页纸张中表示中央；横向单页 RTL 表示最大端，其余表示最小端。
    public var resolvedSpine: PageSpinePlacement {
        if spine != .automatic { return spine }
        if case .paged(let effect, let axis) = presentation, effect == .curl || effect == .arch {
            if layout == .spread { return .center }
            return axis == .horizontal && readingOrder == .rightToLeft ? .maximum : .minimum
        }
        return .automatic
    }

    /// next 对应的物理拖动符号；内容 provider 的逻辑方向始终保持不变。
    internal var forwardDisplacementSign: Double {
        guard case .paged(let effect, let axis) = presentation else { return -1 }
        if effect == .curl || effect == .arch {
            if resolvedSpine == .maximum { return 1 }
            if resolvedSpine == .minimum { return -1 }
        }
        return axis == .horizontal && readingOrder == .rightToLeft ? 1 : -1
    }
}

/// 源内容与展示单元分开；同一源可产生多页或多个切片。版本由宿主单调递增。
public struct PageItemIdentity: Sendable, Hashable {
    public let sourceID: String
    public let unitID: String
    public let contentVersion: UInt64
    public let layoutVersion: UInt64

    /// - Parameters: sourceID: 源标识；unitID: 窗口内唯一单元标识；contentVersion: 内容版本；layoutVersion: 布局版本。
    public init(sourceID: String, unitID: String, contentVersion: UInt64 = 0, layoutVersion: UInt64 = 0) {
        self.sourceID = sourceID
        self.unitID = unitID
        self.contentVersion = contentVersion
        self.layoutVersion = layoutVersion
    }
}

/// 每次复用都产生新绑定；异步结果安装前必须由容器验证整个值。
public struct PageViewBinding: Sendable, Hashable {
    public let identity: PageItemIdentity
    public let presentationID: UUID
    public let id: UUID

    /// - Parameters: identity: 当前内容身份；presentationID: renderer 代际。
    public init(identity: PageItemIdentity, presentationID: UUID) {
        self.identity = identity
        self.presentationID = presentationID
        self.id = UUID()
    }
}

/// 一个窗口安装请求的前置版本；并发请求中只有与当前版本一致者可安装。
public struct ContinuousUpdateToken: Sendable, Equatable {
    public let presentationID: UUID
    public let revision: UInt64

    /// - Parameters: presentationID: 展示代际；revision: 窗口修订号。
    public init(presentationID: UUID, revision: UInt64) {
        self.presentationID = presentationID
        self.revision = revision
    }
}

public struct PageTransition: Sendable, Equatable {
    public let id: UUID
    public let presentationID: UUID
    public let from: PageItemIdentity
    public let to: PageItemIdentity
    public let direction: PageTurnDirection

    /// - Parameters: presentationID: 展示代际；from: 原页面；to: 目标页面；direction: 逻辑方向。
    public init(presentationID: UUID, from: PageItemIdentity, to: PageItemIdentity, direction: PageTurnDirection) {
        id = UUID()
        self.presentationID = presentationID
        self.from = from
        self.to = to
        self.direction = direction
    }
}

public enum PageTransitionEvent: Sendable, Equatable {
    case willBegin(PageTransition)
    case didCommit(PageTransition)
    case didSettle(PageTransition, completed: Bool)
}

/// 与原覆盖翻页保持相同的半屏归一化和反向速度优先规则。
public enum PageTurnReleasePolicy {
    /// - Parameters: displacement: 沿逻辑方向的位移；extent: 视口轴长；velocity: 沿逻辑方向的速度，point/s。
    /// - Returns: 是否提交本次翻页；负向快速甩动优先取消。
    public static func shouldComplete(displacement: Double, extent: Double, velocity: Double) -> Bool {
        guard displacement.isFinite, extent.isFinite, extent > 0, velocity.isFinite else { return false }
        if velocity <= -500 { return false }
        return max(0, displacement) / (extent * 0.5) >= 0.17 || velocity >= 500
    }
}
