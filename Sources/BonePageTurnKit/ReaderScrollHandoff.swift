#if canImport(UIKit)
import UIKit

/// 内层滚动到边缘后，同一次拖动继续交给外层分页；高倍缩放默认仍由内容独占。
public struct ReaderScrollHandoffPolicy: Sendable, Equatable {
    public let threshold: Double
    public let allowsPagingWhileZoomed: Bool
    public static let standard = ReaderScrollHandoffPolicy()

    /// - Parameters: threshold: 边缘外的启动距离，允许 1...200 point；allowsPagingWhileZoomed: 放大后是否仍允许边缘翻页。
    public init(threshold: Double = 18, allowsPagingWhileZoomed: Bool = false) {
        self.threshold = threshold
        self.allowsPagingWhileZoomed = allowsPagingWhileZoomed
    }
}

/// 不替换 UIScrollView.delegate 或原生手势 delegate；只观察已登记内容的 pan／pinch。
/// 容器持有登记对象，登记对象弱引用容器和 scrollView；离开当前页面后自动注销。
@MainActor
public final class ReaderScrollHandoff: NSObject {
    public let id = UUID()
    public let policy: ReaderScrollHandoffPolicy
    public private(set) var isActive = true
    public private(set) var isHandingOff = false
    internal weak var scrollView: UIScrollView?
    private weak var reader: PagedReaderViewController?
    private var panActive = false
    private var pinchActive = false
    private var blocked = false
    private var startOffset: CGFloat = 0
    private var minimumOffset: CGFloat = 0
    private var maximumOffset: CGFloat = 0
    private var translationBaseline: CGFloat = 0
    private var directionSign: CGFloat = 1
    private var transactionID: UUID?
    private var pinnedOffset: CGPoint?
    private var originalBounces: Bool?
    private let horizontal: Bool
    private let originalAlwaysBounce: Bool

    /// - Parameters: scrollView: 需要边缘交接的真实滚动内容；reader: 外层分页；policy: 交接参数。
    internal init(scrollView: UIScrollView, reader: PagedReaderViewController, policy: ReaderScrollHandoffPolicy) {
        self.scrollView = scrollView
        self.reader = reader
        self.policy = policy
        if case .paged(_, let axis) = reader.configuration.presentation { horizontal = axis == .horizontal }
        else { horizontal = true }
        originalAlwaysBounce = horizontal ? scrollView.alwaysBounceHorizontal : scrollView.alwaysBounceVertical
        super.init()
        // 适屏内容也必须产生原生 pan，否则永远没有机会达到边缘交接阈值。
        if horizontal { scrollView.alwaysBounceHorizontal = true }
        else { scrollView.alwaysBounceVertical = true }
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
    }

    /// 注销并归还滚动属性；重复调用无副作用，不修改宿主的 delegate。
    public func invalidate() { invalidate(reason: .cancelled) }

