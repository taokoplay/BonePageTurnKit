import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import BonePageTurnKit

final class ReaderZoomGeometryTests: XCTestCase {
    /// 无参数；完整适配的最小、最大倍率保持相对关系，小内容两侧居中。
    func testAspectFitScaleAndCentering() throws {
        let geometry = try XCTUnwrap(ReaderZoomGeometry(contentSize: CGSize(width: 200, height: 400),
                                                        viewportSize: CGSize(width: 300, height: 300),
                                                        fitsWidth: false, maximumFactor: 4))
        XCTAssertEqual(geometry.minimumScale, 0.75)
        XCTAssertEqual(geometry.maximumScale, 3)
        XCTAssertEqual(geometry.padding(at: 0.75), CGPoint(x: 75, y: 0))
        XCTAssertEqual(geometry.offset(for: CGPoint(x: 0.5, y: 0.5), scale: 0.75), CGPoint(x: -75, y: 0))
        XCTAssertEqual(geometry.normalizedCenter(offset: CGPoint(x: -75, y: 0), scale: 0.75), CGPoint(x: 0.5, y: 0.5))
    }

    /// 无参数；宽度适配从顶部开始，长图在最小倍率仍有完整垂直滚动范围。
    func testWidthFitStartsAtTopAndScrollsAtMinimumScale() throws {
        let geometry = try XCTUnwrap(ReaderZoomGeometry(contentSize: CGSize(width: 600, height: 2400),
                                                        viewportSize: CGSize(width: 300, height: 400),
                                                        fitsWidth: true, maximumFactor: 4))
        XCTAssertEqual(geometry.minimumScale, 0.5)
        XCTAssertEqual(geometry.scaledSize(at: 0.5), CGSize(width: 300, height: 1200))
        XCTAssertEqual(geometry.offset(for: geometry.initialCenter(at: 0.5), scale: 0.5), .zero)
        XCTAssertEqual(geometry.offset(for: CGPoint(x: 0.5, y: 1), scale: 0.5).y, 800)
    }

    /// 无参数；尺寸改变后相对三倍缩放和归一化中心均可准确恢复。
    func testResizePreservesNormalizedCenterAndRelativeZoom() throws {
        let content = CGSize(width: 1200, height: 1600)
        let before = try XCTUnwrap(ReaderZoomGeometry(contentSize: content, viewportSize: CGSize(width: 300, height: 400),
                                                      fitsWidth: false, maximumFactor: 4))
        let after = try XCTUnwrap(ReaderZoomGeometry(contentSize: content, viewportSize: CGSize(width: 500, height: 300),
                                                     fitsWidth: false, maximumFactor: 4))
        let target = CGPoint(x: 0.6, y: 0.65)
        let originalOffset = before.offset(for: target, scale: before.minimumScale * 3)
        let center = before.normalizedCenter(offset: originalOffset, scale: before.minimumScale * 3)
        let restored = after.offset(for: center, scale: after.minimumScale * 3)
        let actual = after.normalizedCenter(offset: restored, scale: after.minimumScale * 3)
        XCTAssertEqual(actual.x, target.x, accuracy: 1e-12)
        XCTAssertEqual(actual.y, target.y, accuracy: 1e-12)
        XCTAssertNotEqual(before.minimumScale, after.minimumScale)
    }

    /// 无参数；边缘锚点受合法滚动范围钳制，缩小的内容持续居中。
    func testEdgesClampAndShortContentCenters() throws {
        let geometry = try XCTUnwrap(ReaderZoomGeometry(contentSize: CGSize(width: 200, height: 100),
                                                        viewportSize: CGSize(width: 300, height: 400),
                                                        fitsWidth: true, maximumFactor: 4))
        XCTAssertEqual(geometry.padding(at: 1.5), CGPoint(x: 0, y: 125))
        XCTAssertEqual(geometry.offset(for: .zero, scale: 1.5), CGPoint(x: 0, y: -125))
        XCTAssertEqual(geometry.offset(for: CGPoint(x: 1, y: 1), scale: 1.5), CGPoint(x: 0, y: -125))
        XCTAssertEqual(geometry.offset(for: .zero, scale: 6), .zero)
        XCTAssertEqual(geometry.offset(for: CGPoint(x: 1, y: 1), scale: 6), CGPoint(x: 900, y: 200))
    }

