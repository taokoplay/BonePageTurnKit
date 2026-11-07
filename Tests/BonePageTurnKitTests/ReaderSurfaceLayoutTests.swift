import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import BonePageTurnKit

final class ReaderSurfaceLayoutTests: XCTestCase {
    /// 无参数及返回值；三档运动范围只切换渲染区域，正文和装饰保留相同的小数坐标。
    func testMotionOnlyChangesRendererFrame() throws {
        let bounds = CGRect(x: -2.5, y: -10.75, width: 430.5, height: 800.25)
        let reading = CGRect(x: 13.5, y: 27.25, width: 350.5, height: 700.5)
        let metrics = ReaderSurfaceMetrics(headerHeight: 50.25, footerHeight: 30.5,
                                           headerGap: 7.75, footerGap: 11.25,
                                           bodyInsets: .init(top: 13.5, left: 17.25, bottom: 19.75, right: 23.5))
        let body = CGRect(x: 30.75, y: 98.75, width: 309.75, height: 567.5)
        for (motion, renderer) in [(ReaderSurfaceMotion.contentOnly, body),
                                   (.contentAndChrome, reading), (.wholePage, bounds)] {
            let layout = try metrics.layout(in: bounds, readingFrame: reading, motion: motion)
            XCTAssertEqual(layout.motion, motion)
            XCTAssertEqual(layout.rendererFrame, renderer)
            XCTAssertEqual(layout.bodyFrame, body)
            XCTAssertEqual(layout.headerFrame, CGRect(x: 13.5, y: 27.25, width: 350.5, height: 50.25))
            XCTAssertEqual(layout.footerFrame, CGRect(x: 13.5, y: 697.25, width: 350.5, height: 30.5))
            assertContained(layout, in: bounds, reading: reading)
        }
    }

    /// 无参数及返回值；正文只扣除一次实际装饰高度、对应间距和各边内边距。
    func testBodyConsumesEachMetricOnce() throws {
        let bounds = CGRect(x: 4, y: 8, width: 300, height: 400)
        let metrics = ReaderSurfaceMetrics(headerHeight: 20, footerHeight: 30, headerGap: 7, footerGap: 11,
                                           bodyInsets: .init(top: 2, left: 3, bottom: 5, right: 13))
        let layout = try metrics.layout(in: bounds)
        XCTAssertEqual(layout.headerFrame, CGRect(x: 4, y: 8, width: 300, height: 20))
        XCTAssertEqual(layout.footerFrame, CGRect(x: 4, y: 378, width: 300, height: 30))
        XCTAssertEqual(layout.bodyFrame, CGRect(x: 7, y: 37, width: 284, height: 325))
        XCTAssertEqual(layout.rendererFrame, layout.bodyFrame)
        assertContained(layout, in: bounds, reading: bounds)
    }

    /// 无参数及返回值；默认没有装饰槽位，正文及阅读区域保留完整的非零原点边界。
    func testDefaultsHaveNoDecorationSlots() throws {
        let bounds = CGRect(x: -31.25, y: 42.5, width: 321.75, height: 654.25)
        let metrics = ReaderSurfaceMetrics()
        XCTAssertEqual(metrics, ReaderSurfaceMetrics(headerHeight: 0, footerHeight: 0,
                                                     headerGap: 0, footerGap: 0, bodyInsets: .init()))
        try metrics.validate()
        let layout = try metrics.layout(in: bounds)
        XCTAssertNil(layout.headerFrame)
        XCTAssertNil(layout.footerFrame)
        XCTAssertEqual(layout.bodyFrame, bounds)
        XCTAssertEqual(layout.rendererFrame, bounds)
        XCTAssertEqual(layout.motion, .contentOnly)
        assertContained(layout, in: bounds, reading: bounds)
    }

