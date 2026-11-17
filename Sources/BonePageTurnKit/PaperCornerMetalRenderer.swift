#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit

/// 同一设备共享着色管线；只在首次使用时编译，不在抓取或逐帧绘制时创建管线。
@MainActor
private final class PaperCornerMetalContext {
    enum Failure: Error { case unavailable, shader, texture, buffer, command }
    static let shared: Result<PaperCornerMetalContext, Error> = Result { try PaperCornerMetalContext() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let loader: MTKTextureLoader

    /// 创建本设备资源；无参数，失败向调用方返回明确错误。
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        self.device = device; self.queue = queue; loader = MTKTextureLoader(device: device)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cornerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cornerFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct CornerVertex { float2 point; float2 uv; float material; float shade; float2 padding; };
    struct CornerOutput { float4 position [[position]]; float2 uv; float material [[flat]]; float shade; };
    vertex CornerOutput cornerVertex(uint id [[vertex_id]], const device CornerVertex *vertices [[buffer(0)]],
                                     constant float2 &viewport [[buffer(1)]]) {
        CornerVertex v = vertices[id]; CornerOutput out;
        out.position = float4(v.point.x * 2.0 / viewport.x - 1.0, 1.0 - v.point.y * 2.0 / viewport.y, 0, 1);
        out.uv = v.uv; out.material = v.material; out.shade = v.shade; return out;
    }
    fragment float4 cornerFragment(CornerOutput in [[stage_in]], texture2d<float> current [[texture(0)]],
                                   texture2d<float> target [[texture(1)]], constant float4 &paper [[buffer(0)]]) {
        if (in.material > 2.5) { return float4(0, 0, 0, in.shade); }
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        // 单页背材保留移动纸页的透印，源坐标随纸面反折；弧面和平面采用相同混合。
        // 0.52 让纸背能读出整行正文（外部参考录屏实测约 +10% 亮度、正文可读），同时仍压住纸色底。
        float4 color = in.material > 1.5 ? mix(paper, current.sample(imageSampler, in.uv), 0.52)
            : (in.material > 0.5 ? target.sample(imageSampler, in.uv) : current.sample(imageSampler, in.uv));
        return float4(color.rgb * (1.0 - in.shade), 1);
    }
    """
}

/// 四角卷曲的 GPU 绘制器。正反面和阴影共用一批三角形，一次提交；没有逐块整页重绘。
@MainActor
final class PaperCornerMetalRenderer {
    private struct Vertex {
        let point: SIMD2<Float>
        let uv: SIMD2<Float>
        let material: Float
        let shade: Float
        let padding: SIMD2<Float> = .zero
    }
    private struct Slot {
        let buffer: MTLBuffer
        var command: MTLCommandBuffer?
    }
    struct Timing {
        let cpu: TimeInterval
        let gpu: TimeInterval
    }
    /// 位图与其已上传纹理成对交接；只接受同一 CGImage 和同一 Metal 设备。
    struct TextureSnapshot {
        let image: CGImage
        let texture: MTLTexture
    }
    private(set) var targetPageSnapshot: TextureSnapshot?
    private(set) var textureUploadCount = 0

    private let context: PaperCornerMetalContext
    private var current: MTLTexture?
    private var target: MTLTexture?
    private let size: CGSize
    private let axis: PageTurnAxis
    private let direction: PageTurnDirection
    private let readingOrder: ReaderReadingOrder
    private let spread: Bool
    private let strips: Int
    private let color: SIMD4<Float>
    private var slots: [Slot] = []
    private var nextSlot = 0
    private var vertices: [Vertex] = []
    private let maximumVertices: Int
    private(set) var lastTiming: Timing?
    private(set) var submittedFrameCount = 0
    var collectsPresentationMetrics = false {
        didSet {
            guard oldValue != collectsPresentationMetrics else { return }
            presentationCollectionID = UUID()
            presentedTimes.removeAll(keepingCapacity: true)
            frameCPUTimes.removeAll(keepingCapacity: true)
            presentedFrameCount = 0
            collectionSubmissionStart = submittedFrameCount
        }
    }
    private(set) var presentationCollectionID = UUID()
    private(set) var presentedFrameCount = 0
    private var collectionSubmissionStart = 0
    var diagnosticSubmissionCount: Int { collectsPresentationMetrics ? submittedFrameCount - collectionSubmissionStart : 0 }
    private(set) var presentedTimes: [TimeInterval] = []
    private(set) var frameCPUTimes: [TimeInterval] = []
    var isActive: Bool { current != nil && target != nil && !slots.isEmpty }

    /// 预热编译；没有 Metal 的系统保留同几何的软件绘制路径。
    static func prewarm() { _ = PaperCornerMetalContext.shared }
    static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// - Parameters: current: 当前页快照；target: 目标页快照；size: 点坐标视口；axis: 翻页轴；spread: 是否双页；strips: 曲面精度；paperColor: 单页纸背底色。
    /// - Throws: 本机 Metal 资源创建失败；不创建另一种翻页效果。
    init(current: CGImage, target: CGImage, size: CGSize, axis: PageTurnAxis,
         spread: Bool, strips: Int, paperColor: UIColor, direction: PageTurnDirection = .next,
         cachedCurrentTexture: TextureSnapshot? = nil, readingOrder: ReaderReadingOrder = .leftToRight,
         effect: PageTurnEffect = .curl) throws {
        context = try PaperCornerMetalContext.shared.get()
        self.size = size; self.axis = axis; self.direction = direction; self.spread = spread; self.strips = strips
        self.readingOrder = readingOrder
        maximumVertices = effect == .arch ? 32_768 : 8_192
        let rgb = paperColor.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        let components = rgb?.components ?? [1, 1, 1, 1]
        color = components.count >= 3 ? SIMD4(Float(components[0]), Float(components[1]), Float(components[2]), 1)
            : SIMD4(repeating: Float(components.first ?? 1))
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue]
        let currentPage: TextureSnapshot
        if let cached = cachedCurrentTexture, cached.image === current,
           cached.texture.device.registryID == context.device.registryID,
           cached.texture.width == current.width, cached.texture.height == current.height {
            currentPage = cached
        } else {
            currentPage = TextureSnapshot(image: current, texture: try context.loader.newTexture(cgImage: current, options: options))
            textureUploadCount += 1
        }
        let targetPage = TextureSnapshot(image: target, texture: try context.loader.newTexture(cgImage: target, options: options))
        textureUploadCount += 1
        targetPageSnapshot = targetPage
        // 回翻的运动纸张统一取上一页，底页仍为当前页；正翻角色不变。
        let swapsPages = direction == .previous
        self.current = swapsPages ? targetPage.texture : currentPage.texture
        self.target = swapsPages ? currentPage.texture : targetPage.texture
        for _ in 0..<3 {
            guard let buffer = context.device.makeBuffer(length: maximumVertices * MemoryLayout<Vertex>.stride, options: .storageModeShared) else {
                throw PaperCornerMetalContext.Failure.buffer
            }
            slots.append(Slot(buffer: buffer))
        }
        vertices.reserveCapacity(maximumVertices)
    }

    /// - Parameter layer: 本视图拥有的 Metal 图层；无返回值，仅配置资源，不抓取 drawable。
    func configure(_ layer: CAMetalLayer) {
        layer.device = context.device; layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true; layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true; layer.presentsWithTransaction = false
    }

    /// - Parameters: drag: 最新触点；layer: 显示图层。
    /// - Returns: 是否已提交。GPU 忙时保留最新状态供下一帧使用，不在主线程等待旧帧。
    var canSubmitFrame: Bool {
        isActive && slots.contains { $0.command == nil || $0.command?.status == .completed || $0.command?.status == .error }
    }
    func present(_ drag: PaperCornerDrag, drawable: CAMetalDrawable) -> Bool {
        guard let folded = foldingPresentation(drag) else { return false }
        return presentFolding(folded, drawable: drawable)
    }

    /// - Parameter input: 原交互坐标。返回实际材料坐标中的折面，用于追随与 GPU 绘制。
    func foldingPresentation(_ input: PaperCornerDrag) -> PaperCornerDrag? {
        input.foldingPresentation(direction: direction, size: size, spread: spread)
    }

    /// - Parameter folding: 已提交的材料坐标。返回供收尾使用的等价交互坐标。
    func interactivePresentation(_ folding: PaperCornerDrag) -> PaperCornerDrag? {
        folding.interactivePresentation(direction: direction, size: size, spread: spread)
    }

    /// - Parameters: drag: 已求得的材料折面；drawable: 目标图层。返回是否成功提交，不再重复转换回翻坐标。
    func presentFolding(_ drag: PaperCornerDrag, drawable: CAMetalDrawable) -> Bool {
        guard isActive, let index = availableSlot() else { return false }
        return encode(drag, texture: drawable.texture, drawable: drawable, slot: index, wait: false)
    }

    /// - Parameter drag: 被测触点；返回 GPU 的真实绘制结果和提交／执行时间。只用于离屏验收，不进入原生手势路径。
    func snapshot(_ drag: PaperCornerDrag, scale: CGFloat = 1) throws -> UIImage {
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        guard let folding = foldingPresentation(drag),
              let texture = context.device.makeTexture(descriptor: descriptor), let index = availableSlot(),
              encode(folding, texture: texture, drawable: nil, slot: index, wait: true) else { throw PaperCornerMetalContext.Failure.command }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PaperCornerMetalContext.Failure.texture }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// 失效时停止接收新帧；已提交命令自行持有其 GPU 资源直至执行结束。无参数及返回值。
    func invalidate() {
        current = nil; target = nil; targetPageSnapshot = nil; slots.removeAll(); vertices.removeAll(keepingCapacity: false)
    }

    /// 呈现窗口持续滚动，总数持续累加；关闭或重开采集后拒绝迟到的旧代次回调。
    func recordPresentedTime(_ timestamp: TimeInterval, collectionID: UUID) {
        guard isActive, collectsPresentationMetrics, collectionID == presentationCollectionID,
              timestamp.isFinite, timestamp > 0 else { return }
        presentedFrameCount += 1
        presentedTimes.append(timestamp)
        if presentedTimes.count > 512 { presentedTimes.removeFirst(presentedTimes.count - 512) }
    }

    /// 返回可复用的缓冲区；不等待、不覆盖 GPU 仍在使用的顶点数据。
    private func availableSlot() -> Int? {
        guard !slots.isEmpty else { return nil }
        for offset in slots.indices {
            let index = (nextSlot + offset) % slots.count
            guard let command = slots[index].command else { nextSlot = (index + 1) % slots.count; return index }
            if command.status == .completed || command.status == .error {
                nextSlot = (index + 1) % slots.count; return index
            }
        }
        return nil
    }

    /// - Parameters: drag: 抓取状态；texture: 输出纹理；drawable: 可选屏幕输出；slot: 空闲缓冲区；wait: 仅离屏验收同步等待。
    /// - Returns: 是否已提交；正常显示路径从不等待命令完成。
    private func encode(_ drag: PaperCornerDrag, texture: MTLTexture, drawable: CAMetalDrawable?, slot: Int, wait: Bool) -> Bool {
        guard let current, let target, slots.indices.contains(slot) else { return false }
        let start = CACurrentMediaTime()
        buildVertices(drag)
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        guard !vertices.isEmpty, vertices.count <= maximumVertices, byteCount <= slots[slot].buffer.length,
              let command = context.queue.makeCommandBuffer() else { return false }
        // 仅拷贝有界 POD 顶点字节，借用期内完成拷贝，缓冲区在命令完成前不复用。
        vertices.withUnsafeBytes { source in
            if let address = source.baseAddress { slots[slot].buffer.contents().copyMemory(from: address, byteCount: source.count) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(context.pipeline)
        encoder.setVertexBuffer(slots[slot].buffer, offset: 0, index: 0)
        var viewport = SIMD2(Float(size.width), Float(size.height)), paper = color
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&paper, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(current, index: 0); encoder.setFragmentTexture(target, index: 1)
        encoder.setCullMode(.none)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        if let drawable {
            #if !targetEnvironment(simulator)
            if collectsPresentationMetrics {
                let collectionID = presentationCollectionID
                drawable.addPresentedHandler { [weak self] presented in
                    let timestamp = presented.presentedTime
                    DispatchQueue.main.async { [weak self] in
                        self?.recordPresentedTime(timestamp, collectionID: collectionID)
                    }
                }
            }
            #endif
            command.present(drawable)
        }
        slots[slot].command = command; command.commit(); submittedFrameCount += 1
        let cpu = CACurrentMediaTime() - start
        if collectsPresentationMetrics, frameCPUTimes.count < 512 { frameCPUTimes.append(cpu) }
        if wait {
            command.waitUntilCompleted()
            guard command.status == .completed else { return false }
            lastTiming = Timing(cpu: cpu, gpu: max(0, command.gpuEndTime - command.gpuStartTime))
        } else { lastTiming = Timing(cpu: cpu, gpu: 0) }
        return true
    }

    /// - Parameter drag: 当前纸面；无返回值，复用顶点数组生成背景、轮廓阴影和有序正反面。
    private func buildVertices(_ drag: PaperCornerDrag) {
        vertices.removeAll(keepingCapacity: true)
        let page = CGRect(origin: .zero, size: size)
        if drag.effect == .arch { buildArchVertices(drag, page: page); return }
        if drag.translation == .zero { rectangle(page, material: 0); return }
        let cross = axis == .horizontal ? drag.translation.y : drag.translation.x
        if drag.progress == 1, cross == 0 { rectangle(page, material: 1); return }
        if spread { rectangle(page, material: 0); rectangle(drag.page, material: 1) }
        else { rectangle(page, material: 1) }
        let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: strips)
        var shadowPlaced = false
        for patch in patches {
            guard patch.source.count >= 3 else { continue }
            // 投影必须位于已画好的正文之上、纸背之下，不能被后画的正面擦掉。
            if patch.back, !shadowPlaced { shadow(patches, drag: drag); shadowPlaced = true }
            let material: Float = patch.back ? (spread ? 1 : 2) : 0
            for i in 1..<(patch.source.count - 1) {
                for source in [patch.source[0], patch.source[i], patch.source[i + 1]] {
                    var uvPoint = source
                    if patch.back && spread {
                        if axis == .horizontal { uvPoint.x = size.width - source.x }
                        else { uvPoint.y = size.height - source.y }
                    }
                    vertex(source.applying(patch.transform), uv: uvPoint, material: material, shade: Float(patch.shade))
                }
            }
        }
    }

    /// 拱页共用同一次约束求解的纸面与高度投影，不在逐帧路径重复建立几何。
    private func buildArchVertices(_ drag: PaperCornerDrag, page: CGRect) {
        let returning = direction == .previous
        if drag.gestureProgress == 0 { rectangle(page, material: returning ? 1 : 0); return }
        if drag.gestureProgress == 1, drag.archContactStrength == 0 { rectangle(page, material: returning ? 0 : 1); return }
        let sourcePage = PaperArchGeometry.materialPage(for: drag, direction: direction)
        if spread { rectangle(page, material: 0); rectangle(sourcePage, material: 1) }
        else { rectangle(page, material: 1) }
        let mesh = PaperArchGeometry.mesh(for: drag, direction: direction, stripCount: strips, readingOrder: readingOrder)
        for shade in mesh.shadow { vertex(shade.point, material: 3, shade: Float(shade.opacity)) }
        for (patchIndex, patch) in mesh.patches.enumerated() {
            for (vertexIndex, source) in patch.source.enumerated() {
                var uv = source
                if patch.back && spread {
                    if axis == .horizontal { uv.x = size.width - source.x }
                    else { uv.y = size.height - source.y }
                }
                vertex(source.applying(patch.transform), uv: uv, material: patch.back ? (spread ? 1 : 2) : 0,
                    shade: Float(mesh.shades[patchIndex][vertexIndex]))
            }
        }
    }

    /// - Parameters: point: 投影坐标；uv: 材料采样坐标；material: 当前／目标／纸背／阴影；shade: 明暗。追加单个有界顶点。
    private func vertex(_ point: CGPoint, uv: CGPoint = .zero, material: Float, shade: Float = 0) {
        vertices.append(Vertex(point: SIMD2(Float(point.x), Float(point.y)),
            uv: SIMD2(Float(uv.x / size.width), Float(uv.y / size.height)), material: material, shade: shade))
    }

    /// - Parameters: rect: 全页或半页；material: 快照来源。追加两个三角形。
    private func rectangle(_ rect: CGRect, material: Float) {
        let a = CGPoint(x: rect.minX, y: rect.minY), b = CGPoint(x: rect.maxX, y: rect.minY)
        let c = CGPoint(x: rect.maxX, y: rect.maxY), d = CGPoint(x: rect.minX, y: rect.maxY)
        for p in [a, b, c, a, c, d] { vertex(p, uv: p, material: material) }
    }

    /// - Parameters: patches: 当前纸面；drag: 抓取状态。
    /// - Returns: 无返回值；根部到纸角的局部高度决定投影宽度与透明度，仍为同一 GPU 批次。
    private func shadow(_ patches: [PaperCornerPatch], drag: PaperCornerDrag) {
        for shadowVertex in PaperCornerShadowGeometry.vertices(for: drag, patches: patches) {
            vertex(shadowVertex.point, material: 3, shade: Float(shadowVertex.opacity))
        }
    }

}

/// Metal 图层只接收最新触点；一次屏幕刷新最多提交一帧，GPU 忙时不排队积累过时手势。
@MainActor
final class PaperCornerMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private let renderer: PaperCornerMetalRenderer
    private let clock = ReaderDisplayLink()
    private var pending: PaperCornerDrag?
    private var follower = PaperCornerDragFollower()
    private(set) var submittedFrameCount = 0
    private(set) var submittedDrag: PaperCornerDrag?
    /// 追随已收敛且没有待提交姿态：之后不会再产生新提交。
    var framesExhausted: Bool { pending == nil }
    var requestedFramesPerSecond: Int? {
        guard clock.isRunning else { return nil }
        return Int(clock.activeFrameRateRange?.preferred ?? 0)
    }
    /// 最后提交的姿态；首帧之前使用追随起点，不能从未显示的逻辑目标直接开始收尾。
    var releaseStartDrag: PaperCornerDrag? {
        submittedDrag ?? follower.current.flatMap { renderer.interactivePresentation($0) }
    }
    private var active = true
    private var idleFrames = 0
    private let drawableQueue = DispatchQueue(label: "BonePageTurnKit.cornerDrawable", qos: .userInteractive)
    private var acquiringDrawable = false
    /// 原生收尾和绘制共用此时钟；每次取 drawable 前先推进一笔待显示姿态。
    var beforeRender: ((TimeInterval) -> Void)? {
        didSet { if beforeRender != nil { clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond) } }
    }
    var drivesNativeRelease: Bool { beforeRender != nil && clock.isRunning }

    /// - Parameters: renderer: 本次翻页拥有的资源；frame: 全幅纸面坐标。
    init(renderer: PaperCornerMetalRenderer, frame: CGRect) {
        self.renderer = renderer
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = true; isHidden = true
        if let metal = layer as? CAMetalLayer { renderer.configure(metal) }
        clock.onTick = { [weak self] elapsed in self?.renderLatest(elapsed: elapsed) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// - Parameters: drag: 最新逻辑触点；followsTouch: 拖动时轻缓跟随，收尾直接使用已求得姿态。
    /// - Returns: 无返回值；中间过时目标直接覆盖，不排队重播。
    func update(_ drag: PaperCornerDrag, followsTouch: Bool = false) {
        guard active, let folding = renderer.foldingPresentation(drag) else { return }
        // 两个方向都在实际材料坐标中追随；回翻起手从画布外连续翻向手指，而非先跳半页。
        pending = folding; follower.update(folding, followsTouch: followsTouch)
        idleFrames = 0; clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clock.stop() }
        else if pending != nil || beforeRender != nil { clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let metal = layer as? CAMetalLayer {
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            if metal.drawableSize != size { metal.drawableSize = size }
        }
    }

    /// 清理时钟和纹理；无参数及返回值。
    func invalidate() { active = false; beforeRender = nil; pending = nil; submittedDrag = nil; follower.reset(); clock.stop(); renderer.invalidate() }

    /// - Parameter elapsed: 可见帧推进秒数；只有成功提交画面后才保留进度，等待不产生隐藏快进。
    /// - Returns: 无返回值；只提交当前姿态，停手收敛后停止空闲绘制。
    private func renderLatest(elapsed: TimeInterval) {
        guard active, let metal = layer as? CAMetalLayer, window != nil else { clock.stop(); return }
        beforeRender?(elapsed)
        // 推进可能已提交终态、失效并移除此视图；旧 tick 不得继续绘制。
        guard active, window != nil else { return }
        guard pending != nil else {
            idleFrames += 1
            if idleFrames >= 2, beforeRender == nil { clock.stop() }
            return
        }
        guard bounds.width > 0, bounds.height > 0, !acquiringDrawable, renderer.canSubmitFrame else { return }
        layoutIfNeeded(); acquiringDrawable = true
        // nextDrawable 可能等待显示服务器归还资源；任何情况下都不占用主线程。
        // ObjC drawable 的所有权只沿此单一任务回传；工作队列不读写任何视图状态。
        let request = DispatchWorkItem { [weak self] in
            let drawable = metal.nextDrawable()
            let completion = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.acquiringDrawable = false
                    guard self.active, self.window != nil, let drawable, let latest = self.pending else { return }
                    var next = self.follower
                    next.advance(elapsed: elapsed)
                    guard let shown = next.current else { return }
                    if self.renderer.presentFolding(shown, drawable: drawable) {
                        self.follower = next
                        self.submittedFrameCount += 1
                        self.submittedDrag = self.renderer.interactivePresentation(shown)
                        if self.follower.isSettled, self.pending == latest { self.pending = nil }
                        self.isHidden = false; self.idleFrames = 0
                    }
                }
            }
            DispatchQueue.main.async(execute: completion)
        }
        drawableQueue.async(execute: request)
    }
}
#endif
