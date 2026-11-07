import Foundation
import XCTest
@testable import BonePageTurnKit

final class ImmersiveReaderLayoutTests: XCTestCase {
    /// 使用 Duo 外屏隐藏系统栏后的实际采集值：右侧安全区仍为 84，具体遮挡只占顶部 82。
    func testHiddenDuoBarsExpandBelowCameraInsteadOfKeepingWholeColumn() throws {
        let camera = CGRect(x: 382, y: 0, width: 84, height: 82)
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 466, height: 678),
            safeAreaInsets: .init(bottom: 34, right: 84), widthClass: .compact,
            regions: [.init(kind: .occlusion, frame: camera),
                      .init(kind: .occlusion, frame: CGRect(x: 399.6666666666667, y: 29.333333333333332, width: 37, height: 37))])
        let standard = try ReaderAdaptiveLayoutPolicy().layout(for: environment)
        let immersive = try ReaderAdaptiveLayoutPolicy(horizontalSafeArea: .reservedRegions).layout(for: environment)
        XCTAssertEqual(standard.contentFrame, CGRect(x: 0, y: 0, width: 382, height: 644))
        XCTAssertEqual(immersive.contentFrame, CGRect(x: 0, y: 82, width: 466, height: 562))
        XCTAssertFalse(immersive.contentFrame.intersects(camera))
        XCTAssertEqual(immersive.pageLayout, .single)
        XCTAssertGreaterThan(immersive.contentFrame.width, standard.contentFrame.width)
        let restored = try ReaderAdaptiveLayoutPolicy(horizontalSafeArea: .system).layout(for: environment)
        XCTAssertEqual(restored, standard)
    }

    /// 没有摄像头遮挡时可以展开水平区域，但仍保留上下安全距离和非零坐标原点。
    func testExpansionRetainsTopAndBottomInsetsAndDoesNotMirrorPhysicalEdges() throws {
        let environment = ReaderViewportEnvironment(bounds: CGRect(x: 19, y: 27, width: 951, height: 669),
            safeAreaInsets: .init(top: 20, left: 84, bottom: 30), widthClass: .regular)
        let layout = try ReaderAdaptiveLayoutPolicy(horizontalSafeArea: .reservedRegions).layout(for: environment)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 19, y: 47, width: 951, height: 619))
        XCTAssertEqual(layout.pageLayout, .spread)
        let leftCamera = CGRect(x: 19, y: 27, width: 84, height: 82)
        let withCamera = ReaderViewportEnvironment(bounds: environment.bounds, safeAreaInsets: environment.safeAreaInsets,
            widthClass: .compact, regions: [.init(kind: .occlusion, frame: leftCamera)])
        let single = try ReaderAdaptiveLayoutPolicy(horizontalSafeArea: .reservedRegions).layout(for: withCamera)
        XCTAssertFalse(single.contentFrame.intersects(leftCamera))
        // 宽窗口中摄像头右侧的面积更大，保留真实物理右侧矩形，不按阅读顺序镜像。
        XCTAssertEqual(single.contentFrame.minX, leftCamera.maxX)
        XCTAssertEqual(single.contentFrame.width, 867)
        XCTAssertEqual(single.contentFrame.maxY, 666)
    }

    /// 横向安全区模式不能取消折痕避让；书本双页和 tabletop 上下区域仍保持在折痕两侧。
    func testExpandedContentStillAvoidsActiveBookAndTabletopDivisions() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bookFold = CGRect(x: 490, y: 0, width: 20, height: 800)
        let policy = ReaderAdaptiveLayoutPolicy(horizontalSafeArea: .reservedRegions)
        let book = try policy.layout(for: .init(bounds: bounds, safeAreaInsets: .init(top: 8, left: 32, bottom: 34, right: 84),
            widthClass: .regular, regions: [.init(kind: .division, frame: bookFold)]))
        XCTAssertEqual(book.pageLayout, .spread)
        XCTAssertEqual(book.contentFrame, CGRect(x: 0, y: 8, width: 1000, height: 758))
        XCTAssertEqual(book.spreadGap, 20)
        let pageWidth = (book.contentFrame.width - book.spreadGap) / 2
        XCTAssertFalse(CGRect(x: book.contentFrame.minX, y: book.contentFrame.minY, width: pageWidth, height: book.contentFrame.height).intersects(bookFold))
        XCTAssertFalse(CGRect(x: book.contentFrame.maxX - pageWidth, y: book.contentFrame.minY, width: pageWidth, height: book.contentFrame.height).intersects(bookFold))
        let tabletopFold = CGRect(x: 0, y: 390, width: 1000, height: 20)
        let tabletop = try policy.layout(for: .init(bounds: bounds, safeAreaInsets: .init(top: 8, bottom: 34, right: 84),
            widthClass: .regular, regions: [.init(kind: .division, frame: tabletopFold)]))
        XCTAssertEqual(tabletop.pageLayout, .single)
        XCTAssertEqual(tabletop.contentFrame, CGRect(x: 0, y: 8, width: 1000, height: 382))
        XCTAssertFalse(tabletop.contentFrame.intersects(tabletopFold))
        XCTAssertEqual(tabletop.auxiliaryFrame, CGRect(x: 0, y: 410, width: 1000, height: 356))
    }
}
