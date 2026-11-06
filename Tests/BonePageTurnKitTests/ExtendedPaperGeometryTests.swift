import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import BonePageTurnKit

/// 轴向与中央纸张的纯几何回归，不依赖 UIKit 或显示服务器。
final class ExtendedPaperGeometryTests: XCTestCase {
    /// - Parameters: effect: 曲面；progress: 逻辑进度；direction: 翻页方向；axis: 轴；order: 阅读顺序；pixels: 半页像素长度。
    /// - Returns: 1000 点翻页轴、600 点横跨轴的中央纸张材料投影。
    private func spread(_ effect: PageTurnEffect, _ progress: Double,
                        direction: PageTurnDirection = .next, axis: PageTurnAxis = .horizontal,
                        order: ReaderReadingOrder = .leftToRight, pixels: Int = 397) -> [PaperStripGeometry] {
        PaperSpreadGeometry.strips(width: axis == .horizontal ? 1000 : 600,
            height: axis == .horizontal ? 600 : 1000, progress: progress,
            effect: effect, direction: direction, axis: axis, readingOrder: order,
            stripCount: 128, sourcePixelLength: pixels)
    }

    /// 无参数；坐标转置必须同时转置采样轴，稳定文字矩形保持原画布朝向。无返回值。
    func testAxisMappingPreservesPageAndExpansionCoordinates() {
        let horizontal = PaperAxisGeometry(width: 320, height: 480, axis: .horizontal)
        let vertical = PaperAxisGeometry(width: 480, height: 320, axis: .vertical)
        XCTAssertEqual(horizontal.length, vertical.length)
        XCTAssertEqual(horizontal.breadth, vertical.breadth)
        XCTAssertEqual(horizontal.rect(start: 20, end: 80, expansion: 5),
                       CGRect(x: 20, y: -5, width: 60, height: 490))
        XCTAssertEqual(vertical.rect(start: 20, end: 80, expansion: 5),
                       CGRect(x: -5, y: 20, width: 490, height: 60))
        for effect in [PageTurnEffect.curl, .arch] {
            for spine in [PageSpinePlacement.minimum, .maximum] {
                let a = PaperTurnGeometry.strips(width: horizontal.length, height: horizontal.breadth,
                    progress: 0.375, effect: effect, direction: .next, spine: spine, stripCount: 128,
                    sourcePixelWidth: 320)
                let b = PaperTurnGeometry.strips(width: vertical.length, height: vertical.breadth,
                    progress: 0.625, effect: effect, direction: .previous, spine: spine, stripCount: 128,
                    sourcePixelWidth: 320)
                XCTAssertEqual(a, b)
            }
        }
    }

