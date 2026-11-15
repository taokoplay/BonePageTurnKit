import XCTest
@testable import BonePageTurnKit

final class CoverRenderingOptionsTests: XCTestCase {
    /// 旧初始化方式保持可用，标准配置完全关闭新增外观。
    func testStandardAndSourceCompatibleConfiguration() throws {
        let configuration = PageTurnConfiguration(presentation: .paged(effect: .cover, axis: .horizontal))
        XCTAssertEqual(configuration.cover, .standard)
        XCTAssertEqual(configuration.cover, CoverRenderingOptions())
        XCTAssertFalse(configuration.cover.isEnabled)
        XCTAssertNoThrow(try configuration.validate())
        XCTAssertNoThrow(try CoverRenderingOptions(cornerRadius: 50, shadowOpacity: 1, shadowRadius: 50,
                                                  shadowOffsetX: -12, shadowOffsetY: -8).validate())
    }

    /// 非有限数、负半径和越界透明度按字段报告独立错误，配置安装也执行相同校验。
    func testInvalidOptionsAreRejectedWithoutClamping() {
        var cases: [(CoverRenderingOptions, CoverRenderingError)] = []
        for value in [-1.0, .nan, .infinity, -.infinity] {
            cases.append((.init(cornerRadius: value), .invalidCornerRadius))
            cases.append((.init(shadowRadius: value), .invalidShadowRadius))
        }
        for value in [-0.1, 1.1, Double.nan, .infinity, -.infinity] {
            cases.append((.init(shadowOpacity: value), .invalidShadowOpacity))
        }
        for value in [Double.nan, .infinity, -.infinity] {
            cases.append((.init(shadowOffsetX: value), .invalidShadowOffset))
            cases.append((.init(shadowOffsetY: value), .invalidShadowOffset))
        }
        for (options, expected) in cases {
            XCTAssertThrowsError(try options.validate()) { XCTAssertEqual($0 as? CoverRenderingError, expected) }
            let configuration = PageTurnConfiguration(presentation: .paged(effect: .cover, axis: .horizontal), cover: options)
            XCTAssertThrowsError(try configuration.validate()) { XCTAssertEqual($0 as? CoverRenderingError, expected) }
        }
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class CoverDecorationTests: XCTestCase {
    private let decorated = CoverRenderingOptions(cornerRadius: 50, shadowOpacity: 0.4, shadowRadius: 24,
                                                  shadowOffsetX: 20, shadowOffsetY: -3)
    private let viewport = CGRect(x: 17, y: 31, width: 320, height: 480)

    private final class InsertHookView: UIView {
        var onAdd: ((UIView) -> Void)?
        var onRemove: ((UIView) -> Void)?

        /// - Parameter subview: 刚插入的视图；模拟宿主同步回调。
        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            onAdd?(subview)
        }

        /// - Parameter subview: 即将移除的视图；模拟清理阶段的宿主同步回调。
        override func willRemoveSubview(_ subview: UIView) {
            super.willRemoveSubview(subview)
            onRemove?(subview)
        }
    }

    private final class HookPage: UIViewController {
        var onAttach: (() -> Void)?

        /// - Parameter parent: 新父控制器；回调只消费一次，允许转交另一个容器。
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil, let action = onAttach { onAttach = nil; action() }
        }
    }

