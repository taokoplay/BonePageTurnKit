#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 回翻斜向折痕：点击注入固定斜向意图、拖动路径中段渐入斜度；正翻与拱页不受影响，端点仍精确落页。
@MainActor
final class PreviousSlantTurnTests: XCTestCase {
    private let canvas = CGSize(width: 390, height: 844)

    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index % 2 == 0 ? .systemYellow : .systemTeal
        return .init(identity: .init(sourceID: "previous-slant", unitID: String(index)), controller: child)
    }

    /// - Returns: 关闭原生时钟、由测试显式推进收尾的真实分页容器。
    private func makeReader() throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "斜向折痕测试需要开启翻页动画")
        let value = try PagedReaderViewController(page: Self.page(2),
            configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal),
                paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        value.usesDisplayLinkForPaperAnimation = false; value.usesDisplayLinkForAutomaticReading = false
        value.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            let next = current + (direction == .next ? 1 : -1)
            guard (0...8).contains(next) else { return .end }
            return .page(Self.page(next))
        }
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        value.view.setNeedsLayout(); value.view.layoutIfNeeded()
        return value
    }

    /// - Returns: 画布右缘中点起手、已向内展开一段的回翻交互拖拽。
    private func previousDrag(unfolded: CGFloat) throws -> PaperCornerDrag {
        let drag = try XCTUnwrap(PaperCornerDrag(size: canvas, axis: .horizontal, spread: false,
            inwardSign: -1, origin: CGPoint(x: canvas.width, y: canvas.height / 2), effect: .curl))
        return try XCTUnwrap(drag.moved(to: CGPoint(x: canvas.width - unfolded, y: canvas.height / 2),
                                        direction: .previous))
    }

    /// 无参数；点击回翻的固定斜向意图必须让收尾中段扫过斜向弧线，起点与落点与原收尾完全一致。无返回值。
    func testTapSlantIntentSweepsMidpathAndKeepsExactEndpoints() throws {
        let drag = try previousDrag(unfolded: 120)
        let intent = drag.makingTapSlantIntent()
        XCTAssertFalse(intent.prefersFlatTurn, "斜向意图必须允许折痕跟随")
        XCTAssertLessThan(intent.gripPosition.y, drag.gripPosition.y - 40, "意图横跨必须反向偏向所选纸角")
        var peakDelta: CGFloat = 0
        for fraction: CGFloat in stride(from: 0.2, through: 0.8, by: 0.1) {
            let base = drag.released(completed: true, fraction: fraction, direction: .previous)
            let slanted = drag.released(completed: true, fraction: fraction, direction: .previous,
                                        angleIntent: intent)
            peakDelta = max(peakDelta, abs(slanted.gripPosition.y - base.gripPosition.y))
        }
        XCTAssertGreaterThan(peakDelta, 30, "收尾中段必须出现明显的斜向折痕")
        for fraction: CGFloat in [CGFloat(0), 1] {
            let base = drag.released(completed: true, fraction: fraction, direction: .previous)
            let slanted = drag.released(completed: true, fraction: fraction, direction: .previous,
                                        angleIntent: intent)
            XCTAssertEqual(slanted.gripPosition.x, base.gripPosition.x, accuracy: 0.5,
                           "端点不能残留斜度：fraction \(fraction)")
            XCTAssertEqual(slanted.gripPosition.y, base.gripPosition.y, accuracy: 0.5,
                           "端点不能残留斜度：fraction \(fraction)")
        }
    }

    /// 无参数；回翻拖动保持逻辑触点精确贴手，斜向折痕由渲染姿态层叠加。无返回值。
    func testInteractivePreviousDragKeepsFingerExactContact() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        let origin = CGPoint(x: reader.view.bounds.maxX - 2, y: reader.view.bounds.midY)
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: origin))
        let mid = CGPoint(x: reader.view.bounds.maxX - reader.view.bounds.width * 0.4,
                          y: reader.view.bounds.midY)
        reader.updateInteractiveTurn(to: mid)
        let drag = try XCTUnwrap(reader.interactiveCornerDragForTesting)
        XCTAssertEqual(drag.gripPosition.x, mid.x, accuracy: 1e-6, "逻辑触点保持贴手")
        XCTAssertEqual(drag.gripPosition.y, mid.y, accuracy: 1e-6, "逻辑触点保持贴手")
    }

    /// 无参数；正翻同一路径不能出现额外横跨。无返回值。
    func testInteractiveNextDragKeepsZeroCross() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        let origin = CGPoint(x: reader.view.bounds.minX + 2, y: reader.view.bounds.midY)
        XCTAssertTrue(try reader.beginInteractiveTurn(.next, at: origin))
        let mid = CGPoint(x: reader.view.bounds.minX + reader.view.bounds.width * 0.4,
                          y: reader.view.bounds.midY)
        reader.updateInteractiveTurn(to: mid)
        let drag = try XCTUnwrap(reader.interactiveCornerDragForTesting)
        XCTAssertEqual(drag.gripPosition.y, reader.view.bounds.midY, accuracy: 0.5,
                       "正翻不能出现额外横跨")
    }

    /// 无参数；开启 previousTurnSlant 后点击回翻注入斜向意图，点击前进不注入；落定后意图随之清空。无返回值。
    func testTapPreviousInjectsSlantIntentAndNextDoesNot() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        reader.previousTurnSlant = 0.24
        XCTAssertTrue(try reader.turn(.previous))
        let intent = try XCTUnwrap(reader.pendingSlantIntentForTesting, "点击回翻必须注入固定斜向意图")
        XCTAssertFalse(intent.prefersFlatTurn)
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
        XCTAssertNil(reader.pendingSlantIntentForTesting, "落定后斜向意图随之清空")
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertNil(reader.pendingSlantIntentForTesting, "点击前进不能注入斜向意图")
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "2")
    }

    /// 无参数；默认 previousTurnSlant = 0：点击回翻不注入斜向意图，保持既有贴手契约。无返回值。
    func testDefaultSlantKeepsTapStraight() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        XCTAssertTrue(try reader.turn(.previous))
        XCTAssertNil(reader.pendingSlantIntentForTesting, "默认斜度关闭时不注入斜向意图")
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "1")
    }

    /// 无参数；开启 previousTurnSlant 后回翻拖动中段在逻辑横跨方向出现正弦包络偏向。无返回值。
    func testSlantModeBiasesInteractivePreviousDrag() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        reader.previousTurnSlant = 0.24
        let origin = CGPoint(x: reader.view.bounds.maxX - 2, y: reader.view.bounds.midY)
        XCTAssertTrue(try reader.beginInteractiveTurn(.previous, at: origin))
        let mid = CGPoint(x: reader.view.bounds.maxX - reader.view.bounds.width * 0.4,
                          y: reader.view.bounds.midY)
        reader.updateInteractiveTurn(to: mid)
        let drag = try XCTUnwrap(reader.interactiveCornerDragForTesting)
        let bias = 0.24 * reader.view.bounds.height * sin(.pi * min(1, max(0, drag.progress)))
        XCTAssertEqual(drag.gripPosition.y, mid.y - bias, accuracy: 1,
                       "回翻中段横跨按反向正弦包络偏向所选纸角")
        XCTAssertLessThan(drag.gripPosition.y, mid.y - 50)
    }

    /// 无参数；开启 nextTurnSlant 后点击下一页注入斜向意图，默认 0 不注入。无返回值。
    func testNextTapSlantFollowsHostSwitch() throws {
        let reader = try makeReader()
        defer { reader.invalidate() }
        XCTAssertTrue(try reader.turn(.next))
        XCTAssertNil(reader.pendingSlantIntentForTesting, "默认 nextTurnSlant = 0 不注入")
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "3")
        reader.nextTurnSlant = 0.16
        XCTAssertTrue(try reader.turn(.next))
        let intent = try XCTUnwrap(reader.pendingSlantIntentForTesting, "开启后点击下一页注入斜向意图")
        XCTAssertFalse(intent.prefersFlatTurn)
        for _ in 0..<400 { reader.advancePaperAnimation(elapsed: 1.0 / 60.0) }
        XCTAssertEqual(reader.currentPage.identity.unitID, "4")
        XCTAssertNil(reader.pendingSlantIntentForTesting)
    }
}
#endif
