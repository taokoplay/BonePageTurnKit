#if canImport(UIKit)
import UIKit
import QuartzCore
import Darwin
import XCTest
@testable import BonePageTurnKit

/// 真机 Release 下直接调用当前 CPU 四角绘图路径，记录单帧离屏绘制耗时。
@MainActor
final class CornerRenderingPerformanceTests: XCTestCase {
    private struct FrameMeasurement {
        let milliseconds: Double
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// 无参数；在 iPhone 13 Pro 上预热六帧后记录四角共 36 帧，日志和 JSON 附件始终保留。无返回值。
    func testRecordSoftwareCornerBaseline() throws {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        try XCTSkipIf(isSimulator, "CPU 基线必须使用实际 iPhone 13 Pro")
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        XCTAssertEqual(configuration, "Release")
        let machine = machineIdentifier()
        XCTAssertEqual(machine, "iPhone14,2", "基线设备应为 iPhone 13 Pro")

        let size = CGSize(width: 390, height: 844)
        let bounds = CGRect(origin: .zero, size: size)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        let host = UIViewController()
        host.view = UIView(frame: bounds)
        host.view.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let current = page(target: false, size: size)
        let target = page(target: true, size: size)
        host.view.addSubview(target)
        host.view.addSubview(current)
        host.view.layoutIfNeeded()
        let displayScale = window.screen.scale > 0 ? window.screen.scale : UIScreen.main.scale
        let scaleSource = window.screen.scale > 0 ? "window.screen.scale" : "UIScreen.main.scale"
        let currentNeededOverride = current.traitCollection.displayScale != displayScale
        let targetNeededOverride = target.traitCollection.displayScale != displayScale
        if #available(iOS 17.0, *) {
            if currentNeededOverride { current.traitOverrides.displayScale = displayScale }
            if targetNeededOverride { target.traitOverrides.displayScale = displayScale }
        }
        current.layoutIfNeeded()
        target.layoutIfNeeded()
        XCTAssertEqual(displayScale, 3, "iPhone 13 Pro 的实际屏幕倍率应为 3x")
        XCTAssertEqual(current.traitCollection.displayScale, displayScale)
        XCTAssertEqual(target.traitCollection.displayScale, displayScale)
        XCTAssertEqual(current.bounds.size, size)
        XCTAssertEqual(target.bounds.size, size)

        let options = PaperRenderingOptions.standard
        let paper = try PaperTransitionView(currentView: current, targetView: target,
            effect: .curl, direction: .next, spine: .minimum, options: .standard)
        defer { paper.invalidateResources() }
        XCTAssertTrue(paper.hasResources)
        let snapshotPlan = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(
            width: Double(size.width), height: Double(size.height), displayScale: Double(displayScale),
            maximumSnapshotPixels: options.maximumSnapshotPixels))
        XCTAssertEqual(paper.snapshotPixelCount, snapshotPlan.totalPixelCount)

        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let cornerNames = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
        let warmupFrameCount = 6
        let frameCount = 36
        let thermalBefore = thermalName(ProcessInfo.processInfo.thermalState)
        let lowPowerBefore = ProcessInfo.processInfo.isLowPowerModeEnabled
        for index in 0..<warmupFrameCount {
            let drag = try cornerDrag(index: index % 4,
                progress: CGFloat(index + 1) / CGFloat(warmupFrameCount + 1), size: size)
            _ = try drawFrame(renderer: renderer, paper: paper, drag: drag)
        }

