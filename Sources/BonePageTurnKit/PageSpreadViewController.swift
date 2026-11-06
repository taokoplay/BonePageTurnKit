#if canImport(UIKit)
import UIKit

/// 两个真实子页面组成的展示单元；先后顺序与物理左右分开，空侧不创建虚假页码。
@MainActor
public final class PageSpreadViewController: UIViewController {
    public let firstPage: PageContent?
    public let secondPage: PageContent?
    public let axis: PageTurnAxis
    public let readingOrder: ReaderReadingOrder
    /// 两个真实页面之间的空隙；由自适应视口的折痕宽度提供，默认无空隙。
    public let gutter: CGFloat
    public var pages: [PageContent] { [firstPage, secondPage].compactMap { $0 } }

    /// - Parameters: first: 逻辑第一侧；second: 逻辑第二侧；axis: 两页排列轴；readingOrder: 水平左右顺序；gutter: 有限非负书脊留白。
    /// - Throws: 双侧都空、重复身份／控制器、候选已经挂载。
    public init(first: PageContent?, second: PageContent?, axis: PageTurnAxis = .horizontal,
                readingOrder: ReaderReadingOrder = .leftToRight, gutter: CGFloat = 0) throws {
        let pages = [first, second].compactMap { $0 }
        guard !pages.isEmpty else { throw PageTurnError.invalidPageLayout }
        guard gutter.isFinite, gutter >= 0 else { throw PageTurnError.invalidPageLayout }
        for page in pages {
            guard page.controller.parent == nil, page.controller.viewIfLoaded?.superview == nil else {
                throw PageTurnError.invalidPageController
            }
        }
        if let first, let second {
            guard first.controller !== second.controller, first.identity != second.identity else {
                throw PageTurnError.invalidPageLayout
            }
        }
        firstPage = first
        secondPage = second
        self.axis = axis
        self.readingOrder = readingOrder
        self.gutter = gutter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用双页内容初始化方法") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        for page in pages {
            let child = page.controller
            guard child.parent == nil, child.viewIfLoaded?.superview == nil else { continue }
            child.loadViewIfNeeded()
            guard child.parent == nil, let childView = child.viewIfLoaded, childView.superview == nil else { continue }
            addChild(child)
            guard child.parent === self else { continue }
            guard childView.superview == nil else {
                child.willMove(toParent: nil); child.removeFromParent(); continue
            }
            view.addSubview(childView)
            if child.parent === self { child.didMove(toParent: self) }
            else if childView.superview === view { childView.removeFromSuperview() }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let horizontal = axis == .horizontal
        let firstAtMinimum = !horizontal || readingOrder == .leftToRight
        let length = horizontal ? bounds.width : bounds.height
        let gap = min(gutter, max(0, length))
        let half = max(0, length - gap) / 2
        for (index, page) in [firstPage, secondPage].enumerated() {
            guard let page, page.controller.parent === self, let childView = page.controller.viewIfLoaded else { continue }
            let minimum = (index == 0) == firstAtMinimum
            let rect = horizontal
                ? CGRect(x: bounds.minX + (minimum ? 0 : half + gap), y: bounds.minY, width: half, height: bounds.height)
                : CGRect(x: bounds.minX, y: bounds.minY + (minimum ? 0 : half + gap), width: bounds.width, height: half)
            childView.frame = rect
        }
    }

    /// - Parameter configuration: 目标分页配置。
    /// - Throws: 排列轴／顺序不匹配或子页 containment 被外部回调破坏。
    internal func validate(for configuration: PageTurnConfiguration) throws {
        guard configuration.layout == .spread,
              case .paged(_, let configuredAxis) = configuration.presentation,
              axis == configuredAxis, readingOrder == configuration.readingOrder else { throw PageTurnError.invalidPageLayout }
        for page in pages {
            if isViewLoaded {
                guard page.controller.parent === self, page.controller.viewIfLoaded?.superview === viewIfLoaded else {
                    throw PageTurnError.invalidPageController
                }
            } else if page.controller.parent != nil || page.controller.viewIfLoaded?.superview != nil {
                throw PageTurnError.invalidPageController
            }
            if let zoom = page.controller as? ReaderZoomViewController, !zoom.hasValidContent {
                throw PageTurnError.invalidPageController
            }
        }
    }
}
#endif
