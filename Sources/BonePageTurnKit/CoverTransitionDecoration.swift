#if canImport(UIKit)
import UIKit

/// 单次覆盖事务的装饰所有者；不接管页面 containment，也不持有 renderer。
@MainActor
internal final class CoverTransitionDecoration {
    @MainActor
    private struct LayerRestoration {
        weak var layer: CALayer?
        let cornerRadius: CGFloat
        let masksToBounds: Bool
        let maskedCorners: CACornerMask
        let cornerCurve: CALayerCornerCurve
        let installedRadius: CGFloat

        /// - Parameters: layer: 宿主原始 layer；radius: 此次装饰写入的圆角。
        init(layer: CALayer, radius: CGFloat) {
            self.layer = layer
            cornerRadius = layer.cornerRadius
            masksToBounds = layer.masksToBounds
            maskedCorners = layer.maskedCorners
            cornerCurve = layer.cornerCurve
            installedRadius = radius
        }

        /// 仅撤销仍等于本事务写入值的属性，保留宿主在过渡期间设置的新样式。
        func restore() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if layer.cornerRadius == installedRadius { layer.cornerRadius = cornerRadius }
            if layer.masksToBounds { layer.masksToBounds = masksToBounds }
            if layer.maskedCorners == CoverTransitionDecoration.allCorners { layer.maskedCorners = maskedCorners }
            if layer.cornerCurve == .circular { layer.cornerCurve = cornerCurve }
        }
    }

    private static let allCorners: CACornerMask = [
        .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner
    ]
    private weak var owner: UIViewController?
    private weak var page: UIViewController?
    private weak var movingView: UIView?
    private weak var container: UIView?
    private let options: CoverRenderingOptions
    private let horizontalShadowSign: CGFloat
    private var restoration: LayerRestoration?
    private var isInstalled = false
    private var isInvalidated = false
    internal private(set) var shadowView: UIView?

    /// - Parameters: owner: 页面容器；page: 实际移动页；options: 已校验的装饰配置；horizontalShadowSign: LTR 为 1，RTL 为 -1。
    init(owner: UIViewController, page: UIViewController, options: CoverRenderingOptions,
         horizontalShadowSign: CGFloat) {
        self.owner = owner
        self.page = page
        movingView = page.viewIfLoaded
        container = owner.viewIfLoaded
        self.options = options
        self.horizontalShadowSign = horizontalShadowSign
    }

    deinit {
        // 通常由 finish 同步释放；宿主直接释放活动容器时也归还样式，不形成持有环。
        let saved = restoration
        let shadow = shadowView
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                saved?.restore()
                shadow?.removeFromSuperview()
            }
        } else {
            DispatchQueue.main.async {
                saved?.restore()
                shadow?.removeFromSuperview()
            }
        }
    }

    /// 页面控制器、根视图及父视图三者仍属于本次安装；外部接管后不继续绘制。
    private var ownsPage: Bool {
        guard let owner, let page, let movingView, let container else { return false }
        return page.parent === owner && page.viewIfLoaded === movingView && movingView.superview === container
    }

    /// 调用者必须先持有 helper，再安装，以便 UIKit 同步回调取消时能立即找到并清理它。
    /// - Returns: 安装结束后所有权仍有效时为 true。
    func install() -> Bool {
        guard !isInstalled, !isInvalidated, options.isEnabled, ownsPage,
              let movingView, let container else { return false }
        isInstalled = true
        if options.cornerRadius > 0 {
            let layer = movingView.layer
            restoration = LayerRestoration(layer: layer, radius: CGFloat(options.cornerRadius))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            layer.cornerRadius = CGFloat(options.cornerRadius)
            guard installationIsValid() else { return false }
            layer.masksToBounds = true
            guard installationIsValid() else { return false }
            layer.maskedCorners = Self.allCorners
            guard installationIsValid() else { return false }
            layer.cornerCurve = .circular
            guard installationIsValid() else { return false }
        }
        if options.shadowOpacity > 0 {
            let shadow = UIView(frame: movingView.frame)
            shadow.isUserInteractionEnabled = false
            shadow.isAccessibilityElement = false
            shadow.accessibilityElementsHidden = true
            shadow.backgroundColor = .clear
            shadow.layer.shadowColor = UIColor.black.cgColor
            shadow.layer.shadowOpacity = Float(options.shadowOpacity)
            shadow.layer.shadowRadius = CGFloat(options.shadowRadius)
            shadow.layer.shadowOffset = CGSize(width: CGFloat(options.shadowOffsetX) * horizontalShadowSign,
                                               height: CGFloat(options.shadowOffsetY))
            shadowView = shadow
            container.insertSubview(shadow, belowSubview: movingView)
            // didAddSubview 等回调可以取消事务；外层插入即使晚于清理完成，也不能留下孤儿阴影。
            guard installationIsValid(), shadowView === shadow, shadow.superview === container else {
                shadow.removeFromSuperview()
                invalidate()
                return false
            }
        }
        return true
    }

    /// - Returns: 安装仍然有效时为 true，否则幂等清理后返回 false。
    private func installationIsValid() -> Bool {
        guard isInstalled, !isInvalidated, ownsPage else { invalidate(); return false }
        return true
    }

    /// - Parameter progress: 归一化事务进度；两个逻辑方向都按 1 - progress 衰减。
    /// - Returns: 是否仍可绘制；失败时调用方应取消事务。
    func update(progress: CGFloat) -> Bool {
        guard installationIsValid(), let movingView else { return false }
        guard let shadow = shadowView else { return true }
        guard shadow.superview === container else { invalidate(); return false }
        shadow.frame = movingView.frame
        shadow.layer.zPosition = movingView.layer.zPosition
        let radius = min(movingView.layer.cornerRadius, min(shadow.bounds.width, shadow.bounds.height) / 2)
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: max(0, radius)).cgPath
        // alpha 是 UIView 动画属性，松手收尾时会与页面 frame 在同一个 animator 中插值。
        shadow.alpha = 1 - min(1, max(0, progress))
        return installationIsValid()
    }

    /// 先释放所有权再恢复，允许清理期间的同步回调重入；不移动外部视图或改写其新样式。
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isInstalled = false
        let saved = restoration
        restoration = nil
        let shadow = shadowView
        shadowView = nil
        saved?.restore()
        shadow?.removeFromSuperview()
    }
}
#endif
