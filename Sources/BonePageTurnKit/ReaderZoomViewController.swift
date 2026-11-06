#if canImport(UIKit)
import UIKit

/// 最小倍率的适配方式；宽度适配保留长内容的纵向滚动。
@MainActor
public enum ReaderZoomFit: Equatable {
    case aspectFit
    case width
}

/// 缩放容器的输入或控制器所有权错误。
public enum ReaderZoomError: Error, Sendable, Equatable {
    case invalidContentController
    case invalidContentSize
    case invalidMaximumZoomFactor
    case invalidZoomFactor
    case invalidZoomCenter
}

/// 用真实子控制器承载任意内容，保留原生捏合、滚动与局部双击缩放。
@MainActor
public final class ReaderZoomViewController: UIViewController, UIScrollViewDelegate {
    /// 供宿主注册手势或观察滚动；delegate 由此容器持有，宿主不应替换。
    public let scrollView = UIScrollView()
    public let contentController: UIViewController

    /// 相对于当前适配倍率的放大倍数；改变倍率请使用可抛错的 setZoomFactor。
    public var zoomFactor: CGFloat {
        guard geometry != nil else { return requestedFactor }
        return min(maximumZoomFactor, max(1, scrollView.zoomScale / scrollView.minimumZoomScale))
    }

    private let contentSize: CGSize
    private let fit: ReaderZoomFit
    private let maximumZoomFactor: CGFloat
    private let canvas = UIView()
    private var geometry: ReaderZoomGeometry?
    private var requestedFactor: CGFloat = 1
    private var requestedCenter: CGPoint?
    private var isUpdatingGeometry = false
    internal var hasValidContent: Bool {
        contentController.parent === self && contentController.viewIfLoaded?.superview === canvas
    }

    /// 创建并安装真实子控制器，所有可能失败的校验先于 containment。
    /// - Parameters:
    ///   - content: 尚无父控制器、未展示且根视图未挂载的内容控制器。
    ///   - contentSize: 固定逻辑基准尺寸，每边须为 1e-9…1e9 的有限正数。
    ///   - fit: 最小倍率按完整适配或宽度适配计算。
    ///   - maximumZoomFactor: 相对于适配倍率的最大倍数，范围 1…1e6。
    /// - Throws: `ReaderZoomError`；失败时不会把内容挂到构造失败的容器上。
    public init(content: UIViewController, contentSize: CGSize, fit: ReaderZoomFit = .aspectFit,
                maximumZoomFactor: CGFloat = 4) throws {
        guard content.parent == nil, content.presentingViewController == nil,
              content.viewIfLoaded?.superview == nil else { throw ReaderZoomError.invalidContentController }
        guard ReaderZoomGeometry.isValidSize(contentSize) else { throw ReaderZoomError.invalidContentSize }
        guard ReaderZoomGeometry.isValidMaximumFactor(maximumZoomFactor) else {
            throw ReaderZoomError.invalidMaximumZoomFactor
        }
        // loadView 可能同步调用宿主逻辑；回调后重新核对所有权，再开始安装。
        content.loadViewIfNeeded()
        guard content.parent == nil, content.presentingViewController == nil,
              let contentView = content.viewIfLoaded, contentView.superview == nil else {
            throw ReaderZoomError.invalidContentController
        }
        self.contentController = content
        self.contentSize = contentSize
        self.fit = fit
        self.maximumZoomFactor = maximumZoomFactor
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
        var installed = false
        defer {
            if !installed {
                if content.parent === self { content.willMove(toParent: nil) }
                if contentView.superview === canvas { contentView.removeFromSuperview() }
                if content.parent === self { content.removeFromParent() }
            }
        }
        addChild(content)
        guard content.parent === self, contentView.superview == nil else { throw ReaderZoomError.invalidContentController }
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.addSubview(contentView)
        guard hasValidContent else { throw ReaderZoomError.invalidContentController }
        content.didMove(toParent: self)
        guard hasValidContent else { throw ReaderZoomError.invalidContentController }
        installed = true
    }

    /// 不支持归档构造；请显式提供内容控制器及尺寸。
    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// 创建滚动视图和固定尺寸内容画布，无参数及返回值。
    public override func loadView() {
        let root = UIView(frame: .zero)
        root.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        canvas.frame = CGRect(origin: .zero, size: contentSize)
        root.addSubview(scrollView)
        scrollView.addSubview(canvas)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        view = root
    }

