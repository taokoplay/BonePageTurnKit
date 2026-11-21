#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit

// MARK: - 整页 GPU 效果元数据

extension PageTurnEffect {
    /// 依赖整页两张快照纹理与片段着色器的效果；拖动按位移驱动，没有角点姿态，
    /// 与参考实现（page-turn-lab）的视频转场一一对应。
    var isWholePageMetalEffect: Bool {
        switch self {
        case .burn, .glitch, .fold, .shatter, .inkwash, .icecrack, .wave: return true
        default: return false
        }
    }

    /// 拖动进度换算系数；参考实现 dragProgressScale：火焰／水墨／破冰 0.5，浪潮 0.6，其余 1。
    var dragProgressScale: CGFloat {
        switch self {
        case .burn, .inkwash, .icecrack: return 0.5
        case .wave: return 0.6
        default: return 1
        }
    }

    /// 点击翻页收尾时长相对基准（0.36s）的倍率；对齐参考实现整页播放时长
    /// （火焰 633ms、故障 1067ms、折纸 560ms、碎片 560ms、水墨 750ms、破冰 800ms、浪潮 850ms）。
    var releaseDurationScale: Double {
        switch self {
        case .burn: return 1.75
        case .glitch: return 2.95
        case .fold, .shatter: return 1.55
        case .inkwash: return 2.08
        case .icecrack: return 2.22
        case .wave: return 2.35
        default: return 1
        }
    }

    /// 触点作为效果原点：起火点、落墨点、裂源、浪源、碎裂波；上一页点击仍取运动侧页缘中点。
    var usesTouchOrigin: Bool {
        switch self {
        case .burn, .inkwash, .icecrack, .wave, .shatter: return true
        default: return false
        }
    }

    /// 拖动中原点持续跟随手指：破冰融霜手指移到哪里融到哪里，水墨／浪潮／碎片同理。
    var originFollowsFinger: Bool {
        switch self {
        case .inkwash, .icecrack, .wave, .shatter: return true
        default: return false
        }
    }

    /// 共享 shader 库中的片段函数名。
    var metalFragmentName: String {
        switch self {
        case .burn: return "burnFragment"
        case .glitch: return "glitchFragment"
        case .fold: return "foldFragment"
        case .shatter: return "shatterFragment"
        case .inkwash: return "inkwashFragment"
        case .icecrack: return "icecrackFragment"
        case .wave: return "waveFragment"
        default: return "burnFragment"
        }
    }
}

// MARK: - 共享 GPU 上下文

/// 整页 GPU 翻页效果的共享上下文：设备、命令队列与一次编译的通用着色库。
/// 火焰烧穿、电视故障、折纸翻页、碎片飞散、水墨晕染、破冰融霜、浪潮共用同一
/// 顶点函数、同一噪声函数与同一张全屏两三角形管线，仅片段函数不同。
@MainActor
final class PaperEffectMetalContext {
    enum Failure: Error { case unavailable, shader, pipeline }
    static let shared: Result<PaperEffectMetalContext, Error> = Result { try PaperEffectMetalContext() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let loader: MTKTextureLoader
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var cachedShardPipelines: (background: MTLRenderPipelineState, shards: MTLRenderPipelineState)?

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        library = try device.makeLibrary(source: Self.shader, options: nil)
    }

    /// 取（或编译）某个效果片段函数对应的管线；顶点函数统一为全屏 effectVertex。
    /// - Parameter fragment: 片段函数名。
    /// - Returns: 该效果的渲染管线状态。
    func pipeline(fragment: String) throws -> MTLRenderPipelineState {
        if let cached = pipelines[fragment] { return cached }
        guard let function = library.makeFunction(name: fragment),
              let vertex = library.makeFunction(name: "effectVertex") else { throw Failure.pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = function
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[fragment] = state
        return state
    }

    /// 碎片飞散的几何管线：背景（整页相邻页，不混合）+ 碎片三角形（alpha 混合）。
    /// - Returns: 背景与碎片的渲染管线状态。
    func shardPipelines() throws -> (background: MTLRenderPipelineState, shards: MTLRenderPipelineState) {
        if let cached = cachedShardPipelines { return cached }
        guard let backgroundFragment = library.makeFunction(name: "pageFragment"),
              let shardVertexFunction = library.makeFunction(name: "shardVertex"),
              let shardFragmentFunction = library.makeFunction(name: "shardFragment"),
              let vertexFunction = library.makeFunction(name: "effectVertex") else { throw Failure.pipeline }
        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.vertexFunction = vertexFunction
        backgroundDescriptor.fragmentFunction = backgroundFragment
        backgroundDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let shardDescriptor = MTLRenderPipelineDescriptor()
        shardDescriptor.vertexFunction = shardVertexFunction
        shardDescriptor.fragmentFunction = shardFragmentFunction
        shardDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        shardDescriptor.colorAttachments[0].isBlendingEnabled = true
        shardDescriptor.colorAttachments[0].rgbBlendOperation = .add
        shardDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        shardDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        shardDescriptor.colorAttachments[0].alphaBlendOperation = .add
        shardDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        shardDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        // 顶点布局：position(float2) uv(float2) alpha(float) shade(float)，步长 24 字节。
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float
        vertexDescriptor.attributes[2].offset = 16
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float
        vertexDescriptor.attributes[3].offset = 20
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 24
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        shardDescriptor.vertexDescriptor = vertexDescriptor
        let background = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        let shards = try device.makeRenderPipelineState(descriptor: shardDescriptor)
        cachedShardPipelines = (background, shards)
        return cachedShardPipelines!
    }

    /// 通用效果头部：所有效果 uniforms 的前 8 个 float，保证 Swift 端统一写入。
    private static let commonSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EffectVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // 全屏两三角形；uv 以页面左上为原点。
    vertex EffectVertexOut effectVertex(uint id [[vertex_id]]) {
        float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
        float2 c = corners[id];
        EffectVertexOut out;
        out.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
        out.uv = c;
        return out;
    }

    struct EffectHeader {
        float2 viewport;    // 页面 pt 尺寸
        float  progress;    // 0…1
        float  direction;   // +1 next / -1 previous
        float2 origin;      // 触点原点（顶部原点 pt）
        float  isVertical;  // 1 = 纵向翻页
        float  time;        // 墙钟秒数：手指停住时浪花仍随时间翻滚
    };

    float fxHash(uint x, uint y, uint seed) {
        uint v = x * 374761393u;
        v ^= y * 668265263u;
        v ^= seed * 1274126177u;
        v = (v ^ (v >> 13u)) * 1274126177u;
        v ^= v >> 16u;
        return float(v) / 4294967295.0;
    }

    float fxNoise(float2 p, uint seed) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = fxHash(uint(i.x), uint(i.y), seed);
        float b = fxHash(uint(i.x) + 1u, uint(i.y), seed);
        float c = fxHash(uint(i.x), uint(i.y) + 1u, seed);
        float d = fxHash(uint(i.x) + 1u, uint(i.y) + 1u, seed);
        float top = mix(a, b, w.x);
        float bottom = mix(c, d, w.x);
        return mix(top, bottom, w.y);
    }

    float fxPhase(float progress, float start, float end) {
        return clamp((progress - start) / (end - start), 0.0, 1.0);
    }