    internal func invalidate(reason: PageTurnAnimationDiagnostic.EndReason) {
        guard isActive else { return }
        isActive = false
        cancelInteraction(reason: reason)
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        scrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(pinchChanged(_:)))
        if horizontal { scrollView?.alwaysBounceHorizontal = originalAlwaysBounce }
        else { scrollView?.alwaysBounceVertical = originalAlwaysBounce }
        reader = nil
    }

    /// 暂停／退出／尺寸改变时清理手势所有权，登记仍可供下一次拖动使用。
    internal func cancelInteraction(reason: PageTurnAnimationDiagnostic.EndReason = .cancelled) {
        endTracking(pan: false, pinch: false, reason: reason)
    }

    /// - Parameters: pan: 是否仍有由内层独占的拖动；pinch: 是否仍有捏合。
    private func endTracking(pan: Bool, pinch: Bool, reason: PageTurnAnimationDiagnostic.EndReason = .cancelled) {
        let owned = transactionID
        transactionID = nil
        isHandingOff = false
        blocked = true
        panActive = pan
        pinchActive = pinch
        restoreScrollProperties()
        if let owned, reader?.activeTransitionID == owned { reader?.cancelTransition(reason: reason) }
        reader?.setScrollInteraction(pan || pinch, id: id)
    }

    /// 在 willBegin 通知前登记所有权，回调内注销也能取消这笔事务。
    internal func takeOwnership(of transitionID: UUID) {
        self.transactionID = transitionID
        isHandingOff = true
    }

    /// - Parameter settledID: 已完成或取消的事务；同步归还属性，等待原 pan 终态释放占用。
    internal func transitionDidSettle(_ settledID: UUID) {
        guard transactionID == settledID else { return }
        transactionID = nil
        isHandingOff = false
        blocked = true
        restoreScrollProperties()
    }

    /// - Parameter recognizer: 内层原生 pan，使用与测试相同的状态机。
    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView else { invalidate(); return }
        let coordinateView = reader?.viewIfLoaded ?? scrollView
        processPan(state: recognizer.state, translation: recognizer.translation(in: coordinateView),
                   velocity: recognizer.velocity(in: coordinateView), touches: recognizer.numberOfTouches)
    }

    /// - Parameter recognizer: 原生捏合，开始后取消外层翻页，结束前不移交。
    @objc private func pinchChanged(_ recognizer: UIPinchGestureRecognizer) {
        processPinch(state: recognizer.state)
    }

    /// - Parameter state: 原生 pinch 状态；捏合结束后需要新的 pan 才能重新交接。
    internal func processPinch(state: UIGestureRecognizer.State) {
        guard isActive, let scrollView, let reader, reader.containsCurrentContent(scrollView) else { return }
        if state == .began {
            endTracking(pan: panActive, pinch: true)
        } else if state == .ended || state == .cancelled || state == .failed {
            pinchActive = false
        }
        reader.setScrollInteraction(panActive || pinchActive, id: id)
    }

    /// - Parameters: state: pan 状态；translation: 阅读器坐标的累计位移；velocity: 阅读器坐标的速度；touches: 触点数。
    internal func processPan(state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint, touches: Int = 1) {
        guard isActive, let scrollView, let reader else { return }
        guard translation.x.isFinite, translation.y.isFinite, velocity.x.isFinite, velocity.y.isFinite else {
            cancelInteraction(); return
        }
        let primary = horizontal ? translation.x : translation.y
        let secondary = horizontal ? translation.y : translation.x
        let speed = horizontal ? velocity.x : velocity.y
        switch state {
        case .began:
            endTracking(pan: false, pinch: pinchActive)
            guard reader.containsCurrentContent(scrollView), scrollView.isScrollEnabled,
                  reader.canTrackScrollInteraction else { return }
            let inset = scrollView.adjustedContentInset
            minimumOffset = horizontal ? -inset.left : -inset.top
            maximumOffset = max(minimumOffset, horizontal
                ? scrollView.contentSize.width - scrollView.bounds.width + inset.right
                : scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            startOffset = min(maximumOffset, max(minimumOffset, horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y))
            guard minimumOffset.isFinite, maximumOffset.isFinite, startOffset.isFinite else { return }
            panActive = true
            blocked = touches > 1 || pinchActive || scrollView.isZooming
            reader.setScrollInteraction(true, id: id)
        case .changed:
            guard panActive, !blocked else { return }
            guard touches <= 1, !pinchActive, !scrollView.isZooming,
                  policy.allowsPagingWhileZoomed || scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 else {
                endTracking(pan: true, pinch: pinchActive); return
            }
            if isHandingOff {
                guard let transactionID, reader.activeTransitionID == transactionID else { cancelInteraction(); return }
                if let pinnedOffset { scrollView.setContentOffset(pinnedOffset, animated: false) }
                reader.updateInteractiveTurn(displacement: max(0, (primary - translationBaseline) * directionSign))
                return
            }
            guard reader.containsCurrentContent(scrollView), reader.canTrackScrollInteraction,
                  abs(primary) > abs(secondary) * 1.1 else { return }
            let desiredOffset = startOffset - primary
            let residual: CGFloat
            let edge: CGFloat
            if desiredOffset < minimumOffset { edge = minimumOffset; residual = minimumOffset - desiredOffset }
            else if desiredOffset > maximumOffset { edge = maximumOffset; residual = maximumOffset - desiredOffset }
            else { return }
            guard abs(residual) >= CGFloat(policy.threshold) else { return }
            directionSign = residual > 0 ? 1 : -1
            translationBaseline = primary - residual + directionSign * CGFloat(policy.threshold)
            let forward = CGFloat(reader.configuration.forwardDisplacementSign)
            let direction: PageTurnDirection = residual * forward > 0 ? .next : .previous
            originalBounces = scrollView.bounces
            var offset = scrollView.contentOffset
            if horizontal { offset.x = edge } else { offset.y = edge }
            pinnedOffset = offset
            scrollView.bounces = false
            scrollView.setContentOffset(offset, animated: false)
            do {
                guard try reader.beginScrollHandoff(direction, owner: self), isActive,
                      let transaction = reader.activeTransitionID else {
                    blocked = true
                    restoreScrollProperties()
                    return
                }
                transactionID = transaction
                isHandingOff = true
                reader.updateInteractiveTurn(displacement: max(0, (primary - translationBaseline) * directionSign))
            } catch {
                blocked = true
                restoreScrollProperties()
            }
        case .ended:
            guard panActive else { return }
            if let transactionID, reader.activeTransitionID == transactionID {
                if let pinnedOffset { scrollView.setContentOffset(pinnedOffset, animated: false) }
                reader.updateInteractiveTurn(displacement: max(0, (primary - translationBaseline) * directionSign))
                // 在清理登记可能重入前交出所有权；动画终态仍由分页事务统一交付。
                self.transactionID = nil
                isHandingOff = false
                reader.endInteractiveTurn(velocity: speed * directionSign)
            }
            panActive = false
            restoreScrollProperties()
            reader.setScrollInteraction(pinchActive, id: id)
        case .cancelled, .failed: endTracking(pan: false, pinch: pinchActive)
        default: break
        }
    }

    /// 归还临时关闭的弹性；不修改 zoom、delegate 或宿主滚动启用状态。
    private func restoreScrollProperties() {
        if let originalBounces { scrollView?.bounces = originalBounces }
        originalBounces = nil
        pinnedOffset = nil
    }
}
#endif