    /// - Parameters: name: 单元标识；controller: 可选同步回调页面；version: 内容与排版版本。
    /// - Returns: 带宿主自定义 layer 样式和真实按钮的页面。
    private func page(_ name: String, controller: UIViewController? = nil, version: UInt64 = 0) -> PageContent {
        let controller = controller ?? UIViewController()
        let root = UIView()
        root.backgroundColor = .white
        let button = UIButton(frame: CGRect(x: 90, y: 160, width: 120, height: 60))
        button.setTitle(name, for: .normal)
        root.addSubview(button)
        root.layer.cornerRadius = 7
        root.layer.masksToBounds = false
        root.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMaxYCorner]
        root.layer.cornerCurve = .continuous
        root.layer.shadowOpacity = 0.15
        root.layer.shadowRadius = 3
        root.layer.shadowOffset = CGSize(width: 2, height: 4)
        controller.view = root
        return .init(identity: .init(sourceID: "cover-book", unitID: name, contentVersion: version, layoutVersion: version),
                     controller: controller)
    }

    /// - Parameters: initial: 初始页；order: 内容顺序；options: 覆盖样式；effect: 待检验效果；root: 可选容器根视图。
    /// - Returns: 已按非零 bounds 原点完成初次布局的容器。
    private func reader(_ initial: PageContent, order: ReaderReadingOrder = .leftToRight,
                        options: CoverRenderingOptions? = nil, effect: PageTurnEffect = .cover,
                        root: UIView? = nil) throws -> PagedReaderViewController {
        let result = try PagedReaderViewController(page: initial, configuration: .init(
            presentation: .paged(effect: effect, axis: .horizontal), readingOrder: order, cover: options ?? decorated))
        if let root {
            // 手动注入根视图绕过了 loadView；显式执行一次容器初始化以挂载初始页。
            result.view = root
            result.viewDidLoad()
        }
        result.loadViewIfNeeded()
        result.view.frame = CGRect(origin: .zero, size: viewport.size)
        result.view.bounds = viewport
        result.view.setNeedsLayout()
        result.view.layoutIfNeeded()
        result.usesDisplayLinkForAutomaticReading = false
        result.usesDisplayLinkForPaperAnimation = false
        return result
    }

    /// - Parameters: page: 原始页面；file: 调用文件；line: 调用行。
    private func assertOriginalStyle(_ page: PageContent, file: StaticString = #filePath, line: UInt = #line) {
        let layer = page.controller.view.layer
        XCTAssertEqual(layer.cornerRadius, 7, file: file, line: line)
        XCTAssertFalse(layer.masksToBounds, file: file, line: line)
        XCTAssertEqual(layer.maskedCorners, [.layerMinXMinYCorner, .layerMaxXMaxYCorner], file: file, line: line)
        XCTAssertEqual(layer.cornerCurve, .continuous, file: file, line: line)
        XCTAssertEqual(layer.shadowOpacity, 0.15, file: file, line: line)
        XCTAssertEqual(layer.shadowRadius, 3, file: file, line: line)
        XCTAssertEqual(layer.shadowOffset, CGSize(width: 2, height: 4), file: file, line: line)
    }

    /// 两个方向、两种阅读顺序都装饰实际移动页，阴影始终夹在两页之间且同步移动、衰减。
    func testRealLayersGeometryStackingAndFadeForBothDirectionsAndOrders() throws {
        for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
            for direction in [PageTurnDirection.next, .previous] {
                let original = page("a")
                let target = page("b")
                let reader = try reader(original, order: order)
                defer { reader.invalidate() }
                reader.pageProvider = { _, _ in .page(target) }
                XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                let moving = direction == .next ? original : target
                let stationary = direction == .next ? target : original
                let shadow = try XCTUnwrap(reader.activeCoverDecoration?.shadowView)
                let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                XCTAssertEqual(moving.controller.view.layer.cornerRadius, 50)
                XCTAssertTrue(moving.controller.view.layer.masksToBounds)
                XCTAssertEqual(moving.controller.view.layer.maskedCorners, allCorners)
                XCTAssertEqual(moving.controller.view.layer.cornerCurve, .circular)
                assertOriginalStyle(stationary)
                XCTAssertEqual(shadow.layer.shadowOpacity, 0.4)
                XCTAssertEqual(shadow.layer.shadowRadius, 24)
                XCTAssertEqual(shadow.layer.shadowOffset, CGSize(width: order == .leftToRight ? 20 : -20, height: -3))
                XCTAssertFalse(shadow.layer.masksToBounds)
                XCTAssertNil(shadow.layer.contents)
                XCTAssertFalse(shadow.layer.shouldRasterize)
                XCTAssertFalse(shadow.isUserInteractionEnabled)
                XCTAssertNil(shadow.hitTest(CGPoint(x: 100, y: 100), with: nil))
                for fraction in [CGFloat(0), 0.25, 0.75, 1] {
                    reader.updateInteractiveTurn(displacement: viewport.width * fraction)
                    let sign: CGFloat = order == .leftToRight ? -1 : 1
                    let offset = sign * (direction == .next ? fraction : 1 - fraction) * viewport.width
                    XCTAssertEqual(moving.controller.view.frame, viewport.offsetBy(dx: offset, dy: 0))
                    XCTAssertEqual(stationary.controller.view.frame, viewport)
                    XCTAssertEqual(shadow.frame, moving.controller.view.frame)
                    XCTAssertEqual(shadow.alpha, 1 - fraction, accuracy: 0.001)
                    XCTAssertEqual(shadow.layer.shadowPath?.boundingBoxOfPath, shadow.bounds)
                    XCTAssertEqual(reader.view.subviews, [stationary.controller.view, shadow, moving.controller.view])
                    XCTAssertEqual(reader.children.count, 2)
                    XCTAssertTrue(reader.activeCoverDecoration?.shadowView === shadow)
                }
                reader.cancelTransition()
                XCTAssertNil(shadow.superview)
                XCTAssertNil(reader.activeCoverDecoration)
                assertOriginalStyle(original)
                assertOriginalStyle(target)
            }
        }
    }

    /// 默认 cover 及其他效果完全不安装装饰，不覆盖宿主原有样式。
    func testStandardAndOtherEffectsKeepHostLayersUntouched() throws {
        for effect in [PageTurnEffect.cover, .none, .slide, .curl, .arch] {
            let original = page("a")
            let target = page("b")
            let reader = try reader(original, options: effect == .cover ? .standard : decorated, effect: effect)
            defer { reader.invalidate() }
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            reader.updateInteractiveTurn(displacement: 120)
            XCTAssertNil(reader.activeCoverDecoration)
            assertOriginalStyle(original)
            assertOriginalStyle(target)
            if effect == .cover { XCTAssertEqual(reader.view.subviews.count, 2) }
            reader.cancelTransition()
        }
    }

    /// 圆角和阴影独立启用；宿主已有 mask、阴影及 rasterize 设置不被装饰覆盖。
    func testCornerOnlyAndShadowOnlyDoNotChangeUnrelatedProperties() throws {
        for cornerOnly in [false, true] {
            let original = page("a")
            let target = page("b")
            let mask = CALayer()
            original.controller.view.layer.mask = mask
            let reader = try reader(original, options: cornerOnly ? .init(cornerRadius: 30) : .init(shadowOpacity: 0.5))
            defer { reader.invalidate() }
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            XCTAssertTrue(original.controller.view.layer.mask === mask)
            XCTAssertEqual(original.controller.view.layer.shadowOpacity, 0.15)
            XCTAssertFalse(original.controller.view.layer.shouldRasterize)
            if cornerOnly {
                XCTAssertEqual(original.controller.view.layer.cornerRadius, 30)
                XCTAssertNil(reader.activeCoverDecoration?.shadowView)
                XCTAssertEqual(reader.view.subviews.count, 2)
            } else {
                assertOriginalStyle(original)
                XCTAssertNotNil(reader.activeCoverDecoration?.shadowView)
            }
            reader.cancelTransition()
            assertOriginalStyle(original)
            XCTAssertTrue(original.controller.view.layer.mask === mask)
        }
    }

    /// 成功、反向取消都在终态事件之前恢复真实页面，稳定页上的按钮继续命中。
    func testCompletionAndCancellationRestoreBeforeCallbacksAndPreserveHitTesting() throws {
        for direction in [PageTurnDirection.next, .previous] {
            for completed in [false, true] {
                let original = page("a")
                let target = page("b")
                let reader = try reader(original)
                defer { reader.invalidate() }
                var terminalEvents = 0
                reader.pageProvider = { _, _ in .page(target) }
                reader.onTransition = { [weak reader] event in
                    if case .willBegin = event { return }
                    terminalEvents += 1
                    XCTAssertNil(reader?.activeCoverDecoration)
                    self.assertOriginalStyle(original)
                    self.assertOriginalStyle(target)
                }
                XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                reader.updateInteractiveTurn(displacement: 160)
                reader.endInteractiveTurn(velocity: completed ? 600 : -600, animated: false)
                XCTAssertEqual(reader.currentPage.identity, completed ? target.identity : original.identity)
                XCTAssertEqual(terminalEvents, completed ? 2 : 1)
                XCTAssertEqual(reader.view.subviews.count, 1)
                let root = reader.currentPage.controller.view
                XCTAssertTrue(root?.hitTest(CGPoint(x: 120, y: 180), with: nil) is UIButton)
                reader.cancelTransition()
                XCTAssertEqual(terminalEvents, completed ? 2 : 1)
            }
        }
    }

    /// 取消、暂停、尺寸变化、退出、失效和后台通知都释放阴影并恢复原 layer。
    func testEveryInterruptionRestoresLayers() throws {
        for direction in [PageTurnDirection.next, .previous] {
            for operation in 0..<6 {
                let original = page("a")
                let target = page("b")
                let reader = try reader(original)
                defer { reader.invalidate() }
                reader.pageProvider = { _, _ in .page(target) }
                XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                reader.updateInteractiveTurn(displacement: 120)
                let shadow = try XCTUnwrap(reader.activeCoverDecoration?.shadowView)
                switch operation {
                case 0: reader.cancelTransition()
                case 1: reader.setSuspended(true, reason: "cover-test")
                case 2:
                    reader.view.bounds.size.width += 40
                    reader.view.setNeedsLayout()
                    reader.view.layoutIfNeeded()
                case 3: reader.viewWillDisappear(false)
                case 4: reader.invalidate()
                default: NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                }
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertNil(reader.activeCoverDecoration)
                XCTAssertNil(shadow.superview)
                XCTAssertEqual(reader.view.subviews, [original.controller.view])
                XCTAssertNil(target.controller.parent)
                assertOriginalStyle(original)
                assertOriginalStyle(target)
            }
        }
    }

    /// 已启动的 UIKit 收尾动画被取消后立即归还样式，迟到 completion 不得重新安装装饰。
    func testCancellationWhileReleaseAnimatorIsRunningRestoresLayers() throws {
        guard !UIAccessibility.isReduceMotionEnabled, UIView.areAnimationsEnabled else {
            throw XCTSkip("系统或测试环境关闭动画时会即时完成事务")
        }
        let original = page("a")
        let target = page("b")
        let reader = try reader(original)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = reader
        window.isHidden = false
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        defer {
            reader.invalidate()
            window.isHidden = true
            window.rootViewController = nil
        }
        reader.pageProvider = { _, _ in .page(target) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous))
        reader.updateInteractiveTurn(displacement: 120)
        let shadow = try XCTUnwrap(reader.activeCoverDecoration?.shadowView)
        reader.endInteractiveTurn(velocity: 600, animated: true)
        reader.cancelTransition()
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertNil(reader.activeCoverDecoration)
        XCTAssertNil(shadow.superview)
        XCTAssertEqual(reader.currentPage.identity, original.identity)
        assertOriginalStyle(original)
        assertOriginalStyle(target)
    }

    /// 页面回填在事务结束后安装，之后切换模式也不会携带旧圆角或阴影。
    func testPageReplacementAndModeSwitchDoNotCarryDecoration() throws {
        let original = page("a")
        let target = page("b")
        let replacement = page("a", version: 1)
        let reader = try reader(original)
        defer { reader.invalidate() }
        reader.pageProvider = { _, _ in .page(target) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 100)
        var installed = false
        _ = try reader.submitCurrentPage(replacement, expectedBinding: reader.currentPageBinding) { outcome in
            if case .installed = outcome { installed = true }
        }
        reader.cancelTransition()
        reader.installPendingCurrentPageIfIdle()
        XCTAssertTrue(installed)
        XCTAssertTrue(reader.currentPage.controller === replacement.controller)
        XCTAssertNil(reader.activeCoverDecoration)
        assertOriginalStyle(original)
        assertOriginalStyle(replacement)
        reader.invalidate()
        replacement.controller.willMove(toParent: nil)
        replacement.controller.view.removeFromSuperview()
        replacement.controller.removeFromParent()
        let slide = try self.reader(replacement, effect: .slide)
        defer { slide.invalidate() }
        XCTAssertNil(slide.activeCoverDecoration)
        XCTAssertEqual(slide.view.subviews, [replacement.controller.view])
        assertOriginalStyle(replacement)
    }

    /// willBegin 和阴影插入回调中同步取消／失效均不留下装饰或孤儿视图。
    func testReentrantCancellationDuringBeginAndDecorationInsertion() throws {
        for duringInsertion in [false, true] {
            for invalidates in [false, true] {
                let original = page("a")
                let target = page("b")
                let root = InsertHookView()
                let reader = try reader(original, root: root)
                defer { reader.invalidate() }
                reader.pageProvider = { _, _ in .page(target) }
                let interrupt: () -> Void = { [weak reader] in
                    if invalidates { reader?.invalidate() } else { reader?.cancelTransition() }
                }
                if duringInsertion {
                    root.onAdd = { [weak reader, weak root] inserted in
                        guard inserted === reader?.activeCoverDecoration?.shadowView else { return }
                        root?.onAdd = nil
                        interrupt()
                    }
                } else {
                    reader.onTransition = { if case .willBegin = $0 { interrupt() } }
                }
                XCTAssertFalse(try reader.beginInteractiveTurn(.next))
                XCTAssertNil(reader.activeCoverDecoration)
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertEqual(root.subviews, [original.controller.view])
                XCTAssertNil(target.controller.parent)
                assertOriginalStyle(original)
                assertOriginalStyle(target)
            }
        }
    }

    /// 阴影清理回调也不能重入新事务；目标此时被外部接管或 reader 失效不得继续提交。
    func testCleanupCallbacksCannotReenterOrCommitAnAdoptedTarget() throws {
        for invalidates in [false, true] {
            let original = page("a")
            let target = page("b")
            let external = UIViewController()
            let root = InsertHookView()
            let reader = try reader(original, root: root)
            defer { reader.invalidate() }
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            let shadow = try XCTUnwrap(reader.activeCoverDecoration?.shadowView)
            root.onRemove = { [weak reader, weak root] removed in
                guard removed === shadow, let reader else { return }
                root?.onRemove = nil
                do { _ = try reader.beginInteractiveTurn(.next); XCTFail("装饰清理回调不能重入翻页") }
                catch { XCTAssertEqual(error as? PageTurnError, .interactionInProgress) }
                if invalidates { reader.invalidate() }
                else { self.adopt(target, into: external) }
            }
            reader.endInteractiveTurn(velocity: 600, animated: false)
            XCTAssertNil(reader.activeCoverDecoration)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity, original.identity)
            XCTAssertNil(shadow.superview)
            assertOriginalStyle(original)
            if !invalidates { assertExternallyOwned(target, by: external) }
        }
    }

    /// - Parameters: page: 被转交的页面；owner: 外部容器。新样式用于检测清理是否误改外部所有权。
    private func adopt(_ page: PageContent, into owner: UIViewController) {
        let controller = page.controller
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        owner.addChild(controller)
        owner.view.addSubview(controller.view)
        controller.didMove(toParent: owner)
        controller.view.frame = CGRect(x: 12, y: 34, width: 123, height: 234)
        controller.view.isHidden = true
        controller.view.layer.cornerRadius = 91
        controller.view.layer.masksToBounds = false
        controller.view.layer.maskedCorners = [.layerMaxXMinYCorner]
        controller.view.layer.cornerCurve = .continuous
    }

    /// - Parameters: page: 外部页面；owner: 外部容器。
    private func assertExternallyOwned(_ page: PageContent, by owner: UIViewController) {
        XCTAssertTrue(page.controller.parent === owner)
        XCTAssertTrue(page.controller.view.superview === owner.view)
        XCTAssertEqual(page.controller.view.frame, CGRect(x: 12, y: 34, width: 123, height: 234))
        XCTAssertTrue(page.controller.view.isHidden)
        XCTAssertEqual(page.controller.view.layer.cornerRadius, 91)
        XCTAssertFalse(page.controller.view.layer.masksToBounds)
        XCTAssertEqual(page.controller.view.layer.maskedCorners, [.layerMaxXMinYCorner])
        XCTAssertEqual(page.controller.view.layer.cornerCurve, .continuous)
    }

    /// 目标在挂载回调中被接管时不安装装饰，也不把其视图重新移回 reader。
    func testTargetAdoptedDuringAttachmentRemainsUntouched() throws {
        let original = page("a")
        let controller = HookPage()
        let target = page("b", controller: controller)
        let reader = try reader(original)
        defer { reader.invalidate() }
        let external = UIViewController()
        controller.onAttach = { self.adopt(target, into: external) }
        reader.pageProvider = { _, _ in .page(target) }
        XCTAssertFalse(try reader.beginInteractiveTurn(.previous))
        XCTAssertNil(reader.activeCoverDecoration)
        XCTAssertEqual(reader.view.subviews, [original.controller.view])
        assertOriginalStyle(original)
        assertExternallyOwned(target, by: external)
    }

    /// 活动移动页被接管后立即取消；宿主新样式、几何及可见性不被恢复逻辑覆盖。
    func testExternalTakeoverDuringTransitionPreservesNewStylesAndPreventsCommit() throws {
        for direction in [PageTurnDirection.next, .previous] {
            for completesDirectly in [false, true] {
                let original = page("a")
                let target = page("b")
                let reader = try reader(original)
                defer { reader.invalidate() }
                reader.pageProvider = { _, _ in .page(target) }
                XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                reader.updateInteractiveTurn(displacement: 120)
                let shadow = try XCTUnwrap(reader.activeCoverDecoration?.shadowView)
                let external = UIViewController()
                let moved = direction == .next ? original : target
                adopt(moved, into: external)
                if completesDirectly { reader.endInteractiveTurn(velocity: 600, animated: false) }
                else { reader.updateInteractiveTurn(displacement: 200) }
                XCTAssertFalse(reader.isTransitioning)
                XCTAssertEqual(reader.currentPage.identity, original.identity)
                XCTAssertNil(reader.activeCoverDecoration)
                XCTAssertNil(shadow.superview)
                assertExternallyOwned(moved, by: external)
            }
        }
    }

    /// 外部仅取走目标根视图时，取消不能移除该外部视图；仍属于装饰的属性恢复原值。
    func testViewOnlyTakeoverRestoresOwnedStyleWithoutRemovingExternalView() throws {
        let original = page("a")
        let target = page("b")
        let reader = try reader(original)
        defer { reader.invalidate() }
        reader.pageProvider = { _, _ in .page(target) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous))
        let foreign = UIView()
        foreign.addSubview(target.controller.view)
        let frame = CGRect(x: 8, y: 9, width: 100, height: 120)
        target.controller.view.frame = frame
        reader.cancelTransition()
        XCTAssertTrue(target.controller.view.superview === foreign)
        XCTAssertEqual(target.controller.view.frame, frame)
        XCTAssertNil(target.controller.parent)
        assertOriginalStyle(target)
        XCTAssertNil(reader.activeCoverDecoration)
    }

    /// 快速成功和取消交替执行，活动时最多一个阴影，结束后只剩一个真实页面。
    func testRepeatedTurnsDoNotAccumulateDecoration() throws {
        let reader = try reader(page("initial"))
        defer { reader.invalidate() }
        for index in 0..<20 {
            let original = reader.currentPage
            let target = page("page-\(index)")
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(index.isMultiple(of: 2) ? .next : .previous))
            XCTAssertEqual(reader.view.subviews.count, 3)
            reader.updateInteractiveTurn(displacement: 160)
            reader.endInteractiveTurn(velocity: index.isMultiple(of: 3) ? -600 : 600, animated: false)
            XCTAssertNil(reader.activeCoverDecoration)
            XCTAssertEqual(reader.children.count, 1)
            XCTAssertEqual(reader.view.subviews.count, 1)
            assertOriginalStyle(original)
            assertOriginalStyle(target)
        }
    }

    /// helper 弱持有 reader 和页面；直接释放活动容器也恢复仍由宿主持有的真实页面。
    func testReaderAndDecorationReleaseWithoutExplicitInvalidation() throws {
        let original = page("a")
        let target = page("b")
        weak var weakReader: PagedReaderViewController?
        weak var weakDecoration: CoverTransitionDecoration?
        try autoreleasepool {
            let reader = try self.reader(original)
            weakReader = reader
            reader.pageProvider = { _, _ in .page(target) }
            XCTAssertTrue(try reader.beginInteractiveTurn(.next))
            weakDecoration = reader.activeCoverDecoration
        }
        XCTAssertNil(weakReader)
        XCTAssertNil(weakDecoration)
        assertOriginalStyle(original)
        assertOriginalStyle(target)
    }
}
#endif
