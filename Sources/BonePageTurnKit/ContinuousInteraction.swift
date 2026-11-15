import Foundation

/// 连续阅读中互相独立的临时暂停目标；宿主按拥有者原因配对释放。
public struct ContinuousSuspensionTargets: OptionSet, Sendable {
    public let rawValue: UInt8
    /// - Parameter rawValue: 位集合；控制方法仅使用已知目标。
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let userScrolling = Self(rawValue: 1 << 0)
    public static let taps = Self(rawValue: 1 << 1)
    public static let automaticReading = Self(rawValue: 1 << 2)
    public static let contentInstallation = Self(rawValue: 1 << 3)
    public static let all: Self = [.userScrolling, .taps, .automaticReading, .contentInstallation]
}

#if canImport(UIKit)
import UIKit

/// 一次查询的可见内容快照；不会延长绑定有效期。不要长期缓存 view，异步使用前验证 binding。
@MainActor
public struct ContinuousVisibleContent {
    public let item: ContinuousItem
    public let binding: PageViewBinding
    public let view: UIView
    /// 完整块矩形与裁剪后的可见矩形，均在查询指定的目标坐标系。
    public let frame: CGRect
    public let visibleFrame: CGRect
}

/// 正文点击上下文；空白处 content 和 pointInContent 为 nil。
@MainActor
public struct ContinuousTapContext {
    public let point: CGPoint
    public let content: ContinuousVisibleContent?
    public let pointInContent: CGPoint?
}

/// 保留 UIScrollView 的原生手势代理，只在 UIView 的开始问询中追加宿主门禁。
@MainActor
final class ReaderContinuousScrollView: UIScrollView {
    var allowUserPan: ((UIPanGestureRecognizer) -> Bool)?
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard super.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
        guard gestureRecognizer === panGestureRecognizer else { return true }
        return allowUserPan?(panGestureRecognizer) ?? true
    }
}
#endif
