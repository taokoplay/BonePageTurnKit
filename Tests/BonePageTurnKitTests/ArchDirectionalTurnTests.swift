#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// Arch 的二维输入、参考栅格与原生提交分别验收，避免离屏读回掩盖 follower 或收尾问题。
@MainActor
final class ArchDirectionalTurnTests: XCTestCase {
    private let axes: [PageTurnAxis] = [.horizontal, .vertical]
    private let directions: [PageTurnDirection] = [.next, .previous]
    private let orders: [ReaderReadingOrder] = [.leftToRight, .rightToLeft]

    private final class PanSample: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .possible
        var origin = CGPoint.zero
        var sampleTranslation = CGPoint.zero
        var sampleVelocity = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint {
            CGPoint(x: origin.x + sampleTranslation.x, y: origin.y + sampleTranslation.y)
        }
        override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
        override func velocity(in view: UIView?) -> CGPoint { sampleVelocity }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func rgb(x: Int, y: Int) -> [UInt8] {
            let offset = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
            return Array(bytes[offset..<(offset + 3)])
        }

        func changedFraction(from other: Raster, tolerance: Int = 12, rasterRadius: Int = 0) -> Double {
            guard width == other.width, height == other.height else { return 1 }
            var changed = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if (0..<3).contains(where: { abs(Int(bytes[offset + $0]) - Int(other.bytes[offset + $0])) > tolerance }) {
                    let x = (offset / 4) % width, y = (offset / 4) / width
                    let radius = min(1, max(0, rasterRadius))
                    var matches = false
                    if radius > 0 {
                        for yy in max(0, y - radius)...min(height - 1, y + radius) {
                            for xx in max(0, x - radius)...min(width - 1, x + radius) {
                                let candidate = (yy * width + xx) * 4
                                if (0..<3).allSatisfy({ abs(Int(bytes[offset + $0]) - Int(other.bytes[candidate + $0])) <= tolerance }) {
                                    matches = true
                                }
                            }
                        }
                    }
                    if !matches { changed += 1 }
                }
            }
            return Double(changed) / Double(width * height)
        }
    }

    private func size(_ axis: PageTurnAxis) -> CGSize {
        axis == .horizontal ? CGSize(width: 240, height: 360) : CGSize(width: 360, height: 240)
    }

    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    private func primary(_ point: CGPoint, axis: PageTurnAxis) -> CGFloat {
        axis == .horizontal ? point.x : point.y
    }

    private func cross(_ point: CGPoint, axis: PageTurnAxis) -> CGFloat {
        axis == .horizontal ? point.y : point.x
    }

    private func inwardSign(axis: PageTurnAxis, order: ReaderReadingOrder,
                            direction: PageTurnDirection) -> CGFloat {
        let forward: CGFloat = axis == .horizontal && order == .rightToLeft ? 1 : -1
        return direction == .next ? forward : -forward
    }

    private func spine(axis: PageTurnAxis, order: ReaderReadingOrder, spread: Bool) -> PageSpinePlacement {
        spread ? .center : (axis == .horizontal && order == .rightToLeft ? .maximum : .minimum)
    }

    private func options(for size: CGSize) -> PaperRenderingOptions {
        // 恰好容纳两张 1x 原图，端点比较不引入独立的快照缩放误差。
        .init(maximumSnapshotPixels: Int(size.width * size.height) * 2, stripCount: 64)
    }

    private func markerRects(in size: CGSize) -> [CGRect] {
        let width = size.width * 0.43 - 8
        return [CGRect(x: 10, y: 12, width: width, height: 28),
                CGRect(x: size.width * 0.55, y: size.height * 0.21, width: width, height: 28),
                CGRect(x: 10, y: size.height * 0.66, width: width, height: 28),
                CGRect(x: size.width * 0.55, y: size.height - 38, width: width, height: 28)]
    }

    private func fixture(_ title: String, target: Bool, size: CGSize,
                         axis: PageTurnAxis, spread: Bool) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = target
            ? UIColor(red: 0.78, green: 0.94, blue: 0.96, alpha: 1)
            : UIColor(red: 0.98, green: 0.91, blue: 0.77, alpha: 1)
        if spread {
            let half = UIView(frame: axis == .horizontal
                ? CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
                : CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            half.backgroundColor = target
                ? UIColor(red: 0.85, green: 0.80, blue: 0.97, alpha: 1)
                : UIColor(red: 0.79, green: 0.94, blue: 0.81, alpha: 1)
            view.addSubview(half)
        }
        let block = UIView(frame: CGRect(x: size.width * 0.16, y: size.height * 0.37,
                                         width: size.width * 0.21, height: size.height * 0.17))
        block.backgroundColor = target ? .blue : .red
        let inset = UIView(frame: CGRect(x: 3, y: 4, width: block.bounds.width * 0.3, height: block.bounds.height * 0.7))
        inset.backgroundColor = .yellow
        block.addSubview(inset)
        view.addSubview(block)
        for (index, rect) in markerRects(in: size).enumerated() {
            let label = UILabel(frame: rect)
            label.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
            label.textColor = .black
            label.text = "\(title)\(index) F→"
            view.addSubview(label)
        }
        view.layoutIfNeeded()
        return view
    }

    private func content(_ index: Int, axis: PageTurnAxis, layout: ReaderPageLayout,
                         order: ReaderReadingOrder) throws -> PageContent {
        func leaf(_ suffix: String, size: CGSize) -> PageContent {
            let controller = UIViewController()
            controller.view = fixture("\(index)\(suffix)", target: index != 6, size: size, axis: axis, spread: false)
            return .init(identity: .init(sourceID: "arch-directional", unitID: "\(index)\(suffix)"), controller: controller)
        }
        guard layout == .spread else { return leaf("", size: size(axis)) }
        let canvas = size(axis)
        let half = axis == .horizontal
            ? CGSize(width: canvas.width / 2, height: canvas.height)
            : CGSize(width: canvas.width, height: canvas.height / 2)
        let controller = try PageSpreadViewController(first: leaf("A", size: half), second: leaf("B", size: half),
                                                       axis: axis, readingOrder: order)
        return .init(identity: .init(sourceID: "arch-directional", unitID: String(index)), controller: controller)
    }

    private func reader(axis: PageTurnAxis, layout: ReaderPageLayout = .single,
                        order: ReaderReadingOrder = .leftToRight, effect: PageTurnEffect = .arch,
                        nativeClock: Bool = false) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "纸张交互回归要求关闭 Reduce Motion")
        let initial = try content(6, axis: axis, layout: layout, order: order)
        let next = try content(7, axis: axis, layout: layout, order: order)
        let previous = try content(5, axis: axis, layout: layout, order: order)
        let reader = try PagedReaderViewController(page: initial, configuration: .init(
            presentation: .paged(effect: effect, axis: axis), paper: options(for: size(axis)),
            layout: layout, readingOrder: order))
        reader.usesDisplayLinkForPaperAnimation = nativeClock
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { _, direction in .page(direction == .next ? next : previous) }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(origin: .zero, size: size(axis))
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return reader
    }

    private func capture(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
    }

    private func software(_ view: PaperTransitionView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in view.draw(view.bounds) }
    }

    private func raster(_ image: UIImage) throws -> Raster {
        let source = try XCTUnwrap(image.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let data = try XCTUnwrap(context.makeImage()?.dataProvider?.data)
        return Raster(width: source.width, height: source.height, bytes: [UInt8](data as Data))
    }

    private func assertMarkers(_ actual: Raster, match expected: Raster, size: CGSize, context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard actual.width == expected.width, actual.height == expected.height else {
            return XCTFail("\(context)：整图尺寸不同", file: file, line: line)
        }
        for rect in markerRects(in: size) {
            var ink = 0, hits = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where expected.rgb(x: x, y: y).allSatisfy({ $0 < 45 }) {
                    ink += 1
                    if actual.rgb(x: x, y: y).allSatisfy({ $0 < 90 }) { hits += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 15, "\(context)：参考文字夹具必须有实心笔画", file: file, line: line)
            XCTAssertGreaterThan(Double(hits) / Double(max(1, ink)), 0.9,
                                 "\(context)：文字标记缺失、倒置或采到了另一页", file: file, line: line)
        }
    }

    private func attachGallery(_ samples: [(String, UIImage)], name: String) {
        let bounded = Array(samples.prefix(16))
        guard !bounded.isEmpty else { return }
        let columns = 4, cell = CGSize(width: 180, height: 190)
        let rows = (bounded.count + columns - 1) / columns
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let gallery = UIGraphicsImageRenderer(size: CGSize(width: cell.width * CGFloat(columns),
            height: cell.height * CGFloat(rows)), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
            for (index, sample) in bounded.enumerated() {
                let x = CGFloat(index % columns) * cell.width, y = CGFloat(index / columns) * cell.height
                (sample.0 as NSString).draw(in: CGRect(x: x + 4, y: y + 2, width: cell.width - 8, height: 25),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
                let scale = min((cell.width - 8) / sample.1.size.width, (cell.height - 30) / sample.1.size.height)
                sample.1.draw(in: CGRect(x: x + 4, y: y + 28, width: sample.1.size.width * scale, height: sample.1.size.height * scale))
            }
        }
        let attachment = XCTAttachment(image: gallery)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertEvents(_ events: [PageTransitionEvent], completed: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .willBegin(let transaction) = events.first else {
            return XCTFail("缺少唯一的 willBegin", file: file, line: line)
        }
        let expected: [PageTransitionEvent] = completed
            ? [.willBegin(transaction), .didCommit(transaction), .didSettle(transaction, completed: true)]
            : [.willBegin(transaction), .didSettle(transaction, completed: false)]
        XCTAssertEqual(events, expected, file: file, line: line)
    }

    private func finish(_ reader: PagedReaderViewController) {
        for _ in 0..<120 where reader.isTransitioning { reader.advancePaperAnimation(elapsed: 1.0 / 60) }
        XCTAssertFalse(reader.isTransitioning)
    }

    private func send(_ pan: PanSample, to reader: PagedReaderViewController,
                      state: UIGestureRecognizer.State, translation: CGPoint) {
        pan.sampleState = state; pan.sampleTranslation = translation
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
    }

    private func assertFinite(_ patches: [PaperCornerPatch], context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(patches.isEmpty, context, file: file, line: line)
        for patch in patches {
            XCTAssertGreaterThanOrEqual(patch.source.count, 3, context, file: file, line: line)
            XCTAssertTrue((patch.source + patch.projected).allSatisfy { $0.x.isFinite && $0.y.isFinite }, context, file: file, line: line)
            let t = patch.transform
            XCTAssertTrue([t.a, t.b, t.c, t.d, t.tx, t.ty, patch.depth, patch.shade].allSatisfy(\.isFinite), context, file: file, line: line)
        }
    }

    private func meanCross(_ patches: [PaperCornerPatch], axis: PageTurnAxis) -> CGFloat {
        let points = patches.flatMap(\.projected)
        return points.reduce(0) { $0 + cross($1, axis: axis) } / CGFloat(max(1, points.count))
    }

    func testArchDragGeometryMatrixUsesRealOriginAndSignedCrossTranslation() throws {
        for axis in axes {
            let canvas = size(axis), extent: CGFloat = 240, breadth: CGFloat = 360
            for spread in [false, true] {
                for order in orders {
                    for direction in directions {
                        let context = "\(axis)/\(spread)/\(order)/\(direction)"
                        let sign = inwardSign(axis: axis, order: order, direction: direction)
                        let origin = point(extent * (sign < 0 ? 0.78 : 0.22), breadth * 0.91, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                            inwardSign: sign, origin: origin, effect: .arch))
                        XCTAssertEqual(seed.effect, .arch, context)
                        XCTAssertEqual(seed.gripOrigin, origin, "\(context)：边角按下也必须保留真实触点")
                        let contacted = try XCTUnwrap(seed.moved(to: origin, direction: direction))
                        XCTAssertEqual(contacted.translation, .zero, context)
                        XCTAssertEqual(contacted.gestureProgress, 0, context)
                        var geometries: [[PaperCornerPatch]] = []
                        for crossOffset: CGFloat in [0, breadth * 0.08, -breadth * 0.08] {
                            let touch = point(primary(origin, axis: axis) + sign * extent * 0.38,
                                              cross(origin, axis: axis) + crossOffset, axis: axis)
                            let drag = try XCTUnwrap(seed.moved(to: touch, direction: direction))
                            XCTAssertEqual(primary(drag.translation, axis: axis), sign * extent * 0.38, accuracy: 1e-6, context)
                            XCTAssertLessThanOrEqual(abs(cross(drag.translation, axis: axis)), abs(crossOffset) + 1e-6, context)
                            XCTAssertGreaterThanOrEqual(cross(drag.translation, axis: axis) * crossOffset, 0, context)
                            XCTAssertEqual(primary(drag.gripPosition, axis: axis), primary(touch, axis: axis), accuracy: 1e-6, context)
                            XCTAssertEqual(drag.gestureProgress, 0.38, accuracy: 1e-9, context)
                            XCTAssertEqual(drag.foldingPresentation(direction: direction, size: canvas, spread: spread), drag, context)
                            XCTAssertEqual(drag.interactivePresentation(direction: direction, size: canvas, spread: spread), drag, context)
                            let patches = PaperArchGeometry.patches(for: drag, direction: direction, stripCount: 64, readingOrder: order)
                            let sourcePage = PaperArchGeometry.materialPage(for: drag, direction: direction)
                            let materialContact = direction == .next ? origin : point(sign > 0
                                ? (axis == .horizontal ? sourcePage.maxX : sourcePage.maxY)
                                : (axis == .horizontal ? sourcePage.minX : sourcePage.minY), cross(origin, axis: axis), axis: axis)
                            let contactPatch = try XCTUnwrap(patches.first { $0.source.contains(materialContact) }, context)
                            let projected = materialContact.applying(contactPatch.transform)
                            XCTAssertEqual(primary(projected, axis: axis), primary(touch, axis: axis), accuracy: 1e-5, context)
                            XCTAssertEqual(cross(projected, axis: axis), cross(drag.gripPosition, axis: axis), accuracy: 1e-5, context)
                            assertFinite(patches, context: context)
                            geometries.append(patches)
                        }
                        let straight = geometries[0], positive = geometries[1], negative = geometries[2]
                        XCTAssertNotEqual(positive.map(\.projected), straight.map(\.projected), context)
                        XCTAssertNotEqual(negative.map(\.projected), straight.map(\.projected), context)
                        for crossSign: CGFloat in [-1, 1] {
                            let far = try XCTUnwrap(seed.moved(to: point(primary(origin, axis: axis) + sign * 1e6,
                                cross(origin, axis: axis) + crossSign * 1e6, axis: axis), direction: direction))
                            let hinge = spread ? extent / 2 : (sign < 0 ? 0 : extent)
                            let currentReach = (primary(origin, axis: axis) - hinge) * -sign
                            let bookHinge: CGFloat = spread ? extent / 2 : (sign > 0 ? 0 : extent)
                            let sourceLength = spread ? extent / 2 : extent
                            let sourceOrigin = (primary(origin, axis: axis) - bookHinge) * sign
                            let reach = direction == .next ? currentReach : sourceLength
                            let maximumPull = direction == .next ? min(extent, 2 * reach)
                                : min(extent, sourceLength - sourceOrigin)
                            let end = direction == .next ? reach - maximumPull : sourceOrigin + maximumPull
                            let fixedEnd = crossSign > 0 ? cross(origin, axis: axis) : breadth - cross(origin, axis: axis)
                            let capacity = max(0, (reach - end) * (reach + end))
                            let across = min(breadth, sqrt(fixedEnd * fixedEnd + capacity) - fixedEnd)
                            XCTAssertEqual(primary(far.translation, axis: axis), sign * maximumPull, accuracy: 1e-6, context)
                            XCTAssertLessThanOrEqual(cross(far.translation, axis: axis) * crossSign, across + 1e-6, context)
                            XCTAssertGreaterThanOrEqual(cross(far.translation, axis: axis) * crossSign, max(0, across - 3), context)
                            XCTAssertEqual(far.gestureProgress, maximumPull / extent, accuracy: 1e-9, context)
                        }
                        let outward = try XCTUnwrap(seed.moved(to: point(primary(origin, axis: axis) - sign * extent,
                            cross(origin, axis: axis), axis: axis), direction: direction))
                        XCTAssertEqual(primary(outward.translation, axis: axis), 0, context)
                    }
                }
            }
        }
    }

    func testStraightArchBendsBetweenSupportAndContactAndPreservesCurlDefault() throws {
        for axis in axes {
            let canvas = size(axis), extent: CGFloat = 240, breadth: CGFloat = 360
            for spread in [false, true] {
                for direction in directions {
                    let sign: CGFloat = direction == .next ? -1 : 1
                    let origin = point(sign < 0 ? extent * 0.85 : extent * 0.15, breadth / 2, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                        inwardSign: sign, origin: origin, effect: .arch))
                    let touch = point(primary(origin, axis: axis) + sign * extent * 0.2, breadth / 2, axis: axis)
                    let drag = try XCTUnwrap(seed.moved(to: touch, direction: direction))
                    let mesh = PaperArchGeometry.mesh(for: drag, direction: direction, stripCount: 64)
                    assertFinite(mesh.patches, context: "\(axis)/\(spread)/\(direction)")
                    let sourcePage = PaperArchGeometry.materialPage(for: drag, direction: direction)
                    let materialContact = direction == .next ? origin : point(sign > 0
                        ? (axis == .horizontal ? sourcePage.maxX : sourcePage.maxY)
                        : (axis == .horizontal ? sourcePage.minX : sourcePage.minY), cross(origin, axis: axis), axis: axis)
                    let contact = try XCTUnwrap(mesh.samples.first { $0.source == materialContact })
                    XCTAssertEqual(contact.point.x, touch.x, accuracy: 1e-6)
                    XCTAssertEqual(contact.point.y, touch.y, accuracy: 1e-6)
                    XCTAssertEqual(contact.height, 0, accuracy: 1e-7, "触点不能成为波峰")
                    XCTAssertGreaterThan(mesh.samples.map(\.height).max() ?? 0, 1, "受压纸段仍应弓起")
                    XCTAssertTrue(mesh.samples.allSatisfy { $0.height >= 0 }, "纸面不能穿过底页")
                    let materialSign = direction == .previous ? -sign : sign
                    let hinge = spread ? extent / 2 : (materialSign < 0 ? 0 : extent)
                    // 固定的是最初装订的材料边；手指变化时不能换成另一条经过支撑线的材料。
                    let support = mesh.samples.filter { abs(primary($0.source, axis: axis) - hinge) < 1e-7 }
                    XCTAssertGreaterThanOrEqual(support.count, 3)
                    for sample in support {
                        XCTAssertEqual(primary(sample.point, axis: axis), hinge, accuracy: 1e-7)
                        XCTAssertEqual(cross(sample.point, axis: axis), cross(sample.source, axis: axis), accuracy: 1e-7)
                        XCTAssertEqual(sample.height, 0, accuracy: 1e-7)
                    }
                }
            }
        }
        let canvas = CGSize(width: 240, height: 360), origin = CGPoint(x: 220, y: 350)
        let implicit = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: .horizontal, spread: false, inwardSign: -1, origin: origin))
        let explicit = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: .horizontal, spread: false, inwardSign: -1, origin: origin, effect: .curl))
        XCTAssertEqual(implicit, explicit)
        XCTAssertEqual(implicit.effect, .curl)
        XCTAssertEqual(implicit.gripOrigin, implicit.corner)
        let moved = try XCTUnwrap(implicit.moved(to: CGPoint(x: 100, y: 280)))
        XCTAssertEqual(moved, explicit.moved(to: CGPoint(x: 100, y: 280)))
        XCTAssertEqual(moved.released(completed: true, fraction: 1).translation.x, -2 * moved.length)
    }

    func testArchReleaseEndpointsAndFollowerRetargetRemainContinuous() throws {
        for axis in axes {
            let canvas = size(axis), extent: CGFloat = 240, breadth: CGFloat = 360
            for spread in [false, true] {
                for direction in directions {
                    let sign: CGFloat = direction == .next ? -1 : 1
                    let origin = point(extent / 2, breadth / 2, axis: axis)
                    let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                        inwardSign: sign, origin: origin, effect: .arch))
                    let live = try XCTUnwrap(seed.moved(to: point(extent / 2 + sign * extent * 0.35,
                        breadth / 2 - 40, axis: axis), direction: direction))
                    for completed in [false, true] {
                        XCTAssertEqual(live.released(completed: completed, fraction: 0, direction: direction), live)
                        let tiny = live.released(completed: completed, fraction: 0.0001, direction: direction)
                        XCTAssertLessThan(hypot(tiny.translation.x - live.translation.x, tiny.translation.y - live.translation.y), 0.1)
                        var last = live
                        for fraction: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.9, 1] {
                            let released = live.released(completed: completed, fraction: fraction, direction: direction)
                            XCTAssertEqual(released.effect, .arch)
                            XCTAssertEqual(released.origin, origin)
                            XCTAssertEqual(released.gripOrigin, origin)
                            let advance = (primary(released.translation, axis: axis) - primary(last.translation, axis: axis)) * sign
                            XCTAssertTrue(completed ? advance >= 0 : advance <= 0)
                            XCTAssertLessThanOrEqual(abs(cross(released.translation, axis: axis)), abs(cross(last.translation, axis: axis)))
                            last = released
                        }
                        XCTAssertEqual(last.translation, point(completed ? sign * extent : 0, 0, axis: axis))
                        XCTAssertEqual(last.gestureProgress, completed ? 1 : 0)
                    }
                    let target = try XCTUnwrap(seed.moved(to: point(extent / 2 + sign * extent * 0.65,
                        breadth / 2 + 45, axis: axis), direction: direction))
                    var follower = PaperCornerDragFollower()
                    follower.update(live, followsTouch: true); follower.update(target, followsTouch: true)
                    XCTAssertEqual(follower.current, live)
                    follower.advance(elapsed: 1.0 / 120)
                    let middle = try XCTUnwrap(follower.current)
                    XCTAssertNotEqual(middle, live); XCTAssertNotEqual(middle, target)
                    XCTAssertEqual(middle.effect, .arch)
                    XCTAssertEqual(middle.inwardSign, sign)
                    XCTAssertEqual(middle.origin, origin)
                    XCTAssertGreaterThan(middle.gestureProgress, live.gestureProgress)
                    XCTAssertLessThan(middle.gestureProgress, target.gestureProgress)
                    let redirected = try XCTUnwrap(seed.moved(to: point(extent / 2 + sign * extent * 0.45,
                        breadth / 2 - 65, axis: axis), direction: direction))
                    follower.update(redirected, followsTouch: true)
                    XCTAssertEqual(follower.current, middle, "重定向不能跳到逻辑目标或重新锚定纸角")
                    for _ in 0..<120 where !follower.isSettled { follower.advance(elapsed: 1.0 / 120) }
                    XCTAssertEqual(follower.current, redirected)
                    XCTAssertTrue(follower.isSettled)
                    let releaseStart = try XCTUnwrap(follower.current).released(completed: true, fraction: 0, direction: direction)
                    follower.update(releaseStart, followsTouch: false)
                    XCTAssertEqual(follower.current, redirected)
                    follower.reset(); XCTAssertNil(follower.current)
                }
            }
        }
    }

    func testActualGPUEndpointsMatchCapturedWholePagesAndAllTextMarkers() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "需要实际 Metal 渲染")
        var gallery: [(String, UIImage)] = []
        defer { attachGallery(gallery, name: "arch-GPU-whole-page-endpoints") }
        for axis in axes {
            let canvas = size(axis)
            for spread in [false, true] {
                let current = fixture("C", target: false, size: canvas, axis: axis, spread: spread)
                let target = fixture("T", target: true, size: canvas, axis: axis, spread: spread)
                let flatCurrent = try raster(capture(current)), flatTarget = try raster(capture(target))
                for order in orders {
                    for direction in directions {
                        let paper = try PaperTransitionView(currentView: current, targetView: target, effect: .arch,
                            direction: direction, spine: spine(axis: axis, order: order, spread: spread),
                            options: options(for: canvas), axis: axis, readingOrder: order, cornerDriven: true)
                        let reference = try PaperTransitionView(currentView: current, targetView: target, effect: .arch,
                            direction: direction, spine: spine(axis: axis, order: order, spread: spread),
                            options: options(for: canvas), axis: axis, readingOrder: order)
                        defer { paper.invalidateResources(); reference.invalidateResources() }
                        XCTAssertTrue(paper.usesMetalCornerRendering)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                            inwardSign: inwardSign(axis: axis, order: order, direction: direction),
                            origin: point(120, 180, axis: axis), effect: .arch))
                        for completed in [false, true] {
                            let drag = seed.released(completed: completed, fraction: 1, direction: direction)
                            paper.update(progress: completed ? 1 : 0, cornerDrag: drag)
                            reference.update(progress: completed ? 1 : 0, cornerDrag: drag)
                            let image = try XCTUnwrap(paper.cornerGPUImage())
                            let actual = try raster(image), expected = completed ? flatTarget : flatCurrent
                            let context = "\(axis)/\(spread)/\(order)/\(direction)/\(completed ? 1 : 0)"
                            XCTAssertEqual(actual.width, expected.width, context)
                            XCTAssertEqual(actual.height, expected.height, context)
                            XCTAssertLessThan(actual.changedFraction(from: expected), 0.015,
                                              "\(context)：逻辑端点必须输出真实整页，不能残留另一半页、阴影或镜像")
                            assertMarkers(actual, match: expected, size: canvas, context: context)
                            let softwareEndpoint = try raster(software(reference))
                            XCTAssertLessThan(softwareEndpoint.changedFraction(from: expected), 0.015,
                                              "\(context)：软件参考的整图端点也必须保持正向")
                            assertMarkers(softwareEndpoint, match: expected, size: canvas, context: "software/\(context)")
                            if order == .leftToRight { gallery.append((context, image)) }
                        }
                    }
                }
            }
        }
    }

    func testActualGPUDiagonalArchDiffersUpAndDownAndMatchesSoftwareReference() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "需要实际 Metal 渲染")
        var gallery: [(String, UIImage)] = []
        defer { attachGallery(gallery, name: "arch-GPU-signed-diagonal-reference") }
        for axis in axes {
            let canvas = size(axis)
            for spread in [false, true] {
                for order in orders {
                    for direction in directions {
                        let current = fixture("C", target: false, size: canvas, axis: axis, spread: spread)
                        let target = fixture("T", target: true, size: canvas, axis: axis, spread: spread)
                        let gpu = try PaperTransitionView(currentView: current, targetView: target, effect: .arch,
                            direction: direction, spine: spine(axis: axis, order: order, spread: spread),
                            options: options(for: canvas), axis: axis, readingOrder: order, cornerDriven: true)
                        let reference = try PaperTransitionView(currentView: current, targetView: target, effect: .arch,
                            direction: direction, spine: spine(axis: axis, order: order, spread: spread),
                            options: options(for: canvas), axis: axis, readingOrder: order)
                        defer { gpu.invalidateResources(); reference.invalidateResources() }
                        let sign = inwardSign(axis: axis, order: order, direction: direction)
                        let origin = point(sign < 0 ? 204 : 36, 180, axis: axis)
                        let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                            inwardSign: sign, origin: origin, effect: .arch))
                        var actualRasters: [Raster] = [], referenceRasters: [Raster] = []
                        for offset: CGFloat in [0, -48, 48] {
                            let drag = try XCTUnwrap(seed.moved(to: point(primary(origin, axis: axis) + sign * 240 * 0.3, 180 + offset,
                                axis: axis), direction: direction))
                            gpu.update(progress: drag.gestureProgress, cornerDrag: drag)
                            reference.update(progress: drag.gestureProgress, cornerDrag: drag)
                            let image = try XCTUnwrap(gpu.cornerGPUImage())
                            let referenceImage = software(reference)
                            let actual = try raster(image), expected = try raster(referenceImage)
                            if axis == .horizontal, !spread, order == .leftToRight, direction == .next, offset == 0 {
                                for (name, output) in [("arch-contact-GPU", image), ("arch-contact-software", referenceImage)] {
                                    let attachment = XCTAttachment(image: output)
                                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                                }
                            }
                            actualRasters.append(actual); referenceRasters.append(expected)
                            let context = "\(axis)/\(spread)/\(order)/\(direction)/\(offset)"
                            XCTAssertLessThan(actual.changedFraction(from: expected, rasterRadius: 1), 0.08,
                                              "\(context)：允许一像素采样边界差异，纸面、材质和文字结构仍须一致")
                            if order == .leftToRight, offset != 0 { gallery.append((context, image)) }
                        }
                        for images in [actualRasters, referenceRasters] {
                            XCTAssertGreaterThan(images[1].changedFraction(from: images[2]), 0.01, "上下斜拉必须改变实际像素")
                            XCTAssertGreaterThan(images[0].changedFraction(from: images[1]), 0.005, "斜拉不能退化为直拖")
                            XCTAssertGreaterThan(images[0].changedFraction(from: images[2]), 0.005, "相反横移也必须传入渲染")
                        }
                        XCTAssertEqual(gpu.softwareCornerDrawCount, 0, "离屏 GPU 验收不能调用软件绘图冒充")
                    }
                }
            }
        }
    }

    func testPublicArchPointMatrixCommitsOrReverseCancelsOnceAndKeepsScalarPolicy() throws {
        for axis in axes {
            for layout in [ReaderPageLayout.single, .spread] {
                for order in orders {
                    for direction in directions {
                        for completed in [false, true] {
                            let reader = try reader(axis: axis, layout: layout, order: order)
                            defer { reader.invalidate() }
                            let old = reader.currentPage.controller
                            var events: [PageTransitionEvent] = []
                            reader.onTransition = { events.append($0) }
                            let sign = inwardSign(axis: axis, order: order, direction: direction)
                            let origin = point(sign < 0 ? 192 : 48, 180, axis: axis)
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                            let paper = try XCTUnwrap(reader.activePaperView)
                            let initial = try XCTUnwrap(paper.cornerDrag)
                            XCTAssertEqual(initial.effect, .arch)
                            XCTAssertEqual(initial.gripOrigin, origin)
                            XCTAssertEqual(initial.gestureProgress, 0)
                            XCTAssertEqual(reader.children.count, 2)
                            XCTAssertTrue(old.view.isHidden)
                            XCTAssertTrue(paper.hasResources)
                            XCTAssertLessThanOrEqual(paper.snapshotPixelCount, options(for: size(axis)).maximumSnapshotPixels)
                            if PaperCornerMetalRenderer.isSupported { XCTAssertTrue(paper.usesMetalCornerRendering) }
                            reader.updateInteractiveTurn(to: point(primary(origin, axis: axis) + sign * 84, 215, axis: axis))
                            let live = try XCTUnwrap(paper.cornerDrag)
                            XCTAssertEqual(live.gestureProgress, 0.35, accuracy: 1e-9)
                            let expected = try XCTUnwrap(initial.moved(to: point(primary(origin, axis: axis) + sign * 84, 215, axis: axis), direction: direction))
                            XCTAssertEqual(cross(live.translation, axis: axis), cross(expected.translation, axis: axis), accuracy: 1e-6)
                            reader.endInteractiveTurn(velocity: completed ? 0 : -900)
                            XCTAssertEqual(paper.cornerDrag, live, "离屏收尾必须从已有二维姿态开始")
                            finish(reader)
                            reader.endInteractiveTurn(velocity: 900); reader.cancelTransition(); finish(reader)
                            assertEvents(events, completed: completed)
                            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? (direction == .next ? "7" : "5") : "6")
                            XCTAssertEqual(reader.children.count, 1)
                            XCTAssertFalse(reader.currentPage.controller.view.isHidden)
                            if completed { XCTAssertNil(old.parent) }
                            else { XCTAssertTrue(reader.currentPage.controller === old) }
                            XCTAssertNil(reader.activePaperView)
                            XCTAssertFalse(paper.hasResources); XCTAssertEqual(paper.snapshotPixelCount, 0)
                            XCTAssertNil(paper.cornerDrag); XCTAssertNil(paper.superview)
                            XCTAssertFalse(reader.isPaperClockRunning)
                        }
                    }
                }
                for effect in [PageTurnEffect.arch, .curl] {
                    for direction in directions {
                        for completed in [false, true] {
                            let reader = try reader(axis: axis, layout: layout, effect: effect)
                            defer { reader.invalidate() }
                            var events: [PageTransitionEvent] = []
                            reader.onTransition = { events.append($0) }
                            XCTAssertTrue(try reader.beginInteractiveTurn(direction))
                            let paper = try XCTUnwrap(reader.activePaperView)
                            XCTAssertNil(paper.cornerDrag)
                            reader.updateInteractiveTurn(displacement: 240 * (completed ? 0.18 : 0.16))
                            let progress = paper.progress
                            reader.updateInteractiveTurn(to: point(-900, 900, axis: axis))
                            XCTAssertNil(paper.cornerDrag); XCTAssertEqual(paper.progress, progress)
                            reader.endInteractiveTurn(velocity: 0, animated: false)
                            assertEvents(events, completed: completed)
                            XCTAssertEqual(reader.currentPage.identity.unitID, completed ? (direction == .next ? "7" : "5") : "6")
                            XCTAssertFalse(paper.hasResources)
                        }
                    }
                }
            }
            for effect in [PageTurnEffect.none, .cover, .slide] {
                if effect == .cover, axis == .vertical {
                    XCTAssertThrowsError(try reader(axis: axis, effect: effect)) {
                        XCTAssertEqual($0 as? PageTurnError, .unsupportedPresentation)
                    }
                    continue
                }
                let reader = try reader(axis: axis, effect: effect)
                defer { reader.invalidate() }
                var requests = 0
                reader.pageProvider = { _, _ in requests += 1; return .waiting }
                XCTAssertThrowsError(try reader.beginInteractiveTurn(.next, at: point(120, 180, axis: axis))) {
                    XCTAssertEqual($0 as? PageTurnError, .unsupportedPresentation)
                }
                XCTAssertEqual(requests, 0); XCTAssertNil(reader.activePaperView)
                XCTAssertFalse(reader.isTransitioning); XCTAssertEqual(reader.children.count, 1)
            }
        }
    }

    func testNativePanUsesPhysicalDirectionAtOppositeBottomCornerAndRetargetsCross() throws {
        for axis in axes {
            for order in orders {
                for sign: CGFloat in [-1, 1] {
                    let reader = try reader(axis: axis, order: order)
                    defer { reader.invalidate() }
                    var requests: [PageTurnDirection] = []
                    let expected: PageTurnDirection = sign == inwardSign(axis: axis, order: order, direction: .next) ? .next : .previous
                    let target = try content(expected == .next ? 7 : 5, axis: axis, layout: .single, order: order)
                    reader.pageProvider = { _, direction in requests.append(direction); return .page(target) }
                    let pan = PanSample()
                    // 负向从最小端、正向从最大端起手；下方斜拖不能按所处纸角反转物理方向。
                    pan.origin = point(sign < 0 ? 18 : 222, 312, axis: axis)
                    pan.sampleVelocity = point(sign * 700, -600, axis: axis)
                    send(pan, to: reader, state: .began, translation: point(sign * 12, -12, axis: axis))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    let initial = try XCTUnwrap(paper.cornerDrag)
                    XCTAssertEqual(requests, [expected])
                    XCTAssertEqual(initial.effect, .arch); XCTAssertEqual(initial.inwardSign, sign)
                    XCTAssertEqual(initial.origin, pan.origin); XCTAssertEqual(initial.gripOrigin, pan.origin)
                    XCTAssertEqual(primary(initial.translation, axis: axis), sign * 12, accuracy: 1e-6)
                    let bounded = try XCTUnwrap(initial.moved(to: point(primary(pan.origin, axis: axis) + sign * 12,
                        cross(pan.origin, axis: axis) - 12, axis: axis), direction: expected))
                    XCTAssertEqual(cross(initial.translation, axis: axis), cross(bounded.translation, axis: axis), accuracy: 1e-6)
                    let transition = reader.activeTransitionID
                    var crossPositions: [CGFloat] = []
                    for offset: CGFloat in [-5, 5] {
                        send(pan, to: reader, state: .changed, translation: point(sign * 13.5, offset, axis: axis))
                        let drag = try XCTUnwrap(paper.cornerDrag)
                        XCTAssertEqual(drag.effect, .arch); XCTAssertEqual(drag.inwardSign, sign)
                        let bounded = try XCTUnwrap(initial.moved(to: point(primary(pan.origin, axis: axis) + sign * 13.5,
                            cross(pan.origin, axis: axis) + offset, axis: axis), direction: expected))
                        XCTAssertEqual(cross(drag.translation, axis: axis), cross(bounded.translation, axis: axis), accuracy: 1e-6)
                        XCTAssertEqual(primary(drag.translation, axis: axis), sign * 13.5, accuracy: 1e-6)
                        let mesh = PaperArchGeometry.mesh(for: drag, direction: expected, stripCount: 64, readingOrder: order)
                        crossPositions.append(meanCross(mesh.patches, axis: axis))
                        let materialSign = expected == .previous ? -sign : sign
                        let sourcePage = PaperArchGeometry.materialPage(for: drag, direction: expected)
                        let hinge = axis == .horizontal ? (materialSign < 0 ? sourcePage.minX : sourcePage.maxX)
                            : (materialSign < 0 ? sourcePage.minY : sourcePage.maxY)
                        let fixed = mesh.samples.filter { abs(primary($0.source, axis: axis) - hinge) < 1e-7 }
                        XCTAssertGreaterThanOrEqual(fixed.count, 3)
                        XCTAssertTrue(fixed.allSatisfy { hypot($0.point.x - $0.source.x, $0.point.y - $0.source.y) < 1e-7 })
                        let materialContact = expected == .next ? drag.origin : point(sign > 0
                            ? (axis == .horizontal ? sourcePage.maxX : sourcePage.maxY)
                            : (axis == .horizontal ? sourcePage.minX : sourcePage.minY), cross(drag.origin, axis: axis), axis: axis)
                        let grip = try XCTUnwrap(mesh.samples.first { $0.source == materialContact })
                        XCTAssertEqual(grip.point.x, drag.gripPosition.x, accuracy: 1e-5)
                        XCTAssertEqual(grip.point.y, drag.gripPosition.y, accuracy: 1e-5)
                        XCTAssertEqual(reader.activeTransitionID, transition)
                    }
                    let shift = crossPositions[1] - crossPositions[0]
                    // 展开的上一页围绕原书脊转动；整张纸的均值不必与触点同向。
                    XCTAssertGreaterThan(expected == .next ? shift : abs(shift), 0.5, "原生 pan 的横向意图应改变弧面")
                    XCTAssertLessThan(abs(shift), 10, "书脊固定，不能整页平移")
                    XCTAssertEqual(requests, [expected], "转向不能重新查询邻页或创建事务")
                    send(pan, to: reader, state: .cancelled, translation: point(sign * 13.5, 5, axis: axis))
                    XCTAssertFalse(reader.isTransitioning); XCTAssertFalse(paper.hasResources)
                }
            }
        }
    }

    func testMountedArchFollowerAndReleaseShareCurlRenderClockAndCleanUpMemory() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "原生提交检查需要 Metal")
        for effect in [PageTurnEffect.arch, .curl] {
            for direction in directions {
                let reader = try reader(axis: .horizontal, effect: effect, nativeClock: true)
                let window = UIWindow(frame: reader.view.bounds)
                window.rootViewController = reader; window.makeKeyAndVisible()
                defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
                var events: [PageTransitionEvent] = []
                reader.onTransition = { events.append($0) }
                let sign: CGFloat = direction == .next ? -1 : 1
                let origin = CGPoint(x: sign < 0 ? 220 : 20, y: 180)
                XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                let paper = try XCTUnwrap(reader.activePaperView)
                XCTAssertTrue(paper.hasLiveNativeCornerPresentation); XCTAssertTrue(paper.usesMetalCornerRendering)
                for _ in 0..<200 {
                    if paper.submittedCornerDrag != nil { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let first = try XCTUnwrap(paper.submittedCornerDrag)
                XCTAssertEqual(first.effect, effect)
                let startCount = paper.nativeCornerSubmittedFrameCount
                reader.updateInteractiveTurn(to: CGPoint(x: origin.x + sign * 110, y: 145))
                let target = try XCTUnwrap(paper.cornerDrag)
                XCTAssertEqual(paper.submittedCornerDrag, first, "更新目标不能同步跳动已经提交的画面")
                var observedIntermediate = false
                for _ in 0..<300 {
                    if let shown = paper.submittedCornerDrag {
                        XCTAssertEqual(shown.effect, effect)
                        if shown != first && shown != target { observedIntermediate = true }
                        if shown == target { break }
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertEqual(paper.submittedCornerDrag, target)
                XCTAssertTrue(observedIntermediate, "挂载后的 follower 必须提交中间姿态")
                XCTAssertGreaterThan(paper.nativeCornerSubmittedFrameCount, startCount + 1)
                let visible = try XCTUnwrap(paper.submittedCornerDrag)
                // 故意在一次主线程调用中重定向并松手，逻辑目标与已提交姿态不同。
                reader.updateInteractiveTurn(to: CGPoint(x: origin.x + sign * 155, y: 220))
                XCTAssertEqual(paper.submittedCornerDrag, visible)
                let releaseCount = paper.nativeCornerSubmittedFrameCount
                reader.endInteractiveTurn(velocity: 900)
                XCTAssertEqual(paper.cornerDrag, visible, "收尾必须从最后已提交姿态连续开始")
                XCTAssertEqual(paper.submittedCornerDrag, visible)
                XCTAssertTrue(reader.usesDisplayLinkForPaperAnimation)
                XCTAssertTrue(paper.isNativeReleaseClockRunning, "arch 与 curl 都必须使用 Metal 的同一刷新时钟")
                XCTAssertTrue(reader.isPaperClockRunning)
                var releaseSubmissions = 0
                var lastCount = releaseCount
                var distinctPoses: [PaperCornerDrag] = []
                for _ in 0..<600 {
                    let count = paper.nativeCornerSubmittedFrameCount
                    if count > lastCount {
                        releaseSubmissions += count - lastCount
                        lastCount = count
                        if let shown = paper.submittedCornerDrag, shown != visible,
                           shown.gestureProgress > 0, shown.gestureProgress < 1,
                           distinctPoses.last != shown { distinctPoses.append(shown) }
                    }
                    if !reader.isTransitioning { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertFalse(reader.isTransitioning, "原生共享时钟必须自行完成，测试不手动推进")
                XCTAssertGreaterThan(releaseSubmissions, 2, "松手后必须实际提交多个可见帧")
                XCTAssertGreaterThan(distinctPoses.count, 1, "不能只提交起点和终点")
                assertEvents(events, completed: true)
                XCTAssertEqual(reader.currentPage.identity.unitID, direction == .next ? "7" : "5")
                XCTAssertFalse(reader.isPaperClockRunning); XCTAssertFalse(paper.isNativeReleaseClockRunning)
                XCTAssertEqual(paper.softwareCornerDrawCount, 0)
                XCTAssertFalse(paper.hasResources); XCTAssertEqual(paper.snapshotPixelCount, 0)
                XCTAssertNil(paper.submittedCornerDrag); XCTAssertTrue(paper.subviews.isEmpty)
                // 再次挂载二维纸面，验证内存警告清掉正在拖动的资源和可重建快照缓存。
                events.removeAll()
                let reverse: PageTurnDirection = direction == .next ? .previous : .next
                XCTAssertTrue(try reader.beginInteractiveTurn(reverse, at: CGPoint(x: 120, y: 180)))
                let interrupted = try XCTUnwrap(reader.activePaperView)
                XCTAssertTrue(interrupted.hasResources)
                reader.didReceiveMemoryWarning()
                assertEvents(events, completed: false)
                XCTAssertFalse(reader.hasCachedPaperSnapshot); XCTAssertNil(reader.activePaperView)
                XCTAssertFalse(interrupted.hasResources); XCTAssertEqual(interrupted.snapshotPixelCount, 0)
                XCTAssertNil(interrupted.cornerDrag); XCTAssertNil(interrupted.submittedCornerDrag)
                XCTAssertTrue(interrupted.subviews.isEmpty); XCTAssertNil(interrupted.superview)
                XCTAssertFalse(reader.isPaperClockRunning); XCTAssertEqual(reader.children.count, 1)
                let eventCount = events.count
                try await Task.sleep(nanoseconds: 60_000_000)
                XCTAssertEqual(events.count, eventCount, "清理后不能再由旧渲染时钟交付终态")
                XCTAssertFalse(reader.isTransitioning)
            }
        }
    }

    func testWholeSheetTextGridAtPhoneAspectRatio() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "Requires an actual Metal device")
        for axis in axes {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            let source = point(320, 422, axis: axis)
            func textPage(target: Bool) -> UIView {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1; format.opaque = true; format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    let context = renderer.cgContext
                    (target ? UIColor(red: 0.91, green: 0.94, blue: 0.92, alpha: 1)
                        : UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    context.setStrokeColor(UIColor(white: 0.3, alpha: 0.12).cgColor); context.setLineWidth(0.5)
                    for x in stride(from: CGFloat(16), to: size.width, by: 24) {
                        context.move(to: CGPoint(x: x, y: 16)); context.addLine(to: CGPoint(x: x, y: size.height - 16))
                    }
                    for y in stride(from: CGFloat(16), to: size.height, by: 24) {
                        context.move(to: CGPoint(x: 16, y: y)); context.addLine(to: CGPoint(x: size.width - 16, y: y))
                    }
                    context.strokePath()
                    let title = target ? "第八回（續）" : "第七回：袁紹磐河戰公孫"
                    (title as NSString).draw(in: CGRect(x: 28, y: 54, width: size.width - 56, height: 60),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: UIColor.black])
                    let lines = ["黃祖伏弓弩手於江邊，見船傍岸，", "亂箭俱發。堅令諸軍不可輕動，", "只伏於船中來往誘之；一連三日，", "船數十次傍岸。黃祖軍只顧放箭，", "箭已放盡。堅乃拔船上所得之箭，", "約十數萬。當日正值順風，", "堅令軍士齊聲吶喊，只得退走。", "黃蓋分兵追趕，背後韓當接應。"]
                    for row in 0..<max(1, Int((size.height - 140) / 32)) {
                        (lines[(row + (target ? 3 : 0)) % lines.count] as NSString).draw(
                            in: CGRect(x: 28, y: 130 + CGFloat(row) * 32, width: size.width - 56, height: 30),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor(white: 0.12, alpha: 1)])
                    }
                    if !target {
                        UIColor(red: 0.0, green: 0.3, blue: 0.3, alpha: 1).setFill()
                        context.fill(axis == .horizontal ? CGRect(x: 0, y: 0, width: 2, height: size.height)
                            : CGRect(x: 0, y: 0, width: size.width, height: 2))
                        UIColor.green.setFill(); context.fill(CGRect(x: source.x - 3, y: source.y - 3, width: 6, height: 6))
                    }
                }
                let view = UIImageView(image: image)
                view.frame = CGRect(origin: .zero, size: size); view.overrideUserInterfaceStyle = .light
                view.backgroundColor = UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
                return view
            }
            let paper = try PaperTransitionView(currentView: textPage(target: false), targetView: textPage(target: true),
                effect: .arch, direction: .next, spine: .minimum,
                options: .init(maximumSnapshotPixels: Int(size.width * size.height) * 2, stripCount: 96), axis: axis, cornerDriven: true)
            defer { paper.invalidateResources() }
            XCTAssertTrue(paper.usesMetalCornerRendering)
            let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                inwardSign: -1, origin: source, effect: .arch))
            let pulls: [(CGFloat, CGFloat)] = [(70, 0), (390 * 0.32, 0), (390 * 0.46, 0), (180, -40), (180, 40), (270, 0), (78, -40), (78, 40)]
            for (index, pull) in pulls.enumerated() {
                let live = try XCTUnwrap(seed.moved(to: point(320 - pull.0, 422 + pull.1, axis: axis)))
                for fraction: CGFloat in (index == 3 ? [0, 0.35, 0.7] : [0]) {
                    let pose = live.released(completed: true, fraction: fraction)
                    let mesh = PaperArchGeometry.mesh(for: pose, direction: .next, stripCount: 96)
                    XCTAssertLessThanOrEqual(mesh.samples.map(\.height).max() ?? 0, pose.length)
                    let fixed = mesh.samples.filter { abs(primary($0.source, axis: axis)) < 1e-7 }
                    XCTAssertGreaterThanOrEqual(fixed.count, 3)
                    XCTAssertTrue(fixed.allSatisfy { hypot($0.point.x - $0.source.x, $0.point.y - $0.source.y) < 1e-7 })
                    if fraction == 0 && pull.1 == 0 && pull.0 <= 180 { XCTAssertTrue(mesh.patches.allSatisfy { !$0.back }) }
                    if pull.1 == 0 {
                        for patch in mesh.patches {
                            let scale = axis == .horizontal ? hypot(patch.transform.c, patch.transform.d)
                                : hypot(patch.transform.a, patch.transform.b)
                            XCTAssertEqual(scale, 1, accuracy: 1e-6, "Straight dragging must preserve parallel material spacing")
                        }
                    }
                    if fraction == 0 && (index == 1 || index == 2) {
                        let bow = mesh.samples.map { abs(cross($0.point, axis: axis) - cross($0.source, axis: axis)) }.max() ?? 0
                        XCTAssertGreaterThan(bow, 2, "32% and 46% must show a curved sheet, not a rigid panel")
                    }
                    paper.update(progress: pose.gestureProgress, cornerDrag: pose)
                    let image = try XCTUnwrap(paper.cornerGPUImage(scale: 1))
                    XCTAssertEqual(image.size, size)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "arch-sheet-\(axis)-pose\(index)-release\(Int(fraction * 100))"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
    }

    func testPreviousArchUnfoldsPreviousPaperFromOriginalBookSpine() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "Requires actual Metal output")
        for axis in axes {
            let canvas = size(axis)
            for sign: CGFloat in [-1, 1] {
                let origin = point(sign > 0 ? 24 : 216, 180, axis: axis)
                let touch = point(primary(origin, axis: axis) + sign * 120, 180, axis: axis)
                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: false,
                    inwardSign: sign, origin: origin, effect: .arch))
                let drag = try XCTUnwrap(seed.moved(to: touch, direction: .previous))
                let mesh = PaperArchGeometry.mesh(for: drag, direction: .previous, stripCount: 96)
                let binding: CGFloat = sign > 0 ? 0 : 240
                let bound = mesh.samples.filter { abs(primary($0.source, axis: axis) - binding) < 1e-8 }
                XCTAssertGreaterThan(bound.count, 2)
                let drift = bound.map { hypot($0.worldPoint.x - $0.source.x, $0.worldPoint.y - $0.source.y) }.max() ?? .infinity
                XCTAssertLessThan(drift, 1e-5, "Returning paper must remain bound to the original book spine")
                let materialContact = point(sign > 0 ? 240 : 0, 180, axis: axis)
                let contactPatch = try XCTUnwrap(mesh.patches.first { $0.source.contains(materialContact) })
                let contact = materialContact.applying(contactPatch.transform)
                XCTAssertEqual(contact.x, drag.gripPosition.x, accuracy: 1e-5)
                XCTAssertEqual(contact.y, drag.gripPosition.y, accuracy: 1e-5)
                func colored(_ color: UIColor) -> UIView {
                    let view = UIView(frame: CGRect(origin: .zero, size: canvas))
                    view.backgroundColor = color; view.overrideUserInterfaceStyle = .light
                    return view
                }
                let paper = try PaperTransitionView(currentView: colored(.red), targetView: colored(.blue),
                    effect: .arch, direction: .previous, spine: sign > 0 ? .minimum : .maximum,
                    options: options(for: canvas), axis: axis, cornerDriven: true)
                defer { paper.invalidateResources() }
                paper.update(progress: drag.progress, cornerDrag: drag)
                let image = try XCTUnwrap(paper.cornerGPUImage(scale: 1)), pixels = try raster(image)
                let probe = point(primary(touch, axis: axis) - sign * 2, 180, axis: axis)
                let rgb = pixels.rgb(x: Int(probe.x), y: Int(probe.y))
                XCTAssertGreaterThan(Int(rgb[2]) - Int(rgb[0]), 100,
                    "The bent returning sheet must carry previous-page blue, with current-page red underneath")
                let attachment = XCTAttachment(image: image)
                attachment.name = "arch-return-material-\(axis)-\(sign)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testPreviousArchTextGridAtPhoneAspectRatio() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported, "Requires actual Metal output")
        for axis in axes {
            let canvas = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            func page(previous: Bool) -> UIView {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
                    let context = renderer.cgContext
                    (previous ? UIColor(red: 0.97, green: 0.955, blue: 0.92, alpha: 1)
                        : UIColor(red: 0.91, green: 0.94, blue: 0.92, alpha: 1)).setFill()
                    context.fill(CGRect(origin: .zero, size: canvas))
                    context.setStrokeColor(UIColor(white: 0.3, alpha: 0.12).cgColor); context.setLineWidth(0.5)
                    for x in stride(from: CGFloat(16), to: canvas.width, by: 24) {
                        context.move(to: CGPoint(x: x, y: 16)); context.addLine(to: CGPoint(x: x, y: canvas.height - 16))
                    }
                    for y in stride(from: CGFloat(16), to: canvas.height, by: 24) {
                        context.move(to: CGPoint(x: 16, y: y)); context.addLine(to: CGPoint(x: canvas.width - 16, y: y))
                    }
                    context.strokePath()
                    ((previous ? "上一頁 · 第七回" : "當前頁 · 第八回") as NSString).draw(
                        in: CGRect(x: 28, y: 54, width: canvas.width - 56, height: 56),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: UIColor.black])
                    for row in 0..<max(1, Int((canvas.height - 140) / 32)) {
                        ((previous ? "黃祖伏弓弩手於江邊，見船傍岸，" : "及桓帝崩，靈帝即位，大將軍竇武，") as NSString).draw(
                            in: CGRect(x: 28, y: 130 + CGFloat(row) * 32, width: canvas.width - 56, height: 30),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor(white: 0.12, alpha: 1)])
                    }
                    if previous {
                        UIColor(red: 0, green: 0.3, blue: 0.3, alpha: 1).setFill()
                        context.fill(axis == .horizontal ? CGRect(x: 0, y: 0, width: 2, height: canvas.height)
                            : CGRect(x: 0, y: 0, width: canvas.width, height: 2))
                    }
                }
                let view = UIImageView(image: image); view.frame = CGRect(origin: .zero, size: canvas)
                view.overrideUserInterfaceStyle = .light; return view
            }
            let paper = try PaperTransitionView(currentView: page(previous: false), targetView: page(previous: true),
                effect: .arch, direction: .previous, spine: .minimum,
                options: options(for: canvas), axis: axis, cornerDriven: true)
            defer { paper.invalidateResources() }
            let origin = point(36, 422, axis: axis)
            let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: false,
                inwardSign: 1, origin: origin, effect: .arch))
            for (index, pull) in [(CGFloat(24), CGFloat(0)), (100, -30), (100, 30), (240, 0)].enumerated() {
                let live = try XCTUnwrap(seed.moved(to: point(36 + pull.0, 422 + pull.1, axis: axis), direction: .previous))
                for fraction: CGFloat in (index == 1 ? [0, 0.35, 0.7, 1] : [0]) {
                    let pose = live.released(completed: true, fraction: fraction, direction: .previous)
                    paper.update(progress: pose.gestureProgress, cornerDrag: pose)
                    let image = try XCTUnwrap(paper.cornerGPUImage(scale: 1))
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "arch-return-sheet-\(axis)-pose\(index)-release\(Int(fraction * 100))"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
    }

    func testPreviousArchFollowerAndLimitedReachKeepMaterialAtGrip() throws {
        for axis in axes {
            let canvas = size(axis)
            let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: true,
                inwardSign: 1, origin: point(100, 180, axis: axis), effect: .arch))
            let start = try XCTUnwrap(seed.moved(to: point(108, 180, axis: axis), direction: .previous))
            let target = try XCTUnwrap(seed.moved(to: point(200, 180, axis: axis), direction: .previous))
            var follower = PaperCornerDragFollower()
            follower.update(start, followsTouch: true); follower.update(target, followsTouch: true)
            var intermediateBeyondOldClamp = false
            for _ in 0..<120 where !follower.isSettled {
                let before = try XCTUnwrap(follower.current)
                follower.advance(elapsed: 1.0 / 120)
                let current = try XCTUnwrap(follower.current)
                XCTAssertLessThan(abs(primary(current.gripPosition, axis: axis) - primary(before.gripPosition, axis: axis)), 20,
                    "Previous native frames must not clamp at x=140 then jump to x=200")
                if !follower.isSettled && primary(current.gripPosition, axis: axis) > 140 { intermediateBeyondOldClamp = true }
            }
            XCTAssertTrue(intermediateBeyondOldClamp)
            XCTAssertEqual(follower.current, target)
            for (spread, origin, requested) in [(false, CGFloat(238), CGFloat(300)), (true, 120, 320)] {
                let seed = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: axis, spread: spread,
                    inwardSign: 1, origin: point(origin, 180, axis: axis), effect: .arch))
                let drag = try XCTUnwrap(seed.moved(to: point(requested, 180, axis: axis), direction: .previous))
                XCTAssertEqual(primary(drag.gripPosition, axis: axis), 240, accuracy: 1e-6)
                let mesh = PaperArchGeometry.mesh(for: drag, direction: .previous, stripCount: 96)
                let material = point(240, 180, axis: axis)
                let actual = try XCTUnwrap(mesh.samples.first { $0.source == material })
                XCTAssertEqual(actual.point.x, drag.gripPosition.x, accuracy: 1e-5)
                XCTAssertEqual(actual.point.y, drag.gripPosition.y, accuracy: 1e-5)
            }
        }
    }
}
#endif
