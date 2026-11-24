#if canImport(UIKit)
import UIKit
import CoreGraphics

/// SDK 自有的 CoreGraphics 纸面后端。构造时捕获、裁图，动画期间只更新曲面投影。
@MainActor
final class PaperTransitionView: UIView {
    private struct PreparedStrip {
        let image: CGImage
        let leadingFraction: CGFloat
        let trailingFraction: CGFloat
    }

    private let effect: PageTurnEffect
    private let direction: PageTurnDirection
    private let spine: PageSpinePlacement
    private let axis: PageTurnAxis
    private let readingOrder: ReaderReadingOrder
    private let requestedStripCount: Int
    private let paperColor: UIColor
    private let cornerPaperColor: UIColor
    private var currentImage: CGImage?
    private var targetImage: CGImage?
    private var strips: [PreparedStrip] = []
    private var backStrips: [PreparedStrip] = []
    /// 当前已请求绘制的进度，包内只读，用于逐帧验证播放完整性。
    private(set) var progress: CGFloat = 0
    private(set) var cornerDrag: PaperCornerDrag?
    private let cornerDriven: Bool
    /// 幽灵收尾层：被新一笔接管的上一笔纸面，在新层上方继续播完；露出的底页区域转透明由下方补齐。
    private(set) var rendersGhostRelease = false
    /// 是否由二维触点纸面驱动；决定快速翻页能否堆叠幽灵收尾层。
    var isCornerDriven: Bool { cornerDriven }
    private var metalRenderer: PaperCornerMetalRenderer?
    private var metalView: PaperCornerMetalView?
    /// 整页 GPU 效果（火焰烧穿／电视故障／折纸／碎片／水墨／破冰／浪潮）共用的渲染器与图层。
    private var effectMetalRenderer: PaperEffectMetalRenderer?
    private var effectMetalView: PaperEffectMetalView?
    var usesMetalCornerRendering: Bool { metalRenderer?.isActive == true }
    /// 当前效果是否由整页 GPU 图层渲染。
    var usesMetalPageRendering: Bool { effectMetalRenderer != nil }
    /// 原生收尾可以驱动整页 GPU 图层的条件：图层已挂窗。
    var hasLiveNativePagePresentation: Bool { effectMetalView?.window != nil }
    /// 整页 GPU 图层的已提交帧数。
    var pageMetalSubmittedFrameCount: Int { effectMetalView?.submittedFrameCount ?? 0 }
    /// 整页 GPU 图层的逐帧呈现时间（诊断开启时采集）。
    var pagePresentationTimes: [TimeInterval] { effectMetalView?.presentedTimes ?? [] }
    /// 整页 GPU 图层的首末提交帧跨度（秒）；呈现时间戳不可靠时的 GPU 帧率兜底。
    var pageMetalSubmissionSpan: TimeInterval? { effectMetalView?.submissionSpan }
    /// 开关整页 GPU 图层的呈现指标采集。
    func setPagePresentationMetricsEnabled(_ enabled: Bool) { effectMetalView?.collectsPresentationMetrics = enabled }
    var metalSubmittedFrameCount: Int { metalRenderer?.submittedFrameCount ?? 0 }
    var nativeCornerSubmittedFrameCount: Int { metalView?.submittedFrameCount ?? 0 }
    /// 最后成功提交到原生 GPU 的纸面；没有屏幕提交时为 nil，离屏验收仍使用逻辑触点。
    var submittedCornerDrag: PaperCornerDrag? { metalView?.submittedDrag }
    /// 只有挂在窗口上的原生 Metal 触点纸面需要等待提交；离屏与软件路径保持原驱动。
    var hasLiveNativeCornerPresentation: Bool { metalView?.window != nil && usesMetalCornerRendering }
    /// 从最后已提交姿态继续；首帧还未提交时使用原生追随的起点，避免快速松手跳到逻辑终点。
    var cornerReleaseStart: PaperCornerDrag? {
        guard hasLiveNativeCornerPresentation else { return cornerDrag }
        return metalView?.releaseStartDrag ?? cornerDrag
    }
    /// 原生纸面是否已经不会再提交新帧。
    var nativeFramesExhausted: Bool { metalView?.framesExhausted ?? true }
    private(set) var softwareCornerDrawCount = 0
    /// 本次是否复用了传入的当前页位图（未重新抓取）。
    private(set) var didReuseCurrentSnapshot = false
    /// 本次抓取的目标页位图；下一笔翻页可用作当前页缓存。
    var targetSnapshot: CGImage? { targetImage }
    var targetTextureSnapshot: PaperCornerMetalRenderer.TextureSnapshot? { metalRenderer?.targetPageSnapshot }
    var textureUploadCount: Int { metalRenderer?.textureUploadCount ?? 0 }
    var metalLastTiming: PaperCornerMetalRenderer.Timing? { metalRenderer?.lastTiming }
    var metalPresentationTimes: [TimeInterval] { metalRenderer?.presentedTimes ?? [] }
    var metalFrameCPUTimes: [TimeInterval] { metalRenderer?.frameCPUTimes ?? [] }
    var metalDiagnosticSubmissionCount: Int { metalRenderer?.diagnosticSubmissionCount ?? 0 }
    var metalPresentationCount: Int { metalRenderer?.presentedFrameCount ?? 0 }
    func collectMetalPresentationMetrics() { metalRenderer?.collectsPresentationMetrics = true }
    func setMetalPresentationMetricsEnabled(_ enabled: Bool) { metalRenderer?.collectsPresentationMetrics = enabled }
    var nativeRequestedFramesPerSecond: Int? { metalView?.requestedFramesPerSecond }
    /// 原生收尾与 Metal 提交共享一个刷新时钟；返回 false 时调用方保留旧驱动。
    @discardableResult
    func driveNativeRelease(_ advance: @escaping (TimeInterval) -> Void) -> Bool {
        if let effectMetalView {
            effectMetalView.beforeRender = advance
            return true
        }
        guard hasLiveNativeCornerPresentation, let metalView else { return false }
        metalView.beforeRender = advance
        return true
    }
    var isNativeReleaseClockRunning: Bool { metalView?.drivesNativeRelease ?? false || effectMetalView?.drivesNativeRelease ?? false }

