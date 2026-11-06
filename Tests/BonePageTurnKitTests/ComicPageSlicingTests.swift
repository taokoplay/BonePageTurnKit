import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import BonePageTurnKit

final class ComicPageSlicingTests: XCTestCase {
    private let source = PageItemIdentity(sourceID: "漫画", unitID: "页:3,左📖", contentVersion: 7, layoutVersion: 11)

    /// 无参数；完整图保持像素、版本和归一化矩形，不改变源身份。
    func testWholePreservesSourceAndVersions() throws {
        let slices = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 401, height: 701), mode: .whole)
        let slice = try XCTUnwrap(slices.first)
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slice.sourcePixelRect, CGRect(x: 0, y: 0, width: 401, height: 701))
        XCTAssertEqual(slice.normalizedRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(slice.sourceIdentity, source)
        XCTAssertEqual(slice.identity.sourceID, source.sourceID)
        XCTAssertEqual(slice.identity.contentVersion, 7)
        XCTAssertEqual(slice.identity.layoutVersion, 11)
        XCTAssertEqual(slice.index, 0)
        XCTAssertEqual(slice.count, 1)
        XCTAssertNotEqual(slice.identity.unitID, source.unitID)
    }

    /// 无参数；奇数列全部保留，阅读顺序只重排物理区域和逻辑序号。
    func testOddWidthSplitAndStablePhysicalIdentityInBothReadingOrders() throws {
        let size = CGSize(width: 1001, height: 700)
        let leftFirst = try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .splitWide)
        let rightFirst = try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .splitWide, readingOrder: .rightToLeft)
        XCTAssertEqual(leftFirst.map(\.sourcePixelRect), [CGRect(x: 0, y: 0, width: 500, height: 700),
                                                        CGRect(x: 500, y: 0, width: 501, height: 700)])
        XCTAssertEqual(leftFirst[0].sourcePixelRect.maxX, leftFirst[1].sourcePixelRect.minX)
        XCTAssertEqual(leftFirst[1].sourcePixelRect.maxX, size.width)
        XCTAssertEqual(leftFirst.map(\.identity), rightFirst.reversed().map(\.identity))
        XCTAssertEqual(leftFirst.map(\.sourcePixelRect), rightFirst.reversed().map(\.sourcePixelRect))
        XCTAssertEqual(rightFirst.map(\.index), [0, 1])
        XCTAssertEqual(rightFirst.map(\.count), [2, 2])
        XCTAssertEqual(leftFirst[0].normalizedRect.width, 500 / 1001.0, accuracy: 1e-12)
        XCTAssertEqual(leftFirst[1].normalizedRect.maxX, 1, accuracy: 1e-12)
    }

    /// 无参数；方图、竖图不拆分，物理区域相同的不同模式产生相同身份。
    func testNarrowAndSquareImagesRemainWhole() throws {
        for size in [CGSize(width: 10, height: 10), CGSize(width: 9, height: 10)] {
            let whole = try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .whole)
            XCTAssertEqual(try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .splitWide), whole)
            XCTAssertEqual(try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .vertical,
                                                      maximumHeightToWidth: 10), whole)
        }
    }

    /// 无参数；纵向按整数边界完整分割，末片保留且 RTL 不改变上下顺序。
    func testVerticalCoverageAndShortFinalSlice() throws {
        let slices = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 7, height: 34), mode: .vertical)
        XCTAssertEqual(slices.map(\.sourcePixelRect), [CGRect(x: 0, y: 0, width: 7, height: 10),
                                                     CGRect(x: 0, y: 10, width: 7, height: 10),
                                                     CGRect(x: 0, y: 20, width: 7, height: 10),
                                                     CGRect(x: 0, y: 30, width: 7, height: 4)])
        XCTAssertEqual(slices.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(slices.map(\.count), [4, 4, 4, 4])
        for pair in zip(slices, slices.dropFirst()) {
            XCTAssertEqual(pair.0.sourcePixelRect.maxY, pair.1.sourcePixelRect.minY)
        }
        XCTAssertEqual(slices.reduce(0) { $0 + $1.sourcePixelRect.height }, 34)
        XCTAssertEqual(try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 7, height: 34),
                                                  mode: .vertical, readingOrder: .rightToLeft), slices)
    }

    /// 无参数；预算边界先于数组创建，极小比例仍按一像素步长推进。
    func testBudgetAndFiniteExtremeRatios() throws {
        let slices = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 1, height: 256), mode: .vertical,
                                               maximumHeightToWidth: .leastNonzeroMagnitude)
        XCTAssertEqual(slices.count, 256)
        XCTAssertEqual(slices.last?.sourcePixelRect.maxY, 256)
        for height in [257, 1_000_000_000] {
            XCTAssertThrowsError(try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 1, height: height),
                                                            mode: .vertical, maximumHeightToWidth: 1)) {
                XCTAssertEqual($0 as? ComicSlicingError, .tooManySlices(limit: 256))
            }
        }
        let hugeRatio = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 1_000_000_000, height: 1_000_000_000),
                                                  mode: .vertical, maximumHeightToWidth: .greatestFiniteMagnitude)
        XCTAssertEqual(hugeRatio.count, 1)
    }

    /// 无参数；非整数、不有限或越界尺寸以及非法比例均返回明确错误。
    func testInvalidInputsThrow() {
        for value: CGFloat in [0, -1, .nan, .infinity, -.infinity, 1.5, 1_000_000_001, .greatestFiniteMagnitude] {
            for size in [CGSize(width: value, height: 10), CGSize(width: 10, height: value)] {
                XCTAssertThrowsError(try ComicPageSlicing.slices(for: source, pixelSize: size, mode: .whole)) {
                    XCTAssertEqual($0 as? ComicSlicingError, .invalidPixelSize)
                }
            }
        }
        for ratio in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 10, height: 10),
                                                            mode: .whole, maximumHeightToWidth: ratio)) {
                XCTAssertEqual($0 as? ComicSlicingError, .invalidMaximumHeightToWidth)
            }
        }
    }

    /// 无参数；含分隔符和 Unicode 的不同源单元不会混淆派生身份。
    func testIdentityIncludesUnambiguousSourceUnitAndPhysicalRect() throws {
        let unitIDs = ["a", "a:0,0,10,10", "1:a", "页:3,左📖", "", "comic-slice:1:a:0,0,10,10"]
        let identities = try unitIDs.map { unitID in
            try XCTUnwrap(ComicPageSlicing.slices(for: PageItemIdentity(sourceID: "same", unitID: unitID),
                                                pixelSize: CGSize(width: 10, height: 10), mode: .whole).first).identity
        }
        XCTAssertEqual(Set(identities).count, unitIDs.count)
        let first = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 20, height: 10), mode: .whole)
        let second = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 20, height: 10), mode: .splitWide)
        XCTAssertFalse(second.contains { $0.identity == first[0].identity })
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class ComicSliceDrawingTests: XCTestCase {
    private let source = PageItemIdentity(sourceID: "彩色图", unitID: "四象限")

    /// - Parameters: size: 输出像素尺寸；draw: 绘制操作。
    /// - Returns: 一倍比例的标准色域位图。
    private func image(size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    /// - Parameter size: 原图尺寸。
    /// - Returns: 上方红绿、下方蓝黄且分界为整数像素的原图。
    private func quadrants(size: CGSize) -> UIImage {
        image(size: size) { _ in
            let x = floor(size.width / 2)
            let y = floor(size.height / 2)
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: x, height: y))
            UIColor.green.setFill()
            UIRectFill(CGRect(x: x, y: 0, width: size.width - x, height: y))
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: y, width: x, height: size.height - y))
            UIColor.yellow.setFill()
            UIRectFill(CGRect(x: x, y: y, width: size.width - x, height: size.height - y))
        }
    }

    /// - Parameter image: 相同 renderer 格式生成的图像。
    /// - Returns: 实际像素数据，用于逐字节检查方向与接缝。
    private func pixels(_ image: UIImage) throws -> Data {
        try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
    }

    /// - Parameters: size: 结果尺寸；first: 左侧或上方颜色；second: 另一侧颜色；vertical: 是否上下排列。
    /// - Returns: 独立绘制的两色参考图。
    private func expected(size: CGSize, first: UIColor, second: UIColor, vertical: Bool) -> UIImage {
        image(size: size) { _ in
            first.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            second.setFill()
            UIRectFill(vertical ? CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                       : CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// 无参数；左右裁剪确实保留上红下蓝、上绿下黄，RTL 不镜像像素。
    func testRealImageLeftAndRightCropsPreserveOrientation() throws {
        let original = quadrants(size: CGSize(width: 12, height: 8))
        let cgImage = try XCTUnwrap(original.cgImage)
        let scaled = UIImage(cgImage: cgImage, scale: 2, orientation: .up)
        let slices = try ComicPageSlicing.slices(for: source, pixelSize: CGSize(width: 12, height: 8),
                                               mode: .splitWide, readingOrder: .rightToLeft)
        for (index, colors) in [(0, (UIColor.green, UIColor.yellow)), (1, (UIColor.red, UIColor.blue))] {
            let view = try ComicSliceView(image: scaled, slice: slices[index])
            XCTAssertTrue(view.image === scaled)
            XCTAssertEqual(view.preferredContentSize, CGSize(width: 6, height: 8))
            let actual = image(size: view.preferredContentSize) { _ in view.draw(view.bounds) }
            let reference = expected(size: view.preferredContentSize, first: colors.0, second: colors.1, vertical: true)
            XCTAssertEqual(try pixels(actual), try pixels(reference))
        }
    }

    /// 无参数；上下裁剪分别呈现红绿和蓝黄，不翻转垂直方向。
    func testRealImageTopAndBottomCropsPreserveOrientation() throws {
        let original = quadrants(size: CGSize(width: 8, height: 12))
        let slices = try ComicPageSlicing.slices(for: source, pixelSize: original.size, mode: .vertical,
                                               maximumHeightToWidth: 0.75)
        for (index, colors) in [(0, (UIColor.red, UIColor.green)), (1, (UIColor.blue, UIColor.yellow))] {
            let view = try ComicSliceView(image: original, slice: slices[index])
            let actual = image(size: view.preferredContentSize) { _ in view.draw(view.bounds) }
            XCTAssertEqual(try pixels(actual), try pixels(expected(size: view.preferredContentSize,
                                                                    first: colors.0, second: colors.1, vertical: false)))
        }
    }

    /// 无参数；奇数宽、非整除长图所有切片拼回后逐像素等于原图，边界无空白或重复。
    func testReassembledOddImagesHaveNoSeams() throws {
        for (size, mode) in [(CGSize(width: 13, height: 8), ComicSliceMode.splitWide),
                             (CGSize(width: 7, height: 19), ComicSliceMode.vertical)] {
            let original = quadrants(size: size)
            let slices = try ComicPageSlicing.slices(for: source, pixelSize: size, mode: mode, maximumHeightToWidth: 1)
            let views = try slices.map { try ComicSliceView(image: original, slice: $0) }
            let reconstructed = image(size: size) { context in
                for view in views {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: view.slice.sourcePixelRect.minX, y: view.slice.sourcePixelRect.minY)
                    view.draw(view.bounds)
                    context.cgContext.restoreGState()
                }
            }
            XCTAssertEqual(try pixels(reconstructed), try pixels(original))
        }
    }

    /// 无参数；方向、实际像素与源尺寸不一致时明确拒绝，不静默裁错。
    func testMismatchedAndRotatedImagesAreRejected() throws {
        let original = quadrants(size: CGSize(width: 12, height: 8))
        let slice = try XCTUnwrap(ComicPageSlicing.slices(for: source, pixelSize: original.size, mode: .whole).first)
        let cgImage = try XCTUnwrap(original.cgImage)
        for orientation: UIImage.Orientation in [.down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            XCTAssertThrowsError(try ComicSliceView(image: UIImage(cgImage: cgImage, scale: 1, orientation: orientation), slice: slice)) {
                XCTAssertEqual($0 as? ComicSliceViewError, .imageMustBeUpright)
            }
        }
        XCTAssertThrowsError(try ComicSliceView(image: quadrants(size: CGSize(width: 8, height: 12)), slice: slice)) {
            XCTAssertEqual($0 as? ComicSliceViewError, .sourcePixelSizeMismatch)
        }
        XCTAssertThrowsError(try ComicSliceView(image: UIImage(), slice: slice)) {
            XCTAssertEqual($0 as? ComicSliceViewError, .imagePixelsUnavailable)
        }
    }

    /// 无参数；显示层不通过缓存延长切片视图或宿主图像生命周期。
    func testSliceAndImageRelease() throws {
        weak var weakView: ComicSliceView?
        weak var weakImage: UIImage?
        try autoreleasepool {
            let original = quadrants(size: CGSize(width: 12, height: 8))
            let slice = try XCTUnwrap(ComicPageSlicing.slices(for: source, pixelSize: original.size, mode: .whole).first)
            let view = try ComicSliceView(image: original, slice: slice)
            weakView = view
            weakImage = original
        }
        XCTAssertNil(weakView)
        XCTAssertNil(weakImage)
    }
}
#endif