    /// 无参数及返回值；零高度关闭对应槽位及其间距，另一侧的槽位仍正常布局。
    func testDisabledSlotsDoNotConsumeGaps() throws {
        let bounds = CGRect(x: 5, y: 7, width: 60, height: 100)
        let noSlots = try ReaderSurfaceMetrics(headerGap: .greatestFiniteMagnitude,
                                               footerGap: .greatestFiniteMagnitude).layout(in: bounds)
        XCTAssertNil(noSlots.headerFrame)
        XCTAssertNil(noSlots.footerFrame)
        XCTAssertEqual(noSlots.bodyFrame, bounds)

        let footerOnly = try ReaderSurfaceMetrics(footerHeight: 20, headerGap: .greatestFiniteMagnitude,
                                                  footerGap: 3).layout(in: bounds)
        XCTAssertNil(footerOnly.headerFrame)
        XCTAssertEqual(footerOnly.footerFrame, CGRect(x: 5, y: 87, width: 60, height: 20))
        XCTAssertEqual(footerOnly.bodyFrame, CGRect(x: 5, y: 7, width: 60, height: 77))

        let headerOnly = try ReaderSurfaceMetrics(headerHeight: 20, headerGap: 3,
                                                  footerGap: .greatestFiniteMagnitude).layout(in: bounds)
        XCTAssertNil(headerOnly.footerFrame)
        XCTAssertEqual(headerOnly.headerFrame, CGRect(x: 5, y: 7, width: 60, height: 20))
        XCTAssertEqual(headerOnly.bodyFrame, CGRect(x: 5, y: 30, width: 60, height: 77))
    }

    /// 无参数及返回值；宿主提供安全区后背景仍铺满边界，正文不重复扣除安全距离。
    func testHostReadingFrameKeepsFullBackground() throws {
        let bounds = CGRect(x: 17, y: 23, width: 390, height: 844)
        let reading = CGRect(x: 29, y: 82, width: 366, height: 751)
        for motion in [ReaderSurfaceMotion.contentOnly, .contentAndChrome, .wholePage] {
            let layout = try ReaderSurfaceMetrics().layout(in: bounds, readingFrame: reading, motion: motion)
            XCTAssertEqual(layout.backgroundFrame, bounds)
            XCTAssertEqual(layout.bodyFrame, reading)
            XCTAssertNil(layout.headerFrame)
            XCTAssertNil(layout.footerFrame)
            XCTAssertEqual(layout.rendererFrame, motion == .wholePage ? bounds : reading)
            assertContained(layout, in: bounds, reading: reading)
        }
    }

    /// 无参数及返回值；先保留页脚高度，再将两侧过大间距逐步钳制到剩余空间。
    func testDecorationHeightsTakePriorityOverGaps() throws {
        let bounds = CGRect(x: 5, y: 7, width: 3, height: 10)
        let layout = try ReaderSurfaceMetrics(headerHeight: 2, footerHeight: 3,
                                              headerGap: .greatestFiniteMagnitude,
                                              footerGap: .greatestFiniteMagnitude).layout(in: bounds)
        XCTAssertEqual(layout.headerFrame, CGRect(x: 5, y: 7, width: 3, height: 2))
        XCTAssertEqual(layout.footerFrame, CGRect(x: 5, y: 14, width: 3, height: 3))
        XCTAssertEqual(layout.bodyFrame, CGRect(x: 5, y: 14, width: 3, height: 0))
        assertContained(layout, in: bounds, reading: bounds)
    }

    /// 无参数及返回值；页眉优先分配，页脚高度只能消耗页眉之后的剩余高度。
    func testFooterIsClampedAfterHeader() throws {
        let bounds = CGRect(x: 4, y: 9, width: 20, height: 10)
        let layout = try ReaderSurfaceMetrics(headerHeight: 3, footerHeight: 20,
                                              headerGap: 100, footerGap: 100).layout(in: bounds)
        XCTAssertEqual(layout.headerFrame, CGRect(x: 4, y: 9, width: 20, height: 3))
        XCTAssertEqual(layout.footerFrame, CGRect(x: 4, y: 12, width: 20, height: 7))
        XCTAssertEqual(layout.bodyFrame, CGRect(x: 4, y: 12, width: 20, height: 0))
        assertContained(layout, in: bounds, reading: bounds)
    }

