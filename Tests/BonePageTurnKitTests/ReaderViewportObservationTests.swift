#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderViewportObservationTests: XCTestCase {
    /// 确定性安全区和尺寸类别夹具；真实根视图保持 final，不向宿主开放区域模拟接口。
    private final class CaptureFixtureView: UIView {
        var testInsets = UIEdgeInsets.zero
        var testWidthClass = UIUserInterfaceSizeClass.unspecified
        override var safeAreaInsets: UIEdgeInsets { testInsets }
        override var traitCollection: UITraitCollection { UITraitCollection(horizontalSizeClass: testWidthClass) }
    }

    /// 无参数及返回值；布局、约束、安全区与 trait 的重复刷新只发送一次相同快照。
    func testObservationDeduplicatesAcrossUIKitCallbacks() {
        let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        var snapshots: [ReaderViewportEnvironment] = []
        view.onEnvironmentChange = { snapshots.append($0) }
        view.refreshEnvironment()
        view.refreshEnvironment()
        view.setNeedsUpdateConstraints()
        view.updateConstraintsIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.safeAreaInsetsDidChange()
        view.traitCollectionDidChange(nil)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(view.environment, snapshots.first)
        XCTAssertEqual(snapshots.first?.bounds, view.bounds)
    }

    /// 无参数及返回值；bounds 原点改变但宽高不变时仍会通知。
    func testBoundsOriginChangeWithSameSizeNotifies() {
        let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        var snapshots: [ReaderViewportEnvironment] = []
        view.onEnvironmentChange = { snapshots.append($0) }
        view.refreshEnvironment()
        view.bounds.origin = CGPoint(x: 17, y: 29)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.refreshEnvironment()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].bounds.size, snapshots[1].bounds.size)
        XCTAssertEqual(snapshots[1].bounds.origin, CGPoint(x: 17, y: 29))
    }

    /// 无参数及返回值；真实宿主附加安全区改变时，根视图在相同 bounds 下交付新环境。
    func testHostSafeAreaChangeWithUnchangedBoundsNotifies() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let host = UIViewController()
        let view = ReaderViewportView(frame: window.bounds)
        host.view = view
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        var snapshots: [ReaderViewportEnvironment] = []
        view.onEnvironmentChange = { snapshots.append($0) }
        host.additionalSafeAreaInsets = .init(top: 11, left: 17, bottom: 23, right: 37)
        window.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let first = try XCTUnwrap(view.environment)
        let previousCount = snapshots.count
        host.additionalSafeAreaInsets = .init(top: 11, left: 37, bottom: 23, right: 17)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let second = try XCTUnwrap(view.environment)
        XCTAssertEqual(first.bounds, second.bounds)
        XCTAssertEqual(second.safeAreaInsets.left - first.safeAreaInsets.left, 20, accuracy: 1e-9)
        XCTAssertEqual(second.safeAreaInsets.right - first.safeAreaInsets.right, -20, accuracy: 1e-9)
        XCTAssertGreaterThan(snapshots.count, previousCount)
        XCTAssertEqual(snapshots.last, second)
        XCTAssertNil(view.environmentOverride)
    }

    /// 无参数及返回值；静态采集读取视图自身的非零 bounds、安全区和尺寸类别。
    func testCaptureUsesViewBoundsSafeAreaAndSizeClass() {
        let view = CaptureFixtureView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        view.bounds.origin = CGPoint(x: 23, y: 31)
        view.testInsets = .init(top: 17, left: 29, bottom: 41, right: 53)
        view.testWidthClass = .regular
        let first = ReaderViewportEnvironment.capture(from: view)
        XCTAssertEqual(first.bounds, CGRect(x: 23, y: 31, width: 900, height: 700))
        XCTAssertEqual(first.safeAreaInsets, .init(top: 17, left: 29, bottom: 41, right: 53))
        XCTAssertEqual(first.widthClass, .regular)
        view.testInsets = .init(top: 17, left: 53, bottom: 41, right: 29)
        view.testWidthClass = .compact
        let second = ReaderViewportEnvironment.capture(from: view)
        XCTAssertEqual(first.bounds, second.bounds)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.safeAreaInsets, .init(top: 17, left: 53, bottom: 41, right: 29))
        XCTAssertEqual(second.widthClass, .compact)
        view.testWidthClass = .unspecified
        XCTAssertEqual(ReaderViewportEnvironment.capture(from: view).widthClass, .unspecified)
    }

    /// 无参数及返回值；同尺寸下安全区左右互换、区域活跃状态和尺寸类别变化均独立通知。
    func testSameSizeEnvironmentChangesAreObserved() {
        let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let bounds = view.bounds
        let crease = CGRect(x: 440, y: 0, width: 20, height: 700)
        let environments: [ReaderViewportEnvironment] = [
            .init(bounds: bounds, safeAreaInsets: .init(left: 17, right: 31), widthClass: .regular,
                  regions: [.init(kind: .division, frame: crease)]),
            .init(bounds: bounds, safeAreaInsets: .init(left: 31, right: 17), widthClass: .regular,
                  regions: [.init(kind: .division, frame: crease)]),
            .init(bounds: bounds, safeAreaInsets: .init(left: 31, right: 17), widthClass: .regular,
                  regions: [.init(kind: .division, frame: crease, isActive: false)]),
            .init(bounds: bounds, safeAreaInsets: .init(left: 31, right: 17), widthClass: .compact,
                  regions: [.init(kind: .division, frame: crease, isActive: false)])
        ]
        var snapshots: [ReaderViewportEnvironment] = []
        view.onEnvironmentChange = { snapshots.append($0) }
        for environment in environments {
            view.environmentOverride = environment
            view.refreshEnvironment()
        }
        XCTAssertEqual(snapshots, environments)
        XCTAssertEqual(view.environment, environments.last)
    }

    /// 无参数及返回值；清除模块内 override 后立即恢复真实视图环境。
    func testEnvironmentOverrideCanBeRemoved() {
        let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let actual = ReaderViewportEnvironment.capture(from: view)
        let override = ReaderViewportEnvironment(bounds: CGRect(x: 19, y: 27, width: 1200, height: 800), widthClass: .regular)
        var snapshots: [ReaderViewportEnvironment] = []
        view.onEnvironmentChange = { snapshots.append($0) }
        view.environmentOverride = override
        XCTAssertEqual(view.environment, override)
        view.environmentOverride = override
        XCTAssertEqual(snapshots.count, 1)
        view.environmentOverride = nil
        XCTAssertEqual(view.environment, actual)
        XCTAssertEqual(snapshots, [override, actual])
    }

    /// 无参数及返回值；回调修改环境并重入时不递归，下一次外部刷新交付最新值。
    func testCallbackReentrancyIsBoundedAndNextRefreshSeesMutation() {
        let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let first = ReaderViewportEnvironment(bounds: CGRect(x: 0, y: 0, width: 900, height: 700), widthClass: .regular)
        let second = ReaderViewportEnvironment(bounds: CGRect(x: 13, y: 29, width: 900, height: 700), widthClass: .regular)
        var snapshots: [ReaderViewportEnvironment] = []
        var depth = 0
        var maximumDepth = 0
        view.onEnvironmentChange = { [weak view] snapshot in
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            snapshots.append(snapshot)
            view?.environmentOverride = snapshot == first ? second : first
            view?.refreshEnvironment()
            depth -= 1
        }
        view.environmentOverride = first
        XCTAssertEqual(snapshots, [first])
        XCTAssertEqual(maximumDepth, 1)
        view.refreshEnvironment()
        XCTAssertEqual(snapshots, [first, second])
        XCTAssertEqual(view.environment, second)
        XCTAssertEqual(maximumDepth, 1)
    }

    /// 无参数及返回值；原生区域排序归一化，UIKit 枚举顺序变化不产生不同快照。
    func testNativeRegionOrderingIsCanonical() {
        let regions: [ReaderReservedRegion] = [
            .init(kind: .occlusion, frame: CGRect(x: 25, y: 31, width: 20, height: 20)),
            .init(kind: .division, frame: CGRect(x: 440, y: 0, width: 20, height: 700)),
            .init(kind: .division, frame: CGRect(x: 440, y: 0, width: 20, height: 700), isActive: false),
            .init(kind: .occlusion, frame: CGRect(x: 25, y: 5, width: 20, height: 20))
        ]
        let canonical = ReaderViewportEnvironment.orderedRegions(regions)
        XCTAssertEqual(canonical, ReaderViewportEnvironment.orderedRegions(regions.reversed()))
        XCTAssertEqual(canonical, ReaderViewportEnvironment.orderedRegions([regions[2], regions[0], regions[3], regions[1]]))
        XCTAssertEqual(canonical.first?.kind, .division)
        XCTAssertEqual(canonical.first?.isActive, false)
    }

    /// 无参数及返回值；观察不安装持有根视图的任务、通知闭包或对象环。
    func testViewportReleasesWithPendingConstraintAndLayoutUpdates() {
        weak var released: ReaderViewportView?
        autoreleasepool {
            let view = ReaderViewportView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
            released = view
            view.onEnvironmentChange = { [weak view] _ in view?.refreshEnvironment() }
            view.refreshEnvironment()
            view.setNeedsUpdateConstraints()
            view.setNeedsLayout()
        }
        XCTAssertNil(released)
    }
}
#endif
