#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 系统仿真容器只承诺“按页切换”：页码收敛、越界拒绝、切换回调各触发一次。
@MainActor
final class SystemCurlReaderTests: XCTestCase {
    /// - Parameters:
    ///   - count: 总页数；
    ///   - initial: 初始页码。
    /// - Returns: 已挂载的真实容器与页码记录。
    private func makeReader(count: Int, initial: Int) -> (SystemCurlReaderViewController, () -> [Int]) {
        let reader = SystemCurlReaderViewController(pageCount: count, initialIndex: initial)
        var changes: [Int] = []
        reader.onPageChange = { changes.append($0) }
        reader.pageProvider = { index in
            let controller = UIViewController()
            controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            controller.view.backgroundColor = index % 2 == 0 ? .white : .systemTeal
            return controller
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader
        window.makeKeyAndVisible()
        addTeardownBlock { window.isHidden = true; window.rootViewController = nil }
        reader.view.frame = window.bounds
        reader.view.layoutIfNeeded()
        return (reader, { changes })
    }

    /// 无参数；初始页码超界时收敛到有效区间。无返回值。
    func testInitialIndexIsClamped() {
        let (reader, _) = makeReader(count: 3, initial: 99)
        XCTAssertEqual(reader.currentIndex, 2)
        XCTAssertEqual(reader.pageCount, 3)
        let (empty, _) = makeReader(count: 0, initial: 5)
        XCTAssertEqual(empty.currentIndex, 0)
    }

    /// 无参数；非动画切换立即生效并回调一次，越界与重复切换被拒绝。无返回值。
    func testProgrammaticTurnReportsOnceAndRejectsOutOfRange() {
        let (reader, changes) = makeReader(count: 3, initial: 0)
        XCTAssertTrue(reader.setCurrentIndex(1, animated: false))
        XCTAssertEqual(reader.currentIndex, 1)
        XCTAssertFalse(reader.setCurrentIndex(1, animated: false), "同一页不应重复切换")
        XCTAssertFalse(reader.setCurrentIndex(9, animated: false), "越界应拒绝")
        XCTAssertFalse(reader.setCurrentIndex(-1, animated: false), "负下标应拒绝")
        XCTAssertEqual(reader.currentIndex, 1)
        XCTAssertEqual(changes(), [1])
    }

    /// 无参数；页数收缩时页码收敛，不出现越界状态。无返回值。
    func testPageCountShrinkClampsIndex() {
        let (reader, _) = makeReader(count: 5, initial: 4)
        reader.setPageCount(2)
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertEqual(reader.currentIndex, 1)
        reader.setPageCount(0)
        XCTAssertEqual(reader.currentIndex, 0)
    }
}
#endif
