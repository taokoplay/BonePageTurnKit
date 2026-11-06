#if canImport(UIKit)
import UIKit
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

/// 直接调用真实 draw(_:) 的位图回归；不复刻分页容器状态机。
@MainActor
final class PaperTransitionViewTests: XCTestCase {
    /// 通过只读返回非法 bounds，避免把 NaN 传给真实 CALayer 属性而触发系统异常。
    private final class BoundsFixtureView: UIView {
        var reportedBounds: CGRect = .zero
        override var bounds: CGRect {
            get { reportedBounds }
            set { super.bounds = newValue }
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: Data

        /// - Parameters: x: 横向像素；y: 纵向像素。
        /// - Returns: 标准 RGBA 数据中的前三个分量。
        func rgb(x: Int, y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 3)])
        }

        var averageBrightness: Double {
            let sum = stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { partial, offset in
                partial + Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])
            }
            return sum / Double(width * height * 3)
        }
    }

    /// - Parameters: index: 页面身份；origin: 局部 bounds 原点；dark: 是否使用深色 trait。
    /// - Returns: 含真实 UILabel、UIImageView 和四边方向标记的已布局页面。
    private func page(_ index: Int, origin: CGPoint = .zero, dark: Bool = false) -> UIView {
        let size = CGSize(width: 240, height: 360)
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.bounds = CGRect(origin: origin, size: size)
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        view.backgroundColor = dark ? (index == 0 ? .systemBackground : .secondarySystemBackground)
            : (index == 0 ? UIColor(red: 1, green: 0.96, blue: 0.84, alpha: 1)
                         : UIColor(red: 0.83, green: 0.96, blue: 1, alpha: 1))
        let markers: [(CGRect, UIColor)] = [
            (CGRect(x: 0, y: 0, width: 10, height: 360), .red),
            (CGRect(x: 230, y: 0, width: 10, height: 360), .blue),
            (CGRect(x: 10, y: 0, width: 220, height: 10), .green),
            (CGRect(x: 10, y: 350, width: 220, height: 10), .magenta)
        ]
        for (frame, color) in markers {
            let marker = UIView(frame: frame.offsetBy(dx: origin.x, dy: origin.y))
            marker.backgroundColor = color
            view.addSubview(marker)
        }
        let label = UILabel(frame: CGRect(x: 22, y: 30, width: 196, height: 95)
            .offsetBy(dx: origin.x, dy: origin.y))
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .label
        label.text = "第 \(index + 1) 页 ABC →\n纸张曲面 0123\n文字方向保持稳定"
        view.addSubview(label)
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.scale = 1
        imageFormat.preferredRange = .standard
        let illustration = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 70), format: imageFormat).image {
            UIColor.systemOrange.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 100, height: 70))
            UIColor.systemTeal.setFill()
            $0.fill(CGRect(x: index == 0 ? 0 : 60, y: 0, width: 40, height: 70))
            UIColor.systemPurple.setFill()
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: 20, y: 60))
            triangle.addLine(to: CGPoint(x: 70, y: 60))
            triangle.addLine(to: CGPoint(x: 45, y: 10))
            triangle.close()
            triangle.fill()
        }
        let imageView = UIImageView(image: illustration)
        imageView.frame = CGRect(x: 24, y: 155, width: 192, height: 140).offsetBy(dx: origin.x, dy: origin.y)
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        view.layoutIfNeeded()
        return view
    }

    /// - Parameters: current: 当前页；target: 目标页；effect: 曲面；direction: 方向；spine: 书脊；options: 预算。
    /// - Returns: 不依赖窗口或容器的纸面 overlay。
    private func overlay(_ current: UIView, _ target: UIView, effect: PageTurnEffect = .curl,
                         direction: PageTurnDirection = .next, spine: PageSpinePlacement = .minimum,
                         options: PaperRenderingOptions = .init()) throws -> PaperTransitionView {
        try PaperTransitionView(currentView: current, targetView: target, effect: effect,
                                direction: direction, spine: spine, options: options)
    }

    /// - Parameters: view: 被测 overlay；outputSize: 可选的缩小输出，避免测试本身为大视图分配巨图。
    /// - Returns: 执行实际曲面 draw(_:) 后的截图。
    private func render(_ view: PaperTransitionView, outputSize: CGSize? = nil) -> UIImage {
        let size = outputSize ?? view.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image {
            $0.cgContext.scaleBy(x: size.width / view.bounds.width, y: size.height / view.bounds.height)
            $0.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
            view.draw(view.bounds)
        }
    }

    /// - Parameter image: 实际绘制输出。
    /// - Returns: 固定 RGBA 顺序的像素副本；避免依赖 UIKit 默认的 BGRA 内存顺序。
    private func raster(_ image: UIImage) throws -> Raster {
        let source = try XCTUnwrap(image.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
                                             bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let result = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(result.dataProvider?.data)
        return Raster(width: source.width, height: source.height, bytes: data as Data)
    }

    /// - Parameters: image: 已绘制图；name: 截图库名称。
    /// - Returns: 无返回值；附件由父代理统一执行 UIKit 测试时生成。
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 无参数；两种效果、两个方向、两个书脊的 0/.3/.6/1 截图库及稳定文字方向。
    func testRenderedGalleryHasStableEndpointsAndDistinctCurves() throws {
        let current = page(0)
        let target = page(1)
        let reference = try overlay(current, target)
        let initial = try XCTUnwrap(render(reference).pngData())
        reference.update(progress: 1)
        let final = try XCTUnwrap(render(reference).pngData())
        XCTAssertNotEqual(initial, final)
        for direction in [PageTurnDirection.next, .previous] {
            for spine in [PageSpinePlacement.minimum, .maximum] {
                var curlFrames: [CGFloat: Data] = [:]
                for effect in [PageTurnEffect.curl, .arch] {
                    let view = try overlay(current, target, effect: effect, direction: direction, spine: spine)
                    for progress: CGFloat in [0, 0.3, 0.6, 1] {
                        view.update(progress: progress)
                        let image = render(view)
                        let data = try XCTUnwrap(image.pngData())
                        let pixels = try raster(image)
                        attach(image, name: "纸面-\(effect)-\(direction)-\(spine)-\(progress)")
                        XCTAssertGreaterThan(pixels.averageBrightness, 120, "中间帧不得黑屏")
                        if progress == 0 || progress == 1 {
                            XCTAssertEqual(data, progress == 0 ? initial : final)
                            let left = pixels.rgb(x: 3, y: 180)
                            let right = pixels.rgb(x: 236, y: 180)
                            XCTAssertGreaterThan(Int(left[0]) - Int(left[2]), 180)
                            XCTAssertGreaterThan(Int(right[2]) - Int(right[0]), 180)
                            let top = pixels.rgb(x: 120, y: 3)
                            let bottom = pixels.rgb(x: 120, y: 356)
                            XCTAssertGreaterThan(Int(top[1]) - Int(top[0]), 180, "Y 轴不可倒置")
                            XCTAssertGreaterThan(Int(bottom[0]) - Int(bottom[1]), 180)
                        } else {
                            XCTAssertNotEqual(data, initial)
                            XCTAssertNotEqual(data, final)
                            if effect == .curl { curlFrames[progress] = data }
                            else { XCTAssertNotEqual(data, curlFrames[progress], "两种曲面不能复用同一平移图") }
                        }
                    }
                }
            }
        }
    }

    /// 条带共享边界不能透出底页；curl 未弯曲区域应保持稳定文字和插图像素。
    func testStripEdgesDoNotLeakUnderlyingPageOrFadeFlatText() throws {
        let current = page(0)
        let target = page(1)
        let curl = try overlay(current, target)
        let original = try raster(render(curl))
        curl.update(progress: 0.3)
        let curved = try raster(render(curl))
        var changed = 0
        for y in 20..<330 {
            for x in 12..<150 {
                let a = original.rgb(x: x, y: y)
                let b = curved.rgb(x: x, y: y)
                if zip(a, b).contains(where: { abs(Int($0.0) - Int($0.1)) > 3 }) { changed += 1 }
            }
        }
        XCTAssertLessThan(changed, 100, "平面区域不应因条带而丢失文字像素")
        for effect in [PageTurnEffect.curl, .arch] {
            let red = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 360))
            let blue = UIView(frame: red.frame)
            red.backgroundColor = .red
            blue.backgroundColor = .blue
            let paper = try overlay(red, blue, effect: effect)
            for progress: CGFloat in [0.3, 0.6] {
                paper.update(progress: progress)
                let output = try raster(render(paper))
                for x in 10..<60 {
                    let pixel = output.rgb(x: x, y: 180)
                    XCTAssertGreaterThan(pixel[0], 200)
                    XCTAssertLessThan(pixel[2], 5, "接缝不得透出蓝色底页：\(effect) x=\(x)")
                    if effect == .arch { XCTAssertLessThan(pixel[0], 250, "阴影不能在半像素拼接处漏列") }
                }
            }
        }
    }

    /// 无参数；实际捕获像素数与预算计划一致，极窄位图可减少实际条带数。
    func testCapturePixelBudgetAndConfiguredStripCounts() throws {
        let current = page(0)
        let target = page(1)
        let scale = max(1, current.traitCollection.displayScale)
        for budget in [65_536, 4_194_304, 16_777_216] {
            for count in [32, 128, 256] {
                let options = PaperRenderingOptions(maximumSnapshotPixels: budget, stripCount: count)
                let view = try overlay(current, target, options: options)
                let plan = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(width: 240, height: 360,
                    displayScale: Double(scale), maximumSnapshotPixels: budget))
                XCTAssertEqual(view.snapshotPixelCount, plan.totalPixelCount)
                XCTAssertLessThanOrEqual(view.snapshotPixelCount, budget)
                XCTAssertEqual(view.stripCount, min(count, plan.pixelWidth))
                XCTAssertEqual(view.contentScaleFactor, CGFloat(plan.scale), accuracy: 1e-9)
                XCTAssertTrue(view.hasResources)
                view.invalidateResources()
            }
        }
    }

    /// 无参数；大点尺寸在创建 UIGraphicsImageRenderer 前缩小，不先分配全尺寸位图。
    func testLargeViewIsDownsampledBeforeCapture() throws {
        let size = CGSize(width: 36_000, height: 24_000)
        let current = UIView(frame: CGRect(origin: .zero, size: size))
        let target = UIView(frame: CGRect(origin: .zero, size: size))
        current.backgroundColor = .orange
        target.backgroundColor = .cyan
        let view = try overlay(current, target, effect: .arch,
                               options: .init(maximumSnapshotPixels: 65_536))
        XCTAssertLessThan(view.contentScaleFactor, 0.01)
        XCTAssertLessThanOrEqual(view.snapshotPixelCount, 65_536)
        XCTAssertGreaterThan(view.snapshotPixelCount, 60_000)
        view.update(progress: 0.6)
        let image = render(view, outputSize: CGSize(width: 240, height: 160))
        XCTAssertGreaterThan(try raster(image).averageBrightness, 80)
        attach(image, name: "大页面预算缩放-arch-0.6")
    }

    /// 无参数；非法尺寸和捕获前的错误不会静默替换为其他效果。
    func testInvalidDimensionsAndUnsupportedInputsThrow() throws {
        let normal = page(0)
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 360),
                       CGRect(x: 0, y: 0, width: CGFloat.nan, height: 360),
                       CGRect(x: 0, y: 0, width: 240, height: CGFloat.infinity),
                       CGRect(x: CGFloat.nan, y: 0, width: 240, height: 360),
                       CGRect(x: 0, y: 0, width: 241, height: 360)] {
            let invalid = BoundsFixtureView(frame: .zero)
            invalid.reportedBounds = bounds
            XCTAssertThrowsError(try overlay(normal, invalid)) {
                XCTAssertEqual($0 as? PageTurnError, .snapshotUnavailable)
            }
            XCTAssertThrowsError(try overlay(invalid, normal)) {
                XCTAssertEqual($0 as? PageTurnError, .snapshotUnavailable)
            }
        }
        XCTAssertThrowsError(try overlay(normal, page(1), effect: .cover)) {
            XCTAssertEqual($0 as? PageTurnError, .unsupportedPresentation)
        }
        XCTAssertThrowsError(try overlay(normal, page(1), options: .init(stripCount: 31)))
    }

    /// 无参数；释放接口清空所有资源，且 overlay 不持有页面或形成自身引用环。
    func testInvalidationIsIdempotentAndDoesNotRetainPages() throws {
        let currentWeak = WeakObject<UIView>(nil)
        let targetWeak = WeakObject<UIView>(nil)
        var view: PaperTransitionView?
        try autoreleasepool {
            let current = page(0)
            let target = page(1)
            currentWeak.value = current
            targetWeak.value = target
            view = try overlay(current, target)
        }
        XCTAssertNil(currentWeak.value)
        XCTAssertNil(targetWeak.value)
        let overlayWeak = WeakObject(view)
        XCTAssertEqual(view?.hasResources, true)
        view?.update(progress: 0.6)
        if let view { _ = render(view) }
        view?.invalidateResources()
        view?.invalidateResources()
        XCTAssertEqual(view?.snapshotPixelCount, 0)
        XCTAssertEqual(view?.stripCount, 0)
        XCTAssertEqual(view?.hasResources, false)
        view?.update(progress: 1)
        if let view { _ = render(view) }
        view = nil
        XCTAssertNil(overlayWeak.value)
    }

    /// 无参数；非零源 bounds 和非零 overlay bounds 都归一到相同截图。
    func testNonzeroBoundsOriginProducesNormalizedSnapshots() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let normalized = try overlay(page(0), page(1), effect: effect)
            let shifted = try overlay(page(0, origin: CGPoint(x: 17, y: 31)),
                                      page(1, origin: CGPoint(x: -13, y: 7)), effect: effect)
            shifted.bounds = CGRect(x: 9, y: 21, width: 240, height: 360)
            for progress: CGFloat in [0, 0.3, 0.6, 1] {
                normalized.update(progress: progress)
                shifted.update(progress: progress)
                XCTAssertEqual(render(shifted).pngData(), render(normalized).pngData())
            }
        }
    }

    /// 无参数；动态背景和背面纸色使用源页面的深色 trait。
    func testDarkTraitsRenderLabelsImagesAndPaperBack() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 360))
            let host = UIViewController()
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let current = page(0, dark: true)
            let target = page(1, dark: true)
            host.view.addSubview(current)
            host.view.addSubview(target)
            host.view.layoutIfNeeded()
            XCTAssertEqual(current.traitCollection.userInterfaceStyle, .dark)
            let view = try overlay(current, target, effect: effect)
            XCTAssertEqual(view.overrideUserInterfaceStyle, .dark)
            let initial = try raster(render(view))
            XCTAssertTrue(initial.rgb(x: 20, y: 20).allSatisfy { $0 < 64 })
            for progress: CGFloat in [0.3, 0.6] {
                view.update(progress: progress)
                let image = render(view)
                let output = try raster(image)
                XCTAssertGreaterThan(output.averageBrightness, 5, "深色背景仍有文字和彩色图像")
                XCTAssertLessThan(output.averageBrightness, 160, "纸张背面不能突然变成白色")
                attach(image, name: "深色纸面-\(effect)-\(progress)")
            }
        }
    }

    /// 无参数；有限进度钳制、非有限值忽略，上一页的真实绘图与下一页反向一致。
    func testProgressClampingAndPreviousRenderedReversal() throws {
        let current = page(0)
        let target = page(1)
        for effect in [PageTurnEffect.curl, .arch] {
            for spine in [PageSpinePlacement.minimum, .maximum] {
                let forward = try overlay(current, target, effect: effect, spine: spine)
                let reverse = try overlay(target, current, effect: effect, direction: .previous, spine: spine)
                for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    forward.update(progress: progress)
                    reverse.update(progress: 1 - progress)
                    XCTAssertEqual(render(forward).pngData(), render(reverse).pngData())
                }
                forward.update(progress: 0.3)
                let stable = render(forward).pngData()
                for invalid in [CGFloat.nan, .infinity, -.infinity] {
                    forward.update(progress: invalid)
                    XCTAssertEqual(render(forward).pngData(), stable)
                }
                forward.update(progress: -1)
                reverse.update(progress: 1)
                XCTAssertEqual(render(forward).pngData(), render(reverse).pngData())
                forward.update(progress: 2)
                reverse.update(progress: 0)
                XCTAssertEqual(render(forward).pngData(), render(reverse).pngData())
            }
        }
    }
}
#endif