    /// 无参数；非有限和不合理尺寸、最大倍数被拒绝，已允许边界的计算保持有限。
    func testInvalidGeometryAndNumericBounds() throws {
        for value in [CGFloat.zero, -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude, 1e-10] {
            XCTAssertFalse(ReaderZoomGeometry.isValidSize(CGSize(width: value, height: 100)))
            XCTAssertNil(ReaderZoomGeometry(contentSize: CGSize(width: 100, height: 100),
                                             viewportSize: CGSize(width: 100, height: value),
                                             fitsWidth: false, maximumFactor: 4))
        }
        for factor in [CGFloat.zero, 0.5, -1, .nan, .infinity, 1e6 + 1] {
            XCTAssertFalse(ReaderZoomGeometry.isValidMaximumFactor(factor))
        }
        let geometry = try XCTUnwrap(ReaderZoomGeometry(contentSize: CGSize(width: 1e-9, height: 1e9),
                                                        viewportSize: CGSize(width: 1e9, height: 1e-9),
                                                        fitsWidth: true, maximumFactor: 1e6))
        XCTAssertTrue(geometry.maximumScale.isFinite)
        XCTAssertTrue(geometry.scaledSize(at: geometry.maximumScale).height.isFinite)
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class ReaderZoomContentTests: XCTestCase {
    private final class CallbackContent: UIViewController {
        var moves: [String] = []

        /// 创建真实标签视图，无参数及返回值。
        override func loadView() {
            let label = UILabel()
            label.text = "文字 →"
            view = label
        }

        /// - Parameter parent: 将要安装的父控制器；记录标准 containment 回调，无返回值。
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            moves.append(parent == nil ? "willRemove" : "willAdd")
        }

        /// - Parameter parent: 已安装的父控制器；同步请求布局以检查重入安全，无返回值。
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            moves.append(parent == nil ? "didRemove" : "didAdd")
            parent?.view.layoutIfNeeded()
        }
    }

    private final class AdoptingContent: UIViewController {
        weak var adopter: UIViewController?

        /// 加载视图时同步被另一个宿主接管，无参数及返回值。
        override func loadView() {
            view = UIView()
            if let adopter {
                adopter.addChild(self)
                adopter.view.addSubview(view)
                didMove(toParent: adopter)
            }
        }
    }

    /// - Parameters: controller: 待布局控制器；size: 容器可见尺寸。无返回值。
    private func layout(_ controller: UIViewController, size: CGSize = CGSize(width: 300, height: 400)) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    /// - Parameter reader: 已布局的缩放容器。
    /// - Returns: 以固定基准内容尺寸归一化的可见中心。
    private func normalizedCenter(_ reader: ReaderZoomViewController) -> CGPoint {
        let scroll = reader.scrollView
        return CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width,
                       y: (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height)
    }