    /// 无参数；中央材料端点覆盖一整半页，铰链在两轴、两种阅读顺序下始终固定。无返回值。
    func testSpreadEndpointsAndHingeAreFixedForEveryPresentation() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let sign = axis == .horizontal && order == .rightToLeft ? -1.0 : 1.0
                for effect in [PageTurnEffect.curl, .arch] {
                    for t in [0.0, 1.0] {
                        let strips = spread(effect, t, axis: axis, order: order)
                        XCTAssertEqual(strips.count, 128)
                        for strip in strips {
                            XCTAssertEqual(strip.xStart, 500 + sign * (1 - 2 * t) * strip.sourceStart, accuracy: 1e-10)
                            XCTAssertEqual(strip.xEnd, 500 + sign * (1 - 2 * t) * strip.sourceEnd, accuracy: 1e-10)
                            XCTAssertEqual(strip.depth, 0)
                            XCTAssertEqual(strip.verticalExpansion, 0)
                            XCTAssertEqual(strip.shade, 0)
                            XCTAssertEqual(strip.isBackFace, t == 1)
                        }
                        XCTAssertEqual(try XCTUnwrap(strips.last).sourceEnd, 500)
                    }
                    for t in stride(from: 0.0, through: 1.0, by: 0.01) {
                        let strips = spread(effect, t, axis: axis, order: order)
                        XCTAssertEqual(try XCTUnwrap(strips.first).xStart, 500, accuracy: 1e-10)
                        for (index, strip) in strips.enumerated() {
                            XCTAssertGreaterThanOrEqual(strip.minimumX, -1e-8)
                            XCTAssertLessThanOrEqual(strip.maximumX, 1000 + 1e-8)
                            XCTAssertTrue(strip.depth.isFinite && strip.depth >= 0)
                            XCTAssertTrue(strip.verticalExpansion.isFinite && strip.verticalExpansion >= 0)
                            XCTAssertTrue((0...0.27).contains(strip.shade))
                            if index > 0 { XCTAssertEqual(strips[index - 1].xEnd, strip.xStart, accuracy: 1e-10) }
                        }
                    }
                }
            }
        }
    }

    /// 无参数；上一页严格反向；横向 RTL 仅镜像投影，纵向阅读顺序不改变上下布局。无返回值。
    func testReversalAndReadingOrderOnlyChangePhysicalPlacement() {
        for effect in [PageTurnEffect.curl, .arch] {
            for axis in [PageTurnAxis.horizontal, .vertical] {
                for t in [0.0, 0.125, 0.25, 0.5, 0.75, 0.875, 1.0] {
                    let ltr = spread(effect, t, axis: axis)
                    let rtl = spread(effect, t, axis: axis, order: .rightToLeft)
                    XCTAssertEqual(ltr, spread(effect, 1 - t, direction: .previous, axis: axis))
                    XCTAssertEqual(rtl, spread(effect, 1 - t, direction: .previous, axis: axis, order: .rightToLeft))
                    for index in ltr.indices {
                        XCTAssertEqual(ltr[index].sourceStart, rtl[index].sourceStart)
                        XCTAssertEqual(ltr[index].sourceEnd, rtl[index].sourceEnd)
                        XCTAssertEqual(ltr[index].depth, rtl[index].depth)
                        XCTAssertEqual(ltr[index].isBackFace, rtl[index].isBackFace)
                        XCTAssertEqual(ltr[index].xStart,
                            axis == .horizontal ? 1000 - rtl[index].xStart : rtl[index].xStart, accuracy: 1e-10)
                    }
                }
            }
        }
    }

    /// 无参数；卷页和拱页均有真实正反面，但中间帧弓形位置、深度和明暗不同。无返回值。
    func testCurlAndArchHaveDistinctSurfacesAndRealBackFaces() throws {
        let curl = spread(.curl, 0.5)
        let arch = spread(.arch, 0.5)
        for strips in [curl, arch] {
            XCTAssertTrue(strips.contains(where: { !$0.isBackFace }))
            XCTAssertTrue(strips.contains(where: \.isBackFace))
            XCTAssertGreaterThan(try XCTUnwrap(strips.map(\.depth).max()), 400)
            XCTAssertEqual(try XCTUnwrap(strips.first).xStart, 500)
        }
        XCTAssertGreaterThan(curl[60].xStart, 600)
        XCTAssertLessThan(arch[60].xStart, 410)
        XCTAssertGreaterThan(abs(curl[60].shade - arch[60].shade), 0.05)
        XCTAssertGreaterThan(abs(curl[60].depth - arch[60].depth), 30)
        XCTAssertTrue(spread(.curl, 0.9).allSatisfy(\.isBackFace))
        XCTAssertTrue(spread(.arch, 0.9).allSatisfy(\.isBackFace))
    }

    /// 无参数；不同像素数量的预裁材料边界无重叠、无缺口，极窄半页相应减少条数。无返回值。
    func testHalfPagePixelPartitionAndSnapshotBudget() throws {
        for pixels in [1, 17, 397, 2048] {
            let strips = spread(.curl, 0.4, pixels: pixels)
            XCTAssertEqual(strips.count, min(128, pixels))
            XCTAssertEqual(try XCTUnwrap(strips.first).sourceStart, 0)
            XCTAssertEqual(try XCTUnwrap(strips.last).sourceEnd, 500)
            for (index, strip) in strips.enumerated() {
                let pixelStart = strip.sourceStart / 500 * Double(pixels)
                XCTAssertEqual(pixelStart, pixelStart.rounded(), accuracy: 1e-9)
                XCTAssertGreaterThan(strip.sourceEnd, strip.sourceStart)
                if index > 0 { XCTAssertEqual(strips[index - 1].sourceEnd, strip.sourceStart) }
            }
        }
        for budget in [65_536, 4_194_304, 16_777_216] {
            for size in [(12_000.0, 7_001.0), (7_001.0, 12_000.0)] {
                let plan = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(
                    width: size.0, height: size.1, displayScale: 3, maximumSnapshotPixels: budget))
                XCTAssertLessThanOrEqual(plan.totalPixelCount, budget)
                XCTAssertLessThanOrEqual(max(plan.pixelWidth, plan.pixelHeight), 4096)
            }
        }
    }

    /// 无参数；非法输入返回空数组，有限越界进度保持端点。无返回值。
    func testInvalidInputsAndProgressClamping() {
        XCTAssertEqual(spread(.curl, -1), spread(.curl, 0))
        XCTAssertEqual(spread(.arch, 2), spread(.arch, 1))
        for value in [Double.nan, .infinity, -.infinity] { XCTAssertTrue(spread(.curl, value).isEmpty) }
        for value in [Int.min, 0, 2049, Int.max] { XCTAssertTrue(spread(.curl, 0.5, pixels: value).isEmpty) }
        for value in [Double.nan, .infinity, -1, 0, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
            XCTAssertTrue(PaperSpreadGeometry.strips(width: value, height: 600, progress: 0.5,
                effect: .curl, direction: .next, axis: .horizontal, readingOrder: .leftToRight, stripCount: 128).isEmpty)
        }
        XCTAssertTrue(spread(.slide, 0.5).isEmpty)
        for count in [31, 257] {
            XCTAssertTrue(PaperSpreadGeometry.strips(width: 1000, height: 600, progress: 0.5,
                effect: .curl, direction: .next, axis: .vertical, readingOrder: .rightToLeft, stripCount: count).isEmpty)
        }
    }
}
