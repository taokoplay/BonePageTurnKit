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
    private var currentImage: CGImage?
    private var targetImage: CGImage?
    private var strips: [PreparedStrip] = []
    private var backStrips: [PreparedStrip] = []
    private var progress: CGFloat = 0

    /// 当前持有的两张原始快照的实际像素总数；释放后为零。
    private(set) var snapshotPixelCount = 0
    var hasResources: Bool {
        currentImage != nil && targetImage != nil && !strips.isEmpty &&
            (spine != .center || backStrips.count == strips.count)
    }
    /// 实际材料条数；中央双页每条另有对应的真实背面，不重复计数。
    var stripCount: Int { strips.count }

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
         readingOrder: ReaderReadingOrder = .leftToRight) throws {
        try options.validate()
        guard effect == .curl || effect == .arch else { throw PageTurnError.unsupportedPresentation }
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

        let current = try Self.capture(currentView, plan: plan)
        let target = try Self.capture(targetView, plan: plan)
        let moving = direction == .next ? current : target
        let landing = direction == .next ? target : current
        let prepared: [PreparedStrip]
        let preparedBack: [PreparedStrip]
        if spine == .center {
            let minimum = PaperSpreadGeometry.frontIsMinimum(axis: axis, readingOrder: readingOrder)
            prepared = try Self.prepareStrips(moving, count: options.stripCount, axis: axis, minimumHalf: minimum)
            preparedBack = try Self.prepareStrips(landing, count: options.stripCount, axis: axis, minimumHalf: !minimum)
        } else {
            prepared = try Self.prepareStrips(moving, count: options.stripCount, axis: axis)
            preparedBack = []
        }
        self.effect = effect
        self.direction = direction
        self.spine = spine == .automatic ? .minimum : spine
        self.axis = axis
        self.readingOrder = readingOrder
        self.requestedStripCount = options.stripCount
        self.paperColor = Self.paperColor(for: direction == .next ? currentView : targetView)
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
    }

    /// - Parameter coder: 不支持归档构造。
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用页面快照初始化方法") }

    /// - Parameter progress: 逻辑进度；有限值钳制到 0...1，非有限值保持上一帧。
    /// - Returns: 无返回值。
    func update(progress: CGFloat) {
        guard progress.isFinite else { return }
        self.progress = min(1, max(0, progress))
        setNeedsDisplay()
    }

    /// 幂等释放原图、正反面条带及已显示的图层位图，不持有或修改宿主页面。
    /// - Returns: 无返回值。
    func invalidateResources() {
        currentImage = nil
        targetImage = nil
        strips.removeAll(keepingCapacity: false)
        backStrips.removeAll(keepingCapacity: false)
        snapshotPixelCount = 0
        layer.contents = nil
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