    /// 无参数；真实内容具有标准父子关系，标签及文字方向保留，滚动 delegate 归容器所有。
    func testRealContentContainmentAndNativeGestures() throws {
        let child = CallbackContent()
        let reader = try ReaderZoomViewController(content: child, contentSize: CGSize(width: 600, height: 800))
        layout(reader)
        XCTAssertTrue(child.parent === reader)
        XCTAssertEqual(reader.children.count, 1)
        XCTAssertTrue(reader.contentController === child)
        XCTAssertEqual(child.moves, ["willAdd", "didAdd"])
        XCTAssertTrue(child.view.isDescendant(of: reader.scrollView))
        XCTAssertEqual((child.view as? UILabel)?.text, "文字 →")
        XCTAssertEqual(child.view.bounds.size, CGSize(width: 600, height: 800))
        XCTAssertEqual(child.view.transform, .identity)
        XCTAssertTrue(reader.scrollView.delegate === reader)
        XCTAssertNotNil(reader.scrollView.pinchGestureRecognizer)
        let doubleTaps = (reader.scrollView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        XCTAssertEqual(doubleTaps.filter { $0.numberOfTapsRequired == 2 }.count, 1)
        XCTAssertTrue(reader.viewForZooming(in: reader.scrollView) === child.view.superview)
    }

    /// 无参数；最小、最大倍率按适配计算，局部放大保留真实基准尺寸，reset 恢复适配。
    func testFitRelativeScaleLocalCenterAndReset() throws {
        let child = UIViewController()
        let reader = try ReaderZoomViewController(content: child, contentSize: CGSize(width: 1200, height: 1600))
        layout(reader)
        XCTAssertEqual(reader.scrollView.minimumZoomScale, 0.25, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.maximumZoomScale, 1, accuracy: 1e-6)
        try reader.setZoomFactor(3, centeredAt: CGPoint(x: 720, y: 1040))
        XCTAssertEqual(reader.zoomFactor, 3, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.zoomScale, 0.75, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).y, 0.65, accuracy: 1e-6)
        XCTAssertEqual(child.view.bounds.size, CGSize(width: 1200, height: 1600))
        XCTAssertEqual(child.view.transform, .identity)
        reader.resetZoom()
        XCTAssertEqual(reader.zoomFactor, 1, accuracy: 1e-6)
    }

    /// 无参数；宽度适配长图最小倍率从顶部显示，并可滚动至底部。
    func testWidthFitLongContentScrollsWithoutZooming() throws {
        let reader = try ReaderZoomViewController(content: UIViewController(), contentSize: CGSize(width: 600, height: 2400), fit: .width)
        layout(reader)
        XCTAssertEqual(reader.zoomFactor, 1, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.contentSize, CGSize(width: 300, height: 1200))
        XCTAssertEqual(reader.scrollView.contentOffset.y, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(reader.scrollView.contentSize.height, reader.scrollView.bounds.height)
        reader.scrollView.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 800, accuracy: 1e-6)
    }

    /// 无参数；小内容用对称 inset 居中，缩放后仍遵守可见区域边缘。
    func testShortContentCenters() throws {
        let reader = try ReaderZoomViewController(content: UIViewController(), contentSize: CGSize(width: 600, height: 200), fit: .width)
        layout(reader)
        XCTAssertEqual(reader.scrollView.contentInset.top, 150, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.contentInset.bottom, 150, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.contentOffset.y, -150, accuracy: 1e-6)
        try reader.setZoomFactor(2)
        XCTAssertEqual(reader.scrollView.contentInset.top, 100, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.contentOffset.y, -100, accuracy: 1e-6)
    }

