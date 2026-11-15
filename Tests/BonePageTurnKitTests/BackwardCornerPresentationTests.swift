#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 回翻应为上一张纸翻出的逆过程；GPU 与软件参考分别对照，不只检查页码。
@MainActor
final class BackwardCornerPresentationTests: XCTestCase {
    /// - Parameters: name: 页面文字标记；size: 画布；axis: 分页轴；spread: 是否给两个半页不同颜色。
    /// - Returns: 有真实字形和非对称标记的独立页面。
    private func page(_ name: String, size: CGSize, axis: PageTurnAxis, spread: Bool) -> UIView {
        let bounds = CGRect(origin: .zero, size: size)
        let view = UIView(frame: bounds); view.overrideUserInterfaceStyle = .light
        view.backgroundColor = name == "上一页 A" ? UIColor(red: 0.65, green: 0.74, blue: 0.84, alpha: 1)
            : UIColor(red: 0.20, green: 0.30, blue: 0.22, alpha: 1)
        if spread {
            let half = axis == .horizontal ? CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
                : CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
            let block = UIView(frame: half)
            block.backgroundColor = name == "上一页 A" ? .systemOrange : .systemPurple
            view.addSubview(block)
        }
        let text = UILabel(frame: bounds.insetBy(dx: 18, dy: 25)); text.numberOfLines = 0
        text.font = .systemFont(ofSize: 18); text.textColor = .black
        text.text = String(repeating: name + " · ABC 012\n回翻展开上一张纸，当前正文留在下面。\n\n", count: 6)
        view.addSubview(text); view.layoutIfNeeded(); return view
    }

    /// - Parameters: primary: 轴向坐标；cross: 横向坐标；axis: 分页轴。
    /// - Returns: UIKit 画布点。
    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    /// - Parameter image: 实际渲染结果。
    /// - Returns: 固定 RGBA 字节，用于两个相同物理姿态的逐像素比较。
    private func pixels(_ image: UIImage) throws -> Data {
        let source = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
    }

