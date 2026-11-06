#if canImport(UIKit)
import UIKit
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

/// 调用真实 UIKit 捕获和 draw(_:)；附件由执行 iOS 测试的父代理生成。
@MainActor
final class ExtendedPaperRenderingTests: XCTestCase {
    private struct Raster {
        let width: Int
        let height: Int
        let bytes: Data

        /// - Parameters: advance: 翻页轴比例；cross: 横跨轴比例；axis: 翻页轴。
        /// - Returns: 对应实际画布方向的 RGB 像素。
        func rgb(advance: Double, cross: Double = 0.75, axis: PageTurnAxis) -> [UInt8] {
            let x = Int((axis == .horizontal ? advance : cross) * Double(width))
            let y = Int((axis == .horizontal ? cross : advance) * Double(height))
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<(offset + 3)])
        }
    }

    /// - Parameters: target: 是否目标跨页；axis: 布局轴；decorated: 是否添加文字和非对称方向标记。
    /// - Returns: 按实际坐标摆放 UILabel 的两半页；四种底色用于识别真实正反面。
    private func spread(target: Bool, axis: PageTurnAxis, decorated: Bool = true) -> UIView {
        let size = axis == .horizontal ? CGSize(width: 320, height: 240) : CGSize(width: 240, height: 320)
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = .white
        let colors: [UIColor] = target ? [.blue, .yellow] : [.red, .green]
        for index in 0..<2 {
            let frame = axis == .horizontal
                ? CGRect(x: CGFloat(index) * size.width / 2, y: 0, width: size.width / 2, height: size.height)
                : CGRect(x: 0, y: CGFloat(index) * size.height / 2, width: size.width, height: size.height / 2)
            let panel = UIView(frame: frame)
            panel.backgroundColor = colors[index]
            view.addSubview(panel)
            guard decorated else { continue }
            let label = UILabel(frame: CGRect(x: 14, y: 22, width: frame.width - 28, height: 65))
            label.text = "\(target ? "目标" : "当前") \(index + 1) →\nABC 中文 012"
            label.numberOfLines = 2
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = .black
            label.backgroundColor = .white
            panel.addSubview(label)
            for (markerFrame, color) in [
                (CGRect(x: 4, y: 4, width: 8, height: 8), UIColor.magenta),
                (CGRect(x: frame.width - 12, y: 4, width: 8, height: 8), UIColor.cyan),
                (CGRect(x: 4, y: frame.height - 12, width: 8, height: 8), UIColor.black)
            ] {
                let marker = UIView(frame: markerFrame)
                marker.backgroundColor = color
                panel.addSubview(marker)
            }
        }
        view.layoutIfNeeded()
        return view
    }

    /// - Parameters: view: 被测纸张；outputSize: 可选的小画布，用于巨大页面预算测试。
    /// - Returns: 直接调用真实 draw(_:) 产生的正向截图。
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

    /// - Parameter image: UIKit 实际绘制结果。
    /// - Returns: sRGB、RGBA 顺序的像素数据，不依赖设备默认位图排列。
    private func raster(_ image: UIImage) throws -> Raster {
        let source = try XCTUnwrap(image.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let output = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(output.dataProvider?.data)
        return Raster(width: source.width, height: source.height, bytes: data as Data)
    }

    /// - Parameters: image: 实际截图；name: 含轴向、效果和进度的附件名。
    /// - Returns: 无返回值。
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// - Parameters: actual: 实际像素；expected: 无阴影的页面 RGB；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；允许纸面阴影变暗，但不允许混入另一页或透印原正面。
    private func assertPageColor(_ actual: [UInt8], _ expected: [UInt8],
                                 file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<3 {
            if expected[index] == 0 { XCTAssertLessThan(actual[index], 5, file: file, line: line) }
            else { XCTAssertGreaterThan(actual[index], 170, file: file, line: line) }
        }
    }

    /// 无参数；两轴、单双页、两种书脊及阅读顺序的端点正向，并逐帧验证 previous 精确反向。无返回值。
    func testAxesSpinesOrdersAndDirectionsKeepUprightEndpointsAndReverseExactly() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let current = spread(target: false, axis: axis)
            let target = spread(target: true, axis: axis)
            let reference = try PaperTransitionView(currentView: current, targetView: target,
                effect: .curl, direction: .next, spine: .minimum, options: .standard)
            let first = try XCTUnwrap(render(reference).pngData())
            reference.update(progress: 1)
            let last = try XCTUnwrap(render(reference).pngData())
            for spine in [PageSpinePlacement.minimum, .maximum, .center] {
                for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                    for effect in [PageTurnEffect.curl, .arch] {
                        let forward = try PaperTransitionView(currentView: current, targetView: target,
                            effect: effect, direction: .next, spine: spine, options: .standard,
                            axis: axis, readingOrder: order)
                        let reverse = try PaperTransitionView(currentView: target, targetView: current,
                            effect: effect, direction: .previous, spine: spine, options: .standard,
                            axis: axis, readingOrder: order)
                        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                            forward.update(progress: progress)
                            reverse.update(progress: 1 - progress)
                            let image = render(forward)
                            let data = try XCTUnwrap(image.pngData())
                            XCTAssertEqual(data, render(reverse).pngData(), "\(axis)-\(spine)-\(order)-\(effect)-\(progress)")
                            if progress == 0 || progress == 1 {
                                // 与旧水平整图路径逐像素一致，文字、左右标记及上下标记不可旋转或镜像。
                                XCTAssertEqual(data, progress == 0 ? first : last)
                            } else {
                                XCTAssertNotEqual(data, first)
                                XCTAssertNotEqual(data, last)
                            }
                            if spine == .center || progress == 0.5 {
                                attach(image, name: "扩展纸张-\(axis)-\(spine)-\(order)-\(effect)-next-\(progress)")
                            }
                            if progress == 0.5 {
                                attach(render(reverse), name: "扩展纸张-\(axis)-\(spine)-\(order)-\(effect)-previous-0.5")
                            }
                        }
                        forward.update(progress: 0.375)
                        let stable = render(forward).pngData()
                        for invalid in [CGFloat.nan, .infinity, -.infinity] {
                            forward.update(progress: invalid)
                            XCTAssertEqual(render(forward).pngData(), stable)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；底页身份全程固定；前段为当前正面，后段为真实目标背面，中线附近不闪现错误半页。无返回值。
    func testCentralFixedPagesAndRealMovingFrontAndBackContent() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let minimumFront = axis == .horizontal && order == .rightToLeft
                let fixedMinimum: [UInt8] = minimumFront ? [0, 0, 255] : [255, 0, 0]
                let fixedMaximum: [UInt8] = minimumFront ? [0, 255, 0] : [255, 255, 0]
                let frontColor: [UInt8] = minimumFront ? [255, 0, 0] : [0, 255, 0]
                let backColor: [UInt8] = minimumFront ? [255, 255, 0] : [0, 0, 255]
                for effect in [PageTurnEffect.curl, .arch] {
                    let view = try PaperTransitionView(currentView: spread(target: false, axis: axis, decorated: false),
                        targetView: spread(target: true, axis: axis, decorated: false),
                        effect: effect, direction: .next, spine: .center, options: .standard,
                        axis: axis, readingOrder: order)
                    for progress: CGFloat in [0.25, 0.49, 0.5, 0.51, 0.75] {
                        view.update(progress: progress)
                        let image = render(view)
                        let pixels = try raster(image)
                        XCTAssertEqual(pixels.rgb(advance: 0.05, axis: axis), fixedMinimum)
                        XCTAssertEqual(pixels.rgb(advance: 0.95, axis: axis), fixedMaximum)
                        if progress == 0.25 {
                            assertPageColor(pixels.rgb(advance: minimumFront ? 0.4 : 0.6, axis: axis), frontColor)
                        }
                        if progress == 0.75 {
                            assertPageColor(pixels.rgb(advance: minimumFront ? 0.6 : 0.4, axis: axis), backColor)
                        }
                        attach(image, name: "中央真实页身份-\(axis)-\(order)-\(effect)-\(progress)")
                    }
                }
            }
        }
    }

    /// 无参数；纵向平面文字保持原像素采样，条带接缝不得透出蓝色底页或漏画阴影。无返回值。
    func testVerticalFlatTextAndStripSeamsKeepOriginalSampling() throws {
        for spine in [PageSpinePlacement.minimum, .maximum] {
            let view = try PaperTransitionView(currentView: spread(target: false, axis: .vertical),
                targetView: spread(target: true, axis: .vertical), effect: .curl, direction: .next,
                spine: spine, options: .standard, axis: .vertical)
            let initial = try raster(render(view))
            view.update(progress: 0.25)
            let curved = try raster(render(view))
            var changed = 0
            for y in (spine == .minimum ? 16..<120 : 200..<304) {
                for x in 14..<226 {
                    let offset = (y * initial.width + x) * 4
                    if (0..<3).contains(where: { abs(Int(initial.bytes[offset + $0]) - Int(curved.bytes[offset + $0])) > 3 }) {
                        changed += 1
                    }
                }
            }
            XCTAssertLessThan(changed, 30, "静止文字不能因纵向采样而旋转或模糊")
        }
        for effect in [PageTurnEffect.curl, .arch] {
            let red = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 320))
            let blue = UIView(frame: red.frame)
            red.backgroundColor = .red
            blue.backgroundColor = .blue
            let view = try PaperTransitionView(currentView: red, targetView: blue, effect: effect,
                direction: .next, spine: .minimum, options: .standard, axis: .vertical)
            for progress: CGFloat in [0.3, 0.6] {
                view.update(progress: progress)
                let pixels = try raster(render(view))
                for y in 10..<60 {
                    let pixel = pixels.rgb(advance: Double(y) / 320, cross: 0.5, axis: .vertical)
                    XCTAssertGreaterThan(pixel[0], 200)
                    XCTAssertLessThan(pixel[2], 5)
                    if effect == .arch { XCTAssertLessThan(pixel[0], 250) }
                }
            }
        }
    }

    /// 无参数；两轴、单双页均先预算再捕获，正反面与原图幂等释放，不持有宿主页面。无返回值。
    func testBudgetNarrowStripsAndReleaseForBothAxesAndLayouts() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for spine in [PageSpinePlacement.minimum, .maximum, .center] {
                let currentWeak = WeakObject<UIView>(nil)
                let targetWeak = WeakObject<UIView>(nil)
                var overlay: PaperTransitionView?
                var sourceScale: CGFloat = 1
                let size = axis == .horizontal ? CGSize(width: 12_000, height: 7_001) : CGSize(width: 7_001, height: 12_000)
                try autoreleasepool {
                    let current = UIView(frame: CGRect(origin: .zero, size: size))
                    let target = UIView(frame: current.frame)
                    sourceScale = max(1, current.traitCollection.displayScale)
                    current.backgroundColor = .red
                    target.backgroundColor = .blue
                    currentWeak.value = current
                    targetWeak.value = target
                    overlay = try PaperTransitionView(currentView: current, targetView: target, effect: .curl,
                        direction: .next, spine: spine,
                        options: .init(maximumSnapshotPixels: 65_536, stripCount: 256),
                        axis: axis, readingOrder: .rightToLeft)
                }
                XCTAssertNil(currentWeak.value)
                XCTAssertNil(targetWeak.value)
                let plan = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(width: Double(size.width), height: Double(size.height),
                    displayScale: Double(sourceScale), maximumSnapshotPixels: 65_536))
                let axisPixels = axis == .horizontal ? plan.pixelWidth : plan.pixelHeight
                let crossPixels = axis == .horizontal ? plan.pixelHeight : plan.pixelWidth
                let expectedPixels = (spine == .center ? axisPixels / 2 * 2 : axisPixels) * crossPixels * 2
                XCTAssertEqual(overlay?.snapshotPixelCount, expectedPixels)
                XCTAssertLessThanOrEqual(overlay?.snapshotPixelCount ?? Int.max, 65_536)
                XCTAssertEqual(overlay?.stripCount, min(256, spine == .center ? axisPixels / 2 : axisPixels))
                XCTAssertEqual(overlay?.hasResources, true)
                let weakOverlay = WeakObject(overlay)
                if let view = overlay {
                    view.update(progress: 0.75)
                    let image = render(view, outputSize: CGSize(width: 240, height: 160))
                    attach(image, name: "扩展纸张预算-\(axis)-\(spine)")
                    view.layer.contents = image.cgImage
                    view.invalidateResources()
                    view.invalidateResources()
                    XCTAssertNil(view.layer.contents)
                    XCTAssertEqual(view.snapshotPixelCount, 0)
                    XCTAssertEqual(view.stripCount, 0)
                    XCTAssertFalse(view.hasResources)
                    view.update(progress: 0.5)
                    _ = render(view, outputSize: CGSize(width: 24, height: 16))
                }
                overlay = nil
                XCTAssertNil(weakOverlay.value)
            }
        }
    }
}
#endif