    /// 目标页已显示的占比；原生窗口采用最后提交姿态，首帧未提交时不推断隐形进度。
    /// 只用于单页触点 curl 的松手判定；双页与非触点路径保持原来的完成策略。
    func visibleTargetFraction(for input: PaperCornerDrag) -> CGFloat? {
        guard effect == .curl, spine != .center, hasResources else { return nil }
        let shown: PaperCornerDrag
        if hasLiveNativeCornerPresentation {
            guard let submittedCornerDrag else { return nil }
            shown = submittedCornerDrag
        } else { shown = input }
        guard let material = shown.foldingPresentation(direction: direction, size: bounds.size, spread: false),
              let moving = PaperCornerCurlGeometry.visiblePaperFraction(for: material, stripCount: requestedStripCount) else { return nil }
        return direction == .next ? 1 - moving : moving
    }


    /// 当前持有的两张原始快照的实际像素总数；释放后为零。
    private(set) var snapshotPixelCount = 0
    var hasResources: Bool {
        guard currentImage != nil, targetImage != nil else { return false }
        if effect.isWholePageMetalEffect { return effectMetalRenderer != nil }
        return cornerDriven || (!strips.isEmpty &&
            (spine != .center || backStrips.count == strips.count))
    }
    /// 实际材料条数；中央双页每条另有对应的真实背面，不重复计数。
    var stripCount: Int { hasResources && cornerDriven ? requestedStripCount : strips.count }

