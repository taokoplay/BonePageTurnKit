import Foundation
import XCTest
@testable import BonePageTurnKit

/// 纯 Double 几何检查，不依赖显示服务器或 UIKit。
final class PaperTurnGeometryTests: XCTestCase {
    /// - Parameters: effect: 曲面类型；progress: 逻辑进度；direction: 方向；spine: 书脊。
    /// - Returns: 1000×1500 页面上的 100 条材料投影。
    private func geometry(_ effect: PageTurnEffect, _ progress: Double,
                          direction: PageTurnDirection = .next,
                          spine: PageSpinePlacement = .minimum) -> [PaperStripGeometry] {
        PaperTurnGeometry.strips(width: 1000, height: 1500, progress: progress,
                                 effect: effect, direction: direction, spine: spine, stripCount: 100)
    }

    /// 无参数；验证未折弯端点的文字坐标稳定，以及完全移出的曲面位置。
    func testFlatAndTurnedEndpoints() {
        for effect in [PageTurnEffect.curl, .arch] {
            for spine in [PageSpinePlacement.automatic, .minimum, .maximum] {
                for direction in [PageTurnDirection.next, .previous] {
                    let flat = geometry(effect, direction == .next ? 0 : 1, direction: direction, spine: spine)
                    XCTAssertEqual(flat.count, 100)
                    for strip in flat {
                        XCTAssertEqual(strip.xStart, strip.sourceStart, accuracy: 1e-9)
                        XCTAssertEqual(strip.xEnd, strip.sourceEnd, accuracy: 1e-9)
                        XCTAssertEqual(strip.verticalExpansion, 0, accuracy: 1e-9)
                        XCTAssertFalse(strip.isBackFace)
                    }
                    let turned = geometry(effect, direction == .next ? 1 : 0, direction: direction, spine: spine)
                    if spine == .maximum {
                        XCTAssertTrue(turned.allSatisfy { $0.minimumX >= 1000 - 1e-9 })
                    } else {
                        XCTAssertTrue(turned.allSatisfy { $0.maximumX <= 1e-9 })
                    }
                }
            }
        }
    }

    /// 无参数；圆柱前后切线连续，且背面深度高于平面。
    func testCurlContainsFlatCylinderAndBackFaceWithContinuousEdges() throws {
        let strips = geometry(.curl, 0.5)
        let flat = try XCTUnwrap(strips.first)
        XCTAssertEqual(flat.depth, 0)
        XCTAssertEqual(flat.xStart, 0)
        let curve = strips[60]
        XCTAssertEqual(curve.xStart, 500 + 140 * sin(100 / 140.0), accuracy: 1e-9)
        XCTAssertGreaterThan(curve.depth, 0)
        XCTAssertFalse(curve.isBackFace)
        let back = try XCTUnwrap(strips.last)
        XCTAssertEqual(back.xStart, 500 - (990 - 500 - .pi * 140), accuracy: 1e-9)
        XCTAssertEqual(back.depth, 280, accuracy: 1e-9)
        XCTAssertTrue(back.isBackFace)
        XCTAssertGreaterThan(back.verticalExpansion, 0)
        for index in 1..<strips.count {
            XCTAssertEqual(strips[index - 1].xEnd, strips[index].xStart, accuracy: 1e-9)
        }
        for sample in stride(from: 0.01, through: 0.99, by: 0.01) {
            XCTAssertTrue(geometry(.curl, sample).allSatisfy { $0.depth.isFinite && $0.shade <= 0.25 })
        }
    }

    /// 无参数；拱页保留旧压缩比例，并在受力边收束纵向拱起。
    func testArchCompressionWaveAndContactEdge() throws {
        let strips = geometry(.arch, 0.6)
        XCTAssertEqual(try XCTUnwrap(strips.first).xStart, -510, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(strips.last).xEnd, 290, accuracy: 1e-9)
        XCTAssertTrue(strips.allSatisfy { !$0.isBackFace && $0.xEnd > $0.xStart })
        let expansions = strips.map(\.verticalExpansion)
        XCTAssertGreaterThan(try XCTUnwrap(expansions.max()), 20)
        XCTAssertLessThan(try XCTUnwrap(expansions.last), strips[85].verticalExpansion)
        XCTAssertGreaterThan(abs(strips[30].verticalExpansion - strips[65].verticalExpansion), 1)
    }