    /// - Parameter paper: 不创建 Metal 子层的软件参考。
    /// - Returns: 同尺寸软件绘图，保留真实字形和阴影。
    private func software(_ paper: PaperTransitionView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: paper.bounds.size, format: format).image { _ in paper.draw(paper.bounds) }
    }

    /// 保留原来上一页展开过程的整帧与端点；起折角另由独立触点／区域检查验证。
    func testPreviousRetainsOriginalUnfoldingAndEndpoints() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            for spread in [false, true] {
                for sign: CGFloat in [-1, 1] {
                    for far in [false, true] {
                        let order: ReaderReadingOrder = sign > 0 ? .leftToRight : .rightToLeft
                        let spine: PageSpinePlacement = spread ? .center : (sign > 0 ? .minimum : .maximum)
                        let origin = point(sign > 0 ? 20 : 300, far ? 460 : 20, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis,
                            spread: spread, inwardSign: sign, origin: origin))
                        let material = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis,
                            spread: spread, inwardSign: -sign,
                            origin: point(sign > 0 ? 300 : 20, far ? 460 : 20, axis: axis)))
                        let a = page("上一页 A", size: size, axis: axis, spread: spread)
                        let b = page("当前页 B", size: size, axis: axis, spread: spread)
                        let options = PaperRenderingOptions(maximumSnapshotPixels: 262_144, stripCount: 64)
                        let reference = try PaperTransitionView(currentView: a, targetView: b, effect: .curl,
                            direction: .next, spine: spine, options: options, axis: axis, cornerDriven: true)
                        let previous = try PaperTransitionView(currentView: b, targetView: a, effect: .curl,
                            direction: .previous, spine: spine, options: options, axis: axis, readingOrder: order, cornerDriven: true)
                        let referenceCPU = try PaperTransitionView(currentView: a, targetView: b, effect: .curl,
                            direction: .next, spine: spine, options: options, axis: axis)
                        let previousCPU = try PaperTransitionView(currentView: b, targetView: a, effect: .curl,
                            direction: .previous, spine: spine, options: options, axis: axis, readingOrder: order)
                        defer { [reference, previous, referenceCPU, previousCPU].forEach { $0.invalidateResources() } }
                        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                            let touch = point((sign > 0 ? 0 : 320) + sign * 320 * progress,
                                (far ? 480 : 0) + (progress == 0 || progress == 1 ? 0 : (far ? -12 : 12)), axis: axis)
                            let input = progress == 0 ? seed : try XCTUnwrap(seed.moved(to: touch, direction: .previous))
                            let probe = progress == 0 ? material.released(completed: true, fraction: 1)
                                : try XCTUnwrap(material.moved(to: touch))
                            previous.update(progress: progress, cornerDrag: input)
                            previousCPU.update(progress: progress, cornerDrag: input)
                            reference.update(progress: 1 - progress, cornerDrag: probe)
                            referenceCPU.update(progress: 1 - progress, cornerDrag: probe)
                            XCTAssertEqual(try pixels(XCTUnwrap(previous.cornerGPUImage())),
                                try pixels(XCTUnwrap(reference.cornerGPUImage())))
                            XCTAssertEqual(try pixels(software(previousCPU)), try pixels(software(referenceCPU)))
                        }
                    }
                }
            }
        }
    }
    /// 无参数；保存与用户参考图同类的深色左向右回翻姿态，确认纸背属于上一页、正文仍在底部。无返回值。
    func testDarkLeftToRightReferenceFrames() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let size = CGSize(width: 390, height: 844)
        /// - Parameter title: 真实页标题。返回同色深色页面，正文与纸背使用独立内容。
        func darkPage(_ title: String) -> UIView {
            let view = UIView(frame: CGRect(origin: .zero, size: size)); view.overrideUserInterfaceStyle = .dark
            view.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.115, alpha: 1)
            let label = UILabel(frame: view.bounds.insetBy(dx: 24, dy: 45)); label.numberOfLines = 0
            label.font = .systemFont(ofSize: 21); label.textColor = UIColor(red: 0.78, green: 0.81, blue: 0.74, alpha: 1)
            label.text = title + "\n\n" + String(repeating: "林澈沿着石阶走来，将旧信放在桌边。\n翻回来的书页仍保留淡淡的文字。\n\n", count: 8)
            view.addSubview(label); view.layoutIfNeeded(); return view
        }
        let paper = try PaperTransitionView(currentView: darkPage("第七页 · 陌生人的空椅子"),
            targetView: darkPage("第六页 · 回来的人"), effect: .curl, direction: .previous, spine: .minimum,
            options: .standard, cornerDriven: true)
        defer { paper.invalidateResources() }
        let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: false,
            inwardSign: 1, origin: CGPoint(x: 25, y: 422)))
        for (index, point) in [CGPoint(x: 170, y: 300), CGPoint(x: 290, y: 500), CGPoint(x: 375, y: 610)].enumerated() {
            let drag = try XCTUnwrap(seed.moved(to: point, direction: .previous)); paper.update(progress: drag.gestureProgress, cornerDrag: drag)
            let attachment = XCTAttachment(image: try XCTUnwrap(paper.cornerGPUImage()))
            attachment.name = "backward-dark-reference-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    /// 无参数；上一页抓取边的黑色标记必须出现在绝对触点一像素邻域内，覆盖两轴、两物理方向和三种抓取高度。无返回值。
    func testGPUPreviousMaterialMarkerMatchesFinger() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
            let bounds = CGRect(origin: .zero, size: size)
            for sign: CGFloat in [-1, 1] {
                for fraction: CGFloat in [0.1, 0.5, 0.9] {
                    let origin = point(sign > 0 ? 20 : 300, 480 * fraction, axis: axis)
                    let inputSeed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: sign, origin: origin))
                    let materialSeed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: -sign, origin: point(sign > 0 ? 300 : 20, 480 * fraction, axis: axis)))
                    let source = materialSeed.gripOrigin
                    /// - Parameter marked: 上一页材料边是否有标记。返回独立白纸。
                    func whitePage(marked: Bool) -> UIView {
                        let view = UIView(frame: bounds); view.backgroundColor = .white
                        if marked {
                            let marker = UIView(frame: CGRect(x: source.x - 8, y: source.y - 8, width: 16, height: 16))
                            marker.backgroundColor = .black; view.addSubview(marker)
                        }
                        return view
                    }
                    let written = try PaperTransitionView(currentView: whitePage(marked: false), targetView: whitePage(marked: true),
                        effect: .curl, direction: .previous, spine: sign > 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    let empty = try PaperTransitionView(currentView: whitePage(marked: false), targetView: whitePage(marked: false),
                        effect: .curl, direction: .previous, spine: sign > 0 ? .minimum : .maximum,
                        options: .standard, axis: axis, cornerDriven: true)
                    defer { written.invalidateResources(); empty.invalidateResources() }
                    let edge = axis == .horizontal ? inputSeed.gripOrigin.x : inputSeed.gripOrigin.y
                    let samples: [(CGFloat, CGFloat)] = fraction == 0.5
                        ? [(0.125, 64), (0.2, 0), (0.5, 0), (0.8, 0)] : [(0.2, 0), (0.5, 0), (0.8, 0)]
                    for (pull, crossOffset) in samples {
                        let touch = point(edge + sign * 320 * pull, 480 * fraction + crossOffset, axis: axis)
                        let input = try XCTUnwrap(inputSeed.moved(to: touch, direction: .previous))
                        written.update(progress: input.gestureProgress, cornerDrag: input)
                        empty.update(progress: input.gestureProgress, cornerDrag: input)
                        let image = try XCTUnwrap(written.cornerGPUImage())
                        let actual = try pixels(image), blank = try pixels(XCTUnwrap(empty.cornerGPUImage()))
                        let cg = try XCTUnwrap(image.cgImage)
                        var nearest = CGFloat.infinity
                        for y in (Int(touch.y) - 5)...(Int(touch.y) + 5) {
                            for x in (Int(touch.x) - 5)...(Int(touch.x) + 5) {
                                guard (0..<cg.width).contains(x), (0..<cg.height).contains(y) else { continue }
                                let index = (y * cg.width + x) * 4
                                if abs(Int(actual[index]) - Int(blank[index])) > 15 {
                                    nearest = min(nearest, hypot(CGFloat(x) + 0.5 - touch.x, CGFloat(y) + 0.5 - touch.y))
                                }
                            }
                        }
                        XCTAssertLessThanOrEqual(nearest, 1.1, "实际 GPU 纸面必须贴住手指：\(axis)/\(sign)/\(fraction)/\(pull)")
                        if pull == 0.5 {
                            let attachment = XCTAttachment(image: image)
                            attachment.name = "previous-finger-marker-\(axis)-\(sign)-\(fraction)"
                            attachment.lifetime = .keepAlways; add(attachment)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；真实窗口中的回翻追随必须提交到手指位置，重定向不瞬移，完成／取消从已显示姿态开始。无返回值。
    func testLivePreviousFollowerAndReleaseUseShownContact() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        for completed in [false, true] {
            let current = UIViewController(); current.view.backgroundColor = .white
            let target = UIViewController(); target.view.backgroundColor = .systemTeal
            let currentPage = PageContent(identity: .init(sourceID: "live-return", unitID: "current"), controller: current)
            let targetPage = PageContent(identity: .init(sourceID: "live-return", unitID: "previous"), controller: target)
            let reader = try PagedReaderViewController(page: currentPage,
                configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal)))
            reader.usesDisplayLinkForPaperAnimation = false; reader.usesDisplayLinkForAutomaticReading = false
            reader.pageProvider = { _, _ in .page(targetPage) }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.rootViewController = reader; window.makeKeyAndVisible()
            defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
            reader.view.frame = window.bounds; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: CGPoint(x: 20, y: 240)))
            let paper = try XCTUnwrap(reader.activePaperView)
            let firstTarget = CGPoint(x: 160, y: 240)
            reader.updateInteractiveTurn(to: firstTarget)
            for _ in 0..<150 {
                if let shown = paper.submittedCornerDrag,
                   hypot(shown.gripPosition.x - firstTarget.x, shown.gripPosition.y - firstTarget.y) < 0.1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let first = try XCTUnwrap(paper.submittedCornerDrag)
            XCTAssertEqual(first.gripPosition.x, firstTarget.x, accuracy: 0.1)
            XCTAssertEqual(first.gripPosition.y, firstTarget.y, accuracy: 0.1)
            let nextTarget = CGPoint(x: 230, y: 240)
            reader.updateInteractiveTurn(to: nextTarget)
            XCTAssertEqual(paper.submittedCornerDrag, first, "目标更新不能立即改写已显示姿态")
            for _ in 0..<150 {
                if let shown = paper.submittedCornerDrag,
                   hypot(shown.gripPosition.x - nextTarget.x, shown.gripPosition.y - nextTarget.y) < 0.1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let displayed = try XCTUnwrap(paper.submittedCornerDrag)
            XCTAssertEqual(displayed.gripPosition.x, nextTarget.x, accuracy: 0.1)
            XCTAssertEqual(displayed.gripPosition.y, nextTarget.y, accuracy: 0.1)
            reader.endInteractiveTurn(velocity: completed ? 900 : -900)
            XCTAssertEqual(paper.cornerDrag, displayed, "收尾不能回到逻辑目标或旧的逆向偏移")
            reader.advancePaperAnimation(elapsed: 0.0001)
            let early = try XCTUnwrap(paper.cornerDrag)
            XCTAssertLessThan(hypot(early.gripPosition.x - displayed.gripPosition.x,
                early.gripPosition.y - displayed.gripPosition.y), 2)
            for _ in 0..<12 { reader.advancePaperAnimation(elapsed: 0.1) }
            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "previous" : "current")
            XCTAssertFalse(reader.isTransitioning); XCTAssertFalse(paper.hasResources)
        }
    }

}
#endif