    /// 无参数及返回值；有限但极大的装饰和边距不会求和溢出，零高度页脚仍保留已启用槽位。
    func testTinyViewportWithMaximumMetrics() throws {
        let bounds = CGRect(x: -3.25, y: 11.5, width: 2.5, height: 3.75)
        let metrics = maximumMetrics()
        try metrics.validate()
        let layout = try metrics.layout(in: bounds)
        XCTAssertEqual(layout.headerFrame, bounds)
        XCTAssertEqual(layout.footerFrame, CGRect(x: -3.25, y: 15.25, width: 2.5, height: 0))
        XCTAssertEqual(layout.bodyFrame, CGRect(x: -0.75, y: 15.25, width: 0, height: 0))
        assertContained(layout, in: bounds, reading: bounds)
    }

    /// 无参数及返回值；上下左右分别钳制，已耗尽的轴保持合法原点，另一轴仍独立布局。
    func testBodyInsetsConsumeEachEdgeWithinAvailableSpace() throws {
        let bounds = CGRect(x: 5, y: 7, width: 10, height: 20)
        let cases: [(ReaderViewportInsets, CGRect)] = [
            (.init(top: 100, left: 100, bottom: 100, right: 100), CGRect(x: 15, y: 27, width: 0, height: 0)),
            (.init(bottom: 100, right: 100), CGRect(x: 5, y: 7, width: 0, height: 0)),
            (.init(top: 3, left: 4, bottom: 100, right: 100), CGRect(x: 9, y: 10, width: 0, height: 0)),
            (.init(left: 100), CGRect(x: 15, y: 7, width: 0, height: 20)),
            (.init(top: 100), CGRect(x: 5, y: 27, width: 10, height: 0))
        ]
        for (insets, expected) in cases {
            let layout = try ReaderSurfaceMetrics(bodyInsets: insets).layout(in: bounds)
            XCTAssertEqual(layout.bodyFrame, expected)
            assertContained(layout, in: bounds, reading: bounds)
        }
    }

    /// 无参数及返回值；空视口允许启用零高度槽位，不将槽位误判成关闭。
    func testEmptyBoundsPreserveEnabledSlots() throws {
        let bounds = CGRect(x: 3, y: -7, width: 0, height: 0)
        let layout = try maximumMetrics().layout(in: bounds)
        XCTAssertEqual(layout.headerFrame, bounds)
        XCTAssertEqual(layout.footerFrame, bounds)
        XCTAssertEqual(layout.bodyFrame, bounds)
        assertContained(layout, in: bounds, reading: bounds)
        let disabled = try ReaderSurfaceMetrics().layout(in: bounds)
        XCTAssertNil(disabled.headerFrame)
        XCTAssertNil(disabled.footerFrame)
    }

    /// 无参数及返回值；阅读区域可以退化为边界上的点或线，但其全部端点必须合法。
    func testZeroSizedReadingFramesOnEveryBoundaryAreAccepted() throws {
        let bounds = CGRect(x: -10, y: -20, width: 100, height: 200)
        let readings = [
            CGRect(x: -10, y: -20, width: 0, height: 0),
            CGRect(x: 90, y: -20, width: 0, height: 0),
            CGRect(x: -10, y: 180, width: 0, height: 0),
            CGRect(x: 90, y: 180, width: 0, height: 0),
            CGRect(x: 90, y: -20, width: 0, height: 200),
            CGRect(x: -10, y: 180, width: 100, height: 0), bounds
        ]
        for reading in readings {
            let layout = try ReaderSurfaceMetrics().layout(in: bounds, readingFrame: reading)
            XCTAssertEqual(layout.bodyFrame, reading)
            assertContained(layout, in: bounds, reading: reading)
        }
        XCTAssertEqual(try ReaderSurfaceMetrics().layout(in: .zero, readingFrame: .zero).bodyFrame, .zero)
    }