    /// 无参数；两个中间曲面必须在位置、深度和正反面上有可辨别的差异。
    func testCurlAndArchHaveDifferentIntermediateSurfaces() {
        let curl = geometry(.curl, 0.6)
        let arch = geometry(.arch, 0.6)
        XCTAssertGreaterThan(abs(curl[60].xStart - arch[60].xStart), 200)
        XCTAssertTrue(curl.contains(where: \.isBackFace))
        XCTAssertFalse(arch.contains(where: \.isBackFace))
        XCTAssertGreaterThan(abs(curl[60].depth - arch[60].depth), 50)
    }

    /// 无参数；最大端只镜像材料几何，源条带始终保持从左到右的索引。
    func testMaximumSpineMirrorsGeometryWithoutReversingSourceCoordinates() {
        for effect in [PageTurnEffect.curl, .arch] {
            for progress in [0.0, 0.3, 0.6, 1.0] {
                let minimum = geometry(effect, progress)
                let maximum = geometry(effect, progress, spine: .maximum)
                XCTAssertEqual(geometry(effect, progress, spine: .automatic), minimum)
                for index in minimum.indices {
                    let reflected = minimum[minimum.count - 1 - index]
                    XCTAssertEqual(maximum[index].sourceStart, minimum[index].sourceStart)
                    XCTAssertEqual(maximum[index].xStart, 1000 - reflected.xEnd, accuracy: 1e-8)
                    XCTAssertEqual(maximum[index].xEnd, 1000 - reflected.xStart, accuracy: 1e-8)
                    XCTAssertEqual(maximum[index].depth, reflected.depth, accuracy: 1e-8)
                    XCTAssertEqual(maximum[index].verticalExpansion, reflected.verticalExpansion, accuracy: 1e-8)
                    XCTAssertEqual(maximum[index].isBackFace, reflected.isBackFace)
                }
            }
        }
    }

