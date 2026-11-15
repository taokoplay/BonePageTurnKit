#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 以实际目标页面显露范围验证松手；不把手指位移当作纸面进度。
@MainActor
final class VisiblePageReleaseTests: XCTestCase {
    private func point(_ primary: CGFloat, _ cross: CGFloat, axis: PageTurnAxis) -> CGPoint {
        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
    }

    private func sign(axis: PageTurnAxis, order: ReaderReadingOrder) -> CGFloat {
        axis == .horizontal && order == .rightToLeft ? -1 : 1
    }

    private func fixture(axis: PageTurnAxis = .horizontal,
                         order: ReaderReadingOrder = .leftToRight) throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let current = UIViewController(); current.view.backgroundColor = .white
        let target = UIViewController(); target.view.backgroundColor = .blue
        let page = PageContent(identity: .init(sourceID: "visible-half", unitID: "current"), controller: current)
        let next = PageContent(identity: .init(sourceID: "visible-half", unitID: "target"), controller: target)
        let reader = try PagedReaderViewController(page: page, configuration: .init(
            presentation: .paged(effect: .curl, axis: axis),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64), readingOrder: order))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { _, _ in .page(next) }
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return reader
    }

    private func blueFraction(_ image: UIImage) throws -> CGFloat {
        let source = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for index in stride(from: 0, to: source.width * source.height * 4, by: 4) {
            if Int(bytes[index + 2]) > Int(bytes[index]) + 30 { count += 1 }
        }
        return CGFloat(count) / CGFloat(source.width * source.height)
    }

    func testSmallMovementCommitsWhenVisiblePreviousPageAlreadyCoversHalf() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let reader = try fixture(axis: axis, order: order); defer { reader.invalidate() }
                let extent: CGFloat = axis == .horizontal ? 320 : 480
                let cross: CGFloat = axis == .horizontal ? 240 : 160
                let physical = sign(axis: axis, order: order)
                let origin = extent * (physical > 0 ? 0.25 : 0.75)
                XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: point(origin, cross, axis: axis)))
                reader.updateInteractiveTurn(to: point(origin + physical * 4, cross, axis: axis))
                let paper = try XCTUnwrap(reader.activePaperView)
                let drag = try XCTUnwrap(paper.cornerDrag)
                XCTAssertGreaterThan(drag.gestureProgress, 0)
                XCTAssertLessThan(drag.gestureProgress, 0.17)
                XCTAssertFalse(drag.hasReachedCanvasMidpoint)
                let image = try XCTUnwrap(paper.cornerGPUImage())
                XCTAssertGreaterThan(try blueFraction(image), 0.55, "实际 GPU 中目标页必须已显露超过半屏")
                let attachment = XCTAttachment(image: image)
                attachment.name = "visible-over-half-small-drag-\(axis)-\(order)"
                attachment.lifetime = .keepAlways; add(attachment)
                reader.endInteractiveTurn(velocity: 0, animated: false)
                XCTAssertEqual(reader.currentPage.identity.unitID, "target", "纸面已过半，不能因手指只移动 4pt 而回退")
            }
        }
    }

    func testVisibleFractionMatchesActualGPUPixelsAcrossFacesAndAxes() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for direction in [PageTurnDirection.next, .previous] {
                    for crossFraction: CGFloat in [0.12, 0.5, 0.88] {
                        let reader = try fixture(axis: axis, order: order); defer { reader.invalidate() }
                        let extent: CGFloat = axis == .horizontal ? 320 : 480
                        let breadth: CGFloat = axis == .horizontal ? 480 : 320
                        let physical = sign(axis: axis, order: order) * (direction == .next ? -1 : 1)
                        let origin = point(extent * (physical > 0 ? 0.08 : 0.92), breadth * crossFraction, axis: axis)
                        XCTAssertTrue(try reader.beginInteractiveTurn(direction, at: origin))
                        let paper = try XCTUnwrap(reader.activePaperView)
                        for fraction: CGFloat in [0.15, 0.5, 0.85] {
                            let touch = point(extent * (physical > 0 ? fraction : 1 - fraction),
                                breadth * crossFraction + (fraction - 0.5) * 10, axis: axis)
                            reader.updateInteractiveTurn(to: touch)
                            let drag = try XCTUnwrap(paper.cornerDrag)
                            let estimated = try XCTUnwrap(paper.visibleTargetFraction(for: drag))
                            let pixels = try blueFraction(XCTUnwrap(paper.cornerGPUImage()))
                            XCTAssertEqual(estimated, pixels, accuracy: 0.006,
                                "实际显露面积必须一致：\(axis)/\(order)/\(direction)/\(crossFraction)/\(fraction)")
                        }
                    }
                }
            }
        }
    }

    func testVisibleHalfBoundaryNoMovementAndReversePriority() throws {
        // 平翻圆柱在投影中占用弧长，独立求得目标页恰好显露一半时的轴向坐标。
        let half = (CGFloat.pi - 2) * 0.1
        let cases: [(CGFloat, CGFloat, CGFloat, Bool)] = [
            (0.02, half - 0.001, 0, false), (0.02, half, 0, true), (0.02, half + 0.001, 0, true),
            (0.25, 0.25, 0, false), (0.25, 0.2625, -500, false), (0.25, 0.2625, -499, true),
            (0.25, 0.2625, .nan, false), (0.02, 0.06, 500, true)
        ]
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                for (start, end, velocity, completed) in cases {
                    let reader = try fixture(axis: axis, order: order); defer { reader.invalidate() }
                    let extent: CGFloat = axis == .horizontal ? 320 : 480
                    let cross: CGFloat = axis == .horizontal ? 240 : 160
                    let physical = sign(axis: axis, order: order)
                    func position(_ fraction: CGFloat) -> CGPoint {
                        point(extent * (physical > 0 ? fraction : 1 - fraction), cross, axis: axis)
                    }
                    XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: position(start)))
                    reader.updateInteractiveTurn(to: position(end))
                    let paper = try XCTUnwrap(reader.activePaperView)
                    let drag = try XCTUnwrap(paper.cornerDrag)
                    XCTAssertFalse(drag.hasReachedCanvasMidpoint)
                    XCTAssertLessThan(drag.gestureProgress, 0.17)
                    if end == half {
                        XCTAssertEqual(try XCTUnwrap(paper.visibleTargetFraction(for: drag)), 0.5, accuracy: 1e-8)
                    }
                    reader.endInteractiveTurn(velocity: velocity, animated: false)
                    XCTAssertEqual(reader.currentPage.identity.unitID, completed ? "target" : "current")
                }
            }
        }
    }

    func testNativeSmallReleaseUsesLastSubmittedArea() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let reader = try fixture()
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: CGPoint(x: 6.4, y: 240)))
        reader.updateInteractiveTurn(to: CGPoint(x: 80, y: 240))
        let paper = try XCTUnwrap(reader.activePaperView)
        let target = try XCTUnwrap(paper.cornerDrag)
        for _ in 0..<200 {
            if (paper.visibleTargetFraction(for: target) ?? 0) > 0.55 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(try XCTUnwrap(paper.visibleTargetFraction(for: target)), 0.55)
        // 新的逻辑目标尚未显示；判定仍须采用已提交的过半纸面。
        reader.updateInteractiveTurn(to: CGPoint(x: 25.6, y: 240))
        let logical = try XCTUnwrap(paper.cornerDrag)
        let material = try XCTUnwrap(logical.foldingPresentation(direction: .previous, size: reader.view.bounds.size, spread: false))
        XCTAssertLessThan(try XCTUnwrap(PaperCornerCurlGeometry.visiblePaperFraction(for: material, stripCount: 64)), 0.5)
        reader.endInteractiveTurn(velocity: 0, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "target")
    }

    func testNativeUnsubmittedAreaCannotCommitSmallMovement() throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let reader = try fixture()
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: CGPoint(x: 80, y: 240)))
        reader.updateInteractiveTurn(to: CGPoint(x: 84, y: 240))
        let paper = try XCTUnwrap(reader.activePaperView)
        XCTAssertEqual(paper.nativeCornerSubmittedFrameCount, 0)
        XCTAssertNil(paper.visibleTargetFraction(for: try XCTUnwrap(paper.cornerDrag)))
        reader.endInteractiveTurn(velocity: 0, animated: false)
        XCTAssertEqual(reader.currentPage.identity.unitID, "current")
    }
}
#endif
