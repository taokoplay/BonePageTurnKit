#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

/// 底部中间水平平移应整页平翻，只有明显斜拉才翻起纸角。
@MainActor
final class FlatEdgeTurnTests: XCTestCase {
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

    private func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index.isMultiple(of: 2) ? .systemTeal : .systemGray
        return .init(identity: .init(sourceID: "flat-turn", unitID: String(index)), controller: child)
    }

    private func reader() throws -> PagedReaderViewController {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let reader = try PagedReaderViewController(page: page(6), configuration: .init(
            presentation: .paged(effect: .curl, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { [self] identity, direction in
            .page(page((Int(identity.unitID) ?? 6) + (direction == .next ? 1 : -1)))
        }
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        return reader
    }

    private func send(_ pan: PanSample, to reader: PagedReaderViewController, state: UIGestureRecognizer.State,
                      translation: CGPoint) {
        pan.sampleState = state; pan.sampleTranslation = translation
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
    }

    private func assertWholeEdge(_ input: PaperCornerDrag, direction: PageTurnDirection,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(input.prefersFlatTurn, file: file, line: line)
        XCTAssertEqual(input.gripOrigin.y, input.origin.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(input.translation.y, 0, accuracy: 1e-6, file: file, line: line)
        let folded = try XCTUnwrap(input.foldingPresentation(direction: direction,
            size: input.canvasSize, spread: false), file: file, line: line)
        XCTAssertTrue(folded.prefersFlatTurn, file: file, line: line)
        let patches = PaperCornerCurlGeometry.patches(for: folded, stripCount: 64)
        XCTAssertTrue(patches.allSatisfy { abs($0.transform.b) < 1e-6 && abs($0.transform.c) < 1e-6 },
                      "整页折痕不能倾斜掀起底角", file: file, line: line)
    }
    /// - Parameters:
    ///   - flat: 是否按平翻呈现；
    ///   - start: 按下位置。
    /// - Returns: 水平拖动 120 点后的抓取状态。
    private func drag(flat: Bool, start: CGPoint) throws -> PaperCornerDrag {
        var drag = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
                                                 spread: false, inwardSign: -1, origin: start))
        drag.prefersFlatTurn = flat
        return try XCTUnwrap(drag.moved(to: CGPoint(x: start.x - 120, y: start.y)))
    }

    /// 无参数；底部中间按住时，平翻模式抓取基准保留触点高度，抓角模式锚定纸角。无返回值。
    func testFlatTurnKeepsFingerHeightInsteadOfCorner() throws {
        let start = CGPoint(x: 180, y: 474)
        let flat = try drag(flat: true, start: start)
        XCTAssertEqual(flat.gripOrigin.y, start.y, accuracy: 0.001, "平翻必须保留触点高度")
        let corner = try drag(flat: false, start: start)
        XCTAssertEqual(corner.gripOrigin.y, 480, accuracy: 0.001, "抓角仍锚定下方纸角")
        XCTAssertNotEqual(flat.gripOrigin.y, corner.gripOrigin.y)
    }

    /// 无参数；拖动过程中打开平翻标志后仍然保持触点高度。无返回值。
    func testFlatFlagSurvivesDragUpdates() throws {
        let start = CGPoint(x: 180, y: 474)
        var drag = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
                                                 spread: false, inwardSign: -1, origin: start))
        let first = try XCTUnwrap(drag.moved(to: CGPoint(x: 160, y: 474)))
        drag = first
        drag.prefersFlatTurn = true
        let second = try XCTUnwrap(drag.moved(to: CGPoint(x: 60, y: 474)))
        XCTAssertTrue(second.prefersFlatTurn, "标志必须随拖动更新保留")
        XCTAssertEqual(second.gripOrigin.y, start.y, accuracy: 0.001)
    }

    func testNativeBottomHorizontalPanStaysFlatThroughRelease() throws {
        for direction in [PageTurnDirection.next, .previous] {
            let reader = try reader(); defer { reader.invalidate() }
            let sign: CGFloat = direction == .next ? -1 : 1
            let pan = PanSample()
            pan.origin = CGPoint(x: sign < 0 ? 300 : 20, y: 474)
            pan.sampleVelocity = CGPoint(x: sign * 900, y: -40)
            send(pan, to: reader, state: .began, translation: CGPoint(x: sign * 12, y: -1))
            try assertWholeEdge(XCTUnwrap(reader.activePaperView?.cornerDrag), direction: direction)
            send(pan, to: reader, state: .changed, translation: CGPoint(x: sign * 150, y: -6))
            try assertWholeEdge(XCTUnwrap(reader.activePaperView?.cornerDrag), direction: direction)
            send(pan, to: reader, state: .ended, translation: CGPoint(x: sign * 150, y: -6))
            var frames = 0
            for _ in 0..<120 where reader.isTransitioning {
                try assertWholeEdge(XCTUnwrap(reader.activePaperView?.cornerDrag), direction: direction)
                reader.advancePaperAnimation(elapsed: 1.0 / 60)
                frames += 1
            }
            XCTAssertGreaterThan(frames, 4, "平翻收尾仍需完整播放")
            XCTAssertFalse(reader.isTransitioning)
            XCTAssertEqual(reader.currentPage.identity.unitID, direction == .next ? "7" : "5")
        }
    }

    func testHorizontalPanUsesFingerDirectionEvenAtOppositeBottomCorner() throws {
        for sign: CGFloat in [-1, 1] {
            let reader = try reader(); defer { reader.invalidate() }
            let pan = PanSample()
            pan.origin = CGPoint(x: sign < 0 ? 40 : 280, y: 474)
            pan.sampleVelocity = CGPoint(x: sign * 900, y: 0)
            send(pan, to: reader, state: .began, translation: CGPoint(x: sign * 12, y: 0))
            let drag = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            XCTAssertEqual(drag.inwardSign, sign, "底部平翻方向由手指决定，不能按所处角落反向")
            XCTAssertTrue(drag.prefersFlatTurn)
        }
    }

    func testNativeBottomDiagonalPanStillUsesCorner() throws {
        for sign: CGFloat in [-1, 1] {
            let reader = try reader(); defer { reader.invalidate() }
            let pan = PanSample()
            pan.origin = CGPoint(x: sign < 0 ? 300 : 20, y: 474)
            pan.sampleVelocity = CGPoint(x: sign * 600, y: -600)
            send(pan, to: reader, state: .began, translation: CGPoint(x: sign * 12, y: -12))
            send(pan, to: reader, state: .changed, translation: CGPoint(x: sign * 90, y: -90))
            let input = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            XCTAssertFalse(input.prefersFlatTurn)
            XCTAssertEqual(input.gripOrigin.y, 480, accuracy: 1e-6)
            let folded = try XCTUnwrap(input.foldingPresentation(direction: sign < 0 ? .next : .previous,
                size: input.canvasSize, spread: false))
            XCTAssertTrue(PaperCornerCurlGeometry.patches(for: folded, stripCount: 64).contains {
                abs($0.transform.b) > 0.01 || abs($0.transform.c) > 0.01
            })
        }
    }

    func testFlatModeSurvivesPreviousMaterialRoundTrip() throws {
        var seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 320, height: 480), axis: .horizontal,
            spread: false, inwardSign: 1, origin: CGPoint(x: 20, y: 474)))
        seed.prefersFlatTurn = true
        let input = try XCTUnwrap(seed.moved(to: CGPoint(x: 170, y: 470), direction: .previous))
        try assertWholeEdge(input, direction: .previous)
        let folded = try XCTUnwrap(input.foldingPresentation(direction: .previous, size: seed.canvasSize, spread: false))
        let returned = try XCTUnwrap(folded.interactivePresentation(direction: .previous, size: seed.canvasSize, spread: false))
        try assertWholeEdge(returned, direction: .previous)
    }

    func testNativeHorizontalThenDiagonalKeepsGrabHeightAndFollowsAngle() throws {
        for direction in [PageTurnDirection.next, .previous] {
            let reader = try reader(); defer { reader.invalidate() }
            let sign: CGFloat = direction == .next ? -1 : 1
            let pan = PanSample()
            pan.origin = CGPoint(x: sign < 0 ? 300 : 20, y: 474)
            pan.sampleVelocity = CGPoint(x: sign * 900, y: 0)
            send(pan, to: reader, state: .began, translation: CGPoint(x: sign * 12, y: 0))
            let initial = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            let id = reader.activeTransitionID
            XCTAssertTrue(initial.prefersFlatTurn)
            send(pan, to: reader, state: .changed, translation: CGPoint(x: sign * 110, y: -36))
            let angled = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            XCTAssertFalse(angled.prefersFlatTurn, "横拖后改变角度必须能退出平翻投影")
            XCTAssertEqual(angled.gripOrigin.y, initial.gripOrigin.y, accuracy: 1e-6,
                           "转向时抓取高度不能突然跳到纸角")
            XCTAssertEqual(angled.gripPosition.y, pan.origin.y - 36, accuracy: 1e-6)
            let folded = try XCTUnwrap(angled.foldingPresentation(direction: direction,
                size: angled.canvasSize, spread: false))
            XCTAssertEqual(folded.gripOrigin.y, initial.gripOrigin.y, accuracy: 1e-6)
            XCTAssertTrue(PaperCornerCurlGeometry.patches(for: folded, stripCount: 64).contains {
                abs($0.transform.b) > 0.01 || abs($0.transform.c) > 0.01
            })
            send(pan, to: reader, state: .changed, translation: CGPoint(x: sign * 160, y: 0))
            let straightAgain = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            let flat = try XCTUnwrap(straightAgain.foldingPresentation(direction: direction,
                size: straightAgain.canvasSize, spread: false))
            XCTAssertTrue(PaperCornerCurlGeometry.patches(for: flat, stripCount: 64).allSatisfy {
                abs($0.transform.b) < 1e-6 && abs($0.transform.c) < 1e-6
            }, "回到水平轨迹时纸面应恢复整边水平翻动")
            XCTAssertEqual(reader.activeTransitionID, id, "改角度不应另起翻页事务")
        }
    }

    func testNativePreviousCanRetargetAngleUpAndDown() throws {
        let reader = try reader(); defer { reader.invalidate() }
        let pan = PanSample()
        pan.origin = CGPoint(x: 20, y: 240)
        pan.sampleVelocity = CGPoint(x: 900, y: 0)
        send(pan, to: reader, state: .began, translation: CGPoint(x: 12, y: 0))
        var slopes: [CGFloat] = []
        for cross: CGFloat in [-40, 40] {
            send(pan, to: reader, state: .changed, translation: CGPoint(x: 140, y: cross))
            let input = try XCTUnwrap(reader.activePaperView?.cornerDrag)
            XCTAssertEqual(input.gripPosition.y, pan.origin.y + cross, accuracy: 1e-6)
            let folded = try XCTUnwrap(input.foldingPresentation(direction: .previous,
                size: input.canvasSize, spread: false))
            let patch = try XCTUnwrap(PaperCornerCurlGeometry.patches(for: folded, stripCount: 64).last { $0.back })
            slopes.append(patch.transform.b)
        }
        XCTAssertLessThan(slopes[0] * slopes[1], 0, "向上、向下斜拖应产生相反的实际折痕倾向")
    }

    func testNativeShallowDiagonalPreviousKeepsItsCrossMovement() throws {
        let reader = try reader(); defer { reader.invalidate() }
        let pan = PanSample()
        pan.origin = CGPoint(x: 20, y: 240)
        pan.sampleVelocity = CGPoint(x: 900, y: 180)
        send(pan, to: reader, state: .began, translation: CGPoint(x: 12, y: 2))
        send(pan, to: reader, state: .changed, translation: CGPoint(x: 180, y: 18))
        let input = try XCTUnwrap(reader.activePaperView?.cornerDrag)
        XCTAssertFalse(input.prefersFlatTurn)
        XCTAssertEqual(input.gripPosition.y, 258, accuracy: 1e-6,
                       "浅角度的有意斜拖也不能永久被压成水平")
    }

    func testDisplayedPreviousPaperFollowsAngleRetargeting() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let reader = try reader()
        reader.usesDisplayLinkForPaperAnimation = true
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        let pan = PanSample()
        pan.origin = CGPoint(x: 20, y: 240)
        pan.sampleVelocity = CGPoint(x: 900, y: 0)
        send(pan, to: reader, state: .began, translation: CGPoint(x: 12, y: 0))
        let paper = try XCTUnwrap(reader.activePaperView)
        var slopes: [CGFloat] = []
        for cross: CGFloat in [-40, 40] {
            let before = paper.submittedCornerDrag
            send(pan, to: reader, state: .changed, translation: CGPoint(x: 140, y: cross))
            XCTAssertEqual(paper.submittedCornerDrag, before, "转向不应瞬移已经提交的纸面")
            for _ in 0..<150 {
                if let shown = paper.submittedCornerDrag,
                   abs(shown.gripPosition.y - (240 + cross)) < 0.1,
                   abs(shown.gripPosition.x - 160) < 0.1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let shown = try XCTUnwrap(paper.submittedCornerDrag)
            XCTAssertEqual(shown.gripPosition.x, 160, accuracy: 0.1)
            XCTAssertEqual(shown.gripPosition.y, 240 + cross, accuracy: 0.1)
            let folded = try XCTUnwrap(shown.foldingPresentation(direction: .previous,
                size: shown.canvasSize, spread: false))
            let back = try XCTUnwrap(PaperCornerCurlGeometry.patches(for: folded, stripCount: 64).last { $0.back })
            slopes.append(back.transform.b)
        }
        XCTAssertLessThan(slopes[0] * slopes[1], 0, "GPU 实际提交的纸面必须随上下斜拖改变方向")
    }

    func testFastDiagonalPreviousReleaseKeepsVisibleAngleAndFullPlayback() async throws {
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
        let reader = try reader()
        reader.usesDisplayLinkForPaperAnimation = true
        let window = UIWindow(frame: reader.view.bounds)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        let pan = PanSample()
        pan.origin = CGPoint(x: 20, y: 240)
        pan.sampleVelocity = CGPoint(x: 2_400, y: -350)
        send(pan, to: reader, state: .began, translation: CGPoint(x: 12, y: 0))
        send(pan, to: reader, state: .changed, translation: CGPoint(x: 270, y: -40))
        send(pan, to: reader, state: .ended, translation: CGPoint(x: 280, y: -40))
        let paper = try XCTUnwrap(reader.activePaperView)
        XCTAssertEqual(paper.nativeCornerSubmittedFrameCount, 0)
        var sawAngle = false
        var maximumFold: CGFloat = 0
        var minimumFold: CGFloat = 1
        for _ in 0..<500 {
            if let shown = paper.submittedCornerDrag,
               let fold = shown.foldingPresentation(direction: .previous, size: shown.canvasSize, spread: false) {
                maximumFold = max(maximumFold, 1 - fold.progress)
                minimumFold = min(minimumFold, 1 - fold.progress)
                sawAngle = sawAngle || PaperCornerCurlGeometry.patches(for: fold, stripCount: 64).contains {
                    abs($0.transform.b) > 0.02 || abs($0.transform.c) > 0.02
                }
            }
            if !reader.isTransitioning { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(reader.isTransitioning)
        XCTAssertEqual(reader.currentPage.identity.unitID, "5")
        XCTAssertGreaterThan(maximumFold, 0.8, "角度修复不能跳过快速回翻的落页阶段")
        XCTAssertLessThan(minimumFold, 0.2, "快速回翻仍须从手势侧尚未展开的位置开始")
        XCTAssertTrue(sawAngle, "首帧之前斜向松手，后续可见动画仍须保留手指的斜向意图")
    }
}
#endif