    /// - Parameters:
    ///   - currentView: 已加载、布局且可见的当前页面；中央书脊时包含两页。
    ///   - targetView: 与当前页 bounds.size 相同的目标页面；中央书脊时包含两页。
    ///   - effect: curl 或 arch。
    ///   - direction: 逻辑翻页方向。
    ///   - spine: 已解析的书脊；automatic 兼容旧接口，按 minimum 解释。
    ///   - options: 原图像素预算和条带精度。
    ///   - axis: 翻页轴；纵向 minimum 为上、maximum 为下。
    ///   - readingOrder: 横向中央书脊的阅读顺序；纵向按上、下排布。
    /// - Throws: 不支持的效果、非法配置或 snapshotUnavailable；不切换为其他动画。
    init(currentView: UIView, targetView: UIView, effect: PageTurnEffect,
         direction: PageTurnDirection, spine: PageSpinePlacement,
         options: PaperRenderingOptions, axis: PageTurnAxis = .horizontal,
         readingOrder: ReaderReadingOrder = .leftToRight, cornerDriven: Bool = false,
         cachedCurrent: CGImage? = nil,
         cachedCurrentTexture: PaperCornerMetalRenderer.TextureSnapshot? = nil,
         effectOrigin: CGPoint? = nil) throws {
        try options.validate()
        guard effect == .curl || effect == .arch || effect.isWholePageMetalEffect else { throw PageTurnError.unsupportedPresentation }
        let size = currentView.bounds.size
        guard Self.validBounds(currentView.bounds), Self.validBounds(targetView.bounds),
              size == targetView.bounds.size else { throw PageTurnError.snapshotUnavailable }
        let displayScale = max(1, currentView.traitCollection.displayScale)
        guard var plan = PaperTurnGeometry.snapshotPlan(
            width: Double(size.width), height: Double(size.height), displayScale: Double(displayScale),
            maximumSnapshotPixels: options.maximumSnapshotPixels
        ) else { throw PageTurnError.snapshotUnavailable }
        if spine == .center {
            // 两个半页共用相同的整数材料边界，最多舍去一个轴向像素，仍在原预算内。
            let pixels = axis == .horizontal ? plan.pixelWidth : plan.pixelHeight
            guard pixels >= 2 else { throw PageTurnError.snapshotUnavailable }
            plan = PaperSnapshotPlan(scale: plan.scale,
                pixelWidth: axis == .horizontal ? pixels / 2 * 2 : plan.pixelWidth,
                pixelHeight: axis == .vertical ? pixels / 2 * 2 : plan.pixelHeight)
        }

        // 上一笔的目标页就是这一笔的当前页：尺寸与预算一致时复用位图，省掉一半抓取开销。
        // 缓存位图按归一化 UV 采样，像素尺寸不必与本次预算完全一致；只要求画布比例一致，
        // 否则会把上一页的图按错误比例铺满。尺寸变化由调用方以视图 bounds 相等为前提。
        let reused = cachedCurrent.flatMap { image -> CGImage? in
            guard image.width > 0, image.height > 0, plan.pixelHeight > 0 else { return nil }
            let cachedAspect = CGFloat(image.width) / CGFloat(image.height)
            let planAspect = CGFloat(plan.pixelWidth) / CGFloat(plan.pixelHeight)
            return abs(cachedAspect - planAspect) < 0.01 ? image : nil
        }
        didReuseCurrentSnapshot = reused != nil
        let current = try reused ?? Self.capture(currentView, plan: plan)
        let target = try Self.capture(targetView, plan: plan)
        let moving = direction == .next ? current : target
        let landing = direction == .next ? target : current
        let prepared: [PreparedStrip]
        let preparedBack: [PreparedStrip]
        if effect.isWholePageMetalEffect || cornerDriven {
            // 整页 GPU 效果只用两张整页位图；GPU 路径直接采样完整纹理，均无需预裁 128 份 CGImage。
            prepared = []; preparedBack = []
        } else if spine == .center {
            let minimum = PaperSpreadGeometry.frontIsMinimum(axis: axis, readingOrder: readingOrder)
            prepared = try Self.prepareStrips(moving, count: options.stripCount, axis: axis, minimumHalf: minimum)
            preparedBack = try Self.prepareStrips(landing, count: options.stripCount, axis: axis, minimumHalf: !minimum)
        } else {
            prepared = try Self.prepareStrips(moving, count: options.stripCount, axis: axis)
            preparedBack = []
        }
        self.effect = effect
        self.cornerDriven = cornerDriven
        self.direction = direction
        self.spine = spine == .automatic ? .minimum : spine
        self.axis = axis
        self.readingOrder = readingOrder
        self.requestedStripCount = options.stripCount
        self.paperColor = Self.paperColor(for: direction == .next ? currentView : targetView)
        self.cornerPaperColor = Self.paperColor(for: direction == .next ? currentView : targetView)
        self.currentImage = current
        self.targetImage = target
        self.strips = prepared
        self.backStrips = preparedBack
        self.snapshotPixelCount = current.width * current.height + target.width * target.height
        super.init(frame: CGRect(origin: .zero, size: size))
        contentScaleFactor = CGFloat(plan.scale)
        contentMode = .redraw
        isOpaque = true
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = Self.paperColor(for: currentView)
        overrideUserInterfaceStyle = currentView.traitCollection.userInterfaceStyle
        if effect.isWholePageMetalEffect {
            // 无触点时沿用参考实现的默认原点（火焰起火点、水墨落墨点、破冰裂源）。
            let origin = effectOrigin ?? CGPoint(x: size.width * 0.79, y: size.height * 0.565)
            if PaperEffectMetalRenderer.isSupported,
               let renderer = try? PaperEffectMetalRenderer(current: current, target: target, size: size,
                   effect: effect, direction: direction, axis: axis, origin: origin) {
                effectMetalRenderer = renderer
                let display = PaperEffectMetalView(renderer: renderer, frame: CGRect(origin: .zero, size: size))
                display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(display)
                effectMetalView = display
            }
        }
        if cornerDriven, PaperCornerMetalRenderer.isSupported {
            metalRenderer = try PaperCornerMetalRenderer(current: current, target: target, size: size,
                axis: axis, spread: spine == .center, strips: options.stripCount, paperColor: cornerPaperColor,
                direction: direction, cachedCurrentTexture: reused == nil ? nil : cachedCurrentTexture,
                readingOrder: readingOrder, effect: effect)
        }
    }

    /// - Parameter coder: 不支持归档构造。
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用页面快照初始化方法") }

