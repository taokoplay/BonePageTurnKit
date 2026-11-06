#if canImport(UIKit)
import UIKit

// MARK: - UIKit 视口快照

public extension ReaderViewportEnvironment {
    /// - Parameter view: 正在布局的宿主视图，所有区域均使用它的本地坐标系。
    /// - Returns: bounds、安全距离、水平尺寸类别和规范排序后的系统保留区域；旧 SDK 仅提供安全区信息。
    @MainActor
    static func capture(from view: UIView) -> ReaderViewportEnvironment {
        let widthClass: ReaderViewportWidthClass
        switch view.traitCollection.horizontalSizeClass {
        case .compact: widthClass = .compact
        case .regular: widthClass = .regular
        default: widthClass = .unspecified
        }
        let insets = view.safeAreaInsets
        var regions: [ReaderReservedRegion] = []
        // 编译器和运行时同时保护新符号，Swift 5.9 工具链仍可编译安全区回退路径。
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            regions += view.reservedRegions(kind: .division, options: .includeInactive).map {
                ReaderReservedRegion(kind: .division, frame: $0.frame, isActive: $0.isActive)
            }
            regions += view.reservedRegions(kind: .occlusion).map {
                ReaderReservedRegion(kind: .occlusion, frame: $0.frame, isActive: $0.isActive)
            }
        }
        #endif
        return .init(bounds: view.bounds,
                     safeAreaInsets: .init(top: Double(insets.top), left: Double(insets.left),
                                           bottom: Double(insets.bottom), right: Double(insets.right)),
                     widthClass: widthClass, regions: orderedRegions(regions))
    }

    /// - Parameter regions: 系统返回的区域；返回按种类、坐标、尺寸及活跃状态稳定排序的数组。
    internal static func orderedRegions(_ regions: [ReaderReservedRegion]) -> [ReaderReservedRegion] {
        regions.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .division }
            let left = [lhs.frame.origin.x, lhs.frame.origin.y, lhs.frame.size.width, lhs.frame.size.height]
            let right = [rhs.frame.origin.x, rhs.frame.origin.y, rhs.frame.size.width, rhs.frame.size.height]
            if left != right { return left.lexicographicallyPrecedes(right) }
            return !lhs.isActive && rhs.isActive
        }
    }
}

// MARK: - 自动观察根视图

/// 将 UIKit 几何变化转换为去重的环境快照；宿主回调若捕获拥有者，应使用弱引用。
@MainActor
public final class ReaderViewportView: UIView {
    /// 只在完整环境值发生变化时通知，回调始终在主线程执行。
    public var onEnvironmentChange: ((ReaderViewportEnvironment) -> Void)?
    public private(set) var environment: ReaderViewportEnvironment?

    /// 仅供模块内确定性测试使用，不是公开的设备模拟接口。
    internal var environmentOverride: ReaderViewportEnvironment? {
        didSet { refreshEnvironment() }
    }

    private var isRefreshingEnvironment = false

    /// - Parameter frame: 初始视图范围；首次布局或显式刷新时生成快照。
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setNeedsUpdateConstraints()
    }

    /// 不支持归档初始化；参数为归档器，无可用返回值。
    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// 无参数及返回值。同步采集最新环境；回调中的重入交给下一次刷新，避免递归或无界通知循环。
    public func refreshEnvironment() {
        guard !isRefreshingEnvironment else { return }
        isRefreshingEnvironment = true
        defer { isRefreshingEnvironment = false }
        let snapshot = environmentOverride ?? ReaderViewportEnvironment.capture(from: self)
        guard snapshot != environment else { return }
        environment = snapshot
        onEnvironmentChange?(snapshot)
    }

    /// 无参数及返回值。在约束阶段读取 reservedRegions，使 UIKit 自动追踪相应系统区域的变化。
    public override func updateConstraints() {
        refreshEnvironment()
        super.updateConstraints()
    }

    /// 无参数及返回值。保留 bounds 原点变化，即使宽高不变也会刷新快照。
    public override func layoutSubviews() {
        super.layoutSubviews()
        refreshEnvironment()
    }

    /// 无参数及返回值。安全距离变化后重新观察系统区域并立即刷新快照。
    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsUpdateConstraints()
        refreshEnvironment()
    }

    /// - Parameter previousTraitCollection: UIKit 提供的旧特征；无返回值，更新分屏及显示环境变化。
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsUpdateConstraints()
        refreshEnvironment()
    }

    /// 无参数及返回值。进入新窗口后重新建立约束阶段的系统区域观察。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsUpdateConstraints()
        refreshEnvironment()
    }
}
#endif
