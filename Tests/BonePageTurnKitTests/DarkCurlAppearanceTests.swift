#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import Testing
@testable import BonePageTurnKit

/// 深色空白纸面没有任何亮色内容；卷起后也不应生成亮于纸色的描边。
@MainActor
struct DarkCurlAppearanceTests {
    @Test(arguments: [PageTurnAxis.horizontal, .vertical], [PageTurnDirection.next, .previous])
    func curlKeepsDarkPaperEdges(axis: PageTurnAxis, direction: PageTurnDirection) throws {
        guard PaperCornerMetalRenderer.isSupported else { return }
        let size = axis == .horizontal ? CGSize(width: 320, height: 480) : CGSize(width: 480, height: 320)
        let bounds = CGRect(origin: .zero, size: size)
        let color = UIColor(white: 0.12, alpha: 1)
        func page() -> UIView {
            let view = UIView(frame: bounds)
            view.backgroundColor = color
            return view
        }
        let paper = try PaperTransitionView(currentView: page(), targetView: page(),
            effect: .curl, direction: direction, spine: .minimum,
            options: .standard, axis: axis, cornerDriven: true)
        let softwarePaper = try PaperTransitionView(currentView: page(), targetView: page(),
            effect: .curl, direction: direction, spine: .minimum,
            options: .standard, axis: axis, cornerDriven: false)
        defer { paper.invalidateResources(); softwarePaper.invalidateResources() }
        func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
            axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
        }
        let sign: CGFloat = direction == .next ? -1 : 1
        let seed = try #require(PaperCornerDrag(size: size, axis: axis, spread: false,
            inwardSign: sign, origin: point(direction == .next ? 300 : 20, 460)))
        for touch in [point(200, 390), point(120, 310), point(240, 280)] {
            let drag = try #require(seed.moved(to: touch, direction: direction))
            softwarePaper.update(progress: drag.gestureProgress, cornerDrag: drag)
            paper.update(progress: drag.gestureProgress, cornerDrag: drag)
            let renderedGPUImage = try paper.cornerGPUImage()
            let gpuImage = try #require(renderedGPUImage)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let softwareImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                softwarePaper.draw(bounds)
            }
            for (backend, image) in [("Metal", gpuImage), ("CoreGraphics", softwareImage)] {
                let peak = try brightestChannel(in: image)
                // 纸面约为 31/255；阴影只能变暗，容许少量颜色转换与取样误差。
                #expect(peak <= 34, "\(backend) \(axis) \(direction) 在 \(touch) 出现非纸面亮线：\(peak)/255")
            }
            if direction == .next, axis == .horizontal, touch == point(200, 390) {
                Attachment.record(gpuImage, named: "dark-curl-without-white-outline.png")
            }
        }
    }

    private func brightestChannel(in image: UIImage) throws -> UInt8 {
        let cg = try #require(image.cgImage)
        let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let data = try #require(context.makeImage()?.dataProvider?.data) as Data
        var peak: UInt8 = 0
        // 排除截图外框，仅检查纸面内部及卷边。
        for y in 2..<(cg.height - 2) {
            for x in 2..<(cg.width - 2) {
                let offset = (y * cg.width + x) * 4
                peak = max(peak, data[offset], data[offset + 1], data[offset + 2])
            }
        }
        return peak
    }
}
#endif