    float fxSmooth(float value) { return value * value * (3.0 - 2.0 * value); }
    """

    // MARK: 各效果片段着色器（逐条对齐 page-turn-lab 参考实现）

    private static let burnSource = """
    struct BurnUniforms {
        EffectHeader header;    // origin 即主起火点
        float2 ignition3;
        float  ignition3Bias;
        float  radius;
    };

    fragment float4 burnFragment(EffectVertexOut in [[stage_in]],
                                 texture2d<float> current [[texture(0)]],
                                 texture2d<float> target [[texture(1)]],
                                 constant BurnUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        float2 ignition2 = u.header.origin + float2(u.header.viewport.x * 0.06, u.header.viewport.y * 0.03);
        float d = min(min(distance(px, u.header.origin), distance(px, ignition2) + 14.0),
                      distance(px, u.ignition3) + u.ignition3Bias);
        float distortion = (fxNoise(px / 110.0, 5u) - 0.5) * 125.0
            + (fxNoise(px / 31.0, 11u) - 0.5) * 37.0
            + (fxNoise(px / 8.0, 19u) - 0.5) * 11.0;
        float edge = max(0.0, d + distortion) - u.radius;
        float4 currentColor = current.sample(imageSampler, in.uv);
        if (edge < -2.0) { return target.sample(imageSampler, in.uv); }
        if (edge < 2.5) { return float4(1.0, 231.0 / 255.0, 54.0 / 255.0, 1.0); }
        if (edge < 10.0) {
            float heat = 1.0 - (edge - 2.5) / 7.5;
            float4 fire = float4(1.0, (119.0 + 88.0 * heat) / 255.0, 6.0 / 255.0, (45.0 + 170.0 * heat) / 255.0);
            return mix(currentColor, fire, fire.a);
        }
        if (edge < 45.0) {
            float glow = 1.0 - (edge - 10.0) / 35.0;
            float a = 68.0 / 255.0 * glow * glow;
            return mix(currentColor, float4(235.0 / 255.0, 111.0 / 255.0, 5.0 / 255.0, 1.0), a);
        }
        return currentColor;
    }
    """

    private static let glitchSource = """
    // 电视故障：26 条水平条带按错开时刻做“旧页→雪花→新页”交接，条带横向错位、
    // 扫描线与细颗粒雪花随恢复逐渐退去。上一页播放整段动画的镜像：条带交接次序
    // 上下颠倒、扰动方向左右翻转，正文本身不翻转。
    struct GlitchUniforms {
        EffectHeader header;
    };

    fragment float4 glitchFragment(EffectVertexOut in [[stage_in]],
                                   texture2d<float> current [[texture(0)]],
                                   texture2d<float> target [[texture(1)]],
                                   constant GlitchUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        bool vertical = u.header.isVertical > 0.5;
        float2 dims = vertical ? u.header.viewport.yx : u.header.viewport;
        float2 q = vertical ? px.yx : px;    // q.x 沿运动轴，q.y 沿交叉轴
        int band = clamp(int(q.y * 26.0 / dims.y), 0, 25);
        int order = u.header.direction < 0.0 ? (25 - band) : band;
        float start = 0.15 + fxHash(uint(order), 5u, 37u) * 0.34 + float(order) / 26.0 * 0.1;
        float local = fxPhase(u.header.progress, start, start + 0.28);
        float incoming = step(0.5, local);
        float strength = fxSmooth(clamp(u.header.progress / 0.16, 0.0, 1.0))
            * (1.0 - fxSmooth(clamp((local - 0.5) / 0.5, 0.0, 1.0)));
        float offset = (fxNoise(float2(float(band) * 0.91, u.header.progress * 9.0), 23u) - 0.5)
            * 18.0 * strength * (u.header.direction < 0.0 ? -1.0 : 1.0);
        float moveNorm = q.x / dims.x;
        float shifted = moveNorm + offset / dims.x;
        float crossNorm = q.y / dims.y;
        float2 baseUV = vertical ? float2(crossNorm, moveNorm) : float2(moveNorm, crossNorm);
        float2 shiftUV = vertical ? float2(crossNorm, shifted) : float2(shifted, crossNorm);
        float2 sampleUV = (shifted >= 0.0 && shifted <= 1.0) ? shiftUV : baseUV;
        float4 color = incoming > 0.5 ? target.sample(imageSampler, sampleUV) : current.sample(imageSampler, sampleUV);
        // 扫描线：每 4pt 一条 0.65pt 细线；条带底部保留 1pt 信号断行，两者随恢复淡出。
        float scanRow = q.y - floor(q.y * 0.25) * 4.0;
        float scan = (1.0 - smoothstep(0.0, 0.65, scanRow)) * 0.12 * strength;
        float bandHeight = dims.y / 26.0;
        float lineDist = (float(band) + 1.0) * bandHeight - q.y;
        float bandLine = (lineDist >= 0.0 && lineDist < 1.0) ? 0.12 * strength : 0.0;
        color.rgb = mix(color.rgb, float3(0.0), clamp(scan + bandLine, 0.0, 1.0));
        // 两帧连续混合的细颗粒雪花：亮度均值约 35 的偏暗灰噪点。
        float snowMix = 0.5 - 0.5 * cos(u.header.progress * M_PI_F * 12.0);
        float brightness = 6.0 + mix(fxHash(uint(px.x), uint(px.y), 40u),
                                     fxHash(uint(px.x), uint(px.y), 41u), snowMix) * 58.0;
        float snow = fxSmooth(clamp(incoming > 0.5 ? (1.0 - local) * 2.0 : local * 2.0, 0.0, 1.0));
        color.rgb = mix(color.rgb, float3(brightness / 255.0), snow);
        return color;
    }
    """

    private static let foldSource = """
    // 折纸翻页：整页分四条折面收拢，折线处交替明暗并压出白色折痕，下一页垫底。
    // 正向折面向左收拢；反向播放整体镜像（折面向右），正文采样保持原方向不翻转。
    struct FoldUniforms {
        EffectHeader header;
    };

