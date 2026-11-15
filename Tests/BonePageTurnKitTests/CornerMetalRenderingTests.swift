#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class CornerMetalRenderingTests: XCTestCase {
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: Data
        func rgb(_ point: CGPoint) -> [UInt8] {
            let x = min(width - 1, max(0, Int(point.x))), y = min(height - 1, max(0, Int(point.y)))
            let index = (y * width + x) * 4
            return Array(bytes[index..<(index + 3)])
        }
    }

    /// - Parameters: color: 纸面底色；text: 真实页面文字。返回布局好的非对称测试页面。
    private func page(_ color: UIColor, text: String) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.backgroundColor = color
        let label = UILabel(frame: CGRect(x: 20, y: 30, width: 270, height: 120))
        label.text = text + "\n纸角与纸背使用相同材质\nABCDEFGHIJKLMNOPQRSTUVWXYZ"
        label.numberOfLines = 3; label.font = .systemFont(ofSize: 17); label.textColor = .label
        view.addSubview(label)
        let block = UIView(frame: CGRect(x: 25, y: 260, width: 80, height: 100)); block.backgroundColor = .systemOrange
        view.addSubview(block); view.layoutIfNeeded(); return view
    }

    /// - Parameter image: 实际软件或 GPU 输出。返回正向 RGBA 字节，采样坐标与 UIKit 一致。
    private func pixels(_ image: UIImage) throws -> Pixels {
        let cg = try XCTUnwrap(image.cgImage)
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        // CGImage 读回行顺序已与 UIImage/UIView 的顶部坐标一致，不再做第二次上下翻转。
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let data = try XCTUnwrap(context.makeImage()?.dataProvider?.data)
        return Pixels(width: cg.width, height: cg.height, bytes: data as Data)
    }

    /// - Parameter view: 参考软件纸面。返回真实 CGContext 输出，不经过屏幕截图缩放。
    private func software(_ view: PaperTransitionView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in view.draw(view.bounds) }
    }

    /// 无参数；当前页抓取边的小标记经真实 GPU 绘制后，须落在手指坐标一像素邻域。无返回值。
    func testGPUContactMarkerStaysAtFingerPosition() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            let bounds = CGRect(origin: .zero, size: size)
            /// - Parameters: primary: 翻页轴坐标；cross: 横跨轴坐标。返回画布点。
            func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
            }
            for sign: CGFloat in [-1, 1] {
                let edge: CGFloat = sign < 0 ? 320 : 0
                for fraction: CGFloat in [0.1, 0.5, 0.9] {
                    let origin = point(176, 480 * fraction)
                    let source = point(edge, fraction == 0.5 ? 240 : (fraction < 0.5 ? 0 : 480))
                    /// - Parameter marked: 是否在材料抓取边放置黑色小标记。返回独立、同底色页面。
                    func page(marked: Bool) -> UIView {
                        let view = UIView(frame: bounds); view.backgroundColor = .white
                        if marked {
                            let mark = UIView(frame: CGRect(x: source.x - 8, y: source.y - 8, width: 16, height: 16))
                            mark.backgroundColor = .black; view.addSubview(mark)
                        }
                        view.layoutIfNeeded(); return view
                    }
                    let target = page(marked: false)
                    let written = try PaperTransitionView(currentView: page(marked: true), targetView: target,
                        effect: .curl, direction: .next, spine: sign < 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    let blank = try PaperTransitionView(currentView: page(marked: false), targetView: target,
                        effect: .curl, direction: .next, spine: sign < 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    defer { written.invalidateResources(); blank.invalidateResources() }
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: sign, origin: origin))
                    for pull: CGFloat in [0.2, 0.4, 0.65] {
                        let touch = point(edge + sign * 320 * pull, 480 * fraction + (pull - 0.4) * 8)
                        let live = try XCTUnwrap(seed.moved(to: touch))
                        written.update(progress: live.progress, cornerDrag: live)
                        blank.update(progress: live.progress, cornerDrag: live)
                        let image = try XCTUnwrap(written.cornerGPUImage())
                        let actual = try pixels(image), expected = try pixels(XCTUnwrap(blank.cornerGPUImage()))
                        var nearest = CGFloat.infinity
                        for y in (Int(touch.y) - 5)...(Int(touch.y) + 5) {
                            for x in (Int(touch.x) - 5)...(Int(touch.x) + 5) {
                                guard (0..<actual.width).contains(x), (0..<actual.height).contains(y) else { continue }
                                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                                if abs(Int(actual.rgb(p)[0]) - Int(expected.rgb(p)[0])) > 15 {
                                    nearest = min(nearest, hypot(p.x - touch.x, p.y - touch.y))
                                }
                            }
                        }
                        XCTAssertLessThanOrEqual(nearest, 1.1, "\(axis)/\(sign)/\(fraction)/\(pull)：标记不能停留在触点之外")
                        if pull == 0.4 {
                            let attachment = XCTAttachment(image: image)
                            attachment.name = "finger-contact-\(axis)-\(sign < 0 ? "maximum" : "minimum")-\(fraction)"
                            attachment.lifetime = .keepAlways; add(attachment)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；原生追随提交多个中间姿态，保留逻辑目标，收尾直接对齐，停止后不持续绘制。无返回值。
    func testGentleTouchFollowConvergesAndStopsIdleRendering() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let host = UIViewController(); host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let window = UIWindow(frame: host.view.frame); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let paper = try PaperTransitionView(currentView: page(.white, text: "当前"), targetView: page(.systemTeal, text: "目标"),
            effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
        host.view.addSubview(paper); defer { paper.invalidateResources() }
        let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: .horizontal, spread: false,
            inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        let start = try XCTUnwrap(seed.moved(to: CGPoint(x: 250, y: 70)))
        let target = try XCTUnwrap(seed.moved(to: CGPoint(x: 120, y: 130)))
        /// - Parameter count: 当前提交数；等待下一次原生 GPU 提交，最多一秒。无返回值。
        func waitForSubmission(after count: Int) async throws {
            for _ in 0..<100 {
                if paper.metalSubmittedFrameCount > count { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("等待轻缓跟随的真实 GPU 提交超时")
        }
        paper.update(progress: start.progress, cornerDrag: start, followsTouch: true)
        try await waitForSubmission(after: 0)
        let before = paper.metalSubmittedFrameCount
        let original = try XCTUnwrap(paper.submittedCornerDrag)
        paper.update(progress: target.progress, cornerDrag: target, followsTouch: true)
        XCTAssertEqual(paper.submittedCornerDrag, original, "更新触点不能同步跳动当前画面")
        try await waitForSubmission(after: before)
        let submitted = try XCTUnwrap(paper.submittedCornerDrag)
        if paper.metalSubmittedFrameCount == before + 1 {
            let full = hypot(target.gripPosition.x - original.gripPosition.x, target.gripPosition.y - original.gripPosition.y)
            let moved = hypot(submitted.gripPosition.x - original.gripPosition.x, submitted.gripPosition.y - original.gripPosition.y)
            XCTAssertLessThan(moved, full * 0.6, "首个可见帧应仍是翻卷过程，不能已强制追近目标")
        }
        XCTAssertEqual(paper.cornerDrag, target, "呈现动画不能改变原始逻辑触点")
        for _ in 0..<100 {
            if paper.submittedCornerDrag == target { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(paper.submittedCornerDrag, target, "停手后必须准确翻到目标")
        XCTAssertGreaterThan(paper.metalSubmittedFrameCount, before + 2, "必须真正提交多个中间姿态")
        let release = target.released(completed: true, fraction: 0.3)
        let previous = paper.metalSubmittedFrameCount
        paper.update(progress: release.progress, cornerDrag: release, followsTouch: false)
        try await waitForSubmission(after: previous)
        XCTAssertEqual(paper.submittedCornerDrag, release, "收尾不能再叠加拖尾")
        try await Task.sleep(nanoseconds: 200_000_000)
        let idle = paper.metalSubmittedFrameCount
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(paper.metalSubmittedFrameCount, idle, "姿态稳定后须停止绘制")
        XCTAssertEqual(paper.softwareCornerDrawCount, 0)
        paper.invalidateResources(); XCTAssertNil(paper.submittedCornerDrag)
    }

    /// 无参数；真实 GPU 在八种大幅斜折平折姿态下，未被纸背遮挡的正文仍有可见接触投影。无返回值。
    func testGPUContactShadowRemainsVisibleAtLargeDiagonalFlatLimit() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        func path(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            if let first = points.first {
                result.move(to: first)
                for point in points.dropFirst() { result.addLine(to: point) }
                result.closeSubpath()
            }
            return result
        }
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
            }
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let bounds = CGRect(origin: .zero, size: size)
                    let current = UIView(frame: bounds), target = UIView(frame: bounds)
                    current.backgroundColor = .white; target.backgroundColor = .white
                    let paper = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: .next, spine: sign < 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    defer { paper.invalidateResources() }
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false, inwardSign: sign, origin: point(195, 422)))
                    let edge: CGFloat = sign < 0 ? 390 : 0
                    var drag = try XCTUnwrap(seed.moved(to: point(edge + sign * 273, 422 + crossSign * 1_000_000)))
                    // 直接建立平折极限，继续覆盖曲面深度为零时的阴影回退。
                    let reach: CGFloat = 273 * (780 - 273)
                    let cross = crossSign * reach / (sqrt(422 * 422 + reach) + 422)
                    if axis == .horizontal { drag.translation.y = cross } else { drag.translation.x = cross }
                    let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
                    XCTAssertLessThan(try XCTUnwrap(patches.filter(\.back).map(\.depth).max()), 1e-5)
                    let flat = path(try XCTUnwrap(patches.first { !$0.back && $0.depth == 0 }).projected)
                    let occluders = patches.filter { $0.back || $0.depth > 0 }.map { path($0.projected) }
                    paper.update(progress: drag.progress, cornerDrag: drag)
                    let image = try XCTUnwrap(paper.cornerGPUImage()), raster = try pixels(image)
                    var visibleShadow = 0
                    for y in stride(from: 2, to: raster.height - 2, by: 3) {
                        for x in stride(from: 2, to: raster.width - 2, by: 3) {
                            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                            guard flat.contains(p), !occluders.contains(where: { $0.contains(p) }) else { continue }
                            if raster.rgb(p).allSatisfy({ $0 < 247 && $0 > 160 }) { visibleShadow += 1 }
                        }
                    }
                    XCTAssertGreaterThan(visibleShadow, 20, "\(axis)/\(sign)/\(crossSign)：大幅斜折时正文投影不可消失")
                    print("FLAT_FOLD_SHADOW_PIXELS \(axis)/\(sign)/\(crossSign)=\(visibleShadow)")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "flat-fold-contact-\(axis)-\(sign < 0 ? "maximum" : "minimum")-\(crossSign < 0 ? "near" : "far")"
                    attachment.lifetime = .keepAlways; add(attachment)
                    if axis == .horizontal, crossSign > 0 {
                        func readingPage(_ title: String) -> UIView {
                            let view = UIView(frame: bounds)
                            view.backgroundColor = UIColor(red: 0.70, green: 0.76, blue: 0.70, alpha: 1)
                            let body = UILabel(frame: bounds.insetBy(dx: 24, dy: 38))
                            body.numberOfLines = 0; body.font = .systemFont(ofSize: 21)
                            body.textColor = UIColor(red: 0.06, green: 0.12, blue: 0.08, alpha: 1)
                            body.text = title + "\n\n" + String(repeating: "风沿着河岸吹来，书页在灯光下缓缓翻起。\n折过来的纸背保留淡淡的文字，正文边缘留下柔和的投影。\n\n", count: 8)
                            view.addSubview(body); view.layoutIfNeeded(); return view
                        }
                        let colored = try PaperTransitionView(currentView: readingPage("当前页 · 斜折投影"), targetView: readingPage("下一页 · 正文"),
                            effect: .curl, direction: .next, spine: sign < 0 ? .minimum : .maximum,
                            options: .standard, axis: axis, cornerDriven: true)
                        defer { colored.invalidateResources() }
                        colored.update(progress: drag.progress, cornerDrag: drag)
                        let sample = XCTAttachment(image: try XCTUnwrap(colored.cornerGPUImage()))
                        sample.name = "reference-shadow-style-\(sign < 0 ? "maximum" : "minimum")"
                        sample.lifetime = .keepAlways; add(sample)
                    }
                }
            }
        }
    }

    /// 无参数；真实交互可达边界保留卷边，实际 GPU 须画出弧面明暗，并保存参考姿势及局部图。无返回值。
    func testGPULargeDiagonalReachKeepsRolledOuterEdge() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
            }
            for sign: CGFloat in [-1, 1] {
                for crossSign: CGFloat in [-1, 1] {
                    let bounds = CGRect(origin: .zero, size: size)
                    let current = UIView(frame: bounds), target = UIView(frame: bounds)
                    current.backgroundColor = .white; target.backgroundColor = .white
                    let paper = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: .next, spine: sign < 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    defer { paper.invalidateResources() }
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: sign, origin: point(195, 422)))
                    let edge: CGFloat = sign < 0 ? 390 : 0
                    let drag = try XCTUnwrap(seed.moved(to: point(edge + sign * 273, 422 + crossSign * 1_000_000)))
                    let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
                    XCTAssertGreaterThan(try XCTUnwrap(patches.map(\.depth).max()), 10)
                    paper.update(progress: drag.progress, cornerDrag: drag)
                    let image = try XCTUnwrap(paper.cornerGPUImage()), raster = try pixels(image)
                    var shadedArcSamples = 0
                    for patch in patches where !patch.back && patch.depth > 0 && patch.shade > 0.08 {
                        let vertices = patch.projected
                        let center = vertices.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                        let p = CGPoint(x: center.x / CGFloat(vertices.count), y: center.y / CGFloat(vertices.count))
                        guard bounds.insetBy(dx: 2, dy: 2).contains(p) else { continue }
                        if raster.rgb(p).allSatisfy({ $0 > 160 && $0 < 247 }) { shadedArcSamples += 1 }
                    }
                    XCTAssertGreaterThan(shadedArcSamples, 8, "真实 GPU 必须画出带明暗的卷曲段")
                    let name = "\(axis)-\(sign < 0 ? "maximum" : "minimum")-\(crossSign < 0 ? "near" : "far")"
                    print("ROLLED_EDGE_ARC_SAMPLES \(name)=\(shadedArcSamples)")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "rolled-edge-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                    if axis == .horizontal, crossSign > 0 {
                        func readingPage(_ title: String) -> UIView {
                            let view = UIView(frame: bounds)
                            view.backgroundColor = UIColor(red: 0.70, green: 0.76, blue: 0.70, alpha: 1)
                            let body = UILabel(frame: bounds.insetBy(dx: 24, dy: 38))
                            body.numberOfLines = 0; body.font = .systemFont(ofSize: 21)
                            body.textColor = UIColor(red: 0.06, green: 0.12, blue: 0.08, alpha: 1)
                            body.text = title + "\n\n" + String(repeating: "风沿着河岸吹来，书页在灯光下缓缓翻起。\n折过来的纸背保留淡淡的文字，正文边缘留下柔和的投影。\n\n", count: 8)
                            view.addSubview(body); view.layoutIfNeeded(); return view
                        }
                        let colored = try PaperTransitionView(currentView: readingPage("当前页 · 斜折投影"),
                            targetView: readingPage("下一页 · 正文"), effect: .curl,
                            direction: .next, spine: sign < 0 ? .minimum : .maximum,
                            options: .standard, axis: axis, cornerDriven: true)
                        defer { colored.invalidateResources() }
                        colored.update(progress: drag.progress, cornerDrag: drag)
                        let reading = try XCTUnwrap(colored.cornerGPUImage())
                        let sample = XCTAttachment(image: reading)
                        sample.name = "rolled-edge-reading-\(sign < 0 ? "maximum" : "minimum")"
                        sample.lifetime = .keepAlways; add(sample)
                        let crop = CGRect(x: sign < 0 ? 235 : 0, y: 590, width: 155, height: 254)
                        let detail = try XCTUnwrap(reading.cgImage?.cropping(to: crop))
                        let closeup = XCTAttachment(image: UIImage(cgImage: detail))
                        closeup.name = "rolled-edge-detail-\(sign < 0 ? "maximum" : "minimum")"
                        closeup.lifetime = .keepAlways; add(closeup)
                    }
                }
            }
        }
    }

    /// GPU 必须实际参与；四角与双色主题的静止区域、曲面和背材应与几何参考一致。
    func testGPUFourCornersMatchReferenceAndHaveUniformBackMaterial() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for dark in [false, true] {
            let color = dark ? UIColor(red: 0.105, green: 0.125, blue: 0.12, alpha: 1) : UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
            for right in [false, true] {
                for bottom in [false, true] {
                    let current = page(color, text: "当前页"), target = page(.systemTeal, text: "下一页")
                    current.overrideUserInterfaceStyle = dark ? .dark : .light
                    target.overrideUserInterfaceStyle = current.overrideUserInterfaceStyle
                    let reference = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: .next, spine: .minimum, options: .standard)
                    let gpu = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
                    defer { reference.invalidateResources(); gpu.invalidateResources() }
                    let origin = CGPoint(x: right ? 300 : 20, y: bottom ? 460 : 20)
                    let start = try XCTUnwrap(PaperCornerDrag(size: current.bounds.size, axis: .horizontal,
                        spread: false, inwardSign: right ? -1 : 1, origin: origin))
                    let live = try XCTUnwrap(start.moved(to: CGPoint(x: origin.x + (right ? -150 : 150), y: origin.y + (bottom ? -110 : 110))))
                    reference.update(progress: live.progress, cornerDrag: live)
                    gpu.update(progress: live.progress, cornerDrag: live)
                    XCTAssertTrue(gpu.usesMetalCornerRendering)
                    let image = try XCTUnwrap(gpu.cornerGPUImage())
                    let actual = try pixels(image), expected = try pixels(software(reference))
                    XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
                    var equal = 0
                    for y in stride(from: 0, to: actual.height, by: 2) {
                        for x in stride(from: 0, to: actual.width, by: 2) {
                            let a = actual.rgb(CGPoint(x: x, y: y)), b = expected.rgb(CGPoint(x: x, y: y))
                            if zip(a, b).allSatisfy({ abs(Int($0) - Int($1)) <= 8 }) { equal += 1 }
                        }
                    }
                    let total = (actual.width / 2) * (actual.height / 2)
                    XCTAssertGreaterThan(Double(equal) / Double(total), 0.91, "纹理方向、颜色及大部分几何必须一致；仅轮廓阴影允许算法差异")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "metal-corner-\(dark ? "dark" : "light")-\(right ? "right" : "left")-\(bottom ? "bottom" : "top")"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
    }

    /// 投影必须留在未翻动的正文表面，不能被正面覆盖或通过改变纸背底色伪造。
    func testContactShadowFallsOnStationaryPaperForEveryCornerAndAxis() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        func path(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            if let first = points.first {
                result.move(to: first)
                for point in points.dropFirst() { result.addLine(to: point) }
                result.closeSubpath()
            }
            return result
        }
        func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
            axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
        }
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for fromMaximum in [false, true] {
                for farCross in [false, true] {
                    let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                    let bounds = CGRect(origin: .zero, size: size)
                    let current = UIView(frame: bounds), target = UIView(frame: bounds)
                    current.backgroundColor = .white; target.backgroundColor = .white
                    let paper = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: .next, spine: fromMaximum ? .minimum : .maximum,
                        options: .init(maximumSnapshotPixels: 262_144, stripCount: 64), axis: axis, cornerDriven: true)
                    defer { paper.invalidateResources() }
                    let origin = point(fromMaximum ? 300 : 20, farCross ? 460 : 20, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: fromMaximum ? -1 : 1, origin: origin))
                    let live = try XCTUnwrap(seed.moved(to: point((fromMaximum ? 300 : 20) + (fromMaximum ? -140 : 140),
                        (farCross ? 460 : 20) + (farCross ? -120 : 120), axis: axis)))
                    let patches = PaperCornerCurlGeometry.patches(for: live, stripCount: 64)
                    let flat = try XCTUnwrap(patches.first { !$0.back && $0.depth == 0 })
                    let flatPath = path(flat.projected)
                    let raisedPaths = patches.filter { $0.depth > 0 || $0.back }.map { path($0.projected) }
                    paper.update(progress: live.progress, cornerDrag: live)
                    let image = try XCTUnwrap(paper.cornerGPUImage()), raster = try pixels(image)
                    var stationaryShadowPixels = 0
                    for y in stride(from: 2, to: raster.height - 2, by: 2) {
                        for x in stride(from: 2, to: raster.width - 2, by: 2) {
                            let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                            guard flatPath.contains(center), !raisedPaths.contains(where: { $0.contains(center) }) else { continue }
                            let rgb = raster.rgb(CGPoint(x: x, y: y))
                            if rgb.allSatisfy({ $0 < 248 && $0 > 160 }) { stationaryShadowPixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(stationaryShadowPixels, 20,
                        "\(axis)/\(fromMaximum)/\(farCross)：纸背之外的平铺正文必须有可见柔和投影")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "contact-shadow-\(axis)-\(fromMaximum ? "maximum" : "minimum")-\(farCross ? "far" : "near")"
                    attachment.lifetime = .keepAlways; add(attachment)
                    for completed in [false, true] {
                        let end = live.released(completed: completed, fraction: 1)
                        paper.update(progress: end.progress, cornerDrag: end)
                        let flatRaster = try pixels(XCTUnwrap(paper.cornerGPUImage()))
                        for y in stride(from: 2, to: flatRaster.height - 2, by: 8) {
                            for x in stride(from: 2, to: flatRaster.width - 2, by: 8) {
                                XCTAssertTrue(flatRaster.rgb(CGPoint(x: x, y: y)).allSatisfy { $0 >= 254 }, "落定后不得残留阴影")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 重现左下折角：在实际 GPU 图像上，折痕附近投影更浅更窄，靠近自由纸角更深更宽。
    func testGPUShadowWidensAndDarkensTowardFreeCorner() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let current = UIView(frame: bounds), target = UIView(frame: bounds)
        current.backgroundColor = .white; target.backgroundColor = .white
        let paper = try PaperTransitionView(currentView: current, targetView: target,
            effect: .curl, direction: .next, spine: .maximum, options: .standard, cornerDriven: true)
        defer { paper.invalidateResources() }
        let seed = try XCTUnwrap(PaperCornerDrag(size: bounds.size, axis: .horizontal,
            spread: false, inwardSign: 1, origin: CGPoint(x: 20, y: 460)))
        // 固定同一实际纸角落点；绝对触点接口不再额外加上原按下点到纸角的偏移。
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 150, y: 370)))
        XCTAssertEqual(drag.gripPosition, CGPoint(x: 150, y: 370))
        let patches = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128)
        let plane = try XCTUnwrap(patches.last { $0.back })
        let polygon = plane.projected
        let index = try XCTUnwrap(polygon.firstIndex { hypot($0.x - drag.tip.x, $0.y - drag.tip.y) < 1e-5 })
        func path(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            if let first = points.first {
                result.move(to: first)
                for p in points.dropFirst() { result.addLine(to: p) }
                result.closeSubpath()
            }
            return result
        }
        let flat = path(try XCTUnwrap(patches.first { !$0.back && $0.depth == 0 }).projected)
        let occluders = patches.filter { $0.depth > 0 || $0.back }.map { path($0.projected) }
        paper.update(progress: drag.progress, cornerDrag: drag)
        let image = try XCTUnwrap(paper.cornerGPUImage()), raster = try pixels(image)
        let centroid = CGPoint(x: polygon.map(\.x).reduce(0, +) / CGFloat(polygon.count),
                               y: polygon.map(\.y).reduce(0, +) / CGFloat(polygon.count))
        var checked = false
        for root in [polygon[(index + 1) % polygon.count], polygon[(index + polygon.count - 1) % polygon.count]] {
            let dx = drag.tip.x - root.x, dy = drag.tip.y - root.y, length = hypot(drag.tip.x - root.x, drag.tip.y - root.y)
            guard length > 20 else { continue }
            var out = CGPoint(x: dy / length, y: -dx / length)
            let middle = CGPoint(x: (root.x + drag.tip.x) / 2, y: (root.y + drag.tip.y) / 2)
            if out.x * (centroid.x - middle.x) + out.y * (centroid.y - middle.y) > 0 { out = CGPoint(x: -out.x, y: -out.y) }
            func shadowSamples(at fraction: CGFloat) -> [(Int, Int)] {
                let edge = CGPoint(x: root.x + dx * fraction, y: root.y + dy * fraction)
                return (1...26).compactMap { distance in
                    let point = CGPoint(x: edge.x + out.x * CGFloat(distance), y: edge.y + out.y * CGFloat(distance))
                    guard bounds.contains(point), flat.contains(point), !occluders.contains(where: { $0.contains(point) }) else { return nil }
                    return (distance, 255 - Int(raster.rgb(point)[0]))
                }
            }
            let near = shadowSamples(at: 0.2), far = shadowSamples(at: 0.8)
            let nearClose = near.filter { $0.0 <= 3 }, farClose = far.filter { $0.0 <= 3 }
            guard nearClose.count >= 2, farClose.count >= 2 else { continue }
            let nearDarkness = Double(nearClose.map { $0.1 }.reduce(0, +)) / Double(nearClose.count)
            let farDarkness = Double(farClose.map { $0.1 }.reduce(0, +)) / Double(farClose.count)
            let nearReach = near.filter { $0.1 > 6 }.map { $0.0 }.max() ?? 0
            let farReach = far.filter { $0.1 > 6 }.map { $0.0 }.max() ?? 0
            XCTAssertGreaterThan(farDarkness, nearDarkness + 8, "纸角外侧应比折痕附近更深")
            XCTAssertGreaterThan(farReach, nearReach + 2, "纸角外侧投影应更宽")
            print("SHADOW_TAPER_PIXELS nearDark=\(nearDarkness) farDark=\(farDarkness) nearWidth=\(nearReach) farWidth=\(farReach)")
            checked = true; break
        }
        XCTAssertTrue(checked, "需要在未被纸背遮挡的正文中取得有效取样")
        let attachment = XCTAttachment(image: image); attachment.name = "shadow-taper-bottom-left-pixel-check"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    /// 无参数；实际 GPU 与软件纸背都须保留移动纸面反折透字，覆盖明暗主题、四角和两轴；逻辑回翻另作逆向整帧对照。返回测试断言。
    func testMovingPageBackRetainsMirroredContentForBothEdgesAndAxes() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for dark in [false, true] {
            let color = dark ? UIColor(red: 0.105, green: 0.125, blue: 0.12, alpha: 1)
                : UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
            for axis in [PageTurnAxis.horizontal, .vertical] {
                let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
                let bounds = CGRect(origin: .zero, size: size)
                /// - Parameter written: 是否铺满位置各异的真实文字。返回独立页面，底色完全相同。
                func fixture(written: Bool) -> UIView {
                    let view = UIView(frame: bounds); view.backgroundColor = color
                    if written {
                        for (row, y) in stride(from: 8, to: Int(size.height) - 28, by: 36).enumerated() {
                            for (column, x) in stride(from: 8, to: Int(size.width) - 40, by: 104).enumerated() {
                                let label = UILabel(frame: CGRect(x: x, y: y, width: 100, height: 30))
                                label.font = .systemFont(ofSize: 22, weight: .heavy)
                                label.textColor = dark ? .white : .black
                                label.text = "\(row)R\(column)F字"
                                view.addSubview(label)
                            }
                        }
                    }
                    view.layoutIfNeeded(); return view
                }
                let written = fixture(written: true), blank = fixture(written: false)
                let target = UIView(frame: bounds); target.backgroundColor = .systemTeal
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
                let source = try pixels(UIGraphicsImageRenderer(size: size, format: format).image { written.layer.render(in: $0.cgContext) })
                let sourceBlank = try pixels(UIGraphicsImageRenderer(size: size, format: format).image { blank.layer.render(in: $0.cgContext) })
                for fromMaximum in [false, true] {
                    for farCross in [false, true] {
                        let direction = PageTurnDirection.next
                        let physicalSpine: PageSpinePlacement = fromMaximum ? .minimum : .maximum
                        let gpu = try PaperTransitionView(currentView: written, targetView: target,
                            effect: .curl, direction: direction, spine: physicalSpine, options: .standard, axis: axis, cornerDriven: true)
                        let empty = try PaperTransitionView(currentView: blank, targetView: target,
                            effect: .curl, direction: direction, spine: physicalSpine, options: .standard, axis: axis, cornerDriven: true)
                        let reference = try PaperTransitionView(currentView: written, targetView: target,
                            effect: .curl, direction: direction, spine: physicalSpine, options: .standard, axis: axis)
                        defer { gpu.invalidateResources(); empty.invalidateResources(); reference.invalidateResources() }
                        /// - Parameters: primary: 翻页轴坐标；cross: 横轴坐标。返回当前方向的画布点。
                        func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                            axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
                        }
                        let origin = point(fromMaximum ? 300 : 20, farCross ? 460 : 20)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                            inwardSign: fromMaximum ? -1 : 1, origin: origin))
                        let drag = try XCTUnwrap(seed.moved(to: point((fromMaximum ? 300 : 20) + (fromMaximum ? -140 : 140),
                            (farCross ? 460 : 20) + (farCross ? -120 : 120))))
                        let plane = try XCTUnwrap(PaperCornerCurlGeometry.patches(for: drag, stripCount: 128).last { $0.back })
                        let path = CGMutablePath()
                        for (index, p) in plane.projected.enumerated() {
                            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        path.closeSubpath()
                        let inverse = plane.transform.inverted()
                        let sampleBounds = path.boundingBoxOfPath.intersection(bounds.insetBy(dx: 2, dy: 2)).integral
                        for paper in [gpu, empty, reference] { paper.update(progress: drag.progress, cornerDrag: drag) }
                        let gpuImage = try XCTUnwrap(gpu.cornerGPUImage())
                        let base = try pixels(XCTUnwrap(empty.cornerGPUImage()))
                        let results = [("GPU", try pixels(gpuImage)), ("software", try pixels(software(reference)))]
                        for (renderer, raster) in results {
                            var inkCount = 0, inkHits = 0, inkStrength = 0, paperCount = 0, paperStrength = 0
                            for y in Int(sampleBounds.minY)..<Int(sampleBounds.maxY) {
                                for x in Int(sampleBounds.minX)..<Int(sampleBounds.maxX) {
                                    let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                                    guard path.contains(p) else { continue }
                                    let uv = p.applying(inverse)
                                    guard bounds.insetBy(dx: 2, dy: 2).contains(uv) else { continue }
                                    let neighbors = [uv, CGPoint(x: uv.x - 1, y: uv.y), CGPoint(x: uv.x + 1, y: uv.y),
                                        CGPoint(x: uv.x, y: uv.y - 1), CGPoint(x: uv.x, y: uv.y + 1)]
                                    let sample = abs(Int(raster.rgb(p)[0]) - Int(base.rgb(p)[0]))
                                    if neighbors.allSatisfy({ dark ? source.rgb($0)[0] > 220 : source.rgb($0)[0] < 45 }) {
                                        inkCount += 1; inkStrength += sample
                                        if sample > 12 { inkHits += 1 }
                                    } else if neighbors.allSatisfy({ abs(Int(source.rgb($0)[0]) - Int(sourceBlank.rgb($0)[0])) <= 2 }) {
                                        paperCount += 1; paperStrength += sample
                                    }
                                }
                            }
                            let context = "\(renderer)/\(dark)/\(axis)/\(direction)/\(farCross)"
                            XCTAssertGreaterThan(inkCount, 12, context); XCTAssertGreaterThan(paperCount, 40, context)
                            XCTAssertGreaterThan(Double(inkStrength) / Double(max(1, inkCount)), 18, "\(context)：当前页文字须在纸背可见")
                            XCTAssertGreaterThan(Double(inkHits) / Double(max(1, inkCount)), 0.75, "\(context)：纹理须随纸面反折，不能多翻一次 UV 或采错页")
                            XCTAssertLessThan(Double(paperStrength) / Double(max(1, paperCount)), 3, "\(context)：空白纸背底色须统一")
                        }
                        let attachment = XCTAttachment(image: gpuImage)
                        attachment.name = "back-content-\(dark ? "dark" : "light")-\(axis)-\(fromMaximum ? "maximum" : "minimum")-\(farCross ? "far" : "near")"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
    }

    /// 纸背平面与相邻弧面明暗连续；不允许出现单独的三角形颜色台阶。
    func testBackShadingIsContinuousAtCurvedToFlatBoundary() throws {
        let seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        for progress: CGFloat in [0.15, 0.3, 0.5, 0.8] {
            let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 300 - 640 * progress, y: 110)))
            let back = PaperCornerCurlGeometry.patches(for: drag, stripCount: 128).filter(\.back)
            guard back.count > 2 else { continue }
            let flat = try XCTUnwrap(back.last), arc = back[back.count - 2]
            XCTAssertLessThan(abs(flat.shade - arc.shade), 0.001, "纸背交界处不能跳变几档灰度")
        }
    }

    /// 显示端耗尽 drawable 时主线程仍可响应并取消，不等待 nextDrawable 返回。
    func testDrawableStarvationKeepsMainThreadResponsive() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let controller = UIViewController(); controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let window = UIWindow(frame: controller.view.frame); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let paper = try PaperTransitionView(currentView: page(.white, text: "当前"), targetView: page(.cyan, text: "目标"),
            effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
        controller.view.addSubview(paper)
        let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: .horizontal, spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 170, y: 110)))
        paper.update(progress: drag.progress, cornerDrag: drag); controller.view.layoutIfNeeded()
        let layer = try XCTUnwrap(paper.subviews.first?.layer as? CAMetalLayer)
        var held: [CAMetalDrawable] = []
        for _ in 0..<3 { held.append(try XCTUnwrap(layer.nextDrawable())) }
        let responsive = expectation(description: "显示端占用时主线程 50ms 回调仍可达")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 0.3)
        paper.invalidateResources(); held.removeAll()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(paper.hasResources); XCTAssertTrue(paper.subviews.isEmpty)
        XCTAssertEqual(paper.metalSubmittedFrameCount, 0)
    }

    /// 等待屏幕刷新前的多次触点更新只保留一帧；取消后释放纹理，不再接收旧状态。
    func testMetalFrameCoalescingAndCleanup() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let host = UIViewController(); host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let window = UIWindow(frame: host.view.frame); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let paper = try PaperTransitionView(currentView: page(.white, text: "当前"), targetView: page(.cyan, text: "目标"),
            effect: .curl, direction: .next, spine: .minimum, options: .standard, cornerDriven: true)
        host.view.addSubview(paper); host.view.layoutIfNeeded()
        let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: .horizontal, spread: false, inwardSign: -1, origin: CGPoint(x: 300, y: 20)))
        for i in 0..<60 {
            let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: 280 - i, y: 100)))
            paper.update(progress: drag.progress, cornerDrag: drag)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(paper.usesMetalCornerRendering)
        XCTAssertEqual(paper.metalSubmittedFrameCount, 1)
        XCTAssertEqual(paper.softwareCornerDrawCount, 0)
        paper.invalidateResources()
        XCTAssertFalse(paper.usesMetalCornerRendering)
        XCTAssertFalse(paper.hasResources)
        XCTAssertTrue(paper.subviews.isEmpty)
    }
}
#endif