    /// - Parameters: progress: 逻辑进度；cornerDrag: 二维姿态；followsTouch: 原生拖动呈现轻缓，收尾或离屏参考直接对齐。
    /// - Returns: 无返回值。
    func update(progress: CGFloat, pageOrigin: CGPoint? = nil, cornerDrag: PaperCornerDrag? = nil, followsTouch: Bool = false) {
        guard progress.isFinite else { return }
        self.progress = min(1, max(0, progress))
        self.cornerDrag = cornerDrag
        if effect.isWholePageMetalEffect {
            // 水墨／破冰的原点跟随手指；火焰等固定原点效果每次收到同一原点。
            effectMetalView?.setProgress(self.progress, origin: pageOrigin)
            return
        }
        if let renderer = metalRenderer, let cornerDrag {
            let display: PaperCornerMetalView
            if let metalView { display = metalView }
            else {
                display = PaperCornerMetalView(renderer: renderer, frame: bounds)
                display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(display); metalView = display
            }
            display.update(cornerDrag, followsTouch: followsTouch)
        } else { setNeedsDisplay() }
    }

    /// - Parameter scale: 验收输出倍率；返回实际 GPU 绘制结果。原生手势从不调用读回或等待。
    func cornerGPUImage(scale: CGFloat = 1) throws -> UIImage? {
        guard let metalRenderer, let cornerDrag else { return nil }
        return try metalRenderer.snapshot(cornerDrag, scale: scale)
    }

    /// 幂等释放原图、正反面条带及已显示的图层位图，不持有或修改宿主页面。
    /// - Returns: 无返回值。
    func invalidateResources() {
        metalView?.invalidate(); metalView?.removeFromSuperview(); metalView = nil
        metalRenderer?.invalidate(); metalRenderer = nil
        effectMetalView?.invalidate(); effectMetalView?.removeFromSuperview(); effectMetalView = nil
        effectMetalRenderer = nil
        currentImage = nil
        targetImage = nil
        strips.removeAll(keepingCapacity: false)
        backStrips.removeAll(keepingCapacity: false)
        snapshotPixelCount = 0
        cornerDrag = nil
        layer.contents = nil
        setNeedsDisplay()
    }

    /// 转为幽灵收尾层：自身底图与露出的底页区域透明，只保留正在翻动的纸面与阴影。
    /// - Returns: 无返回值；重复调用无副作用。
    func beginGhostRelease() {
        guard !rendersGhostRelease else { return }
        rendersGhostRelease = true
        isOpaque = false
        backgroundColor = nil
        layer.contents = nil
        metalView?.setGhostUnderPage(true)
        setNeedsDisplay()
    }

    /// - Parameter rect: UIKit 请求刷新的区域；始终按完整 bounds 投影，避免局部刷新改变几何。
    /// - Returns: 无返回值。
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let current = currentImage, let target = targetImage,
              Self.validBounds(bounds), hasResources else { return }
        let page = CGRect(origin: .zero, size: bounds.size)
        let layout = PaperAxisGeometry(width: Double(page.width), height: Double(page.height), axis: axis)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.clip(to: page)
        context.interpolationQuality = .high
        if metalView != nil {
            // Metal 子层负责动态纸面；父层仅保留一次静态底图，避免同时运行 CPU 逐帧绘制。
            // 幽灵层不画底图：露出的底页由下方新一笔纸面补齐，本层只保留翻动纸面。
            if rendersGhostRelease { return }
            Self.drawImage(current, in: page, context: context); return
        }
        if effect.isWholePageMetalEffect {
            // GPU 图层负责动态纸面；父层只保留一次静态底图。
            Self.drawImage(current, in: page, context: context)
            return
        }
        if effect == .arch, let cornerDrag {
            drawDirectionalArch(cornerDrag, current: current, target: target, page: page, context: context)
            return
        }
        if effect == .curl, let cornerDrag {
            drawCornerCurl(cornerDrag, current: current, target: target, page: page, context: context)
            return
        }
        if progress == 0 {
            Self.drawImage(current, in: page, context: context)
            return
        }
        if progress == 1 {
            Self.drawImage(target, in: page, context: context)
            return
        }
        if spine == .center {
            drawSpread(current: current, target: target, page: page, layout: layout, context: context)
            return
        }
        Self.drawImage(direction == .next ? target : current, in: page, context: context)
        let moving = direction == .next ? current : target
        let geometry = PaperTurnGeometry.strips(
            width: layout.length, height: layout.breadth, progress: Double(progress),
            effect: effect, direction: direction, spine: spine,
            stripCount: requestedStripCount, sourcePixelWidth: axis == .horizontal ? moving.width : moving.height
        )
        drawBoundaryShadow(geometry, layout: layout, context: context)
        if effect == .curl, let t = PaperTurnGeometry.movingProgress(Double(progress), direction: direction) {
            let flatLength = CGFloat(layout.length) * CGFloat(1 - t)
            let flatStart = spine == .maximum ? CGFloat(layout.length) - flatLength : 0
            let flatRect = axis == .horizontal
                ? CGRect(x: flatStart, y: 0, width: flatLength, height: page.height)
                : CGRect(x: 0, y: flatStart, width: page.width, height: flatLength)
            context.saveGState()
            context.setShouldAntialias(false)
            context.clip(to: flatRect)
            // 平面区域保持整图采样，避免窄条带分别缩放导致静止文字失真。
            Self.drawImage(moving, in: page, context: context)
            context.restoreGState()
        }
        // 从远到近合成，卷起的背面才能遮住仍然平放的正面。
        for strip in geometry.sorted(by: { lhs, rhs in
            lhs.depth == rhs.depth ? lhs.index < rhs.index : lhs.depth < rhs.depth
        }) {
            guard strips.indices.contains(strip.index), strip.maximumX >= 0,
                  strip.minimumX <= layout.length else { continue }
            if effect == .curl, strip.depth == 0 { continue }
            drawStrip(strips[strip.index], geometry: strip, layout: layout, context: context)
        }
    }
}

