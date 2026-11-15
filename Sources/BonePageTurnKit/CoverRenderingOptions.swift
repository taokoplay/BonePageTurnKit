import Foundation

/// 覆盖翻页的瞬时装饰；稳定页面继续使用宿主原有样式，不申请快照。
public struct CoverRenderingOptions: Sendable, Equatable {
    /// 移动页的圆角半径，单位 point；零表示不修改宿主的裁剪属性。
    public let cornerRadius: Double
    /// 黑色阴影的最大透明度，范围 0...1；实际显示随翻页进度衰减。
    public let shadowOpacity: Double
    /// 阴影模糊半径，单位 point。
    public let shadowRadius: Double
    /// LTR 下的横向阴影偏移，单位 point；RTL 自动镜像，可为负数。
    public let shadowOffsetX: Double
    /// 纵向阴影偏移，单位 point，可为负数。
    public let shadowOffsetY: Double

    /// 保留原 SDK 的平面外观：不修改页面 layer，不创建阴影视图。
    public static let standard = CoverRenderingOptions()

    /// - Parameters:
    ///   - cornerRadius: 有限且非负的圆角半径。
    ///   - shadowOpacity: 有限且位于 0...1 的阴影透明度。
    ///   - shadowRadius: 有限且非负的阴影模糊半径。
    ///   - shadowOffsetX: 有限的横向偏移，按阅读顺序镜像。
    ///   - shadowOffsetY: 有限的纵向偏移，不随阅读顺序变化。
    public init(cornerRadius: Double = 0, shadowOpacity: Double = 0, shadowRadius: Double = 0,
                shadowOffsetX: Double = 0, shadowOffsetY: Double = 0) {
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
    }

    /// 校验所有字段，即使当前配置没有启用覆盖翻页也不忽略非法参数。
    /// - Throws: 对应字段的 CoverRenderingError，不静默钳制配置。
    public func validate() throws {
        guard cornerRadius.isFinite, cornerRadius >= 0 else { throw CoverRenderingError.invalidCornerRadius }
        guard shadowOpacity.isFinite, (0...1).contains(shadowOpacity) else { throw CoverRenderingError.invalidShadowOpacity }
        guard shadowRadius.isFinite, shadowRadius >= 0 else { throw CoverRenderingError.invalidShadowRadius }
        guard shadowOffsetX.isFinite, shadowOffsetY.isFinite else { throw CoverRenderingError.invalidShadowOffset }
    }

    /// 是否需要为实际 cover 事务安装装饰。
    internal var isEnabled: Bool { cornerRadius > 0 || shadowOpacity > 0 }
}

/// 覆盖装饰的独立校验错误，不与纸张快照预算错误混用。
public enum CoverRenderingError: Error, Sendable, Equatable {
    case invalidCornerRadius
    case invalidShadowOpacity
    case invalidShadowRadius
    case invalidShadowOffset
}