    /// 无参数及返回值；每一个指标都独立拒绝负值、NaN 和无穷大，包括已关闭槽位的间距。
    func testInvalidMetricsAreRejectedByValidationAndLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        for value in [Double(-1), .nan, .infinity, -.infinity] {
            let invalid = [
                ReaderSurfaceMetrics(headerHeight: CGFloat(value)),
                ReaderSurfaceMetrics(footerHeight: CGFloat(value)),
                ReaderSurfaceMetrics(headerGap: CGFloat(value)),
                ReaderSurfaceMetrics(footerGap: CGFloat(value)),
                ReaderSurfaceMetrics(bodyInsets: .init(top: value)),
                ReaderSurfaceMetrics(bodyInsets: .init(left: value)),
                ReaderSurfaceMetrics(bodyInsets: .init(bottom: value)),
                ReaderSurfaceMetrics(bodyInsets: .init(right: value))
            ]
            for metrics in invalid {
                XCTAssertThrowsError(try metrics.validate()) { error in
                    XCTAssertEqual(error as? ReaderSurfaceError, .invalidMetrics)
                }
                XCTAssertThrowsError(try metrics.layout(in: bounds)) { error in
                    XCTAssertEqual(error as? ReaderSurfaceError, .invalidMetrics)
                }
            }
        }
    }

    /// 无参数及返回值；无效原始尺寸、坐标、端点溢出和无限矩形哨兵均报告边界错误。
    func testInvalidBoundsAreRejected() {
        for bounds in invalidRectangles() {
            XCTAssertThrowsError(try ReaderSurfaceMetrics().layout(in: bounds)) { error in
                XCTAssertEqual(error as? ReaderSurfaceError, .invalidBounds)
            }
        }
    }

    /// 无参数及返回值；阅读区域使用相同的数值校验，并拒绝各方向越界及边界外的零尺寸点。
    func testInvalidOrUncontainedReadingFramesAreRejected() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 200)
        let outside = [
            CGRect(x: 9, y: 20, width: 1, height: 1),
            CGRect(x: 10, y: 19, width: 1, height: 1),
            CGRect(x: 10, y: 20, width: 101, height: 1),
            CGRect(x: 10, y: 20, width: 1, height: 201),
            CGRect(x: 111, y: 220, width: 0, height: 0),
            CGRect(x: 110, y: 221, width: 0, height: 0),
            CGRect(x: 9, y: 20, width: 0, height: 0),
            CGRect(x: 10, y: 19, width: 0, height: 0),
            CGRect(x: 110, y: 20, width: 0.5, height: 0),
            CGRect(x: 10, y: 220, width: 0, height: 0.5)
        ]
        for reading in invalidRectangles() + outside {
            XCTAssertThrowsError(try ReaderSurfaceMetrics().layout(in: bounds, readingFrame: reading)) { error in
                XCTAssertEqual(error as? ReaderSurfaceError, .invalidReadingFrame)
            }
        }
    }

    /// 无参数及返回值；有限最大尺寸、极大原点和次正规尺寸均不会生成非法端点。
    func testExtremeFiniteCoordinatesAndDimensions() throws {
        let maximum = CGFloat.greatestFiniteMagnitude
        let minimum = CGFloat.leastNonzeroMagnitude
        let boundsCases = [
            CGRect(x: 0, y: 0, width: maximum, height: maximum),
            CGRect(x: -maximum, y: -maximum, width: maximum, height: maximum),
            CGRect(x: maximum, y: maximum, width: 1, height: 1),
            CGRect(x: -maximum, y: -maximum, width: maximum.ulp / 4, height: maximum.ulp / 4),
            CGRect(x: minimum, y: -minimum, width: minimum, height: minimum),
            CGRect(x: -maximum / 2, y: -maximum / 4, width: maximum, height: maximum)
        ]
        for bounds in boundsCases {
            let unchanged = try ReaderSurfaceMetrics().layout(in: bounds)
            XCTAssertEqual(unchanged.bodyFrame, bounds)
            assertContained(unchanged, in: bounds, reading: bounds)
            let filled = try maximumMetrics().layout(in: bounds)
            XCTAssertNotNil(filled.headerFrame)
            XCTAssertNotNil(filled.footerFrame)
            assertContained(filled, in: bounds, reading: bounds)
        }
    }

    /// 无参数及返回值；跨不同指数的非零坐标及小数边距仍保持包含关系和装饰顺序。
    func testFloatingPointScalesKeepFramesContained() throws {
        let scales: [CGFloat] = [.leastNonzeroMagnitude, .leastNormalMagnitude, 1e-200, 1e-20,
                                 1, 1e20, 1e200, .greatestFiniteMagnitude / 32]
        for scale in scales {
            for offset in [CGFloat(-4), 0, 4] {
                let bounds = CGRect(x: offset * scale, y: offset * scale, width: 8 * scale, height: 12 * scale)
                let metrics = ReaderSurfaceMetrics(headerHeight: 3 * scale, footerHeight: 7 * scale,
                                                   headerGap: scale / 4, footerGap: scale / 3,
                                                   bodyInsets: .init(top: Double(scale / 5), left: Double(2 * scale),
                                                                     bottom: Double(scale / 7), right: Double(scale)))
                let layout = try metrics.layout(in: bounds)
                assertContained(layout, in: bounds, reading: bounds)
            }
        }
    }

    /// 无参数及返回值；固定种子的随机视口和指标不重叠、不越界，切换运动范围不改变任何内容坐标。
    func testDeterministicRandomLayoutsStayContainedAndStable() throws {
        var random = SurfaceRandom()
        for _ in 0..<600 {
            let bounds = CGRect(x: CGFloat(random.next(4000) - 2000) / 10,
                                y: CGFloat(random.next(4000) - 2000) / 10,
                                width: CGFloat(random.next(5000)) / 10,
                                height: CGFloat(random.next(9000)) / 10)
            let metrics = ReaderSurfaceMetrics(headerHeight: CGFloat(random.next(6000)) / 10,
                                               footerHeight: CGFloat(random.next(6000)) / 10,
                                               headerGap: CGFloat(random.next(2000)) / 10,
                                               footerGap: CGFloat(random.next(2000)) / 10,
                                               bodyInsets: .init(top: Double(random.next(3000)) / 10,
                                                                 left: Double(random.next(3000)) / 10,
                                                                 bottom: Double(random.next(3000)) / 10,
                                                                 right: Double(random.next(3000)) / 10))
            let base = try metrics.layout(in: bounds)
            for motion in [ReaderSurfaceMotion.contentOnly, .contentAndChrome, .wholePage] {
                let layout = try metrics.layout(in: bounds, motion: motion)
                XCTAssertEqual(layout.bodyFrame, base.bodyFrame)
                XCTAssertEqual(layout.headerFrame, base.headerFrame)
                XCTAssertEqual(layout.footerFrame, base.footerFrame)
                XCTAssertEqual(layout.rendererFrame, motion == .contentOnly ? layout.bodyFrame : bounds)
                assertContained(layout, in: bounds, reading: bounds)
            }
        }
    }

    /// 无参数及返回值；公开结果初始化器只保存各坐标系转换后的值，既不校验也不重算。
    func testPublicLayoutInitializerStoresValuesUnchanged() {
        let reading = CGRect(x: 9, y: 17, width: -3, height: -5)
        let renderer = CGRect(x: 30, y: 40, width: 50, height: 60)
        let body = CGRect(x: -10, y: -20, width: 7.5, height: 8.25)
        let header = CGRect(x: 1000, y: 2000, width: 10, height: 20)
        let layout = ReaderSurfaceLayout(backgroundFrame: .infinite, readingFrame: reading,
                                         rendererFrame: renderer, bodyFrame: body,
                                         headerFrame: header, footerFrame: nil, motion: .wholePage)
        XCTAssertEqual(layout.backgroundFrame, .infinite)
        XCTAssertEqual(layout.readingFrame, reading)
        XCTAssertEqual(layout.rendererFrame, renderer)
        XCTAssertEqual(layout.bodyFrame, body)
        XCTAssertEqual(layout.headerFrame, header)
        XCTAssertNil(layout.footerFrame)
        XCTAssertEqual(layout.motion, .wholePage)
        XCTAssertEqual(layout, ReaderSurfaceLayout(backgroundFrame: .infinite, readingFrame: reading,
                                                   rendererFrame: renderer, bodyFrame: body,
                                                   headerFrame: header, footerFrame: nil, motion: .wholePage))
    }
}