    fragment float4 foldFragment(EffectVertexOut in [[stage_in]],
                                 texture2d<float> current [[texture(0)]],
                                 texture2d<float> target [[texture(1)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        if (u.header.progress > 0.999) { return target.sample(imageSampler, in.uv); }
        float2 px = in.uv * u.header.viewport;
        bool vertical = u.header.isVertical > 0.5;
        float2 dims = vertical ? u.header.viewport.yx : u.header.viewport;
        float2 q = vertical ? px.yx : px;
        float dirSign = u.header.direction < 0.0 ? -1.0 : 1.0;
        float length = dims.x;
        float breadth = dims.y;
        float mx = dirSign < 0.0 ? length - q.x : q.x;    // 镜像空间中的运动轴坐标
        float angle = u.header.progress * M_PI_F * 0.5;
        float sinA = sin(angle);
        float stripWidth = length / 4.0;
        float compressed = stripWidth * cos(angle);
        float offset = -length * 0.22 * u.header.progress;
        float total = compressed * 4.0;
        float3 folded = float3(0.0);
        float covered = 0.0;
        if (compressed > 0.001 && mx >= offset && mx <= offset + total) {
            float global = (mx - offset) / compressed;
            int strip = clamp(int(floor(global)), 0, 3);
            float local = clamp(global - float(strip), 0.0, 1.0);
            float leftLift = (strip % 2 == 1) ? stripWidth * sinA : 0.0;
            float rightLift = (strip % 2 == 1) ? 0.0 : stripWidth * sinA;
            float shear = ((1.0 - local) * leftLift + local * rightLift) * 0.19;
            float fy = (q.y + shear) / (breadth + 2.0 * shear);
            float sourceMove = (float(strip) + local) * stripWidth;
            float sourceNorm = dirSign < 0.0 ? (length - sourceMove) / length : sourceMove / length;
            float2 uv = vertical ? float2(fy, sourceNorm) : float2(sourceNorm, fy);
            float3 c = current.sample(imageSampler, uv).rgb;
            c *= 1.0 - (strip % 2 == 1 ? 0.32 : 0.07) * sinA;
            float creaseX = offset + (float(strip) + 1.0) * compressed;
            float crease = clamp(1.0 - abs(mx - creaseX) / 1.2, 0.0, 1.0) * 0.19 * sinA;
            c = mix(c, float3(1.0), crease);
            folded = c;
            covered = 1.0;
        }
        if (covered > 0.5) { return float4(folded, 1.0); }
        return target.sample(imageSampler, in.uv);
    }
    """

    private static let shatterSource = """
    // 碎片飞散：整页 5×8 抖动网格按随机对角线分成 80 片三角形，碎片沿翻页方向
    // 飞散（横向坠落加向下重力，纵向沿上下方向飞散），二次加速并在末端淡出。
    // 延迟次序由运动方向的前缘开始，重叠碎片保持先离场的在下、后离场的在上。
    struct ShatterShard {
        float2 v0;
        float2 v1;
        float2 v2;
        float2 centroid;
        float2 drift;
        float2 fall;
        float delay;
        float spin;
        float shade;
        float pad0;
        float pad1;
        float pad2;
    };

    struct ShatterUniforms {
        EffectHeader header;
        ShatterShard shards[80];
    };

    fragment float4 shatterFragment(EffectVertexOut in [[stage_in]],
                                    texture2d<float> current [[texture(0)]],
                                    texture2d<float> target [[texture(1)]],
                                    constant ShatterUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        float bestDelay = -1.0;
        float bestAlpha = 0.0;
        float bestShade = 0.0;
        float2 bestUV = float2(0.0);
        for (int i = 0; i < 80; ++i) {
            float delay = u.shards[i].delay;
            float local = clamp((u.header.progress - delay) / (1.0 - delay), 0.0, 1.0);
            if (local >= 1.0) { continue; }
            float drop = local * local;
            float angle = u.shards[i].spin * local * (0.35 + 0.65 * local);
            float ca = cos(angle);
            float sa = sin(angle);
            float2 verts[3] = { u.shards[i].v0, u.shards[i].v1, u.shards[i].v2 };
            float2 moved[3];
            for (int k = 0; k < 3; ++k) {
                float2 rel = verts[k] - u.shards[i].centroid;
                moved[k] = u.shards[i].centroid + float2(rel.x * ca - rel.y * sa, rel.x * sa + rel.y * ca)
                    + u.shards[i].drift * local + u.shards[i].fall * drop;
            }
            float2 edge1 = moved[1] - moved[0];
            float2 edge2 = moved[2] - moved[0];
            float determinant = edge1.x * edge2.y - edge2.x * edge1.y;
            if (abs(determinant) < 1e-8) { continue; }
            float2 rel = px - moved[0];
            float w1 = (rel.x * edge2.y - edge2.x * rel.y) / determinant;
            float w2 = (edge1.x * rel.y - rel.x * edge1.y) / determinant;
            if (w1 < -0.001 || w2 < -0.001 || w1 + w2 > 1.001) { continue; }
            if (delay <= bestDelay) { continue; }    // 后离场（延迟大）的碎片绘制在上层
            bestDelay = delay;
            float w0 = 1.0 - w1 - w2;
            bestUV = (verts[0] * w0 + verts[1] * w1 + verts[2] * w2) / u.header.viewport;
            bestAlpha = local < 0.72 ? 1.0 : 1.0 - pow((local - 0.72) / 0.28, 2.0);
            bestShade = u.shards[i].shade;
        }
        float4 color = target.sample(imageSampler, in.uv);
        if (bestDelay >= 0.0) {
            float3 shard = current.sample(imageSampler, bestUV).rgb * (1.0 - bestShade);
            color = float4(mix(color.rgb, shard, bestAlpha), 1.0);
        }
        return color;
    }
    """

    private static let inkwashSource = """
    // 水墨晕染：从触点洇开的湿墨。四层噪声构成自然化距离场，墨面、细湿边、
    // 触点沉墨与飞溅墨点按参考实现合成；墨色以 multiply 压进纸面，目标页随
    // 纸底显露遮罩从墨团内部逐渐交接。反向只在内部镜像落墨中心，正文不翻转。
    struct InkWashUniforms {
        EffectHeader header;
        float travel;    // 手指离开按下点的累计距离；墨锋半径必须始终包含手指
        float pad0;
    };

    fragment float4 inkwashFragment(EffectVertexOut in [[stage_in]],
                                    texture2d<float> current [[texture(0)]],
                                    texture2d<float> target [[texture(1)]],
                                    constant InkWashUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        // 原点即落墨点，两个方向都不做镜像：手指在哪，墨就在哪。
        float2 center = u.header.origin;
        float maximumRadius = length(u.header.viewport) * 1.08;
        float2 delta = (px - center) * float2(0.98, 0.92);
        float terrain = (fxNoise(px / 142.0, 31u) - 0.5) * 150.0
            + (fxNoise(px / 54.0, 37u) - 0.5) * 62.0
            + (fxNoise(px / 22.0, 41u) - 0.5) * 22.0
            + (fxNoise(px / 8.0, 43u) - 0.5) * 9.0;
        float field = max(0.0, length(delta) + terrain);
        float arrival = pow(clamp((field - 12.0) / maximumRadius, 0.0, 1.0), 1.0 / 0.88);
        float normalized = fxPhase(u.header.progress, 0.025, 0.975);
        float spread = fxSmooth(fxPhase(normalized, 0.0, 0.74));
        float textProgress = fxSmooth(fxPhase(normalized, 0.01, 0.30));
        // 中心退墨推迟到收尾段：拖动中墨始终润在手指下方，跟随感更直接。
        float centerFade = fxSmooth(fxPhase(normalized, 0.55, 0.98));
        float fade = fxSmooth(fxPhase(normalized, 0.62, 0.99));
        // 墨锋始终包含手指：拖动距离作为半径下限，向左拖时墨边跟随指尖推进（参照火焰烧穿）。
        float radius = max(7.0 + maximumRadius * (0.012 + 0.988 * pow(spread, 0.84)), u.travel + 60.0);
        float edge = field - radius;
        float soak = -edge;
        float fiber = fxNoise(px / 18.0, 53u);
        float inkAge = fxSmooth(clamp((normalized - arrival) / 0.48, 0.0, 1.0));
        float freshness = 1.0 - inkAge * 0.32;
        float spreadArea = fxSmooth(clamp((soak + 18.0) / 44.0, 0.0, 1.0));
        float centerWindow = exp(-pow(field / 152.0, 2.0));
        float textCoverage = fxSmooth(clamp((spreadArea - 0.08) / 0.36, 0.0, 1.0));
        float localText = textCoverage * (0.97 + textProgress * 0.03) * (0.95 + fiber * 0.05);
        // 墨团覆盖到哪里，页面就替换到哪里（参考实现文字遮罩的等效整页交接）：
        // 源页文字随覆盖即时退场，避免新旧两页文字在过渡区叠影。
        float4 color = mix(current.sample(imageSampler, in.uv), target.sample(imageSampler, in.uv), clamp(localText, 0.0, 1.0));
        float pooledInk = exp(-pow(field / max(26.0, radius * 0.16), 2.0));
        float interiorBase = fxSmooth(clamp((soak + 14.0) / 52.0, 0.0, 1.0));
        float granule = 0.58 + fiber * 0.55;
        float wetRim = exp(-pow(edge / 9.0, 2.0));
        float spatter = (edge > 2.0 && edge < 160.0 && fiber > 0.87) ? (fiber - 0.87) * 5.0 : 0.0;
        float centerWashFade = clamp(centerWindow * (0.12 + centerFade * 1.05), 0.0, 1.0);
        float interiorInk = interiorBase * 0.42 * granule * (1.0 - centerWashFade);
        float rimInk = wetRim * (0.46 + freshness * 0.3) * (1.0 - centerWashFade * 0.85);
        float centerDeposit = pooledInk * 0.3 * (1.0 - centerWashFade * 0.96);
        float globalInkFade = 1.0 - fade * 0.92;
        float paperGrain = 0.84 + fiber * 0.16;
        float alpha = (interiorInk + rimInk + centerDeposit + spatter * 0.55)
            * globalInkFade * (0.66 + freshness * 0.34) * paperGrain;
        float washAlpha = min(0.92, alpha) * 0.9;
        float tone = (30.0 + interiorBase * 16.0) / 255.0;
        float3 wash = float3(tone, tone + 4.0 / 255.0, tone + 2.0 / 255.0);
        color.rgb *= 1.0 - washAlpha + washAlpha * wash;
        return color;
    }
    """

    private static let icecrackSource = """
    // 破冰融霜：整页先结薄冰，冰缝从裂源（手指位置）放射蔓延成 Voronoi 冰缝网络，
    // 冰块按距裂源次序逐块掀落并显露下一页；掀落瞬间缝线闪光，铰链侧最后脱离。
    // 反向只在内部镜像裂源，正文不翻转。
    struct IcePlate {
        float2 seed;
        float hingeAngle;
        float jitter;
        float shade;
        float pad;
    };

    struct IceCrackUniforms {
        EffectHeader header;
        IcePlate plates[35];
    };

    fragment float4 icecrackFragment(EffectVertexOut in [[stage_in]],
                                     texture2d<float> current [[texture(0)]],
                                     texture2d<float> target [[texture(1)]],
                                     constant IceCrackUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        // 原点即裂源，两个方向都不做镜像：手指滑到哪里，冰就从哪里裂开。
        float2 center = u.header.origin;
        float maximumDistance = length(u.header.viewport);
        float nearestDistance = 1e9;
        float secondDistance = 1e9;
        int owner = 0;
        for (int i = 0; i < 35; ++i) {
            float d = distance(px, u.plates[i].seed);
            if (d < nearestDistance) { secondDistance = nearestDistance; nearestDistance = d; owner = i; }
            else if (d < secondDistance) { secondDistance = d; }
        }
        float seam = secondDistance - nearestDistance;
        float reach = distance(u.plates[owner].seed, center) / maximumDistance;
        float plateDelay = 0.12 + reach * 0.42 + u.plates[owner].jitter * 0.08;
        float crackDelay = max(0.04, plateDelay - 0.08);
        float freezeIn = fxSmooth(fxPhase(u.header.progress, 0.01, 0.1));
        float detach = fxSmooth(fxPhase(u.header.progress, plateDelay, plateDelay + 0.12));
        float2 offset = px - u.plates[owner].seed;
        float offsetLength = max(length(offset), 1e-4);
        float2 hinge = float2(cos(u.plates[owner].hingeAngle), sin(u.plates[owner].hingeAngle));
        float alignment = dot(offset / offsetLength, hinge);
        float fold = (alignment + 1.0) * 0.5;
        float foldStart = fold * 0.5;
        float localDetach = fxSmooth(clamp((detach - foldStart) / (1.0 - foldStart), 0.0, 1.0));
        float crackLife = fxPhase(u.header.progress, crackDelay, crackDelay + 0.06) * (1.0 - localDetach);
        float fallFlash = localDetach * (1.0 - localDetach) * 4.0;
        float crystal = fxNoise(px / 9.0, 91u);
        float crack = exp(-pow(seam / 1.7, 2.0));
        float dome = 1.08 - min(1.0, seam / 46.0) * 0.42;
        float frost = (0.13 + crystal * 0.2 + exp(-pow(seam / 5.0, 2.0)) * 0.28) * dome
            * u.plates[owner].shade * (1.0 - localDetach) * freezeIn;
        float crackGlow = crack * crackLife * 0.8 * freezeIn;
        float flash = crack * fallFlash * 0.6;
        float iceAlpha = min(0.88, frost + crackGlow + flash);
        float brightness = crackGlow + flash;
        float3 ice = float3((245.0 + brightness * 10.0 - crystal * 6.0) / 255.0,
                            (247.0 + brightness * 8.0 - crystal * 3.0) / 255.0,
                            (249.0 + brightness * 6.0) / 255.0);
        float4 color = mix(current.sample(imageSampler, in.uv), target.sample(imageSampler, in.uv), localDetach);
        // 冰面立体感（浅色纸上靠对比与浮雕呈现）：冷灰蓝底打底，以冰块种子为心的左上
        // 光源做漫反射浮雕（块心亮、靠缝暗），缝边压暗描边 + 缝内侧亮倒角成对出现，
        // 叠白霜后加左上高光点；剥落瞬间缝周再压一道投影，冰缝亮线保持蓝白高光。
        float coldBase = freezeIn * (1.0 - localDetach) * 0.16;
        float seamShadow = exp(-pow(seam / 4.0, 2.0)) * 0.3 * freezeIn * (1.0 - localDetach);
        float2 toSeed = px - u.plates[owner].seed;
        float seedDistance = max(length(toSeed), 1e-3);
        float2 plateDir = toSeed / seedDistance;
        float lambert = dot(plateDir, normalize(float2(-0.62, -0.78)));
        color.rgb *= 1.0 + 0.22 * clamp(lambert, -0.35, 1.0) * freezeIn * (1.0 - localDetach);
        color.rgb = mix(color.rgb, color.rgb * float3(0.70, 0.76, 0.88), clamp(coldBase + seamShadow, 0.0, 1.0));
        float bevel = exp(-pow((seam - 7.0) / 4.0, 2.0)) * 0.22 * freezeIn * (1.0 - localDetach);
        color.rgb = mix(color.rgb, float3(0.94, 0.97, 1.0), clamp(bevel, 0.0, 1.0));
        color.rgb = mix(color.rgb, ice, iceAlpha);
        float spec = pow(clamp(lambert, 0.0, 1.0), 10.0) * freezeIn * (1.0 - localDetach) * (1.0 - min(1.0, seam / 50.0));
        color.rgb = mix(color.rgb, float3(1.0), clamp(spec * 0.65, 0.0, 1.0));
        float liftShadow = crack * (localDetach * (1.0 - localDetach)) * 4.0;
        color.rgb *= 1.0 - clamp(liftShadow * 0.22, 0.0, 1.0);
        color.rgb = mix(color.rgb, float3(0.88, 0.95, 1.0), clamp(crackGlow * 1.2 + flash, 0.0, 1.0));
        return color;
    }
    """

    private static let waveSource = """
    // 浪潮（水纹翻页）：浪锋沿翻页方向整幅推进，大中小三层正弦让浪头翻滚；
    // 浪头白沫与飞溅水珠用 screen 加白，浪谷暗带与退潮后的平静水膜着色湿面，
    // 目标页随浪锋滚过的遮罩逐渐显露。方向只决定浪的推进方向，正文不翻转。
    struct WaveUniforms {
        EffectHeader header;
    };

    fragment float4 waveFragment(EffectVertexOut in [[stage_in]],
                                 texture2d<float> current [[texture(0)]],
                                 texture2d<float> target [[texture(1)]],
                                 constant WaveUniforms &u [[buffer(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 px = in.uv * u.header.viewport;
        bool vertical = u.header.isVertical > 0.5;
        float2 dims = vertical ? u.header.viewport.yx : u.header.viewport;
        float2 q = vertical ? px.yx : px;    // q.x 沿运动轴，q.y 沿交叉轴
        float normalized = fxPhase(u.header.progress, 0.02, 0.985);
        float travel = dims.x + 170.0;
        // 浪峰相位叠加墙钟时间：手指停住时浪花仍持续翻滚；时间项放缓，起伏更自然。
        float roll = normalized * 9.4 + u.header.time * 0.9;
        float sweep = u.header.direction < 0.0 ? -85.0 + normalized * travel : dims.x + 85.0 - normalized * travel;
        // 浪锋跟随手指：取指尖与扫过锋线中更靠前者（正向更左、反向更右）；
        // 松手后指尖不动，扫过锋线继续推进完成整页交接，浪花始终随指尖翻滚。
        float originAxis = u.header.isVertical > 0.5 ? u.header.origin.y : u.header.origin.x;
        float base = u.header.direction < 0.0 ? max(sweep, originAxis) : min(sweep, originAxis);
        float front = base + sin(q.y / 116.0 + roll) * 9.0
            + sin(q.y / 57.0 - roll * 1.4) * 5.0
            + sin(q.y / 27.0 + roll * 0.8) * 2.5;
        // 起浪渐显：浪花、湿面与内容交接在前 12% 进度淡入，
        // 浪锋跟随指尖时不从指尖瞬间弹出，而是自然起浪。
        float entry = fxSmooth(fxPhase(u.header.progress, 0.0, 0.12));
        float directionSign = u.header.direction < 0.0 ? -1.0 : 1.0;
        float edge = (front - q.x) * directionSign;
        float inside = -edge;
        float grain = fxNoise(px / 20.0, 109u);
        float spray = fxNoise(px / 5.0 + float2(u.header.time * 1.1, u.header.time * 0.8), 113u);
        float finalDrain = fxSmooth(fxPhase(normalized, 0.88, 0.985));
        // 浪锋滚过即整页交接并保持：源页内容随浪头即时退场，浪后是稳定的下一页。
        float reveal = fxSmooth(clamp((inside - 4.0) / 52.0, 0.0, 1.0)) * entry;
        float4 color = mix(current.sample(imageSampler, in.uv), target.sample(imageSampler, in.uv), reveal);
        // 湿色水面：浪谷暗带、浪后平静水膜与浪锋前缘的湿痕。
        float bubble = 0.45 + spray * 0.55;
        float foamFront = exp(-pow((edge + 5.0) / 12.0, 2.0));
        float foamBody = fxSmooth(clamp((inside + 8.0) / 40.0, 0.0, 1.0))
            * (1.0 - fxSmooth(clamp((inside - 26.0) / 54.0, 0.0, 1.0)));
        float foam = min(0.9, (foamFront * 1.15 + foamBody * 0.6) * bubble) * (1.0 - finalDrain) * entry;
        float droplets = (spray > 0.78 && edge > 3.0 && edge < 44.0 ? (spray - 0.78) * 2.6 : 0.0) * (1.0 - finalDrain) * entry;
        float trough = exp(-pow((inside - 46.0) / 34.0, 2.0)) * 0.3 * (1.0 - finalDrain) * entry;
        float calmRed = 168.0;
        float calmGreen = 204.0;
        float calmBlue = 222.0;
        // 湿色水膜铺满浪锋扫过的全部区域并随浪锋推进持续扩大，全程保持不消退，
        // 只在动画末段整体退干，露出干净的下一页。
        float calm = fxSmooth(clamp((inside - 18.0) / 56.0, 0.0, 1.0))
            * 0.2 * (1.0 - finalDrain) * (0.92 + grain * 0.16) * entry;
        float wetAhead = exp(-pow((edge - 8.0) / 30.0, 2.0)) * 0.05 * (1.0 - finalDrain) * entry;
        float wet = trough + calm + wetAhead;
        if (wet > 0.004) {
            float inverse = 1.0 / wet;
            float3 water = float3((trough * 92.0 + wetAhead * 112.0 + calm * calmRed) * inverse,
                                  (trough * 134.0 + wetAhead * 152.0 + calm * calmGreen) * inverse,
                                  (trough * 158.0 + wetAhead * 176.0 + calm * calmBlue) * inverse) / 255.0;
            color.rgb = mix(color.rgb, water, min(0.4, wet) * 0.92);
        }
        // 浪花与水珠：近纯白泡沫以 screen 混合往纸面加白。
        float sprayTotal = foam + droplets;
        if (sprayTotal > 0.004) {
            float3 foamColor = float3(252.0, 254.0, 255.0) / 255.0;
            float foamAlpha = min(0.95, sprayTotal) * 0.95;
            float3 screened = 1.0 - (1.0 - color.rgb) * (1.0 - foamColor);
            color.rgb = mix(color.rgb, screened, foamAlpha);
        }
        return color;
    }
    """

    // 碎片飞散的几何渲染路径：背景铺完整的相邻页，碎片由 CPU 展开的 240 顶点
    // 三角形 alpha 混合叠加，片元不再逐像素遍历 80 片三角形，保证满帧。
    static let shardSource = """
    struct ShardVertexIn {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
        float alpha [[attribute(2)]];
        float shade [[attribute(3)]];
    };

    struct ShardVertexOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
        float shade;
    };

    vertex ShardVertexOut shardVertex(ShardVertexIn in [[stage_in]],
                                      constant float2 &viewport [[buffer(1)]]) {
        ShardVertexOut out;
        out.position = float4(in.position.x / viewport.x * 2.0 - 1.0,
                              1.0 - in.position.y / viewport.y * 2.0, 0.0, 1.0);
        out.uv = in.uv;
        out.alpha = in.alpha;
        out.shade = in.shade;
        return out;
    }

    fragment float4 shardFragment(ShardVertexOut in [[stage_in]],
                                  texture2d<float> current [[texture(0)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color = current.sample(imageSampler, in.uv);
        color.rgb *= 1.0 - in.shade;
        return float4(color.rgb, in.alpha);
    }

    fragment float4 pageFragment(EffectVertexOut in [[stage_in]],
                                 texture2d<float> target [[texture(1)]]) {
        constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return target.sample(imageSampler, in.uv);
    }
    """

    /// 全部效果共用一个着色库：同一顶点函数与噪声函数，仅片段函数按效果区分。
    static let shader = commonSource + "\n" + burnSource + "\n" + glitchSource + "\n" + foldSource
        + "\n" + shatterSource + "\n" + inkwashSource + "\n" + icecrackSource + "\n" + waveSource
        + "\n" + shardSource
}

// MARK: - 通用 GPU 绘制器

/// 整页 GPU 翻页效果的通用绘制器：两张整页快照纹理 + 全屏两三角形，
/// 每帧只更新 uniform。火焰烧穿、电视故障、折纸翻页、碎片飞散、水墨晕染、
/// 破冰融霜与浪潮共用同一条提交路径，距离场、噪声与配色逐条对齐 page-turn-lab。
@MainActor
final class PaperEffectMetalRenderer {
    enum Failure: Error { case context, texture, buffer, pipeline }

    /// 当前设备是否具备整页 GPU 效果所需的 Metal 能力。
    static var isSupported: Bool {
        if case .success = PaperEffectMetalContext.shared { return true }
        return false
    }

    /// 各效果 uniform 的 float 数量；布局与着色器结构体逐字节对应。
    private static func uniformFloatCount(of effect: PageTurnEffect) -> Int {
        switch effect {
        case .burn: return 12
        case .inkwash: return 10
        case .glitch, .fold, .wave: return 8
        case .icecrack: return 8 + 35 * 6
        case .shatter: return 8
        default: return 8
        }
    }

    private let context: PaperEffectMetalContext
    private let pipeline: MTLRenderPipelineState
    private let currentTexture: MTLTexture
    private let targetTexture: MTLTexture
    private let uniforms: MTLBuffer
    let device: MTLDevice
    private let viewport: SIMD2<Float>
    private let effect: PageTurnEffect
    private let direction: PageTurnDirection
    private let axis: PageTurnAxis
    private let staticUniformTail: [Float]
    private let ignition3: SIMD2<Float>
    private let ignition3Bias: Float
    private let radiusBase: Float
    private(set) var origin: SIMD2<Float>
    private let initialOrigin: SIMD2<Float>
    /// 碎片飞散的确定性拓扑（延迟升序＝绘制次序）与每帧顶点缓冲、几何管线。
    private let shardSeeds: [ShardSeed]
    private let shardVertexBuffer: MTLBuffer
    private let shardPipelines: (background: MTLRenderPipelineState, shards: MTLRenderPipelineState)?
    private(set) var progress: Float = 0

    /// - Parameters:
    ///   - current/target: 两页原始快照。
    ///   - size: 页面 pt 尺寸。
    ///   - effect: 整页 GPU 效果。
    ///   - direction: 逻辑翻页方向；镜像类效果按它决定动画镜像。
    ///   - axis: 翻页轴。
    ///   - origin: 触点原点（顶部原点 pt）；起火点、落墨点或裂源。
    /// - Throws: 设备不可用、管线编译或纹理／缓冲创建失败。
    init(current: CGImage, target: CGImage, size: CGSize, effect: PageTurnEffect,
         direction: PageTurnDirection, axis: PageTurnAxis, origin: CGPoint) throws {
        guard effect.isWholePageMetalEffect else { throw Failure.context }
        guard let shared = try? PaperEffectMetalContext.shared.get() else { throw Failure.context }
        context = shared
        pipeline = try shared.pipeline(fragment: effect.metalFragmentName)
        viewport = SIMD2(Float(max(1, size.width)), Float(max(1, size.height)))
        self.effect = effect
        self.direction = direction
        self.axis = axis
        self.origin = SIMD2(Float(origin.x), Float(origin.y))
        initialOrigin = self.origin
        radiusBase = axis == .horizontal ? viewport.x : viewport.y
        ignition3 = SIMD2(viewport.x * 0.27, viewport.y * 0.975)
        ignition3Bias = viewport.x * 0.54
        staticUniformTail = Self.staticTail(effect: effect, viewport: size, axis: axis, direction: direction)
        // 碎片飞散始终正向播放：当前页碎裂飞散（下一页＝向左／向上，上一页＝向右／向下，
        // 坠落重力保留），露出垫底的相邻页；不使用时间倒放。碎片以几何路径渲染，
        // CPU 每帧展开 240 顶点，片元零循环，保证满帧。
        shardSeeds = effect == .shatter ? Self.shardSeeds(viewport: size, axis: axis, direction: direction) : []
        shardPipelines = effect == .shatter ? try shared.shardPipelines() : nil
        guard let shardVertexBuffer = shared.device.makeBuffer(length: 80 * 3 * 6 * 4, options: .storageModeShared) else { throw Failure.buffer }
        self.shardVertexBuffer = shardVertexBuffer
        guard let currentTexture = try? shared.loader.newTexture(cgImage: current),
              let targetTexture = try? shared.loader.newTexture(cgImage: target) else { throw Failure.texture }
        self.currentTexture = currentTexture
        self.targetTexture = targetTexture
        let byteCount = Self.uniformFloatCount(of: effect) * 4
        guard let uniforms = shared.device.makeBuffer(length: byteCount, options: .storageModeShared) else { throw Failure.buffer }
        self.uniforms = uniforms
        device = shared.device
        writeUniforms()
    }

    /// - Parameters: progress: 逻辑进度；origin: 可选的新触点原点（顶部原点 pt）。
    /// - Returns: 无返回值；只更新状态，下一帧绘制时生效。
    func update(progress: CGFloat, origin: CGPoint? = nil) {
        self.progress = Float(min(1, max(0, progress)))
        if let origin { self.origin = SIMD2(Float(origin.x), Float(origin.y)) }
    }

    /// 为页面的 CAMetalLayer 配置设备与像素格式；无返回值。
    /// - Parameter metal: 视图 backing layer。
    func configure(_ metal: CAMetalLayer) {
        metal.device = context.device
        metal.pixelFormat = .bgra8Unorm
    }

    /// - Parameter drawable: 已取到的可绘制帧。无返回值；写入 uniform 并提交一帧。
    func render(into drawable: CAMetalDrawable) {
        writeUniforms()
        guard let command = context.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encodeFrame(into: command, pass: pass)
        command.present(drawable)
        command.commit()
    }

    /// - Parameter texture: 离屏纹理；供着色器级验收测试同步读取像素，不触碰屏幕。
    func render(into texture: MTLTexture) {
        writeUniforms()
        guard let command = context.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encodeFrame(into: command, pass: pass)
        command.commit()
        command.waitUntilCompleted()
    }

    /// - Parameters: command: 已就绪的命令缓冲；pass: 指向目标的渲染通道。无返回值。
    private func encodeFrame(into command: MTLCommandBuffer, pass: MTLRenderPassDescriptor) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if effect == .shatter, let pipelines = shardPipelines {
            // 背景：完整的相邻页（参考实现的 paper(target)）。
            encoder.setRenderPipelineState(pipelines.background)
            encoder.setFragmentTexture(targetTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // 碎片：CPU 展开的三角形，延迟升序绘制（后离场盖在上层），alpha 混合。
            encoder.setRenderPipelineState(pipelines.shards)
            encoder.setVertexBuffer(shardVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniforms, offset: 0, index: 1)    // float2 viewport
            encoder.setFragmentTexture(currentTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shardSeeds.count * 3)
        } else {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(currentTexture, index: 0)
            encoder.setFragmentTexture(targetTexture, index: 1)
            encoder.setFragmentBuffer(uniforms, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    /// 与参考实现 seededRandom 一致的确定性伪随机；同一种子生成同一序列，可复现碎片拓扑。
    private struct SeededRandom {
        private var value: UInt32
        init(seed: UInt32) { value = seed }
        mutating func next() -> Double {
            value = value &+ 0x6D2B79F5
            var mixed = (value ^ (value >> 15)) &* (value | 1)
            mixed = (mixed &+ ((mixed ^ (mixed >> 7)) &* (mixed | 61))) ^ mixed
            return Double(mixed ^ (mixed >> 14)) / 4294967296.0
        }
    }

    /// 与着色器 fxHash 一致的哈希；用于破冰融霜的板块种子与铰链方向。
    private static func hash(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Double {
        var v = x &* 374761393
        v = v ^ (y &* 668265263)
        v = v ^ (seed &* 1274126177)
        v = (v ^ (v >> 13)) &* 1274126177
        v = v ^ (v >> 16)
        return Double(v) / 4294967295.0
    }

    /// 碎片飞散的单片拓扑：顶点、重心、漂移、坠落、延迟、旋转与明暗。
    private struct ShardSeed {
        let corners: [SIMD2<Double>]
        let centroid: SIMD2<Double>
        let drift: SIMD2<Double>
        let fall: SIMD2<Double>
        let jitter: Double
        let spin: Double
        let shade: Double
    }

    /// 碎片飞散的静态拓扑：5×8 抖动网格按随机对角线拆成两片，漂移沿翻页方向
    /// 为主（横向纯向左／右，纵向沿上下）。碎裂波从手指原点放射——每帧按
    /// 碎片重心到触点的距离计算延迟，手指移到哪里碎片就从哪里开始飞散。
    private static func shardSeeds(viewport: CGSize, axis: PageTurnAxis, direction: PageTurnDirection) -> [ShardSeed] {
        let movementLength = axis == .horizontal ? viewport.width : viewport.height
        let crossLength = axis == .horizontal ? viewport.height : viewport.width
        let columns = 5, rows = 8
        var random = SeededRandom(seed: 20260912)
        var grid: [[SIMD2<Double>]] = []
        for row in 0...rows {
            var line: [SIMD2<Double>] = []
            for column in 0...columns {
                let edge = row == 0 || row == rows || column == 0 || column == columns
                let jitterX = edge ? 0 : (random.next() - 0.5) * movementLength / Double(columns) * 0.6
                let jitterY = edge ? 0 : (random.next() - 0.5) * crossLength / Double(rows) * 0.42
                let x = min(movementLength, max(0, Double(column) * movementLength / Double(columns) + jitterX))
                let y = min(crossLength, max(0, Double(row) * crossLength / Double(rows) + jitterY))
                line.append(SIMD2(x, y))
            }
            grid.append(line)
        }
        func pagePoint(_ point: SIMD2<Double>) -> SIMD2<Double> {
            axis == .horizontal ? SIMD2(point.x, point.y) : SIMD2(point.y, point.x)
        }
        let forward = direction == .next
        // 下一页从右往左滑动时碎片也从右往左：漂移方向跟随翻页运动方向。
        let travelSign = forward ? -1.0 : 1.0
        var seeds: [ShardSeed] = []
        seeds.reserveCapacity(80)
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = grid[row][column], topRight = grid[row][column + 1]
                let bottomRight = grid[row + 1][column + 1], bottomLeft = grid[row + 1][column]
                let diagonals = random.next() > 0.5
                    ? [[topLeft, topRight, bottomRight], [topLeft, bottomRight, bottomLeft]]
                    : [[topLeft, topRight, bottomLeft], [topRight, bottomRight, bottomLeft]]
                for points in diagonals {
                    let centroid = (points[0] + points[1] + points[2]) / 3
                    let jitter = random.next()
                    // 横向纯向左／右飞散（不坠落）；纵向沿上下方向飞散。
                    let driftAmount = 0.45 + random.next() * 0.5
                    let spin = (random.next() - 0.5) * 2.8
                    let shade = 0.08 + random.next() * 0.16
                    let corners = points.map { pagePoint($0) }
                    let center = pagePoint(centroid)
                    let drift: SIMD2<Double>
                    let fall: SIMD2<Double>
                    if axis == .horizontal {
                        drift = SIMD2(travelSign * driftAmount * viewport.width, 0)
                        fall = SIMD2(0, 0)
                    } else {
                        let fallAmount = 0.4 + random.next() * 0.4
                        drift = SIMD2(0, travelSign * driftAmount * viewport.height)
                        fall = SIMD2(0, travelSign * fallAmount * viewport.height)
                    }
                    seeds.append(ShardSeed(corners: corners, centroid: center,
                                           drift: drift, fall: fall,
                                           jitter: jitter, spin: spin, shade: shade))
                }
            }
        }
        return seeds
    }

    /// 每帧把 80 片碎片展开为 GPU 三角形顶点（位置/纹理/透明度/明暗）；
    /// 240 顶点的 CPU 开销可忽略，换取片元着色器零循环满帧渲染。
    /// 碎裂延迟按碎片重心到触点的距离动态计算：碎裂波从手指位置放射。
    private static func fillShardVertices(into buffer: MTLBuffer, seeds: [ShardSeed],
                                          viewport: SIMD2<Float>, progress: Float, origin: SIMD2<Float>) {
        let maximumDistance = max(1.0, Float(hypot(Double(viewport.x), Double(viewport.y))))
        var delays: [Float] = []
        delays.reserveCapacity(seeds.count)
        for shard in seeds {
            let centroid = SIMD2(Float(shard.centroid.x), Float(shard.centroid.y))
            let reach = min(1, distance(centroid, origin) / maximumDistance)
            delays.append(min(0.72, max(0, 0.08 + reach * 0.6 + Float(shard.jitter) * 0.1)))
        }
        // 延迟升序绘制：后离场的碎片盖在上层。
        var order: [Int] = Array(seeds.indices)
        order.sort { delays[$0] < delays[$1] }
        var vertices: [Float] = []
        vertices.reserveCapacity(seeds.count * 3 * 6)
        for index in order {
            let shard = seeds[index]
            let delay = delays[index]
            let local = min(1, max(0, (progress - delay) / (1 - delay)))
            let alpha: Float
            var moved: [SIMD2<Float>]
            if local >= 1 {
                alpha = 0
                moved = [SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: -1), SIMD2<Float>(repeating: -1)]
            } else {
                let drop = local * local
                let angle = Float(shard.spin) * local * (0.35 + 0.65 * local)
                let ca = cos(angle), sa = sin(angle)
                alpha = local < 0.72 ? 1 : 1 - pow((local - 0.72) / 0.28, 2)
                let centroid = SIMD2(Float(shard.centroid.x), Float(shard.centroid.y))
                let drift = SIMD2(Float(shard.drift.x), Float(shard.drift.y)) * local
                let fall = SIMD2(Float(shard.fall.x), Float(shard.fall.y)) * drop
                moved = shard.corners.map { corner in
                    let rel = SIMD2(Float(corner.x), Float(corner.y)) - centroid
                    let rotated = SIMD2(rel.x * ca - rel.y * sa, rel.x * sa + rel.y * ca)
                    return centroid + rotated + drift + fall
                }
            }
            for (index, point) in moved.enumerated() {
                let corner = shard.corners[index]
                vertices += [point.x, point.y,
                             Float(corner.x / Double(viewport.x)), Float(corner.y / Double(viewport.y)),
                             alpha, Float(shard.shade)]
            }
        }
        vertices.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: min(buffer.length, source.count * 4))
        }
    }

    /// 破冰融霜的 35 块冰板：抖动网格种子、掀动铰链方向、剥落抖动与明暗系数。
    private static func iceCrackTail(viewport: CGSize) -> [Float] {
        let width = Double(viewport.width), height = Double(viewport.height)
        var tail: [Float] = []
        tail.reserveCapacity(35 * 6)
        for row in 0..<7 {
            for column in 0..<5 {
                let x = (Double(column) + 0.5 + (hash(UInt32(column), UInt32(row), 71) - 0.5) * 0.6) * width / 5
                let y = (Double(row) + 0.5 + (hash(UInt32(row), UInt32(column), 73) - 0.5) * 0.6) * height / 7
                let hinge = hash(UInt32(column) * 3 + 11, UInt32(row) * 9 + 2, 89) * Double.pi * 2
                let jitter = hash(UInt32(column) * 7 + 1, UInt32(row) * 13 + 5, 79)
                let shade = 0.82 + hash(UInt32(row) * 17 + 3, UInt32(column) * 5 + 7, 83) * 0.34
                tail += [Float(x), Float(y), Float(hinge), Float(jitter), Float(shade), 0]
            }
        }
        return tail
    }

    /// 各效果一次性构建的静态 uniform 尾段；普通帧不再重算。
    private static func staticTail(effect: PageTurnEffect, viewport: CGSize,
                                   axis: PageTurnAxis, direction: PageTurnDirection) -> [Float] {
        switch effect {
        case .icecrack: return iceCrackTail(viewport: viewport)
        default: return []
        }
    }

    /// 无参数；按当前状态重写 uniform 缓冲。无返回值。
    private func writeUniforms() {
        var floats: [Float] = [
            viewport.x, viewport.y, progress, direction == .next ? 1 : -1,
            origin.x, origin.y, axis == .vertical ? 1 : 0, Float(CACurrentMediaTime()),
        ]
        if effect == .burn {
            floats += [ignition3.x, ignition3.y, ignition3Bias, pageRadius()]
        } else if effect == .inkwash {
            // 墨锋始终包含手指：离开按下点的距离作为半径下限（着色器内取 max）。
            let travel = Float(hypot(Double(origin.x - initialOrigin.x), Double(origin.y - initialOrigin.y)))
            floats += [travel, 0]
        } else {
            floats += staticUniformTail
        }
        floats.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            let byteCount = min(uniforms.length, source.count * 4)
            uniforms.contents().copyMemory(from: base, byteCount: byteCount)
        }
        if effect == .shatter {
            Self.fillShardVertices(into: shardVertexBuffer, seeds: shardSeeds,
                                   viewport: viewport, progress: progress, origin: origin)
        }
    }

    /// 无参数；火焰半径全程推进：起火相位 0.02 即现小火孔，熄灭相位 0.97，
    /// 指数 1.4 让前段扩散快、末段沿屏幕边缘扫尾，收尾与落定自然衔接、无静止段。
    /// - Returns: 当前半径（pt）。
    private func pageRadius() -> Float {
        let phase = min(1, max(0, (progress - 0.02) / 0.95))
        let eased = pow(phase, 1.4)
        return radiusBase * (0.06 + 1.79 * eased)
    }
}

/// 整页 GPU 效果的管线预热：提前编译着色库、全部效果管线与碎片几何管线。
/// 首次翻页直接复用已编译的管线状态，避免主线程着色器编译造成首帧掉帧。
/// 在启动阶段调用一次即可（编译期停顿在启动画面期间不可见）；设备不可用时静默跳过。
@MainActor
public enum PaperEffectMetalWarmup {
    /// 无参数；编译共享着色库与全部效果管线。无返回值。
    public static func warmUp() {
        guard case .success(let context) = PaperEffectMetalContext.shared else { return }
        for effect in [PageTurnEffect.burn, .glitch, .fold, .shatter, .inkwash, .icecrack, .wave] {
            _ = try? context.pipeline(fragment: effect.metalFragmentName)
        }
        _ = try? context.shardPipelines()
    }
}

/// 整页 GPU 效果的 Metal 图层视图：挂上窗口后连续渲染，进度由外部或原生收尾推进。
/// 全部效果共用同一视图实现，仅持有的渲染器不同。
@MainActor
final class PaperEffectMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private let renderer: PaperEffectMetalRenderer
    private let clock = ReaderDisplayLink()
    private(set) var submittedFrameCount = 0
    /// 开启后逐帧记录 drawable 的呈现时间（上限 512 帧），供诊断浮层统计 GPU 呈现。
    var collectsPresentationMetrics = false {
        didSet {
            guard oldValue != collectsPresentationMetrics else { return }
            presentedTimes.removeAll(keepingCapacity: true)
        }
    }
    private(set) var presentedTimes: [TimeInterval] = []
    private var active = true
    /// 原生收尾与绘制共用此时钟；设置后由视图时钟推进收尾进度。
    var beforeRender: ((TimeInterval) -> Void)? {
        didSet { if beforeRender != nil { clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond) } }
    }
    var drivesNativeRelease: Bool { beforeRender != nil && clock.isRunning }

    /// - Parameters: renderer: 本次翻页拥有的 GPU 绘制器；frame: 全幅纸面坐标。
    init(renderer: PaperEffectMetalRenderer, frame: CGRect) {
        self.renderer = renderer
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        if let metal = layer as? CAMetalLayer { renderer.configure(metal) }
        clock.onTick = { [weak self] elapsed in self?.renderLatest(elapsed: elapsed) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// - Parameters: progress: 逻辑进度；origin: 可选的新触点原点。无返回值；下一帧绘制生效。
    func setProgress(_ progress: CGFloat, origin: CGPoint? = nil) {
        renderer.update(progress: progress, origin: origin)
        clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clock.stop() }
        else { clock.start(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let metal = layer as? CAMetalLayer {
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            if metal.drawableSize != size { metal.drawableSize = size }
        }
    }

    /// 首末提交帧的时间跨度（秒）；呈现时间戳不可靠时用它换算 GPU 帧率。
    private var firstSubmissionTime: TimeInterval?
    private(set) var submissionSpan: TimeInterval = 0

    /// 清理时钟与状态；无参数及返回值。
    func invalidate() { active = false; beforeRender = nil; clock.stop() }

    /// - Parameter elapsed: 可见帧推进秒数。无返回值；先推进收尾，再提交当前帧。
    private func renderLatest(elapsed: TimeInterval) {
        guard active, let metal = layer as? CAMetalLayer, window != nil else { clock.stop(); return }
        beforeRender?(elapsed)
        guard active, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        layoutIfNeeded()
        guard let drawable = metal.nextDrawable() else { return }
        if collectsPresentationMetrics {
            #if !targetEnvironment(simulator)
            drawable.addPresentedHandler { [weak self] presented in
                let timestamp = presented.presentedTime
                DispatchQueue.main.async { [weak self] in
                    self?.recordPresentedTime(timestamp)
                }
            }
            #endif
        }
        renderer.render(into: drawable)
        submittedFrameCount += 1
        let now = CACurrentMediaTime()
        if let first = firstSubmissionTime { submissionSpan = now - first }
        else { firstSubmissionTime = now }
    }

    /// - Parameter timestamp: drawable 的系统呈现时间。无返回值；采集开启且未达上限时追加。
    private func recordPresentedTime(_ timestamp: TimeInterval) {
        guard active, collectsPresentationMetrics, presentedTimes.count < 512 else { return }
        presentedTimes.append(timestamp)
    }
}
#endif