    /// 无参数；上一页沿同一曲面反向入场，超范围有限进度被钳制。
    func testPreviousReversesMovingProgressAndClampsFiniteValues() {
        for effect in [PageTurnEffect.curl, .arch] {
            for spine in [PageSpinePlacement.minimum, .maximum] {
                for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    XCTAssertEqual(geometry(effect, progress, spine: spine),
                                   geometry(effect, 1 - progress, direction: .previous, spine: spine))
                }
            }
            XCTAssertEqual(geometry(effect, -9), geometry(effect, 0))
            XCTAssertEqual(geometry(effect, 9), geometry(effect, 1))
        }
        XCTAssertEqual(PaperTurnGeometry.movingProgress(0.3, direction: .previous), 0.7)
    }

    /// 无参数；非法输入不生成 NaN 条带，也不会触发整数转换溢出。
    func testInvalidGeometryAndSnapshotInputsAreRejected() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(geometry(.curl, invalid).isEmpty)
            XCTAssertNil(PaperTurnGeometry.movingProgress(invalid, direction: .next))
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude] {
            XCTAssertTrue(PaperTurnGeometry.strips(width: invalid, height: 100, progress: 0.5,
                                                   effect: .curl, direction: .next, spine: .minimum,
                                                   stripCount: 128).isEmpty)
        }
        XCTAssertTrue(geometry(.cover, 0.5).isEmpty)
        XCTAssertTrue(geometry(.curl, 0.5, spine: .center).isEmpty)
        for scale in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(PaperTurnGeometry.snapshotPlan(width: 300, height: 500, displayScale: scale,
                                                        maximumSnapshotPixels: 65_536))
        }
        XCTAssertNil(PaperTurnGeometry.snapshotPlan(width: .infinity, height: 500, displayScale: 3,
                                                    maximumSnapshotPixels: 65_536))
        XCTAssertNil(PaperTurnGeometry.snapshotPlan(width: 1e200, height: 1, displayScale: 3,
                                                    maximumSnapshotPixels: 65_536))
        for budget in [Int.min, 65_535, 16_777_217, Int.max] {
            XCTAssertNil(PaperTurnGeometry.snapshotPlan(width: 300, height: 500, displayScale: 3,
                                                        maximumSnapshotPixels: budget))
        }
    }

    /// 无参数；先预算再分配的计划同时满足像素、最长边、屏幕倍率和极大尺寸约束。
    func testSnapshotBudgetAndMaximumEdgeBeforeAllocation() throws {
        for budget in [65_536, 4_194_304, 16_777_216] {
            for size in [(320.0, 480.0), (12000, 8000), (1e200, 1e200), (12000, 10)] {
                let plan = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(
                    width: size.0, height: size.1, displayScale: 3, maximumSnapshotPixels: budget))
                XCTAssertLessThanOrEqual(plan.totalPixelCount, budget)
                XCTAssertLessThanOrEqual(max(plan.pixelWidth, plan.pixelHeight), 4096)
                XCTAssertGreaterThan(min(plan.pixelWidth, plan.pixelHeight), 0)
                XCTAssertLessThanOrEqual(plan.scale, 3)
                XCTAssertLessThanOrEqual(Double(plan.pixelWidth) / size.0, 3)
                XCTAssertLessThanOrEqual(Double(plan.pixelHeight) / size.1, 3)
            }
        }
        let scaleOne = try XCTUnwrap(PaperTurnGeometry.snapshotPlan(
            width: 300, height: 500, displayScale: 1, maximumSnapshotPixels: 4_194_304))
        XCTAssertEqual(scaleOne.pixelWidth, 300)
        XCTAssertEqual(scaleOne.pixelHeight, 500)
        XCTAssertEqual(scaleOne.totalPixelCount, 300_000)
    }

    /// 无参数；源像素边界无重复无缺口，条数的上下边界有明确行为。
    func testStripLimitsAndIntegerPixelPartition() throws {
        for count in [31, 32, 128, 256, 257] {
            let strips = PaperTurnGeometry.strips(width: 397, height: 500, progress: 0,
                                                 effect: .curl, direction: .next, spine: .minimum,
                                                 stripCount: count, sourcePixelWidth: 397)
            if !(32...256).contains(count) {
                XCTAssertTrue(strips.isEmpty)
                continue
            }
            XCTAssertEqual(strips.count, count)
            XCTAssertEqual(try XCTUnwrap(strips.first).sourceStart, 0)
            XCTAssertEqual(try XCTUnwrap(strips.last).sourceEnd, 397)
            for (index, strip) in strips.enumerated() {
                XCTAssertEqual(strip.sourceStart, strip.sourceStart.rounded(), accuracy: 1e-9)
                XCTAssertGreaterThan(strip.sourceEnd, strip.sourceStart)
                if index > 0 { XCTAssertEqual(strips[index - 1].sourceEnd, strip.sourceStart) }
            }
        }
        let narrow = PaperTurnGeometry.strips(width: 16, height: 500, progress: 0.5,
                                             effect: .arch, direction: .next, spine: .maximum,
                                             stripCount: 128, sourcePixelWidth: 16)
        XCTAssertEqual(narrow.count, 16)
    }

    /// 无参数；公开配置的默认值和边界与几何预算保持一致。
    func testRenderingOptionsDefaultsAndValidationBoundaries() throws {
        let standard = PaperRenderingOptions()
        XCTAssertEqual(standard.maximumSnapshotPixels, 4_194_304)
        XCTAssertEqual(standard.stripCount, 128)
        try standard.validate()
        for budget in [65_536, 16_777_216] {
            for count in [32, 256] {
                try PaperRenderingOptions(maximumSnapshotPixels: budget, stripCount: count).validate()
            }
        }
        for options in [PaperRenderingOptions(maximumSnapshotPixels: 65_535),
                        PaperRenderingOptions(maximumSnapshotPixels: 16_777_217),
                        PaperRenderingOptions(stripCount: 31), PaperRenderingOptions(stripCount: 257)] {
            XCTAssertThrowsError(try options.validate())
        }
    }
}