// MARK: - 测试辅助

private extension ReaderSurfaceLayoutTests {
    /// 无参数；返回每个指标均为对应类型最大有限值的配置，用于检查逐步钳制。
    func maximumMetrics() -> ReaderSurfaceMetrics {
        ReaderSurfaceMetrics(headerHeight: .greatestFiniteMagnitude, footerHeight: .greatestFiniteMagnitude,
                             headerGap: .greatestFiniteMagnitude, footerGap: .greatestFiniteMagnitude,
                             bodyInsets: .init(top: .greatestFiniteMagnitude, left: .greatestFiniteMagnitude,
                                               bottom: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude))
    }

    /// 无参数；返回各原始分量非法、端点溢出或为哨兵值的矩形集合。
    func invalidRectangles() -> [CGRect] {
        var frames: [CGRect] = [.null, .infinite,
                               CGRect(x: 0, y: 0, width: -1, height: 1),
                               CGRect(x: 0, y: 0, width: 1, height: -1)]
        for value in [CGFloat.nan, .infinity, -.infinity] {
            frames.append(CGRect(x: value, y: 0, width: 1, height: 1))
            frames.append(CGRect(x: 0, y: value, width: 1, height: 1))
            frames.append(CGRect(x: 0, y: 0, width: value, height: 1))
            frames.append(CGRect(x: 0, y: 0, width: 1, height: value))
        }
        frames.append(CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                             width: CGFloat.greatestFiniteMagnitude, height: 1))
        frames.append(CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude,
                             width: 1, height: CGFloat.greatestFiniteMagnitude))
        return frames
    }

    /// - Parameters: layout: 待检查布局；bounds: 完整背景边界；reading: 阅读边界；file: 调用文件；line: 调用行。
    /// 无返回值；检查背景、槽位、正文的有限性、包含关系和垂直顺序。
    func assertContained(_ layout: ReaderSurfaceLayout, in bounds: CGRect, reading: CGRect,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.backgroundFrame, bounds, file: file, line: line)
        XCTAssertEqual(layout.readingFrame, reading, file: file, line: line)
        assertRectangle(layout.bodyFrame, inside: reading, file: file, line: line)
        assertRectangle(layout.rendererFrame, inside: bounds, file: file, line: line)
        if let header = layout.headerFrame {
            assertRectangle(header, inside: reading, file: file, line: line)
            XCTAssertEqual(header.origin, reading.origin, file: file, line: line)
            XCTAssertEqual(header.width, reading.width, file: file, line: line)
            XCTAssertGreaterThanOrEqual(layout.bodyFrame.minY, header.maxY, file: file, line: line)
        }
        if let footer = layout.footerFrame {
            assertRectangle(footer, inside: reading, file: file, line: line)
            XCTAssertEqual(footer.minX, reading.minX, file: file, line: line)
            XCTAssertEqual(footer.width, reading.width, file: file, line: line)
            XCTAssertLessThanOrEqual(layout.bodyFrame.maxY, footer.minY, file: file, line: line)
        }
        if let header = layout.headerFrame, let footer = layout.footerFrame {
            XCTAssertLessThanOrEqual(header.maxY, footer.minY, file: file, line: line)
        }
    }

    /// - Parameters: frame: 待检查矩形；container: 包含它的边界；file: 调用文件；line: 调用行。
    /// 无返回值；以端点比较支持零尺寸矩形，并拒绝任何非有限数值或负尺寸。
    func assertRectangle(_ frame: CGRect, inside container: CGRect,
                         file: StaticString, line: UInt) {
        XCTAssertTrue([frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                       frame.origin.x + frame.size.width, frame.origin.y + frame.size.height]
            .allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertFalse(frame.isNull, file: file, line: line)
        XCTAssertFalse(frame.isInfinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.size.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.size.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, container.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, container.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, container.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, container.maxY, file: file, line: line)
    }
}

/// 固定种子的轻量随机数生成器；中间乘积位于 Int64 范围内，无需溢出运算。
private struct SurfaceRandom {
    private var state: Int64 = 20250308

    /// - Parameter upperBound: 非负结果的最大值。
    /// - Returns: 包含上下界的确定性伪随机整数。
    mutating func next(_ upperBound: Int) -> Int {
        state = state * 48271 % 2147483647
        return Int(state % Int64(upperBound + 1))
    }
}