    /// 布局变化保留相对倍率与归一化中心；无参数及返回值。
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isUpdatingGeometry, view.bounds.size != geometry?.viewportSize,
              let next = ReaderZoomGeometry(contentSize: contentSize, viewportSize: view.bounds.size,
                                            fitsWidth: fit == .width, maximumFactor: maximumZoomFactor) else { return }
        let factor = zoomFactor
        let center = geometry.map {
            $0.normalizedCenter(offset: scrollView.contentOffset, scale: scrollView.zoomScale)
        } ?? requestedCenter ?? next.initialCenter(at: next.minimumScale * factor)
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        geometry = next
        scrollView.frame = view.bounds
        // 先扩展可用上界，避免先修改最小倍率时被旧上界截断。
        scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, next.maximumScale)
        scrollView.minimumZoomScale = next.minimumScale
        scrollView.maximumZoomScale = next.maximumScale
        scrollView.setZoomScale(next.minimumScale * factor, animated: false)
        updateInsets(using: next)
        scrollView.setContentOffset(next.offset(for: center, scale: scrollView.zoomScale), animated: false)
        requestedFactor = factor
        requestedCenter = nil
    }

    /// 将内容中的指定位置放到可见区域中心，边缘按合法滚动范围钳制。
    /// - Parameters:
    ///   - factor: 相对于适配倍率的倍数，须处于 1…maximumZoomFactor。
    ///   - point: 固定 contentSize 坐标系中的点；nil 保留当前可见中心。
    ///   - animated: 是否使用 UIScrollView 的原生缩放动画。
    /// - Throws: 非法倍率或非有限、越出内容边界的中心点。
    public func setZoomFactor(_ factor: CGFloat, centeredAt point: CGPoint? = nil, animated: Bool = false) throws {
        guard factor.isFinite, factor >= 1, factor <= maximumZoomFactor else {
            throw ReaderZoomError.invalidZoomFactor
        }
        if let point {
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
                  point.x <= contentSize.width, point.y <= contentSize.height else {
                throw ReaderZoomError.invalidZoomCenter
            }
        }
        view.layoutIfNeeded()
        let suppliedCenter = point.map { CGPoint(x: $0.x / contentSize.width, y: $0.y / contentSize.height) }
        guard let geometry else {
            requestedFactor = factor
            if let suppliedCenter { requestedCenter = suppliedCenter }
            return
        }
        let center = suppliedCenter ?? geometry.normalizedCenter(offset: scrollView.contentOffset,
                                                                  scale: scrollView.zoomScale)
        let scale = geometry.minimumScale * factor
        requestedFactor = factor
        if animated {
            let size = CGSize(width: geometry.viewportSize.width / scale, height: geometry.viewportSize.height / scale)
            let rect = CGRect(x: center.x * contentSize.width - size.width / 2,
                              y: center.y * contentSize.height - size.height / 2,
                              width: size.width, height: size.height)
            scrollView.zoom(to: rect, animated: true)
        } else {
            isUpdatingGeometry = true
            defer { isUpdatingGeometry = false }
            scrollView.setZoomScale(scale, animated: false)
            updateInsets(using: geometry)
            scrollView.setContentOffset(geometry.offset(for: center, scale: scale), animated: false)
        }
    }

    /// 恢复当前适配倍率；参数控制动画，无返回值。
    public func resetZoom(animated: Bool = false) {
        try? setZoomFactor(1, animated: animated)
    }

    /// - Parameter scrollView: 请求缩放对象的滚动视图。
    /// - Returns: 固定基准画布；不把内容转成快照。
    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === self.scrollView ? canvas : nil
    }

    /// 原生捏合和缩放动画过程中更新留白；参数为发出事件的滚动视图，无返回值。
    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !isUpdatingGeometry, let geometry else { return }
        isUpdatingGeometry = true
        updateInsets(using: geometry)
        isUpdatingGeometry = false
    }
}

private extension ReaderZoomViewController {
    /// - Parameter geometry: 当前可见区域的几何；同步内容范围与对称留白，无返回值。
    func updateInsets(using geometry: ReaderZoomGeometry) {
        let padding = geometry.padding(at: scrollView.zoomScale)
        let insets = UIEdgeInsets(top: padding.y, left: padding.x, bottom: padding.y, right: padding.x)
        if scrollView.contentInset != insets { scrollView.contentInset = insets }
        scrollView.contentSize = geometry.scaledSize(at: scrollView.zoomScale)
    }

    /// 双击在局部放大与还原间切换；参数为双击识别器，无返回值。
    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if zoomFactor > 1.01 {
            resetZoom(animated: true)
        } else {
            let location = recognizer.location(in: canvas)
            let point = CGPoint(x: min(contentSize.width, max(0, location.x)),
                                y: min(contentSize.height, max(0, location.y)))
            try? setZoomFactor(min(2, maximumZoomFactor), centeredAt: point, animated: true)
        }
    }
}
#endif
