#if canImport(UIKit)
import UIKit
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

/// 使用公开触点接口、真实 containment 和实际 draw(_:) 验证二维卷页。
@MainActor
final class CornerCurlContainerTests: XCTestCase {
    private struct Raster {
        let width: Int
        let height: Int
        let bytes: Data

        /// - Parameters: primary: 轴向比例；cross: 横跨轴比例；axis: 翻页轴。
        /// - Returns: 固定 RGBA 排列中的 RGB 分量。
        func rgb(primary: CGFloat, cross: CGFloat, axis: PageTurnAxis) -> [UInt8] {
            let x = Int((axis == .horizontal ? primary : cross) * CGFloat(width))
            let y = Int((axis == .horizontal ? cross : primary) * CGFloat(height))
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<(offset + 3)])
        }

        /// - Parameters: other: 同尺寸的对照截图；tolerance: 单通道差异阈值。
        /// - Returns: 至少一个颜色通道发生可见变化的像素数，不依赖图片编码或哈希。
        func changedPixels(from other: Raster, tolerance: Int = 8) -> Int {
            guard width == other.width, height == other.height, bytes.count == other.bytes.count else {
                return max(width * height, other.width * other.height)
            }
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, offset in
                let changed = (0..<3).contains { abs(Int(bytes[offset + $0]) - Int(other.bytes[offset + $0])) > tolerance }
                return count + (changed ? 1 : 0)
            }
        }
    }

    // MARK: - 独立页面及真实绘图 fixture

    /// - Parameters: id: 页面身份；color: 固定底色；decorated: 是否添加可读文字和非对称标记。
    /// - Returns: 无异步加载且不依赖其他测试文件的真实页面。
    private func page(_ id: String, color: UIColor, decorated: Bool = true) -> PageContent {
        let controller = UIViewController()
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        controller.view.overrideUserInterfaceStyle = .light
        controller.view.backgroundColor = color
        if decorated {
            let label = UILabel(frame: CGRect(x: 20, y: 28, width: 270, height: 100))
            label.text = "\(id) → ABC 012\n二维纸角卷曲\n正文方向保持稳定"
            label.numberOfLines = 3
            label.font = .systemFont(ofSize: 18, weight: .medium)
            label.textColor = .black
            label.autoresizingMask = [.flexibleWidth]
            controller.view.addSubview(label)
            let illustration = UIView(frame: CGRect(x: 30, y: 180, width: 110, height: 110))
            illustration.backgroundColor = .systemOrange
            let inset = UIView(frame: CGRect(x: 15, y: 15, width: 35, height: 70))
            inset.backgroundColor = .systemPurple
            illustration.addSubview(inset)
            controller.view.addSubview(illustration)
            let marker = UIView(frame: CGRect(x: 292, y: 450, width: 16, height: 16))
            marker.backgroundColor = .black
            marker.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            controller.view.addSubview(marker)
        }
        return .init(identity: .init(sourceID: "corner-curl", unitID: id), controller: controller)
    }

    /// - Parameters: id: 单元身份；layout: 单双页；axis: 翻页轴；order: 内容顺序。
    /// - Returns: 符合容器布局契约的页面，双页包含两个真实子控制器。
    private func content(_ id: String, layout: ReaderPageLayout, axis: PageTurnAxis,
                         order: ReaderReadingOrder) throws -> PageContent {
        let color: UIColor = id == "current" ? .systemYellow : .systemTeal
        guard layout == .spread else { return page(id, color: color) }
        let spread = try PageSpreadViewController(first: page("\(id)-first", color: color),
            second: page("\(id)-second", color: id == "current" ? .systemOrange : .systemCyan),
            axis: axis, readingOrder: order)
        return .init(identity: .init(sourceID: "corner-curl", unitID: id), controller: spread)
    }

    /// - Parameters: layout: 单双页；axis: 翻页轴；order: 内容顺序；effect: 效果。
    /// - Returns: 手动推进收尾时钟的真实容器；Reduce Motion 环境明确跳过动画检查。
    private func reader(layout: ReaderPageLayout = .single, axis: PageTurnAxis = .horizontal,
                        order: ReaderReadingOrder = .leftToRight,
                        effect: PageTurnEffect = .curl) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "二维纸张测试要求关闭 Reduce Motion")
        let initial = try content("current", layout: layout, axis: axis, order: order)
        let result = try PagedReaderViewController(page: initial, configuration: .init(
            presentation: .paged(effect: effect, axis: axis),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64), layout: layout, readingOrder: order))
        result.usesDisplayLinkForPaperAnimation = false
        result.usesDisplayLinkForAutomaticReading = false
        result.loadViewIfNeeded()
        result.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        result.view.setNeedsLayout()
        result.view.layoutIfNeeded()
        return result
    }

    /// - Parameters: primary: 轴向坐标；cross: 横跨轴坐标；axis: 翻页轴。
    /// - Returns: 实际画布触点。
    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    /// - Parameters: axis: 翻页轴；order: 内容顺序；direction: 逻辑方向。
    /// - Returns: 自动书脊下的预期物理方向；由公开阅读语义独立给出。
    private func inwardSign(axis: PageTurnAxis, order: ReaderReadingOrder, direction: PageTurnDirection) -> CGFloat {
        switch (axis, order, direction) {
        case (.horizontal, .rightToLeft, .next): return 1
        case (.horizontal, .rightToLeft, .previous): return -1
        case (_, _, .next): return -1
        case (_, _, .previous): return 1
        }
    }

    /// - Parameter reader: 已进入收尾的容器。
    /// - Returns: 无返回值；推进一秒并额外检查过期 tick 不会重复交付终态。
    private func finishAnimation(_ reader: PagedReaderViewController) {
        for _ in 0..<10 { reader.advancePaperAnimation(elapsed: 0.1) }
    }

    /// - Parameter view: 真实纸张 overlay。
    /// - Returns: 实际 draw(_:) 的 1 倍率、标准色域截图。
    private func render(_ view: PaperTransitionView) -> UIImage {
        if view.usesMetalCornerRendering {
            do { return try XCTUnwrap(view.cornerGPUImage()) }
            catch { XCTFail("GPU 读回失败：\(error)"); return UIImage() }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
            view.draw(view.bounds)
        }
    }

    /// - Parameter image: 真实绘图输出。
    /// - Returns: 固定 sRGB / RGBA 像素副本，不使用未受保护的指针。
    private func raster(_ image: UIImage) throws -> Raster {
        let source = try XCTUnwrap(image.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let result = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(result.dataProvider?.data)
        return Raster(width: source.width, height: source.height, bytes: data as Data)
    }

    /// - Parameters: image: 待保留截图；name: 含纸角或布局信息的附件名称。
    /// - Returns: 无返回值；成功和失败运行都保留附件，供主代理查看。
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// - Parameters: events: 完整事件序列；completed: 是否提交；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；验证同一事务严格只有一个开始、可选提交和一个落定。
    private func assertEvents(_ events: [PageTransitionEvent], completed: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .willBegin(let transaction) = events.first else {
            return XCTFail("缺少事务开始", file: file, line: line)
        }
        let expected: [PageTransitionEvent] = completed
            ? [.willBegin(transaction), .didCommit(transaction), .didSettle(transaction, completed: true)]
            : [.willBegin(transaction), .didSettle(transaction, completed: false)]
        XCTAssertEqual(events, expected, file: file, line: line)
    }

    /// - Parameters: actual: 实际 RGB；expected: 页面底色；file: 调用文件；line: 调用行。
    /// - Returns: 无返回值；允许曲面阴影，但拒绝另一半页或错误快照的颜色。
    private func assertColor(_ actual: [UInt8], _ expected: [UInt8],
                             file: StaticString = #filePath, line: UInt = #line) {
        for component in 0..<3 {
            if expected[component] == 0 {
                XCTAssertLessThan(actual[component], 8, file: file, line: line)
            } else {
                XCTAssertGreaterThan(actual[component], 170, file: file, line: line)
            }
        }
    }

    /// - Parameters: target: 是否目标页；axis: 半页布局轴。
    /// - Returns: 当前红/绿、目标蓝/黄的无装饰整图，便于判断物理半页身份。
    private func coloredSpread(target: Bool, axis: PageTurnAxis) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.backgroundColor = .white
        view.overrideUserInterfaceStyle = .light
        let colors: [UIColor] = target ? [.blue, .yellow] : [.red, .green]
        for index in 0..<2 {
            let frame = axis == .horizontal
                ? CGRect(x: CGFloat(index) * 160, y: 0, width: 160, height: 480)
                : CGRect(x: 0, y: CGFloat(index) * 240, width: 320, height: 240)
            let half = UIView(frame: frame)
            half.backgroundColor = colors[index]
            view.addSubview(half)
        }
        view.layoutIfNeeded()
        return view
    }

    /// 无参数；初始控制点贴手，中部短拖过中线后应完成，且手指位移仍独立保留。无返回值。
    func testFingerContactBeginsAtTouchAndShortDragPastMidpointCompletes() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    let reader = try reader(axis: axis, order: order)
                    defer { reader.invalidate() }
                    let target = try content("target", layout: .single, axis: axis, order: order)
                    reader.pageProvider = { _, _ in .page(target) }
                    var events: [PageTransitionEvent] = []
                    reader.onTransition = { events.append($0) }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let crossExtent: CGFloat = axis == .horizontal ? 480 : 320
                    let origin = point(extent / 2, crossExtent / 2, axis: axis)
                    XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    let initial = try XCTUnwrap(paper.cornerDrag)
                    XCTAssertEqual(initial.gripPosition.x, origin.x, accuracy: 1e-6)
                    XCTAssertEqual(initial.gripPosition.y, origin.y, accuracy: 1e-6)
                    let sign = inwardSign(axis: axis, order: order, direction: direction)
                    let touch = point(extent / 2 + sign * extent * 0.02, crossExtent / 2 + 5, axis: axis)
                    reader.updateInteractiveTurn(to: touch)
                    let live = try XCTUnwrap(paper.cornerDrag)
                    XCTAssertEqual(live.gripPosition.x, touch.x, accuracy: 1e-6)
                    XCTAssertEqual(live.gripPosition.y, touch.y, accuracy: 1e-6)
                    XCTAssertGreaterThan(live.progress, 0.17, "纸面已经到达中线另一侧")
                    XCTAssertLessThan(live.gestureProgress, 0.17, "仍不能把初始折起程度混入手指移动距离")
                    reader.endInteractiveTurn(velocity: 0, animated: false)
                    XCTAssertEqual(reader.currentPage.identity.unitID, "target")
                    XCTAssertFalse(paper.hasResources)
                    assertEvents(events, completed: true)
                }
            }
        }
    }

    /// 无参数；从内部起拖且移动不足旧距离阈值，只要纸面越过画布中线，慢速松手也应完成。无返回值。
    func testSlowReleasePastMidpointCompletesFromInteriorTouch() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    let reader = try reader(axis: axis, order: order)
                    defer { reader.invalidate() }
                    reader.view.bounds.origin = CGPoint(x: 17, y: 23)
                    reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                    let target = try content("target", layout: .single, axis: axis, order: order)
                    reader.pageProvider = { _, _ in .page(target) }
                    var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let crossExtent: CGFloat = axis == .horizontal ? 480 : 320
                    let sign = inwardSign(axis: axis, order: order, direction: direction)
                    let localOrigin = point(extent * (sign < 0 ? 0.6 : 0.4), crossExtent / 2, axis: axis)
                    let origin = CGPoint(x: localOrigin.x + 17, y: localOrigin.y + 23)
                    XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                    let localTouch = point(extent * 0.5 + sign * extent * 0.01, crossExtent / 2, axis: axis)
                    reader.updateInteractiveTurn(to: CGPoint(x: localTouch.x + 17, y: localTouch.y + 23))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    let live = try XCTUnwrap(paper.cornerDrag)
                    XCTAssertGreaterThan(live.gestureProgress, 0)
                    XCTAssertLessThan(live.gestureProgress, 0.17, "夹具必须不能通过旧位移规则")
                    XCTAssertEqual(live.gripPosition.x, localTouch.x, accuracy: 1e-6)
                    XCTAssertEqual(live.gripPosition.y, localTouch.y, accuracy: 1e-6)
                    reader.endInteractiveTurn(velocity: 0, animated: false)
                    XCTAssertEqual(reader.currentPage.identity.unitID, "target", "纸面过半后的慢速松手应完成")
                    XCTAssertFalse(paper.hasResources)
                    assertEvents(events, completed: true)
                }
            }
        }
    }

    /// 触点中线分支保留；回翻目标页可先显露过半，静止按下仍不能触发翻页。
    func testSlowReleaseMidpointBoundaryAndNoMovement() throws {
        let cases: [(start: CGFloat, end: CGFloat, completed: Bool)] = [
            (0.4, 0.49, false), (0.4, 0.5, true), (0.4, 0.51, true), (0.6, 0.6, false)
        ]
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    for sample in cases {
                        let reader = try reader(axis: axis, order: order)
                        defer { reader.invalidate() }
                        let target = try content("target", layout: .single, axis: axis, order: order)
                        reader.pageProvider = { _, _ in .page(target) }
                        var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
                        let extent: CGFloat = axis == .horizontal ? 320 : 480
                        let cross: CGFloat = axis == .horizontal ? 240 : 160
                        let sign = inwardSign(axis: axis, order: order, direction: direction)
                        let start = extent * (sign < 0 ? 1 - sample.start : sample.start)
                        let end = extent * (sign < 0 ? 1 - sample.end : sample.end)
                        XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: point(start, cross, axis: axis)))
                        reader.updateInteractiveTurn(to: point(end, cross, axis: axis))
                        let paper = try XCTUnwrap(reader.activePaperView)
                        let live = try XCTUnwrap(paper.cornerDrag)
                        XCTAssertLessThan(live.gestureProgress, 0.17)
                        let completed = sample.completed || (direction == .previous && sample.end > sample.start)
                        reader.endInteractiveTurn(velocity: 0)
                        XCTAssertTrue(reader.isTransitioning)
                        finishAnimation(reader)
                        XCTAssertFalse(reader.isTransitioning)
                        XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
                        XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                        XCTAssertEqual(reader.children.count, 1)
                        XCTAssertFalse(paper.hasResources)
                        assertEvents(events, completed: completed)
                    }
                }
            }
        }
    }

    /// 无参数；半屏条件与原位移条件并列，快速反甩及非法速度仍优先取消，正向快甩仍可短拖完成。无返回值。
    func testMidpointReleaseKeepsFlingAndDistanceRules() throws {
        let cases: [(start: CGFloat, end: CGFloat, velocity: CGFloat, completed: Bool)] = [
            (0.4, 0.49, 500, true), (0.4, 0.51, -500, false),
            (0.4, 0.51, -499, true), (0.4, 0.51, .nan, false),
            (0.4, 0.51, .infinity, false), (0.02, 0.4, 0, true)
        ]
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    for sample in cases {
                        let reader = try reader(axis: axis, order: order)
                        defer { reader.invalidate() }
                        let target = try content("target", layout: .single, axis: axis, order: order)
                        reader.pageProvider = { _, _ in .page(target) }
                        var events: [PageTransitionEvent] = []; reader.onTransition = { events.append($0) }
                        let extent: CGFloat = axis == .horizontal ? 320 : 480
                        let cross: CGFloat = axis == .horizontal ? 240 : 160
                        let sign = inwardSign(axis: axis, order: order, direction: direction)
                        let start = extent * (sign < 0 ? 1 - sample.start : sample.start)
                        let end = extent * (sign < 0 ? 1 - sample.end : sample.end)
                        XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: point(start, cross, axis: axis)))
                        reader.updateInteractiveTurn(to: point(end, cross, axis: axis))
                        reader.endInteractiveTurn(velocity: sample.velocity, animated: false)
                        XCTAssertEqual(reader.currentPage.identity.unitID, sample.completed ? "target" : "current")
                        XCTAssertFalse(reader.isTransitioning)
                        assertEvents(events, completed: sample.completed)
                    }
                }
            }
        }
    }

    /// 无参数；首次贴手布局若被宿主页同步取消或失效，begin 必须返回 false 并清理本次事务。无返回值。
    func testInitialFingerLayoutReentryCannotReturnStartedAfterCancellation() throws {
        @MainActor
        final class ReentryView: UIView {
            var onFrame: (@MainActor () -> Void)?
            override var frame: CGRect { didSet { onFrame?() } }
        }
        for invalidate in [false, true] {
            let controller = UIViewController()
            let root = ReentryView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            root.backgroundColor = .systemYellow; controller.view = root
            let initial = PageContent(identity: .init(sourceID: "corner-curl", unitID: "current"), controller: controller)
            let reader = try PagedReaderViewController(page: initial, configuration: .init(
                presentation: .paged(effect: .curl, axis: .horizontal),
                paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
            reader.usesDisplayLinkForPaperAnimation = false
            reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            defer { root.onFrame = nil; reader.invalidate() }
            let target = try content("target", layout: .single, axis: .horizontal, order: .leftToRight)
            reader.pageProvider = { _, _ in .page(target) }
            var events: [PageTransitionEvent] = []
            reader.onTransition = { events.append($0) }
            var fired = false
            var captured: PaperTransitionView?
            root.onFrame = { [weak root, weak reader] in
                guard let root, let reader, root.isHidden else { return }
                root.onFrame = nil
                fired = true; captured = reader.activePaperView
                if invalidate { reader.invalidate() } else { reader.cancelTransition() }
            }
            XCTAssertFalse(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 160, y: 240)),
                "宿主已同步取消时，不能返回此前缓存的 started=true")
            XCTAssertTrue(fired)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertNil(reader.activePaperView)
            XCTAssertNil(target.controller.parent)
            XCTAssertFalse(try XCTUnwrap(captured).hasResources)
            assertEvents(events, completed: false)
        }
    }

    /// 无参数；触点卷页收尾小幅延长，短拖与完成仍准时落定，旧标量时序保持原样。无返回值。
    func testCornerReleaseIsSlightlySlowerWithoutChangingScalarTiming() throws {
        for completed in [false, true] {
            let reader = try reader(); defer { reader.invalidate() }
            let target = try content("target", layout: .single, axis: .horizontal, order: .leftToRight)
            reader.pageProvider = { _, _ in .page(target) }
            var events: [PageTransitionEvent] = []
            reader.onTransition = { events.append($0) }
            let origin = completed ? CGPoint(x: 300, y: 20) : CGPoint(x: 240, y: 240)
            XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: origin))
            reader.updateInteractiveTurn(to: completed ? CGPoint(x: 100, y: 130) : CGPoint(x: 230, y: 245))
            reader.endInteractiveTurn(velocity: 0)
            reader.advancePaperAnimation(elapsed: 0.1)
            if completed {
                reader.advancePaperAnimation(elapsed: 0.1)
                reader.advancePaperAnimation(elapsed: 0.1)
            } else { reader.advancePaperAnimation(elapsed: 0.03) }
            XCTAssertTrue(reader.isTransitioning, "比此前的快速收尾稍慢，不能提前结束")
            reader.advancePaperAnimation(elapsed: 0.1)
            XCTAssertFalse(reader.isTransitioning, "轻缓收尾不能变成长时间等待")
            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
            assertEvents(events, completed: completed)
        }
        let scalar = try reader(); defer { scalar.invalidate() }
        let target = try content("target", layout: .single, axis: .horizontal, order: .leftToRight)
        scalar.pageProvider = { _, _ in .page(target) }
        XCTAssertTrue(try scalar.beginInteractiveTurn(.next))
        scalar.updateInteractiveTurn(displacement: 160)
        scalar.endInteractiveTurn(velocity: 0)
        scalar.advancePaperAnimation(elapsed: 0.1); scalar.advancePaperAnimation(elapsed: 0.1)
        scalar.advancePaperAnimation(elapsed: 0.05)
        XCTAssertFalse(scalar.isTransitioning)
        XCTAssertEqual(scalar.currentPage.identity.unitID, "target")
    }

    // MARK: - 公开交互和生命周期

    /// 无参数；中部先直拖再转向时，公开触点与实际 GPU 纸面都跟随，过零换向保持连续。无返回值。
    func testMiddlePointDragTracksCrossAxisAndChangesRasterContinuously() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    let reader = try reader(axis: axis, order: order)
                    defer { reader.invalidate() }
                    let target = try content("target", layout: .single, axis: axis, order: order)
                    reader.pageProvider = { _, _ in .page(target) }
                    var events: [PageTransitionEvent] = []
                    reader.onTransition = { events.append($0) }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let crossExtent: CGFloat = axis == .horizontal ? 480 : 320
                    let sign = inwardSign(axis: axis, order: order, direction: direction)
                    let primaryOrigin = extent / 2
                    let origin = point(primaryOrigin, crossExtent / 2, axis: axis)
                    XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    let flat = try raster(render(paper))
                    reader.updateInteractiveTurn(to: point(primaryOrigin + sign * extent * 0.00001, crossExtent / 2 + extent * 0.00001, axis: axis))
                    let tiny = try raster(render(paper))
                    XCTAssertLessThan(tiny.changedPixels(from: flat), flat.width * flat.height / 100,
                        "贴手后极小移动不得突然改变大块纸面")
                    var rasters: [Raster] = []
                    let crossDisplacement = min(crossExtent / 4, extent * 0.1)
                    for (index, offset) in [CGFloat(0), crossDisplacement, -crossDisplacement, 0.01, -0.01].enumerated() {
                        reader.updateInteractiveTurn(to: point(primaryOrigin + sign * extent * 0.35, crossExtent / 2 + offset, axis: axis))
                        let drag = try XCTUnwrap(paper.cornerDrag)
                        XCTAssertEqual(drag.origin, origin)
                        XCTAssertEqual(axis == .horizontal ? drag.translation.y : drag.translation.x, offset, accuracy: 1e-6)
                        let image = render(paper); rasters.append(try raster(image))
                        if index < 3 {
                            attach(image, name: "middle-drag-\(axis)-\(order)-\(direction)-\(index)")
                        }
                    }
                    XCTAssertEqual(rasters.count, 5)
                    let straight = rasters[0], down = rasters[1], up = rasters[2]
                    XCTAssertGreaterThan(down.changedPixels(from: straight), straight.width * straight.height / 100)
                    XCTAssertGreaterThan(up.changedPixels(from: straight), straight.width * straight.height / 100)
                    XCTAssertGreaterThan(down.changedPixels(from: up), straight.width * straight.height / 100)
                    XCTAssertLessThan(rasters[3].changedPixels(from: rasters[4]), straight.width * straight.height / 50,
                        "中部换向通过零横移时不得突然跳成另一种整页形状")
                    reader.cancelTransition()
                    XCTAssertEqual(reader.currentPage.identity.unitID, "current")
                    XCTAssertFalse(paper.hasResources)
                    assertEvents(events, completed: false)
                }
            }
        }
    }


    /// 无参数；两轴、单双页、LTR/RTL 及 next/previous 均保持唯一 commit/settle 和真实 containment。无返回值。
    func testPublicPointMatrixCommitsAndCancelsExactlyOnce() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for layout in [ReaderPageLayout.single, .spread] {
                for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                    for direction in [PageTurnDirection.next, .previous] {
                        for completed in [false, true] {
                            let reader = try reader(layout: layout, axis: axis, order: order)
                            defer { reader.invalidate() }
                            let old = reader.currentPage.controller
                            let oldVisible = reader.visiblePageIdentities
                            let target = try content("target", layout: layout, axis: axis, order: order)
                            var requested: [PageTurnDirection] = []
                            reader.pageProvider = { _, value in requested.append(value); return .page(target) }
                            var events: [PageTransitionEvent] = []
                            reader.onTransition = { events.append($0) }
                            let extent = axis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height
                            let length = layout == .spread ? extent / 2 : extent
                            let sign = inwardSign(axis: axis, order: order, direction: direction)
                            let primary = sign < 0 ? extent - 12 : 12
                            let origin = point(primary, 20, axis: axis)
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                            let paper = try XCTUnwrap(reader.activePaperView)
                            let initial = try XCTUnwrap(paper.cornerDrag)
                            XCTAssertEqual(initial.corner, point(sign < 0 ? extent : 0, 0, axis: axis))
                            XCTAssertEqual(initial.length, length)
                            XCTAssertEqual(initial.page.width * initial.page.height,
                                           reader.view.bounds.width * reader.view.bounds.height / (layout == .spread ? 2 : 1))
                            XCTAssertEqual(requested, [direction])
                            XCTAssertEqual(reader.children.count, 2)
                            XCTAssertTrue(old.view.isHidden)
                            XCTAssertTrue(target.controller.view.isHidden)
                            XCTAssertTrue(paper.hasResources)
                            XCTAssertLessThanOrEqual(paper.snapshotPixelCount, 262_144)
                            reader.updateInteractiveTurn(to: point(primary + sign * length * 0.6, 90, axis: axis))
                            let live = try XCTUnwrap(paper.cornerDrag)
                            XCTAssertEqual(live.gestureProgress, 0.3, accuracy: 1e-9)
                            reader.endInteractiveTurn(velocity: completed ? 0 : -900)
                            XCTAssertEqual(paper.cornerDrag, live, "释放不能立即丢弃横轴偏移")
                            XCTAssertTrue(reader.isTransitioning)
                            finishAnimation(reader)
                            reader.endInteractiveTurn(velocity: 900)
                            reader.cancelTransition()
                            finishAnimation(reader)
                            assertEvents(events, completed: completed)
                            XCTAssertTrue(reader.currentPage.controller === (completed ? target.controller : old))
                            XCTAssertEqual(reader.children.count, 1)
                            XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                            XCTAssertNil((completed ? old : target.controller).parent)
                            XCTAssertEqual(reader.visiblePageIdentities.count, layout == .spread ? 2 : 1)
                            if !completed { XCTAssertEqual(reader.visiblePageIdentities, oldVisible) }
                            XCTAssertFalse(reader.isTransitioning)
                            XCTAssertNil(reader.activePaperView)
                            XCTAssertFalse(paper.hasResources)
                            XCTAssertEqual(paper.snapshotPixelCount, 0)
                            XCTAssertNil(paper.cornerDrag)
                            XCTAssertFalse(reader.isPaperClockRunning)
                        }
                    }
                }
            }
        }
    }

    /// 无参数；release 首帧保持实时截图，后续二维位置连续变化，过期触点和非法时钟输入被忽略。无返回值。
    func testReleasePreservesLiveRasterAndIgnoresLateInput() throws {
        for layout in [ReaderPageLayout.single, .spread] {
            for completed in [false, true] {
                let reader = try reader(layout: layout)
                defer { reader.invalidate() }
                let target = try content("target", layout: layout, axis: .horizontal, order: .leftToRight)
                reader.pageProvider = { _, _ in .page(target) }
                XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 300, y: 20)))
                reader.updateInteractiveTurn(to: CGPoint(x: 200, y: 150))
                let paper = try XCTUnwrap(reader.activePaperView)
                let live = try XCTUnwrap(paper.cornerDrag)
                let before = try raster(render(paper))
                reader.endInteractiveTurn(velocity: completed ? 900 : -900)
                XCTAssertEqual(paper.cornerDrag, live)
                XCTAssertEqual(try raster(render(paper)).changedPixels(from: before, tolerance: 0), 0)
                for elapsed in [0.0, -1, .nan, .infinity] { reader.advancePaperAnimation(elapsed: elapsed) }
                XCTAssertEqual(paper.cornerDrag, live)
                reader.advancePaperAnimation(elapsed: 0.0001)
                let released = try XCTUnwrap(paper.cornerDrag)
                XCTAssertGreaterThan(released.translation.y, 0)
                XCTAssertLessThan(released.translation.y, live.translation.y)
                XCTAssertLessThan(hypot(released.tip.x - live.tip.x, released.tip.y - live.tip.y), 2)
                reader.updateInteractiveTurn(to: CGPoint(x: -900, y: 470))
                reader.updateInteractiveTurn(displacement: 0)
                reader.endInteractiveTurn(velocity: completed ? -900 : 900)
                XCTAssertEqual(paper.cornerDrag, released)
                finishAnimation(reader)
                XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
                XCTAssertFalse(paper.hasResources)
            }
        }
    }

    /// 无参数；reader.view 的非零 bounds 原点被归一化，纸面控制点贴合归一化后的绝对触点。无返回值。
    func testPublicPointsNormalizeNonzeroBoundsAndTrackAbsoluteTouch() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let reader = try reader(axis: axis)
            defer { reader.invalidate() }
            reader.view.bounds.origin = CGPoint(x: 17, y: 23)
            reader.view.setNeedsLayout()
            reader.view.layoutIfNeeded()
            let target = try content("target", layout: .single, axis: axis, order: .leftToRight)
            reader.pageProvider = { _, _ in .page(target) }
            let local = axis == .horizontal ? CGPoint(x: 290, y: 30) : CGPoint(x: 30, y: 450)
            let origin = CGPoint(x: local.x + 17, y: local.y + 23)
            XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: origin))
            let paper = try XCTUnwrap(reader.activePaperView)
            XCTAssertEqual(paper.frame, reader.view.bounds)
            XCTAssertEqual(paper.cornerDrag?.origin, local)
            let offset = point(-140, 90, axis: axis)
            reader.updateInteractiveTurn(to: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
            let drag = try XCTUnwrap(paper.cornerDrag)
            let touch = CGPoint(x: local.x + offset.x, y: local.y + offset.y)
            XCTAssertEqual(drag.gripPosition, touch)
            XCTAssertEqual(drag.tip, touch)
            reader.cancelTransition()
            XCTAssertEqual(reader.currentPage.controller.view.frame, reader.view.bounds)
        }
    }

    /// 无参数；非法 begin 不请求邻页，非法 update 保留状态及像素，有限的页外移动正常钳制。无返回值。
    func testInvalidPointsDoNotMountPagesOrCorruptLiveFrame() throws {
        let reader = try reader()
        defer { reader.invalidate() }
        let target = try content("target", layout: .single, axis: .horizontal, order: .leftToRight)
        var requests = 0
        var events: [PageTransitionEvent] = []
        reader.pageProvider = { _, _ in requests += 1; return .page(target) }
        reader.onTransition = { events.append($0) }
        let invalidBegins = [CGPoint(x: -1, y: 20), CGPoint(x: 321, y: 20),
            CGPoint(x: 20, y: -1), CGPoint(x: 20, y: 481),
            CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity)]
        for origin in invalidBegins {
            XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: origin)) {
                XCTAssertEqual($0 as? PageTurnError, .invalidInteractionPoint)
            }
        }
        reader.updateInteractiveTurn(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(target.controller.parent)
        XCTAssertNil(reader.activePaperView)
        XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 300, y: 20)))
        reader.updateInteractiveTurn(to: CGPoint(x: 170, y: 120))
        let paper = try XCTUnwrap(reader.activePaperView)
        let live = try XCTUnwrap(paper.cornerDrag)
        let before = try raster(render(paper))
        for invalid: CGFloat in [.nan, .infinity, -.infinity] {
            reader.updateInteractiveTurn(to: CGPoint(x: invalid, y: 150))
            reader.updateInteractiveTurn(to: CGPoint(x: 150, y: invalid))
            XCTAssertEqual(paper.cornerDrag, live)
            XCTAssertEqual(try raster(render(paper)).changedPixels(from: before, tolerance: 0), 0)
        }
        XCTAssertThrowsError(try reader.beginInteractiveTurn(.previous, at: CGPoint(x: 20, y: 20))) {
            XCTAssertEqual($0 as? PageTurnError, .interactionInProgress)
        }
        XCTAssertEqual(requests, 1)
        reader.updateInteractiveTurn(to: CGPoint(x: -1e6, y: 1e6))
        let clamped = try XCTUnwrap(paper.cornerDrag)
        XCTAssertEqual(clamped.translation, CGPoint(x: -640, y: 0))
        XCTAssertEqual(clamped.progress, 1)
        reader.cancelTransition()
        reader.cancelTransition()
        assertEvents(events, completed: false)
    }

    /// 无参数；非纸张效果误用二维触点接口时，不请求或挂载目标。无返回值。
    func testPointAPIRejectsOtherEffectsBeforeRequestingContent() throws {
        for effect in [PageTurnEffect.none, .cover, .slide] {
            let reader = try reader(effect: effect)
            defer { reader.invalidate() }
            var requests = 0
            reader.pageProvider = { _, _ in requests += 1; return .waiting }
            XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 300, y: 20))) {
                XCTAssertEqual($0 as? PageTurnError, .unsupportedPresentation)
            }
            XCTAssertEqual(requests, 0)
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertNil(reader.activePaperView)
            XCTAssertEqual(reader.children.count, 1)
        }
    }

    /// 无参数；resize、暂停、失效及显式取消在拖动和 release 中都释放全部 snapshot 与图层资源。无返回值。
    func testInterruptionsReleaseCornerSnapshotsDuringDragAndRelease() throws {
        for layout in [ReaderPageLayout.single, .spread] {
            for releasing in [false, true] {
                for interruption in 0..<4 {
                    let reader = try reader(layout: layout)
                    defer { reader.invalidate() }
                    let old = reader.currentPage.controller
                    let target = try content("target", layout: layout, axis: .horizontal, order: .leftToRight)
                    reader.pageProvider = { _, _ in .page(target) }
                    var events: [PageTransitionEvent] = []
                    reader.onTransition = { events.append($0) }
                    XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: CGPoint(x: 300, y: 460)))
                    reader.updateInteractiveTurn(to: CGPoint(x: 180, y: 310))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    XCTAssertTrue(paper.hasResources)
                    XCTAssertGreaterThan(paper.snapshotPixelCount, 0)
                    paper.layer.contents = render(paper).cgImage
                    if releasing { reader.endInteractiveTurn(velocity: 900) }
                    switch interruption {
                    case 0:
                        reader.view.frame.size.width = 400
                        reader.view.setNeedsLayout()
                        reader.view.layoutIfNeeded()
                    case 1: reader.setSuspended(true, reason: "纸角测试")
                    case 2: reader.invalidate()
                    default: reader.cancelTransition()
                    }
                    finishAnimation(reader)
                    reader.cancelTransition()
                    assertEvents(events, completed: false)
                    XCTAssertTrue(reader.currentPage.controller === old)
                    XCTAssertFalse(old.view.isHidden)
                    XCTAssertNil(target.controller.parent)
                    XCTAssertNil(target.controller.view.superview)
                    XCTAssertEqual(reader.children.count, 1)
                    XCTAssertNil(reader.activePaperView)
                    XCTAssertNil(paper.superview)
                    XCTAssertNil(paper.cornerDrag)
                    XCTAssertNil(paper.layer.contents)
                    XCTAssertFalse(paper.hasResources)
                    XCTAssertEqual(paper.snapshotPixelCount, 0)
                    XCTAssertEqual(paper.stripCount, 0)
                    XCTAssertFalse(reader.isPaperClockRunning)
                }
            }
        }
    }

    /// 无参数；旧标量 begin/update 保持原阈值和效果，触点事务结束后也不会残留二维状态。无返回值。
    func testLegacyScalarAPIKeepsThresholdAndHasNoCornerState() throws {
        for effect in [PageTurnEffect.curl, .arch] {
            for axis in [PageTurnAxis.horizontal, .vertical] {
                for layout in [ReaderPageLayout.single, .spread] {
                    for direction in [PageTurnDirection.next, .previous] {
                        let reader = try reader(layout: layout, axis: axis, effect: effect)
                        defer { reader.invalidate() }
                        let target = try content("target", layout: layout, axis: axis, order: .leftToRight)
                        reader.pageProvider = { _, _ in .page(target) }
                        if effect == .curl {
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: CGPoint(x: 40, y: 40)))
                            reader.updateInteractiveTurn(to: CGPoint(x: 100, y: 100))
                            reader.cancelTransition()
                        }
                        let extent = axis == .horizontal ? reader.view.bounds.width : reader.view.bounds.height
                        for completed in [false, true] {
                            var events: [PageTransitionEvent] = []
                            reader.onTransition = { events.append($0) }
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                            let paper = try XCTUnwrap(reader.activePaperView)
                            XCTAssertNil(paper.cornerDrag)
                            reader.updateInteractiveTurn(displacement: extent * (completed ? 0.18 : 0.16))
                            let before = try raster(render(paper))
                            reader.updateInteractiveTurn(to: CGPoint(x: -900, y: 900))
                            XCTAssertNil(paper.cornerDrag)
                            XCTAssertEqual(try raster(render(paper)).changedPixels(from: before, tolerance: 0), 0)
                            reader.endInteractiveTurn(velocity: 0, animated: false)
                            assertEvents(events, completed: completed)
                            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
                            XCTAssertFalse(paper.hasResources)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 真实栅格及附件

    /// 无参数；四个单页纸角留存截图，同主轴位移下上下角及不同横轴位移均产生实际像素差异。无返回值。
    func testFourSingleCornersAndDifferentCrossMovementsProduceDistinctRasters() throws {
        for direction in [PageTurnDirection.next, .previous] {
            var cornerImages: [Raster] = []
            for bottom in [false, true] {
                let reader = try reader()
                defer { reader.invalidate() }
                let target = try content("target", layout: .single, axis: .horizontal, order: .leftToRight)
                reader.pageProvider = { _, _ in .page(target) }
                let right = direction == .next
                let origin = CGPoint(x: right ? 300 : 20, y: bottom ? 460 : 20)
                let primary = origin.x + (right ? -180 : 180)
                XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                reader.updateInteractiveTurn(to: CGPoint(x: primary, y: origin.y + (bottom ? -45 : 45)))
                let paper = try XCTUnwrap(reader.activePaperView)
                let progress = try XCTUnwrap(paper.cornerDrag).progress
                let shallow = try raster(render(paper))
                reader.updateInteractiveTurn(to: CGPoint(x: primary, y: origin.y + (bottom ? -150 : 150)))
                XCTAssertEqual(paper.cornerDrag?.progress, progress)
                let image = render(paper)
                let diagonal = try raster(image)
                XCTAssertGreaterThan(diagonal.changedPixels(from: shallow), 500)
                cornerImages.append(diagonal)
                attach(image, name: "corner-curl-single-\(bottom ? "bottom" : "top")-\(right ? "right" : "left")")
                reader.cancelTransition()
            }
            let top = try XCTUnwrap(cornerImages.first)
            let bottom = try XCTUnwrap(cornerImages.last)
            XCTAssertGreaterThan(top.changedPixels(from: bottom), 1_000)
        }
    }

    /// 无参数；两轴和逻辑双方向均折起当前快照，原始起边露出目标页，远端保持当前页。无返回值。
    func testBothDirectionsPeelCurrentSnapshotFromTheirPhysicalEdge() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    let current = try XCTUnwrap(page("current", color: .red, decorated: false).controller.view)
                    let target = try XCTUnwrap(page("target", color: .blue, decorated: false).controller.view)
                    let spine: PageSpinePlacement = axis == .horizontal && order == .rightToLeft ? .maximum : .minimum
                    let paper = try PaperTransitionView(currentView: current, targetView: target,
                        effect: .curl, direction: direction, spine: spine, options: .standard,
                        axis: axis, readingOrder: order)
                    defer { paper.invalidateResources() }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let breadth: CGFloat = axis == .horizontal ? 480 : 320
                    let sign = inwardSign(axis: axis, order: order, direction: direction)
                    let origin = point(sign < 0 ? extent - 12 : 12, 12, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: axis, spread: false,
                        inwardSign: sign, origin: origin))
                    let live = try XCTUnwrap(seed.moved(to: point((sign < 0 ? extent - 12 : 12) + sign * extent * 0.45,
                        12 + breadth * 0.08, axis: axis)))
                    paper.update(progress: live.progress, cornerDrag: live)
                    let before = try raster(render(paper))
                    assertColor(before.rgb(primary: sign < 0 ? 0.05 : 0.95, cross: 0.5, axis: axis), [255, 0, 0])
                    assertColor(before.rgb(primary: sign < 0 ? 0.95 : 0.05, cross: 0.05, axis: axis), [0, 0, 255])
                    current.backgroundColor = .green
                    target.backgroundColor = .yellow
                    paper.update(progress: live.progress, cornerDrag: live)
                    XCTAssertEqual(try raster(render(paper)).changedPixels(from: before, tolerance: 0), 0,
                                   "拖动中必须复用已捕获的当前/目标快照")
                }
            }
        }
    }

    /// 直接检查可见移动面来自自身快照，底页不能染到纸面；回翻不再取对侧正翻作基准。
    func testSinglePageMovingFaceUsesItsOwnColorInBothDirections() throws {
        for direction in [PageTurnDirection.next, .previous] {
            let moving = try XCTUnwrap(page("moving", color: .red, decorated: false).controller.view)
            let under = try XCTUnwrap(page("under", color: .blue, decorated: false).controller.view)
            let paper = try PaperTransitionView(currentView: direction == .next ? moving : under,
                targetView: direction == .next ? under : moving,
                effect: .curl, direction: direction, spine: .minimum, options: .standard)
            defer { paper.invalidateResources() }
            let sign: CGFloat = direction == .next ? -1 : 1
            let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: .horizontal,
                spread: false, inwardSign: sign, origin: CGPoint(x: sign < 0 ? 300 : 20, y: 20)))
            let drag = try XCTUnwrap(seed.moved(to: CGPoint(x: sign < 0 ? 120 : 200, y: 170), direction: direction))
            paper.update(progress: drag.gestureProgress, cornerDrag: drag)
            let image = render(paper), pixels = try raster(image)
            let material = try XCTUnwrap(drag.foldingPresentation(direction: direction,
                size: paper.bounds.size, spread: false))
            let face = try XCTUnwrap(PaperCornerCurlGeometry.patches(for: material, stripCount: 64).last { $0.back })
            let points = face.projected
            let center = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let sample = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))
            XCTAssertTrue(paper.bounds.insetBy(dx: 2, dy: 2).contains(sample))
            assertColor(pixels.rgb(primary: sample.x / paper.bounds.width,
                cross: sample.y / paper.bounds.height, axis: .horizontal), [255, 0, 0])
            attach(image, name: "single-moving-face-\(direction)")
        }
    }

    /// 双页沿用原来的移动正面与对侧纸背采样，不受单页原生起折修正影响。
    func testSpreadRetainsOriginalFrontAndBackMapping() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    let moving = coloredSpread(target: false, axis: axis), under = coloredSpread(target: true, axis: axis)
                    let paper = try PaperTransitionView(currentView: direction == .next ? moving : under,
                        targetView: direction == .next ? under : moving, effect: .curl, direction: direction,
                        spine: .center, options: .standard, axis: axis, readingOrder: order)
                    defer { paper.invalidateResources() }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let sign = inwardSign(axis: axis, order: order, direction: direction)
                    let origin = point(sign < 0 ? extent - 12 : 12, 20, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: axis, spread: true,
                        inwardSign: sign, origin: origin))
                    func input(_ fold: PaperCornerDrag) throws -> PaperCornerDrag {
                        guard direction == .previous else { return fold }
                        let reflected = axis == .horizontal
                            ? CGPoint(x: paper.bounds.width - fold.origin.x, y: fold.origin.y)
                            : CGPoint(x: fold.origin.x, y: paper.bounds.height - fold.origin.y)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: axis, spread: true,
                            inwardSign: -fold.inwardSign, origin: reflected))
                        var result = try XCTUnwrap(seed.moved(to: seed.gripOrigin))
                        result.translation = CGPoint(x: fold.gripPosition.x - result.gripOrigin.x,
                            y: fold.gripPosition.y - result.gripOrigin.y)
                        return result
                    }
                    let primary = axis == .horizontal ? origin.x : origin.y
                    let early = try input(XCTUnwrap(seed.moved(to: point(primary + sign * extent * 0.15, 20, axis: axis))))
                    paper.update(progress: early.progress, cornerDrag: early)
                    let front = try raster(render(paper))
                    assertColor(front.rgb(primary: sign < 0 ? 0.6 : 0.4, cross: 0.65, axis: axis),
                        sign < 0 ? [0, 255, 0] : [255, 0, 0])
                    let late = try input(XCTUnwrap(seed.moved(to: point(primary + sign * extent * 0.75, 20, axis: axis))))
                    paper.update(progress: late.progress, cornerDrag: late)
                    let back = try raster(render(paper))
                    assertColor(back.rgb(primary: sign < 0 ? 0.05 : 0.95, cross: 0.65, axis: axis),
                        sign < 0 ? [255, 0, 0] : [0, 255, 0])
                    assertColor(back.rgb(primary: sign < 0 ? 0.95 : 0.05, cross: 0.65, axis: axis),
                        sign < 0 ? [255, 255, 0] : [0, 0, 255])
                    assertColor(back.rgb(primary: sign < 0 ? 0.43 : 0.57, cross: 0.65, axis: axis),
                        sign < 0 ? [0, 0, 255] : [255, 255, 0])
                }
            }
        }
    }

    /// 无参数；release 的取消/完成平铺帧应与捕获页面一致，不能在外边或书脊残留卷曲阴影。无返回值。
    func testReleasedFlatRastersMatchCapturedPagesWithoutResidualShadow() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for spread in [false, true] {
                for direction in [PageTurnDirection.next, .previous] {
                    let paper = try PaperTransitionView(currentView: coloredSpread(target: false, axis: axis),
                        targetView: coloredSpread(target: true, axis: axis), effect: .curl, direction: direction,
                        spine: spread ? .center : .minimum, options: .standard, axis: axis)
                    defer { paper.invalidateResources() }
                    let first = try raster(render(paper))
                    paper.update(progress: 1)
                    let last = try raster(render(paper))
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let sign: CGFloat = direction == .next ? -1 : 1
                    let origin = point(sign < 0 ? extent - 12 : 12, 20, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: paper.bounds.size, axis: axis, spread: spread,
                        inwardSign: sign, origin: origin))
                    let primary = axis == .horizontal ? origin.x : origin.y
                    let live = try XCTUnwrap(seed.moved(to: point(primary + sign * seed.length * 0.6, 100, axis: axis)))
                    for completed in [false, true] {
                        let end = live.released(completed: completed, fraction: 1, direction: direction)
                        paper.update(progress: end.progress, cornerDrag: end)
                        let image = render(paper)
                        let differences = try raster(image).changedPixels(from: completed ? last : first, tolerance: 1)
                        XCTAssertEqual(differences, 0, "平铺终帧不应残留阴影：\(axis)-spread=\(spread)-\(direction)-completed=\(completed)")
                        if differences > 0 {
                            attach(image, name: "corner-curl-flat-endpoint-\(axis)-spread-\(spread)-\(direction)-\(completed)")
                        }
                    }
                }
            }
        }
    }
}
#endif
