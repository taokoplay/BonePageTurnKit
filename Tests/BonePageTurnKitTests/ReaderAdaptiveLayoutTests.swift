import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import BonePageTurnKit

final class ReaderAdaptiveLayoutTests: XCTestCase {
    /// 无参数及返回值；Duo 样例的两块面板保持等宽，折痕完整落在双页空隙中。
    func testDuoBookSampleSizes() throws {
        for (width, height, gap) in [(1114.0, 720.0, 34.0), (1344.0, 882.0, 36.0)] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let environment = ReaderViewportEnvironment(bounds: bounds, widthClass: .regular, regions: [
                .init(kind: .division, frame: CGRect(x: (width - gap) / 2, y: 0, width: gap, height: height))
            ])
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            XCTAssertEqual(layout.contentFrame, bounds)
            XCTAssertEqual(layout.pageLayout, .spread)
            XCTAssertEqual(layout.axis, .horizontal)
            XCTAssertEqual(layout.spreadGap, gap)
            XCTAssertNil(layout.auxiliaryFrame)
            assertUnobstructed(layout, in: environment)
        }
    }

    /// 无参数及返回值；安全区逐边缩进，保留非零原点，不镜像不对称边距。
    func testAsymmetricInsetsAndNonzeroBoundsOrigin() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 19, y: 27, width: 1000, height: 800),
                                                     safeAreaInsets: .init(top: 31, left: 41, bottom: 19, right: 73),
                                                     widthClass: .regular)
        let layout = try ReaderAdaptiveLayoutPolicy(spreadGap: 13).layout(for: environment)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 60, y: 58, width: 886, height: 750))
        XCTAssertEqual(layout.pageLayout, .spread)
        XCTAssertEqual(layout.spreadGap, 13)
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；双页以真实折痕为中心，不将折痕移到安全区中线。
    func testBookCreaseAwayFromSafeAreaCenter() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 10, y: 20, width: 1300, height: 900),
                                                     safeAreaInsets: .init(top: 25, left: 40, bottom: 35, right: 90),
                                                     widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 560, y: 20, width: 20, height: 900))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 50, y: 45, width: 1040, height: 840))
        XCTAssertEqual(layout.contentFrame.midX, 570)
        XCTAssertEqual(layout.spreadGap, 20)
        XCTAssertEqual(layout.pageLayout, .spread)
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；小数尺寸不经 floor/ceil，两个页面和空隙恰好填满内容视口。
    func testFractionalDimensionsPreserveBothPanes() throws {
        let bounds = CGRect(x: 7.25, y: 11.5, width: 1001.5, height: 700.5)
        let environment = ReaderViewportEnvironment(bounds: bounds, widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 500.25, y: 11.5, width: 15.5, height: 700.5))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.contentFrame, bounds)
        XCTAssertEqual(layout.spreadGap, 15.5)
        XCTAssertEqual(pageFrames(layout).map(\.width), [493, 493])
        XCTAssertEqual(pageFrames(layout).last?.maxX, bounds.maxX)
        let flat = try ReaderAdaptiveLayoutPolicy().layout(for: .init(bounds: bounds, widthClass: .regular))
        XCTAssertEqual(pageFrames(flat).map(\.width), [500.75, 500.75])
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；共用 Y 区间同时避开左右面板各自的遮挡。
    func testBookUsesCommonVerticalInterval() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1020, height: 800),
                                                     widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 500, y: 0, width: 20, height: 800)),
            .init(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 500, height: 80)),
            .init(kind: .occlusion, frame: CGRect(x: 520, y: 700, width: 500, height: 100))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.pageLayout, .spread)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 80, width: 1020, height: 620))
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；折痕旁摄像头内孔可扩大中间空隙，保留两侧完整阅读高度。
    func testInnerCameraHoleExpandsBookGap() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1020, height: 800),
                                                     widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 500, y: 0, width: 20, height: 800)),
            .init(kind: .occlusion, frame: CGRect(x: 470, y: 300, width: 30, height: 80))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.pageLayout, .spread)
        XCTAssertEqual(layout.contentFrame, environment.bounds)
        XCTAssertEqual(layout.spreadGap, 80)
        XCTAssertEqual(pageFrames(layout).map(\.width), [470, 470])
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；tabletop 正文在折痕上方，辅助区域在下方，手势轴仍是 horizontal。
    func testTabletopSeparatesReadingAndAuxiliaryFrames() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 17, y: 23, width: 800, height: 1150),
                                                     safeAreaInsets: .init(top: 17, left: 11, bottom: 33, right: 23),
                                                     widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 17, y: 580, width: 800, height: 30)),
            .init(kind: .occlusion, frame: CGRect(x: 28, y: 610, width: 20, height: 530))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.pageLayout, .single)
        XCTAssertEqual(layout.axis, .horizontal)
        XCTAssertEqual(layout.spreadGap, 0)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 28, y: 40, width: 766, height: 540))
        XCTAssertEqual(layout.auxiliaryFrame, CGRect(x: 48, y: 610, width: 746, height: 530))
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；左右 Split View 位置不参与断点，尺寸类别及可读页尺寸决定单双页。
    func testSplitViewWidthsAndReadableSizeThresholds() throws {
        let policy = ReaderAdaptiveLayoutPolicy(spreadGap: 16)
        for origin in [0.0, 700.0] {
            for (width, height, widthClass, expected) in [
                (575.0, 800.0, ReaderViewportWidthClass.regular, ReaderPageLayout.single),
                (576.0, 800.0, .regular, .spread),
                (900.0, 239.0, .regular, .single),
                (900.0, 240.0, .regular, .spread),
                (900.0, 800.0, .compact, .single),
                (900.0, 800.0, .unspecified, .single)
            ] {
                let environment = ReaderViewportEnvironment(bounds: CGRect(x: origin, y: 13, width: width, height: height),
                                                             widthClass: widthClass)
                let layout = try policy.layout(for: environment)
                XCTAssertEqual(layout.pageLayout, expected)
                XCTAssertEqual(layout.contentFrame, environment.bounds)
                assertUnobstructed(layout, in: environment)
            }
        }
        XCTAssertEqual(try ReaderAdaptiveLayoutPolicy(prefersSpread: false).layout(for:
            .init(bounds: CGRect(x: 0, y: 0, width: 1200, height: 900), widthClass: .regular)).pageLayout, .single)
    }

    /// 无参数及返回值；折痕两侧无法组成双页时，选面积最大的可读一侧，不跨越分隔。
    func testBookFallbackSelectsLargerReadableSide() throws {
        for widthClass in [ReaderViewportWidthClass.compact, .unspecified, .regular] {
            let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                         widthClass: widthClass, regions: [
                .init(kind: .division, frame: CGRect(x: 250, y: 0, width: 20, height: 800))
            ])
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            XCTAssertEqual(layout.pageLayout, .single)
            XCTAssertEqual(layout.contentFrame, CGRect(x: 270, y: 0, width: 730, height: 800))
            assertUnobstructed(layout, in: environment)
        }
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1300, height: 1500),
                                                     widthClass: .regular, regions: [
            .init(kind: .division, frame: CGRect(x: 250, y: 0, width: 20, height: 1500)),
            .init(kind: .occlusion, frame: CGRect(x: 270, y: 300, width: 1030, height: 1200))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        // 左侧面积更大，但宽度不足，右侧 1030 × 300 是可读单页。
        XCTAssertEqual(layout.contentFrame, CGRect(x: 270, y: 0, width: 1030, height: 300))
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；孔洞和边缘摄像头只裁实际需要的边，不产生四边镜像 inset。
    func testCameraOcclusionsChooseLargestClearRectangle() throws {
        for (camera, expected) in [
            (CGRect(x: 900, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 900, height: 800)),
            (CGRect(x: 450, y: 250, width: 100, height: 100), CGRect(x: 0, y: 350, width: 1000, height: 450)),
            (CGRect(x: -50, y: -50, width: 150, height: 850), CGRect(x: 100, y: 0, width: 900, height: 800))
        ] {
            let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                         widthClass: .regular, regions: [.init(kind: .occlusion, frame: camera)])
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            XCTAssertEqual(layout.contentFrame, expected)
            assertUnobstructed(layout, in: environment)
        }
    }

    /// 无参数及返回值；联合裁剪保留全局最大矩形，避免先选底部后被第二遮挡继续缩小。
    func testMultipleOcclusionsDoNotGreedilyDiscardLargerCandidate() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), regions: [
            .init(kind: .occlusion, frame: CGRect(x: 0, y: 400, width: 1000, height: 100)),
            .init(kind: .occlusion, frame: CGRect(x: 0, y: 800, width: 1000, height: 200))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 1000, height: 400))
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；其他活跃折痕均作为遮挡，区域输入顺序不会改变结果。
    func testAdditionalDivisionsRemainObstructions() throws {
        let primary = ReaderReservedRegion(kind: .division, frame: CGRect(x: 500, y: 0, width: 20, height: 800))
        for secondary in [CGRect(x: 0, y: 350, width: 480, height: 20),
                          CGRect(x: 750, y: 0, width: 10, height: 800),
                          CGRect(x: 0, y: 350, width: 1020, height: 20)] {
            let regions = [primary, ReaderReservedRegion(kind: .division, frame: secondary)]
            let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1020, height: 800),
                                                         widthClass: .regular, regions: regions)
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            let reordered = ReaderViewportEnvironment(bounds: environment.bounds, widthClass: .regular, regions: regions.reversed())
            XCTAssertEqual(layout, try ReaderAdaptiveLayoutPolicy().layout(for: reordered))
            assertUnobstructed(layout, in: environment)
        }
    }

    /// 无参数及返回值；inactive、屏外和零面积区域不阻挡布局，最多 64 个合法区域可接受。
    func testInactiveOffscreenAndEmptyRegionsAreIgnored() throws {
        let bounds = CGRect(x: 30, y: 40, width: 1000, height: 800)
        let regions: [ReaderReservedRegion] = [
            .init(kind: .division, frame: bounds, isActive: false),
            .init(kind: .occlusion, frame: bounds, isActive: false),
            .init(kind: .division, frame: CGRect(x: -100, y: -100, width: 20, height: 50)),
            .init(kind: .occlusion, frame: CGRect(x: 1030, y: 40, width: 100, height: 800)),
            .init(kind: .occlusion, frame: CGRect(x: 300, y: 300, width: 0, height: 400))
        ]
        let policy = ReaderAdaptiveLayoutPolicy()
        let expected = try policy.layout(for: .init(bounds: bounds, widthClass: .regular))
        XCTAssertEqual(try policy.layout(for: .init(bounds: bounds, widthClass: .regular, regions: regions)), expected)
        XCTAssertEqual(try policy.layout(for: .init(bounds: bounds, widthClass: .regular,
                                                   regions: Array(repeating: regions[0], count: 64))), expected)
        XCTAssertThrowsError(try policy.layout(for: .init(bounds: bounds, regions: Array(repeating: regions[0], count: 65)))) {
            XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .tooManyRegions)
        }
    }

    /// 无参数及返回值；边距耗尽、全屏遮挡或上方为空均返回有限空单页，不把辅助区用作正文。
    func testEmptyAndFullyObstructedSpaceIsFinite() throws {
        let bounds = CGRect(x: 13, y: 29, width: 100, height: 200)
        let cases: [ReaderViewportEnvironment] = [
            .init(bounds: CGRect(x: 13, y: 29, width: 0, height: 200)),
            .init(bounds: bounds, safeAreaInsets: .init(top: .greatestFiniteMagnitude, left: .greatestFiniteMagnitude,
                                                      bottom: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)),
            .init(bounds: bounds, regions: [.init(kind: .occlusion, frame: bounds)]),
            .init(bounds: bounds, regions: [.init(kind: .division, frame: CGRect(x: 13, y: 29, width: 100, height: 20))])
        ]
        for environment in cases {
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            XCTAssertEqual(layout.pageLayout, .single)
            XCTAssertEqual(layout.contentFrame.size, .zero)
            XCTAssertTrue(layout.contentFrame.origin.x.isFinite)
            XCTAssertTrue(layout.contentFrame.origin.y.isFinite)
            assertUnobstructed(layout, in: environment)
        }
    }

    /// 无参数及返回值；原始负尺寸、NaN、无穷、端点溢出及非法策略均明确抛错，包括 inactive 区域。
    func testInvalidInputsThrowSpecificErrors() throws {
        let valid = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let invalid: [CGRect] = [
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: -1, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: -1),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1),
            .null, .infinite
        ]
        for bounds in invalid {
            XCTAssertThrowsError(try ReaderAdaptiveLayoutPolicy().layout(for: .init(bounds: bounds))) {
                XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .invalidBounds)
            }
            XCTAssertThrowsError(try ReaderAdaptiveLayoutPolicy().layout(for: .init(bounds: valid, regions: [
                .init(kind: .occlusion, frame: bounds, isActive: false)
            ]))) { XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .invalidRegion(index: 0)) }
        }
        for value in [Double.nan, .infinity, -.infinity, -1] {
            for insets in [ReaderViewportInsets(top: value), .init(left: value), .init(bottom: value), .init(right: value)] {
                XCTAssertThrowsError(try ReaderAdaptiveLayoutPolicy().layout(for: .init(bounds: valid, safeAreaInsets: insets))) {
                    XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .invalidInsets)
                }
            }
        }
        for value in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            for policy in [ReaderAdaptiveLayoutPolicy(minimumPageWidth: value), .init(minimumPageHeight: value)] {
                XCTAssertThrowsError(try policy.layout(for: .init(bounds: valid))) {
                    XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .invalidPolicy)
                }
            }
            if value != 0 {
                XCTAssertThrowsError(try ReaderAdaptiveLayoutPolicy(spreadGap: value).layout(for: .init(bounds: valid))) {
                    XCTAssertEqual($0 as? ReaderAdaptiveLayoutError, .invalidPolicy)
                }
            }
        }
    }

    /// 无参数及返回值；有限巨大宽高的面积比较不溢出，双页阈值不直接计算两倍最小页宽。
    func testLargeFiniteGeometryRemainsFinite() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1e300, height: 1e300)
        let environment = ReaderViewportEnvironment(bounds: bounds, widthClass: .regular, regions: [
            .init(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 1e299, height: 1e300))
        ])
        let layout = try ReaderAdaptiveLayoutPolicy(minimumPageWidth: .greatestFiniteMagnitude).layout(for: environment)
        XCTAssertEqual(layout.pageLayout, .single)
        XCTAssertGreaterThan(layout.contentFrame.width, 0)
        assertUnobstructed(layout, in: environment)
    }

    /// 无参数及返回值；多组偏心折痕和内孔的输出页面、辅助区均位于安全区且不覆盖活跃区域。
    func testGeneratedLayoutsNeverCrossActiveRegions() throws {
        for index in 0..<120 {
            let bounds = CGRect(x: 13.25, y: 21.5, width: 1200.5, height: 1000.5)
            let vertical = index.isMultiple(of: 2)
            let crease = vertical
                ? CGRect(x: 400.25 + CGFloat(index % 11) * 25, y: 21.5, width: 19.5, height: 1000.5)
                : CGRect(x: 13.25, y: 400.5 + CGFloat(index % 7) * 25, width: 1200.5, height: 21.5)
            let environment = ReaderViewportEnvironment(bounds: bounds, safeAreaInsets: .init(top: 17, left: 23, bottom: 31, right: 47),
                                                         widthClass: .regular, regions: [
                .init(kind: .division, frame: crease),
                .init(kind: .occlusion, frame: CGRect(x: CGFloat(index * 83 % 1100), y: CGFloat(index * 131 % 900), width: 71.5, height: 43.5)),
                .init(kind: .occlusion, frame: CGRect(x: CGFloat(index * 197 % 1100), y: CGFloat(index * 73 % 900), width: 33.5, height: 93.5))
            ])
            assertUnobstructed(try ReaderAdaptiveLayoutPolicy(spreadGap: 7.5).layout(for: environment), in: environment)
        }
    }

    /// 无参数及返回值；三分之一点坐标也不得因浮点重组越过真实折痕或安全区边界。
    func testThirdPointCoordinatesDoNotOverlapRegions() throws {
        for index in 0..<100 {
            let bounds = CGRect(x: -10.0 / 3, y: 17.0 / 3, width: CGFloat(3500 + index) / 3, height: 2800.0 / 3)
            let crease = CGRect(x: CGFloat(1450 + index) / 3, y: bounds.minY, width: 55.0 / 3, height: bounds.height)
            let environment = ReaderViewportEnvironment(bounds: bounds,
                                                         safeAreaInsets: .init(top: 17.0 / 3, left: 23.0 / 3, bottom: 31.0 / 3, right: 47.0 / 3),
                                                         widthClass: .regular, regions: [
                .init(kind: .division, frame: crease),
                .init(kind: .occlusion, frame: CGRect(x: crease.minX - 35.0 / 3, y: 100, width: 35.0 / 3, height: 10))
            ])
            let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
            XCTAssertEqual(layout.pageLayout, .spread)
            assertUnobstructed(layout, in: environment)
        }
    }

    /// 无参数及返回值；64 个区域上限内的候选搜索有界并仍满足所有不重叠约束。
    func testMaximumRegionCountWithDistinctEdges() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                                     widthClass: .regular, regions: (0..<64).map { index in
            .init(kind: .occlusion, frame: CGRect(x: index * 23, y: index * 13, width: 17, height: 9))
        })
        let layout = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        XCTAssertGreaterThan(layout.contentFrame.width * layout.contentFrame.height, 0)
        assertUnobstructed(layout, in: environment)
    }

    /// - Parameter layout: 待验证布局；返回双页空隙两侧的实际页矩形，单页直接返回正文区域。
    private func pageFrames(_ layout: ReaderAdaptiveLayout) -> [CGRect] {
        guard layout.pageLayout == .spread else { return [layout.contentFrame] }
        let frame = layout.contentFrame
        let width = (frame.width - layout.spreadGap) / 2
        return [CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
                CGRect(x: frame.minX + width + layout.spreadGap, y: frame.minY, width: width, height: frame.height)]
    }

    /// - Parameters: layout: 待验证结果；environment: 输入环境；file: 调用文件；line: 调用行；无返回值。
    private func assertUnobstructed(_ layout: ReaderAdaptiveLayout, in environment: ReaderViewportEnvironment,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let insets = environment.safeAreaInsets
        let safe = CGRect(x: environment.bounds.minX + min(CGFloat(insets.left), environment.bounds.width),
                          y: environment.bounds.minY + min(CGFloat(insets.top), environment.bounds.height),
                          width: max(0, environment.bounds.width - CGFloat(insets.left) - CGFloat(insets.right)),
                          height: max(0, environment.bounds.height - CGFloat(insets.top) - CGFloat(insets.bottom)))
        let frames = pageFrames(layout) + (layout.auxiliaryFrame.map { [$0] } ?? [])
        for frame in [layout.contentFrame] + frames {
            XCTAssertTrue([frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite), file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.size.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.size.height, 0, file: file, line: line)
            guard !frame.isEmpty else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, safe.minX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, safe.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, safe.maxX, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, safe.maxY, file: file, line: line)
        }
        for frame in frames where !frame.isEmpty {
            for region in environment.regions where region.isActive {
                let overlap = frame.intersection(region.frame)
                XCTAssertTrue(overlap.isNull || overlap.isEmpty, "页面 \(frame) 覆盖区域 \(region.frame)", file: file, line: line)
            }
        }
    }
}