        var samples: [[String: Any]] = []
        var timings: [Double] = []
        var outputPixelWidth = 0
        var outputPixelHeight = 0
        samples.reserveCapacity(frameCount)
        timings.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let cornerIndex = index % 4
            let drag = try cornerDrag(index: cornerIndex,
                progress: CGFloat(index + 1) / CGFloat(frameCount + 1), size: size)
            let result = try drawFrame(renderer: renderer, paper: paper, drag: drag)
            outputPixelWidth = result.pixelWidth
            outputPixelHeight = result.pixelHeight
            XCTAssertEqual(result.pixelWidth, Int(size.width * displayScale))
            XCTAssertEqual(result.pixelHeight, Int(size.height * displayScale))
            timings.append(result.milliseconds)
            samples.append([
                "frame": index + 1, "corner": cornerNames[cornerIndex],
                "progress": Double(drag.progress),
                "translationX": Double(drag.translation.x), "translationY": Double(drag.translation.y),
                "milliseconds": result.milliseconds
            ])
        }
        let thermalAfter = thermalName(ProcessInfo.processInfo.thermalState)
        var perCorner: [String: [String: Any]] = [:]
        for cornerIndex in 0..<4 {
            let values = timings.enumerated().filter { $0.offset % 4 == cornerIndex }.map { $0.element }
            perCorner[cornerNames[cornerIndex]] = distribution(values)
        }
        let scope = "逐帧 CACurrentMediaTime 包围同一个 UIGraphicsImageRenderer.image { paper.draw(paper.bounds) }；包含 context begin/end、CPU geometry 准备和 CoreGraphics CPU 绘制合计。排除页面文字布局、初始化快照及裁图、update、六帧预热、断言、图像释放、JSON 序列化和附件；无 PNG 编码。离屏绘制耗时不等于 native present FPS。"
        let record: [String: Any] = [
            "schemaVersion": 1, "test": "testRecordSoftwareCornerBaseline",
            "renderer": "CPU CoreGraphics PaperTransitionView.drawCornerCurl",
            "configuration": configuration, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "frameCount": frameCount, "warmupFrameCount": warmupFrameCount,
            "scale": Double(displayScale), "scaleSource": scaleSource,
            "currentTraitScale": Double(current.traitCollection.displayScale),
            "targetTraitScale": Double(target.traitCollection.displayScale),
            "currentNeededScaleOverride": currentNeededOverride,
            "targetNeededScaleOverride": targetNeededOverride,
            "points": ["width": Double(size.width), "height": Double(size.height)],
            "pixels": ["width": outputPixelWidth, "height": outputPixelHeight,
                       "perFrame": outputPixelWidth * outputPixelHeight],
            "snapshots": ["scale": snapshotPlan.scale, "width": snapshotPlan.pixelWidth,
                          "height": snapshotPlan.pixelHeight, "totalPixels": paper.snapshotPixelCount,
                          "maximumSnapshotPixels": options.maximumSnapshotPixels],
            "stripCount": paper.stripCount,
            "paperColor": [0.97, 0.955, 0.92, 1.0], "targetColor": [0.72, 0.94, 0.96, 1.0],
            "thermal": ["beforeWarmup": thermalBefore, "afterMeasurement": thermalAfter],
            "lowPowerMode": ["beforeWarmup": lowPowerBefore,
                             "afterMeasurement": ProcessInfo.processInfo.isLowPowerModeEnabled],
            "device": ["machine": machine, "model": UIDevice.current.model,
                       "expectedProduct": "iPhone 13 Pro", "systemName": UIDevice.current.systemName,
                       "systemVersion": UIDevice.current.systemVersion, "simulator": isSimulator],
            "measurementScope": scope, "nativePresentationFPSMeasured": false,
            "percentileMethod": "nearest-rank: sorted[ceil(p * count) - 1]",
            "distribution": distribution(timings), "perCorner": perCorner, "frames": samples
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "corner-software-baseline.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CORNER_SOFTWARE_BASELINE_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("CORNER_SOFTWARE_BASELINE_JSON_END")
    }

    /// 同一真机、同一 36 帧路径测量 GPU 提交、执行和含读回的总耗时，读回不用于交互路径。
    func testRecordMetalCornerPerformance() throws {
        try requireHardwareRelease()
        let size = CGSize(width: 390, height: 844)
        let (window, host) = benchmarkHost(size: size)
        defer { window.isHidden = true; window.rootViewController = nil }
        let current = page(target: false, size: size), target = page(target: true, size: size)
        host.addSubview(target); host.addSubview(current); host.layoutIfNeeded()
        let scale = window.screen.scale
        let paper = try PaperTransitionView(currentView: current, targetView: target,
            effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
        defer { paper.invalidateResources() }
        XCTAssertTrue(paper.usesMetalCornerRendering)
        var cpu: [Double] = [], gpu: [Double] = [], wall: [Double] = []
        let thermalBefore = thermalName(ProcessInfo.processInfo.thermalState)
        for index in 0..<42 {
            let drag = try cornerDrag(index: index % 4,
                progress: CGFloat((index < 6 ? index : index - 6) + 1) / CGFloat(index < 6 ? 7 : 37), size: size)
            try autoreleasepool {
                paper.update(progress: drag.progress, cornerDrag: drag)
                let start = CACurrentMediaTime()
                let image = try XCTUnwrap(paper.cornerGPUImage(scale: scale))
                let elapsed = CACurrentMediaTime() - start
                let times = try XCTUnwrap(paper.metalLastTiming)
                XCTAssertEqual(image.cgImage?.width, 1170); XCTAssertEqual(image.cgImage?.height, 2532)
                if index >= 6 { cpu.append(times.cpu * 1000); gpu.append(times.gpu * 1000); wall.append(elapsed * 1000) }
            }
        }
        let record: [String: Any] = ["renderer": "Metal", "device": machineIdentifier(), "configuration": "Release",
            "scale": Double(scale), "pixels": [1170, 2532], "frameCount": 36, "warmupFrameCount": 6,
            "cpuEncodeMilliseconds": distribution(cpu), "gpuExecutionMilliseconds": distribution(gpu),
            "offscreenIncludingReadbackMilliseconds": distribution(wall),
            "thermalBefore": thermalBefore, "thermalAfter": thermalName(ProcessInfo.processInfo.thermalState),
            "scope": "CPU 为 geometry、顶点拷贝、命令编码和提交；GPU 为 command buffer 执行时间；总耗时另包含离屏目标分配、等待与读回。交互路径不执行读回。",
            "nativePresentationFPSMeasured": false]
        try recordMetrics(record, name: "corner-metal-hardware.json", marker: "CORNER_METAL_HARDWARE")
        XCTAssertLessThan(cpu.sorted()[Int(ceil(0.95 * Double(cpu.count))) - 1], 16.7)
    }

    /// 直接记录 CAMetalDrawable 的呈现时间，不以离屏绘图耗时推导 FPS。
    func testRecordMetalDisplayCadence() async throws {
        try await measureMetalDisplayCadence(highRefresh: false)
    }

    /// ProMotion 环境单独确认最高刷新率申请和真实呈现，不能用旧 60Hz 用例代替。
    func testRecordMetalHighRefreshCadence() async throws {
        try await measureMetalDisplayCadence(highRefresh: true)
    }

    /// - Parameter highRefresh: true 时测量当前屏幕最高值，false 时保留可比较的 60Hz 输入。
    /// - Returns: 无返回值；保存时钟与呈现的真实间隔及系统状态。
    private func measureMetalDisplayCadence(highRefresh: Bool) async throws {
        try requireHardwareRelease()
        let size = CGSize(width: 390, height: 844)
        let (window, host) = benchmarkHost(size: size)
        defer { window.isHidden = true; window.rootViewController = nil }
        let current = page(target: false, size: size), target = page(target: true, size: size)
        host.addSubview(target); host.addSubview(current); host.layoutIfNeeded()
        let paper = try PaperTransitionView(currentView: current, targetView: target,
            effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
        host.addSubview(paper); paper.collectMetalPresentationMetrics(); host.layoutIfNeeded()
        defer { paper.invalidateResources() }
        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: false,
            inwardSign: -1, origin: CGPoint(x: 378, y: 20)))
        let screenMaximum = window.screen.maximumFramesPerSecond
        let proMotionEnabled = Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool == true
        if highRefresh {
            XCTAssertTrue(proMotionEnabled, "高刷测量宿主必须启用 ProMotion Info.plist 配置")
            XCTAssertGreaterThan(screenMaximum, 60, "当前屏幕必须具备高于 60Hz 的能力")
        }
        let requestedFPS = highRefresh ? screenMaximum : min(60, screenMaximum)
        let frameLimit = requestedFPS * 3, cycleFrames = max(1, requestedFPS * 3 / 2)
        let clock = ReaderDisplayLink(), finished = expectation(description: "真机 \(frameLimit) 次刷新")
        var frame = 0
        var driverIntervals: [Double] = []
        let lowPowerBefore = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalBefore = thermalName(ProcessInfo.processInfo.thermalState)
        clock.onTick = { elapsed in
            driverIntervals.append(elapsed * 1000)
            let progress = 0.08 + 0.74 * CGFloat(frame % cycleFrames) / CGFloat(cycleFrames)
            if let drag = seed.moved(to: CGPoint(x: seed.origin.x - 780 * progress, y: 100 + 70 * sin(.pi * progress))) {
                paper.update(progress: drag.progress, cornerDrag: drag)
            }
            frame += 1
            if frame == frameLimit { clock.stop(); finished.fulfill() }
        }
        clock.start(maximumFramesPerSecond: requestedFPS); defer { clock.stop() }
        let range = try XCTUnwrap(clock.activeFrameRateRange)
        await fulfillment(of: [finished], timeout: 10)
        try await Task.sleep(nanoseconds: 150_000_000)
        let times = Array(paper.metalPresentationTimes.sorted().dropFirst(6))
        XCTAssertGreaterThan(times.count, Int(Double(frameLimit) * 0.85), "必须取得足够真实 drawable 呈现回调")
        let intervals = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }
        guard let first = times.first, let last = times.last, intervals.count > 0 else { return XCTFail("缺少屏幕呈现数据") }
        let presentedFPS = Double(intervals.count) / (last - first)
        let record: [String: Any] = ["renderer": "Metal CAMetalLayer", "device": machineIdentifier(),
            "configuration": "Release", "scale": Double(window.screen.scale), "sampleCount": times.count,
            "requestedFPS": requestedFPS, "screenMaximumFPS": screenMaximum, "highRefresh": highRefresh,
            "proMotionInfoPlistEnabled": proMotionEnabled, "inputFrameCount": frameLimit,
            "requestedRange": ["minimum": range.minimum, "maximum": range.maximum, "preferred": range.preferred],
            "driverIntervalMilliseconds": distribution(Array(driverIntervals.dropFirst(6))),
            "lowPowerBefore": lowPowerBefore, "lowPowerAfter": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "presentedFPS": presentedFPS, "presentationIntervalMilliseconds": distribution(intervals),
            "intervalsAbove25ms": intervals.filter { $0 > 25 }.count,
            "intervalsAboveBudget50Percent": intervals.filter { $0 > 1500 / Double(requestedFPS) }.count,
            "cpuEncodeMilliseconds": distribution(paper.metalFrameCPUTimes.map { $0 * 1000 }),
            "softwareCornerDrawCount": paper.softwareCornerDrawCount,
            "thermalBefore": thermalBefore, "thermalAfter": thermalName(ProcessInfo.processInfo.thermalState),
            "scope": "本设备 Release 的 \(frameLimit) 次 CADisplayLink 驱动与 CAMetalDrawable.presentedTime；排除前六次呈现，仅代表此测量流程。"]
        try recordMetrics(record, name: highRefresh ? "reader-high-refresh-cadence.json" : "corner-metal-display-cadence.json",
            marker: highRefresh ? "READER_HIGH_REFRESH_CADENCE" : "CORNER_METAL_CADENCE")
        XCTAssertEqual(paper.softwareCornerDrawCount, 0)
        XCTAssertGreaterThan(presentedFPS, Double(requestedFPS) * 0.9)
        XCTAssertLessThan(intervals.sorted()[Int(ceil(0.95 * Double(intervals.count))) - 1], 1500 / Double(requestedFPS))
    }

    /// 真机 Release 前置条件；不在模拟器伪造硬件数据。
    private func requireHardwareRelease() throws {
        #if targetEnvironment(simulator) || DEBUG
        throw XCTSkip("硬件性能测试只记录已连接 iPhone 的 Release 构建")
        #else
        XCTAssertEqual(machineIdentifier(), "iPhone14,2")
        #endif
    }

    /// - Parameter size: 实际测试视口；返回持有本次显示树的窗口及根视图。
    private func benchmarkHost(size: CGSize) -> (UIWindow, UIView) {
        let bounds = CGRect(origin: .zero, size: size)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene); window.frame = bounds
        } else { window = UIWindow(frame: bounds) }
        let controller = UIViewController(); controller.view = UIView(frame: bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        return (window, controller.view)
    }

    /// - Parameters: record: 实际测量值；name: 附件名；marker: 日志前缀。保存原始结果便于独立核验。
    private func recordMetrics(_ record: [String: Any], name: String, marker: String) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print(marker + "_JSON_BEGIN"); print(String(decoding: data, as: UTF8.self)); print(marker + "_JSON_END")
    }

    /// - Parameters: target: 是否目标页；size: 固定画布点尺寸。
    /// - Returns: 独立、已排版的真实多行文字页面，当前米色、目标青色且正文不同。
    private func page(target: Bool, size: CGSize) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = .light
        view.isOpaque = true
        view.backgroundColor = target
            ? UIColor(red: 0.72, green: 0.94, blue: 0.96, alpha: 1)
            : UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
        let title = UILabel(frame: CGRect(x: 28, y: 42, width: size.width - 56, height: 64))
        title.numberOfLines = 2
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        title.textColor = .black
        title.text = target ? "第二章  晨光与远岸\n下一页 · Reading 002" : "第一章  风从书页来\n当前页 · Reading 001"
        view.addSubview(title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        paragraph.firstLineHeadIndent = 34
        paragraph.alignment = .justified
        let body = UILabel(frame: CGRect(x: 28, y: 124, width: size.width - 56, height: size.height - 186))
        body.numberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        let text = target
            ? "清晨的光沿着河岸铺开，远处的钟声穿过薄雾。旅人翻到新的一页，记下眼前缓缓变化的颜色。\n每一行文字都有自己的间距，每一段故事都从不同的地方开始。纸张弯起时，青色的下一页在折痕后显露。\nThe next chapter follows the river beyond the town. Different words and numbers 24680 remain part of a real text layout.\n船靠近岸边，人们把昨天未完的故事继续讲下去。风吹过窗台，新的道路正在远方延伸。"
            : "傍晚的风穿过书房，吹动桌上的纸页。窗外树影缓慢摇晃，读者沿着字句走进一段安静的故事。\n真实的多行排版保留中文、英文和数字，行间留出呼吸的空间。手指从四个纸角斜向拖动，折痕和阴影随进度改变。\nA page carries words, punctuation, and numbers 13579. The light moves across the paper while the reader follows each line.\n他在页边写下一句短短的话，然后停下来听远处的脚步声。故事仍在继续，下一页已经等候多时。"
        body.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ])
        view.addSubview(body)
        let footer = UILabel(frame: CGRect(x: 28, y: size.height - 42, width: size.width - 56, height: 22))
        footer.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        footer.textColor = .darkGray
        footer.textAlignment = .center
        footer.text = target ? "002 · 河岸清晨" : "001 · 书房晚风"
        view.addSubview(footer)
        view.layoutIfNeeded()
        return view
    }

    /// - Parameters: index: 左上、右上、左下、右下角索引；progress: 各帧不同的进度；size: 画布尺寸。
    /// - Returns: 通过当前 geometry API 生成并约束的斜向纸角拖动。
    private func cornerDrag(index: Int, progress: CGFloat, size: CGSize) throws -> PaperCornerDrag {
        let fromRight = index % 2 == 1
        let fromBottom = index >= 2
        let origin = CGPoint(x: fromRight ? size.width - 12 : 12,
                             y: fromBottom ? size.height - 12 : 12)
        let sign: CGFloat = fromRight ? -1 : 1
        let initial = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal,
            spread: false, inwardSign: sign, origin: origin))
        let point = CGPoint(x: origin.x + sign * 2 * size.width * progress,
                            y: origin.y + (fromBottom ? -1 : 1) * size.height * 0.16 * sin(.pi * progress))
        return try XCTUnwrap(initial.moved(to: point))
    }

    /// - Parameters: renderer: 全程复用的实际屏幕倍率渲染器；paper: 当前 CPU 纸张视图；drag: 此帧拖动。
    /// - Returns: 仅 image/context/draw 区间的毫秒数及真实输出像素；每帧退出 autoreleasepool 释放图像。
    private func drawFrame(renderer: UIGraphicsImageRenderer, paper: PaperTransitionView,
                           drag: PaperCornerDrag) throws -> FrameMeasurement {
        try autoreleasepool {
            paper.update(progress: drag.progress, cornerDrag: drag)
            let start = CACurrentMediaTime()
            let image = renderer.image { _ in paper.draw(paper.bounds) }
            let milliseconds = (CACurrentMediaTime() - start) * 1_000
            let pixels = try XCTUnwrap(image.cgImage)
            return FrameMeasurement(milliseconds: milliseconds, pixelWidth: pixels.width, pixelHeight: pixels.height)
        }
    }

    /// - Parameter values: 排除预热后的逐帧毫秒数，必须非空。
    /// - Returns: 最近秩 p50/p95、最大值、总耗时和帧数。
    private func distribution(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        return ["frameCount": values.count,
                "p50Milliseconds": sorted[Int(ceil(0.50 * Double(sorted.count))) - 1],
                "p95Milliseconds": sorted[Int(ceil(0.95 * Double(sorted.count))) - 1],
                "maxMilliseconds": sorted[sorted.count - 1],
                "totalMilliseconds": values.reduce(0, +)]
    }

    /// 无参数；返回 uname 的实际硬件标识，不依赖可自定义的设备名称。
    private func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// - Parameter state: 实测时的系统温度状态。
    /// - Returns: 可跨运行比较的温度状态名称。
    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
#endif
