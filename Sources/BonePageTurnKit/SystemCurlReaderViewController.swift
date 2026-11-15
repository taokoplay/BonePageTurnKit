#if canImport(UIKit)
import UIKit

/// 系统仿真翻页容器：用 `UIPageViewController(.pageCurl)` 呈现页面，与本库自研 `curl` 并列。
///
/// 能力边界（与 `PagedReaderViewController` 的差异，接入前必读）：
/// - 只提供“按页切换”：`setCurrentIndex(_:animated:)`、`onPageChange`、`isTransitioning`。
/// - **不提供**交互进度、半翻预览、程序化取消/完成、翻页事件三元组（willBegin/didCommit/didSettle）、
///   快照像素预算、连翻排队与手速加速——这些都由 Apple 容器内部实现，没有公开接口。
/// - 手势与动画均由系统容器负责；本类只转发页面与页码。
/// 需要上述任何一项能力时，请使用自研 `curl`（`PageTurnEffect.curl`）。
@MainActor
public final class SystemCurlReaderViewController: UIViewController {
    /// 页码到真实页面的构造闭包；返回 nil 表示该页不可用。
    public var pageProvider: ((Int) -> UIViewController?)?
    /// 页码变化回调，仅在系统容器完成切换后触发一次。
    public var onPageChange: ((Int) -> Void)?
    /// 过渡状态回调：系统容器开始/结束一次翻页。
    public var onTransitionStateChange: ((Bool) -> Void)?

    /// 当前页码；超出页数范围时被约束。
    public private(set) var currentIndex: Int
    /// 总页数；小于 1 时容器不展示任何页面。
    public private(set) var pageCount: Int
    /// 系统容器是否正在播放翻页动画。
    public var isTransitioning: Bool { animating || pendingTransition }

    private let pager: UIPageViewController
    private var indices: [ObjectIdentifier: Int] = [:]
    private var animating = false
    private var pendingTransition = false

    /// - Parameters:
    ///   - pageCount: 总页数；
    ///   - initialIndex: 初始页码，超出范围时约束到有效区间。
    public init(pageCount: Int, initialIndex: Int = 0) {
        self.pageCount = max(0, pageCount)
        currentIndex = min(max(0, initialIndex), max(0, pageCount - 1))
        pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                     options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)])
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持归档构造。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        pager.dataSource = self
        pager.delegate = self
        pager.view.backgroundColor = .clear
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        if let first = page(at: currentIndex) { pager.setViewControllers([first], direction: .forward, animated: false) }
    }

    /// - Parameter pageCount: 新的总页数；页码超界时收敛到末页。无返回值。
    public func setPageCount(_ count: Int) {
        pageCount = max(0, count)
        if currentIndex >= pageCount { currentIndex = max(0, pageCount - 1) }
    }

    /// 切换到指定页码；超出范围时忽略。
    /// - Parameters:
    ///   - index: 目标页码；
    ///   - animated: 是否播放系统卷页动画。
    /// - Returns: 是否接受本次切换。
    @discardableResult
    public func setCurrentIndex(_ index: Int, animated: Bool) -> Bool {
        guard (0..<pageCount).contains(index), !isTransitioning, index != currentIndex,
              let target = page(at: index) else { return false }
        let direction: UIPageViewController.NavigationDirection = index > currentIndex ? .forward : .reverse
        currentIndex = index
        animating = animated
        pendingTransition = animated
        pager.setViewControllers([target], direction: direction, animated: animated) { [weak self] _ in
            guard let self else { return }
            self.animating = false
            self.pendingTransition = false
            self.onTransitionStateChange?(false)
            self.onPageChange?(self.currentIndex)
        }
        return true
    }

    /// - Parameter index: 页码。
    /// - Returns: 该页控制器；越界或无 provider 时为 nil。
    private func page(at index: Int) -> UIViewController? {
        guard (0..<pageCount).contains(index), let controller = pageProvider?(index) else { return nil }
        indices[ObjectIdentifier(controller)] = index
        return controller
    }
}

extension SystemCurlReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    public func pageViewController(_ pageViewController: UIPageViewController,
                                   viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = indices[ObjectIdentifier(viewController)], index > 0 else { return nil }
        return page(at: index - 1)
    }

    public func pageViewController(_ pageViewController: UIPageViewController,
                                   viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = indices[ObjectIdentifier(viewController)], index + 1 < pageCount else { return nil }
        return page(at: index + 1)
    }

    public func pageViewController(_ pageViewController: UIPageViewController,
                                   willTransitionTo pendingViewControllers: [UIViewController]) {
        pendingTransition = true
        onTransitionStateChange?(true)
    }

    public func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                   previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        pendingTransition = false
        if completed, let visible = pageViewController.viewControllers?.first,
           let index = indices[ObjectIdentifier(visible)] {
            currentIndex = index
            onPageChange?(index)
        }
        onTransitionStateChange?(false)
    }
}
#endif
