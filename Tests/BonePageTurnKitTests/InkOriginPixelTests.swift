#if canImport(UIKit)
import XCTest
import UIKit
import Metal
@testable import BonePageTurnKit

/// 着色器级验收：水墨的原点渲染进像素——原点附近必须显著变暗，
/// 远离原点的角落保持纸色。直接读回 GPU 输出，不经过窗口。
@MainActor
final class InkOriginPixelTests: XCTestCase {
    private func solidImage(_ size: CGSize, color: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw XCTSkip("离屏上下文创建失败") }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { throw XCTSkip("离屏位图创建失败") }
        return image
    }

    private func meanLuma(_ texture: MTLTexture, rect: CGRect) throws -> Double {
        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: texture.width, height: texture.height, depth: 1)), mipmapLevel: 0) }
        var total = 0.0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * bytesPerRow) + x * 4
                let luma = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                total += luma; count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    func testInkDarkensAroundOriginNotFarCorner() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("无 Metal 设备") }
        let size = CGSize(width: 200, height: 320)
        let paper = try solidImage(CGSize(width: 16, height: 16), color: (0.95, 0.93, 0.87))
        let renderer = try PaperEffectMetalRenderer(current: paper, target: paper, size: size,
            effect: .inkwash, direction: .next, axis: .horizontal, origin: CGPoint(x: 160, y: 240))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw XCTSkip("纹理创建失败") }
        renderer.update(progress: 0.12)
        renderer.render(into: texture)
        let nearOrigin = try meanLuma(texture, rect: CGRect(x: 140, y: 220, width: 40, height: 40))
        let farCorner = try meanLuma(texture, rect: CGRect(x: 5, y: 5, width: 30, height: 30))
        XCTAssertGreaterThan(farCorner - nearOrigin, 8.0,
            "原点附近应为墨色（near=\(nearOrigin), far=\(farCorner)）")
    }

    func testWaveWetFilmCoversSweptArea() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("无 Metal 设备") }
        let size = CGSize(width: 300, height: 320)
        let paper = try solidImage(CGSize(width: 16, height: 16), color: (0.95, 0.93, 0.87))
        let renderer = try PaperEffectMetalRenderer(current: paper, target: paper, size: size,
            effect: .wave, direction: .next, axis: .horizontal, origin: CGPoint(x: 240, y: 240))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw XCTSkip("纹理创建失败") }
        renderer.update(progress: 0.4)
        renderer.render(into: texture)
        // 正向浪锋从右侧开始向左扫：进度 0.4 时锋线在 x≈200（随时间相位 ±25 摆动）。
        // 锋线右侧是已扫过的湿区（湿色水膜），左侧锋线前方 70pt 外仍是干纸。
        let sweptWet = try meanLuma(texture, rect: CGRect(x: 235, y: 140, width: 55, height: 40))
        let dryAhead = try meanLuma(texture, rect: CGRect(x: 10, y: 140, width: 60, height: 40))
        XCTAssertLessThan(sweptWet, dryAhead,
            "浪锋扫过的深处应带湿色水膜（wet=\(sweptWet), dry=\(dryAhead)）")
    }

    /// 折纸翻页必须能完全折过去：进度 1 时整页都是目标页（无残留折面）。
    func testFoldCompletesToFullTargetAtProgressOne() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("无 Metal 设备") }
        let size = CGSize(width: 300, height: 320)
        let current = try solidImage(CGSize(width: 16, height: 16), color: (0.95, 0.93, 0.87))
        let target = try solidImage(CGSize(width: 16, height: 16), color: (0.2, 0.25, 0.3))
        let renderer = try PaperEffectMetalRenderer(current: current, target: target, size: size,
            effect: .fold, direction: .next, axis: .horizontal, origin: CGPoint(x: 150, y: 160))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw XCTSkip("纹理创建失败") }
        renderer.update(progress: 1.0)
        renderer.render(into: texture)
        let full = try meanLuma(texture, rect: CGRect(x: 10, y: 10, width: 280, height: 300))
        XCTAssertLessThan(full, 110.0, "进度 1 时应整页显露暗色目标页（luma=\(full)）")
        renderer.update(progress: 0.5)
        renderer.render(into: texture)
        // 进度 0.5：折面收拢在左侧（亮色纸面），右侧应已显露暗色目标页。
        let leftHalf = try meanLuma(texture, rect: CGRect(x: 10, y: 120, width: 110, height: 80))
        let rightHalf = try meanLuma(texture, rect: CGRect(x: 180, y: 120, width: 110, height: 80))
        XCTAssertGreaterThan(leftHalf, rightHalf + 8.0,
            "进度 0.5 时折面应收拢在左、右侧显露目标页（left=\(leftHalf), right=\(rightHalf)）")
    }
}
#endif