    /// 无参数；改变窗口尺寸保留高倍率和阅读中心，不强制还原到一倍。
    func testResizePreservesZoomAndReadingCenter() throws {
        let reader = try ReaderZoomViewController(content: UIViewController(), contentSize: CGSize(width: 1200, height: 1600))
        layout(reader)
        try reader.setZoomFactor(3, centeredAt: CGPoint(x: 720, y: 1040))
        let before = normalizedCenter(reader)
        layout(reader, size: CGSize(width: 500, height: 300))
        XCTAssertEqual(reader.zoomFactor, 3, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).x, before.x, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).y, before.y, accuracy: 1e-6)
        layout(reader)
        XCTAssertEqual(reader.zoomFactor, 3, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).x, before.x, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).y, before.y, accuracy: 1e-6)
    }

    /// 无参数；首个有效布局前设置倍率和中心不会丢失。
    func testZoomRequestedBeforeLayout() throws {
        let reader = try ReaderZoomViewController(content: UIViewController(), contentSize: CGSize(width: 1200, height: 1600))
        try reader.setZoomFactor(3, centeredAt: CGPoint(x: 720, y: 1040))
        XCTAssertEqual(reader.zoomFactor, 3)
        layout(reader)
        XCTAssertEqual(reader.zoomFactor, 3, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalizedCenter(reader).y, 0.65, accuracy: 1e-6)
    }

    /// 无参数；非法初始化参数不挂载子控制器，非法缩放不改变现有内容状态。
    func testInvalidInputIsAtomic() throws {
        let child = UIViewController()
        for size in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: CGFloat.infinity, height: 100)] {
            XCTAssertThrowsError(try ReaderZoomViewController(content: child, contentSize: size)) {
                XCTAssertEqual($0 as? ReaderZoomError, .invalidContentSize)
            }
            XCTAssertNil(child.parent)
            XCTAssertFalse(child.isViewLoaded)
        }
        for factor in [CGFloat.zero, 0.5, .nan, .infinity] {
            XCTAssertThrowsError(try ReaderZoomViewController(content: child, contentSize: CGSize(width: 100, height: 100),
                                                              maximumZoomFactor: factor)) {
                XCTAssertEqual($0 as? ReaderZoomError, .invalidMaximumZoomFactor)
            }
            XCTAssertNil(child.parent)
        }
        let reader = try ReaderZoomViewController(content: child, contentSize: CGSize(width: 600, height: 800))
        layout(reader)
        try reader.setZoomFactor(2)
        let offset = reader.scrollView.contentOffset
        for factor in [CGFloat.zero, -1, 0.9, 4.1, .nan, .infinity] {
            XCTAssertThrowsError(try reader.setZoomFactor(factor)) { XCTAssertEqual($0 as? ReaderZoomError, .invalidZoomFactor) }
        }
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: -1, y: 0), CGPoint(x: 601, y: 0)] {
            XCTAssertThrowsError(try reader.setZoomFactor(3, centeredAt: point)) {
                XCTAssertEqual($0 as? ReaderZoomError, .invalidZoomCenter)
            }
        }
        XCTAssertEqual(reader.zoomFactor, 2, accuracy: 1e-6)
        XCTAssertEqual(reader.scrollView.contentOffset, offset)
    }

    /// 无参数；已有父控制器或已挂载根视图的内容不能被窃取。
    func testRejectsAlreadyOwnedContent() throws {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        child.didMove(toParent: parent)
        XCTAssertThrowsError(try ReaderZoomViewController(content: child, contentSize: CGSize(width: 100, height: 100))) {
            XCTAssertEqual($0 as? ReaderZoomError, .invalidContentController)
        }
        XCTAssertTrue(child.parent === parent)
        let attached = UIViewController()
        let host = UIView()
        host.addSubview(attached.view)
        XCTAssertThrowsError(try ReaderZoomViewController(content: attached, contentSize: CGSize(width: 100, height: 100)))
        XCTAssertTrue(attached.view.superview === host)
    }

    /// 无参数；同步加载回调接管内容时重新检查所有权，不把其留在失败容器中。
    func testSynchronousLoadCallbackCannotLeaveOrphan() {
        let adopter = UIViewController()
        let child = AdoptingContent()
        child.adopter = adopter
        XCTAssertThrowsError(try ReaderZoomViewController(content: child, contentSize: CGSize(width: 100, height: 100))) {
            XCTAssertEqual($0 as? ReaderZoomError, .invalidContentController)
        }
        XCTAssertTrue(child.parent === adopter)
        XCTAssertEqual(adopter.children.count, 1)
        XCTAssertTrue(child.view.superview === adopter.view)
    }

    /// 无参数；容器、滚动视图和画布均可释放，宿主持有的真实内容自动解除父子关系。
    func testWeakReleaseWithHostRetainingContent() throws {
        weak var weakReader: ReaderZoomViewController?
        weak var weakScroll: UIScrollView?
        weak var weakCanvas: UIView?
        weak var weakContent: UIViewController?
        var retainedContent: UIViewController? = UIViewController()
        try autoreleasepool {
            let child = try XCTUnwrap(retainedContent)
            let reader = try ReaderZoomViewController(content: child, contentSize: CGSize(width: 600, height: 800))
            layout(reader)
            try reader.setZoomFactor(2)
            weakReader = reader
            weakScroll = reader.scrollView
            weakCanvas = child.view.superview
            weakContent = child
        }
        XCTAssertNil(weakReader)
        XCTAssertNil(weakScroll)
        XCTAssertNil(weakCanvas)
        XCTAssertNil(retainedContent?.parent)
        XCTAssertNil(retainedContent?.viewIfLoaded?.superview)
        retainedContent = nil
        XCTAssertNil(weakContent)
    }
}
#endif