private extension PaperTransitionView {
    /// - Parameters: points: 纸面多边形。返回闭合路径，空数组生成空路径。
    static func polygonPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// 软件参考与 GPU 共用拱页三角形；稳定端点始终直接绘制完整、正向的当前页或目标页。
    func drawDirectionalArch(_ drag: PaperCornerDrag, current: CGImage, target: CGImage,
                             page: CGRect, context: CGContext) {
        softwareCornerDrawCount += 1
        if rendersGhostRelease {
            // 幽灵层只画翻动纸面；完全折出／完全落平的终态不留任何内容。
            if drag.gestureProgress == 0 || (drag.gestureProgress == 1 && drag.archContactStrength == 0) { return }
        } else {
            if drag.gestureProgress == 0 { Self.drawImage(current, in: page, context: context); return }
            if drag.gestureProgress == 1, drag.archContactStrength == 0 { Self.drawImage(target, in: page, context: context); return }
        }
        // 与 Metal 的线性纹理采样保持一致，避免逐三角形的高阶重采样在字形边缘产生不同晕圈。
        context.interpolationQuality = .low
        let front = direction == .next ? current : target, under = direction == .next ? target : current
        let sourcePage = PaperArchGeometry.materialPage(for: drag, direction: direction)
        if rendersGhostRelease { /* 幽灵层不画底页 */ }
        else if spine == .center {
            Self.drawImage(front, in: page, context: context)
            context.saveGState(); context.clip(to: sourcePage)
            Self.drawImage(under, in: page, context: context); context.restoreGState()
        } else { Self.drawImage(under, in: page, context: context) }
        let mesh = PaperArchGeometry.mesh(for: drag, direction: direction, stripCount: requestedStripCount, readingOrder: readingOrder)
        drawCornerContactShadow([], drag: drag, context: context, vertices: mesh.shadow)
        for (patchIndex, patch) in mesh.patches.enumerated() {
            context.saveGState(); context.setShouldAntialias(false)
            context.concatenate(patch.transform)
            context.addPath(Self.polygonPath(patch.source)); context.clip()
            if patch.back, spine == .center {
                context.saveGState()
                context.concatenate(axis == .horizontal
                    ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: page.width, ty: 0)
                    : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: page.height))
                Self.drawImage(under, in: page, context: context); context.restoreGState()
            } else if patch.back {
                context.setFillColor(cornerPaperColor.cgColor); context.fill(page)
                context.saveGState(); context.setAlpha(0.52)
                Self.drawImage(front, in: page, context: context); context.restoreGState()
            } else { Self.drawImage(front, in: page, context: context) }
            let shades = zip(patch.source, mesh.shades[patchIndex]).map { PaperCornerShadowVertex(point: $0.0, opacity: $0.1) }
            drawCornerContactShadow([], drag: drag, context: context, vertices: shades)
            context.restoreGState()
        }
    }

    /// 二维折痕只投影原图，不在拖动中重拍页面或裁切新位图。
    /// - Parameters: drag: 抓取纸角；current: 当前整图；target: 目标整图；page: 画布；context: 绘制上下文。无返回值。
    func drawCornerCurl(_ input: PaperCornerDrag, current: CGImage, target: CGImage, page: CGRect, context: CGContext) {
        softwareCornerDrawCount += 1
        guard let drag = input.foldingPresentation(direction: direction, size: page.size, spread: spine == .center) else { return }
        let front = direction == .next ? current : target
        let under = direction == .next ? target : current
        let ghost = rendersGhostRelease
        if drag.translation == .zero {
            if !ghost { Self.drawImage(front, in: page, context: context) }
            return
        }
        let crossOffset = axis == .horizontal ? drag.translation.y : drag.translation.x
        if drag.progress == 1, crossOffset == 0 { return }
        let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: requestedStripCount)
        if ghost { /* 幽灵层不画底页，只画翻动纸面 */ }
        else if spine == .center {
            Self.drawImage(front, in: page, context: context)
            context.saveGState(); context.clip(to: drag.page)
            Self.drawImage(under, in: page, context: context); context.restoreGState()
        } else { Self.drawImage(under, in: page, context: context) }
        var shadowPlaced = false
        for patch in patches {
            if patch.back, !shadowPlaced {
                drawCornerContactShadow(patches, drag: drag, context: context)
                shadowPlaced = true
            }
            context.saveGState()
            context.setShouldAntialias(false)
            context.concatenate(patch.transform)
            context.addPath(Self.polygonPath(patch.source)); context.clip()
            if patch.back, spine == .center {
                // 目标另一半页先反向映射到材料正面；最终翻到对面时正文恢复正向。
                context.saveGState()
                context.concatenate(axis == .horizontal
                    ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: page.width, ty: 0)
                    : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: page.height))
                Self.drawImage(under, in: page, context: context); context.restoreGState()
            } else if patch.back {
                // 同一底色上保留移动纸页 52% 透印，纸背可读整行正文；反折由材料变换完成，弧面和平面完全一致。
                context.setFillColor(cornerPaperColor.cgColor); context.fill(page)
                context.saveGState(); context.setAlpha(0.52)
                Self.drawImage(front, in: page, context: context); context.restoreGState()
            } else { Self.drawImage(front, in: page, context: context) }
            if patch.shade > 0 {
                context.setFillColor(UIColor.black.withAlphaComponent(patch.shade).cgColor); context.fill(page)
            }
            context.restoreGState()
        }
    }

    /// - Parameters: patches: 当前有序纸面；drag: 抓取状态；context: 软件参考上下文。
    /// - Returns: 无返回值；仅在正面画好后、纸背开始前绘制一次接触阴影。
    func drawCornerContactShadow(_ patches: [PaperCornerPatch], drag: PaperCornerDrag, context: CGContext,
                                 vertices: [PaperCornerShadowVertex]? = nil) {
        let mesh = vertices ?? PaperCornerShadowGeometry.vertices(for: drag, patches: patches)
        for index in stride(from: 0, to: mesh.count, by: 3) {
            guard index + 2 < mesh.count else { continue }
            let a = mesh[index], b = mesh[index + 1], c = mesh[index + 2]
            let ux = b.point.x - a.point.x, uy = b.point.y - a.point.y
            let vx = c.point.x - a.point.x, vy = c.point.y - a.point.y
            let determinant = ux * vy - vx * uy
            guard abs(determinant) > 1e-8 else { continue }
            let da = b.opacity - a.opacity, db = c.opacity - a.opacity
            let gx = (da * vy - db * uy) / determinant
            let gy = (ux * db - vx * da) / determinant
            let magnitude = hypot(gx, gy)
            context.saveGState()
            context.setShouldAntialias(false)
            context.addPath(Self.polygonPath([a.point, b.point, c.point]))
            if magnitude < 1e-8 {
                context.setFillColor(UIColor.black.withAlphaComponent(a.opacity).cgColor)
                context.fillPath()
            } else {
                context.clip()
                let normal = CGPoint(x: gx / magnitude, y: gy / magnitude)
                let positions = [a.point, b.point, c.point].map { normal.x * $0.x + normal.y * $0.y }
                if let lower = positions.min(), let upper = positions.max(), upper > lower {
                    let constant = a.opacity - gx * a.point.x - gy * a.point.y
                    let lowerAlpha = min(1, max(0, magnitude * lower + constant))
                    let upperAlpha = min(1, max(0, magnitude * upper + constant))
                    let colors = [UIColor.black.withAlphaComponent(lowerAlpha).cgColor,
                                  UIColor.black.withAlphaComponent(upperAlpha).cgColor] as CFArray
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                        context.drawLinearGradient(gradient,
                            start: CGPoint(x: normal.x * lower, y: normal.y * lower),
                            end: CGPoint(x: normal.x * upper, y: normal.y * upper),
                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    }
                }
            }
            context.restoreGState()
        }
    }

    /// - Parameters: current: 当前原图；target: 目标原图；page: 零原点画布；layout: 轴向映射；context: 上下文。
    /// - Returns: 无返回值；上一页交换两张原图后复用完全相同的曲面与采样。
    func drawSpread(current: CGImage, target: CGImage, page: CGRect,
                    layout: PaperAxisGeometry, context: CGContext) {
        let front = direction == .next ? current : target
        let back = direction == .next ? target : current
        let minimum = PaperSpreadGeometry.frontIsMinimum(axis: axis, readingOrder: readingOrder)
        let half = layout.length / 2
        for isMinimum in [true, false] {
            context.saveGState()
            context.setShouldAntialias(false)
            context.clip(to: layout.rect(start: isMinimum ? 0 : half, end: isMinimum ? half : layout.length))
            // 固定页保持整图正向采样；移动页的下方是目标固定页，落点下方是当前固定页。
            Self.drawImage(isMinimum == minimum ? back : front, in: page, context: context)
            context.restoreGState()
        }
        let geometry = PaperSpreadGeometry.strips(
            width: Double(page.width), height: Double(page.height), progress: Double(progress),
            effect: effect, direction: direction, axis: axis, readingOrder: readingOrder,
            stripCount: requestedStripCount, sourcePixelLength: (axis == .horizontal ? front.width : front.height) / 2
        )
        for strip in geometry.sorted(by: { lhs, rhs in
            lhs.depth == rhs.depth ? lhs.index < rhs.index : lhs.depth < rhs.depth
        }) {
            guard strips.indices.contains(strip.index), backStrips.indices.contains(strip.index) else { continue }
            // 背面是真实目标半页。裁图时已按铰链距离配对，面向读者的文字无需镜像。
            let prepared = strip.isBackFace ? backStrips[strip.index] : strips[strip.index]
            drawStrip(prepared, geometry: strip, layout: layout, context: context, realBack: true)
        }
    }

    /// - Parameter bounds: 待捕获或绘制的局部坐标范围。
    /// - Returns: 原点有限且尺寸正有限时返回 true。
    static func validBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite &&
            bounds.size.width.isFinite && bounds.size.height.isFinite && bounds.size.width > 0 && bounds.size.height > 0
    }

    /// - Parameter view: 用于解析动态颜色和深色模式的宿主页面。
    /// - Returns: 优先使用宿主背景；透明背景退回当前 trait 的 systemBackground。
    static func paperColor(for view: UIView) -> UIColor {
        let fallback = UIColor.systemBackground.resolvedColor(with: view.traitCollection)
        let preferred = view.backgroundColor?.resolvedColor(with: view.traitCollection) ?? fallback
        return preferred.cgColor.alpha > 0 ? preferred.withAlphaComponent(1) : fallback
    }

    /// 在确定预算后才分配画布。整数像素尺寸配合 scale=1，避免 UIKit 向上取整突破预算。
    /// - Parameters: view: 已布局的页面；plan: 预先校验的两图像素计划。
    /// - Returns: 不含 UIImage 包装的零原点位图。
    /// - Throws: 无法生成与预算计划一致的位图时抛出 snapshotUnavailable。
    static func capture(_ view: UIView, plan: PaperSnapshotPlan) throws -> CGImage {
        let pixelSize = CGSize(width: plan.pixelWidth, height: plan.pixelHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { output in
            let context = output.cgContext
            context.setFillColor(paperColor(for: view).cgColor)
            context.fill(CGRect(origin: .zero, size: pixelSize))
            // 各轴按整像素画布拟合；误差小于一个像素，不裁掉页面最末行或最末列。
            context.scaleBy(x: pixelSize.width / view.bounds.width, y: pixelSize.height / view.bounds.height)
            context.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
            view.layer.render(in: context)
        }
        guard let result = image.cgImage, result.width == plan.pixelWidth,
              result.height == plan.pixelHeight else { throw PageTurnError.snapshotUnavailable }
        return result
    }

    /// 构造时裁出整数材料条带，沿采样轴两侧各保留最多两个像素；核心材料区互不重叠。
    /// CGImage 可能共享原图或另建存储；正反面条带与行对齐开销不计入两张原图预算。
    /// - Parameters: image: 正向整图；count: 请求条数；axis: 采样轴；minimumHalf: 中央半页位置，nil 表示整页。
    /// - Returns: 每帧可直接绘制的条带；半页条带按书脊到外缘排列。
    /// - Throws: 任一裁图失败时抛出 snapshotUnavailable，不交付残缺效果。
    private static func prepareStrips(_ image: CGImage, count: Int, axis: PageTurnAxis,
                                      minimumHalf: Bool? = nil) throws -> [PreparedStrip] {
        let pixels = axis == .horizontal ? image.width : image.height
        let length = minimumHalf == nil ? pixels : pixels / 2
        let offset = minimumHalf == false ? length : 0
        let actualCount = min(count, length)
        var result: [PreparedStrip] = []
        result.reserveCapacity(actualCount)
        for index in 0..<actualCount {
            let materialLower = index * length / actualCount
            let materialUpper = (index + 1) * length / actualCount
            let lower = minimumHalf == true ? length - materialUpper : materialLower
            let upper = minimumHalf == true ? length - materialLower : materialUpper
            let sampleLower = max(0, lower - 2)
            let sampleUpper = min(length, upper + 2)
            let crop = axis == .horizontal
                ? CGRect(x: offset + sampleLower, y: 0, width: sampleUpper - sampleLower, height: image.height)
                : CGRect(x: 0, y: offset + sampleLower, width: image.width, height: sampleUpper - sampleLower)
            guard let cropped = image.cropping(to: crop) else { throw PageTurnError.snapshotUnavailable }
            result.append(PreparedStrip(image: cropped,
                leadingFraction: CGFloat(lower - sampleLower) / CGFloat(upper - lower),
                trailingFraction: CGFloat(sampleUpper - upper) / CGFloat(upper - lower)))
        }
        return result
    }

    /// - Parameters: image: 正向源位图；rect: 目标矩形；context: UIKit 的 Y 向下上下文；mirrored: 是否反向；axis: 反向采样轴。
    /// - Returns: 无返回值；轴向变形与源采样配对，不旋转最终画面。
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext,
                          mirrored: Bool = false, axis: PageTurnAxis = .horizontal) {
        let flipX = mirrored && axis == .horizontal
        let flipY = mirrored && axis == .vertical
        context.saveGState()
        context.translateBy(x: flipX ? rect.maxX : rect.minX, y: flipY ? rect.minY : rect.maxY)
        context.scaleBy(x: flipX ? -1 : 1, y: flipY ? 1 : -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// - Parameters: prepared: 预裁图；geometry: 当前投影；layout: 轴向映射；context: 上下文；realBack: 是否使用真实双页背面。
    /// - Returns: 无返回值。
    private func drawStrip(_ prepared: PreparedStrip, geometry: PaperStripGeometry,
                           layout: PaperAxisGeometry, context: CGContext, realBack: Bool = false) {
        let width = CGFloat(geometry.maximumX - geometry.minimumX)
        guard width > 0 else { return }
        let rect = layout.rect(start: geometry.minimumX, end: geometry.maximumX, expansion: geometry.verticalExpansion)
        context.saveGState()
        // 相邻投影共享精确边界；关闭几何边缘抗锯齿，保留图像内部的高质量插值。
        context.setShouldAntialias(false)
        context.clip(to: rect)
        let mirrored = geometry.isBackFace && !realBack
        let leading = mirrored ? prepared.trailingFraction : prepared.leadingFraction
        let sampleLength = width * (1 + prepared.leadingFraction + prepared.trailingFraction)
        let imageRect = axis == .horizontal
            ? CGRect(x: rect.minX - leading * width, y: rect.minY, width: sampleLength, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY - leading * width, width: rect.width, height: sampleLength)
        if mirrored {
            context.setFillColor(paperColor.cgColor)
            context.fill(rect.insetBy(dx: -1, dy: -1))
            context.setAlpha(0.12)
            Self.drawImage(prepared.image, in: imageRect, context: context, mirrored: true, axis: axis)
            context.setAlpha(1)
        } else {
            Self.drawImage(prepared.image, in: imageRect, context: context)
        }
        context.setFillColor(UIColor.black.withAlphaComponent(CGFloat(geometry.shade)).cgColor)
        // 填满既定 clip；直接按同一 rect 填充在半像素边界可能漏掉一列阴影。
        context.fill(rect.insetBy(dx: -1, dy: -1))
        context.restoreGState()
    }

    /// - Parameters: geometry: 当前帧条带；layout: 轴向映射；context: 绘图上下文。
    /// - Returns: 无返回值。
    func drawBoundaryShadow(_ geometry: [PaperStripGeometry], layout: PaperAxisGeometry, context: CGContext) {
        let visible = geometry.filter { $0.maximumX > 0 && $0.minimumX < layout.length }
        guard !visible.isEmpty,
              let t = PaperTurnGeometry.movingProgress(Double(progress), direction: direction) else { return }
        let strength = CGFloat(sin(.pi * t))
        let boundary = spine == .maximum
            ? visible.reduce(layout.length) { min($0, $1.minimumX) }
            : visible.reduce(0.0) { max($0, $1.maximumX) }
        let bandWidth = (8 + CGFloat(layout.length) * 0.02) * strength / 12
        for index in 0..<12 {
            let offset = CGFloat(index) * bandWidth
            let x = spine == .maximum ? CGFloat(boundary) - offset - bandWidth : CGFloat(boundary) + offset
            let alpha = 0.16 * strength * pow(1 - CGFloat(index) / 12, 2)
            context.setFillColor(UIColor.black.withAlphaComponent(alpha).cgColor)
            context.fill(axis == .horizontal
                ? CGRect(x: x, y: 0, width: bandWidth, height: CGFloat(layout.breadth))
                : CGRect(x: 0, y: x, width: CGFloat(layout.breadth), height: bandWidth))
        }
    }
}
#endif
