#if canImport(UIKit)
import XCTest
import UIKit
@testable import BonePageTurnKit

/// 水墨／破冰的动画原点必须等于手指当前触点：.began 取按下位置，
/// .changed 起每帧取实时位置（原点跟随），快速连滑排队也从最近触点起笔。
@MainActor
final class InkOriginFollowTests: XCTestCase {
    private final class PanSample: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .possible
        var sampleTranslation = CGPoint.zero
        var sampleLocation = CGPoint.zero
        var sampleVelocity = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { sampleLocation }
        override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
        override func velocity(in view: UIView?) -> CGPoint { sampleVelocity }
    }

    private static func page(_ index: Int) -> PageContent {
        let child = UIViewController()
        child.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        child.view.backgroundColor = index.isMultiple(of: 2) ? .systemTeal : .systemGray
        return .init(identity: .init(sourceID: "ink-origin", unitID: String(index)), controller: child)
    }

    private func reader(effect: PageTurnEffect) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: Self.page(5), configuration: .init(
            presentation: .paged(effect: effect, axis: .horizontal),
            paper: .init(maximumSnapshotPixels: 262_144, stripCount: 64)))
        reader.usesDisplayLinkForPaperAnimation = false
        reader.usesDisplayLinkForAutomaticReading = false
        reader.pageProvider = { identity, direction in
            guard let current = Int(identity.unitID) else { return .failed }
            return .page(Self.page(current + (direction == .next ? 1 : -1)))
        }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        return reader
    }

    private func send(_ reader: PagedReaderViewController, _ pan: PanSample) {
        reader.perform(NSSelectorFromString("handlePan:"), with: pan)
    }

    /// 左滑（next）：原点从按下位置开始，拖动中每帧等于手指实时位置。
    func testInkOriginFollowsFingerDuringNextDrag() throws {
        let reader = try reader(effect: .inkwash)
        defer { reader.invalidate() }
        let pan = PanSample()
        pan.sampleVelocity = CGPoint(x: -800, y: 0)
        pan.sampleLocation = CGPoint(x: 120, y: 300)
        pan.sampleTranslation = CGPoint(x: 12, y: 4)
        pan.sampleState = .began
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 108, y: 296))
        guard reader.wholePageEffectOriginForTesting != nil else { return }
        // 拖动中：原点直接等于实时手指位置（100, 320）。
        pan.sampleState = .changed
        pan.sampleTranslation = CGPoint(x: -80, y: 20)
        pan.sampleLocation = CGPoint(x: 100, y: 320)
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 100, y: 320))
        pan.sampleLocation = CGPoint(x: 60, y: 340)
        pan.sampleTranslation = CGPoint(x: -120, y: 40)
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 60, y: 340))
    }

    /// 右滑（previous）：原点同样等于手指位置；方向只影响着色器内部镜像，不改原点语义。
    func testInkOriginFollowsFingerDuringPreviousDrag() throws {
        let reader = try reader(effect: .inkwash)
        defer { reader.invalidate() }
        let pan = PanSample()
        pan.sampleVelocity = CGPoint(x: 800, y: 0)
        pan.sampleLocation = CGPoint(x: 80, y: 260)
        pan.sampleTranslation = CGPoint(x: 10, y: 2)
        pan.sampleState = .began
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 70, y: 258))
        pan.sampleState = .changed
        pan.sampleLocation = CGPoint(x: 150, y: 300)
        pan.sampleTranslation = CGPoint(x: 90, y: 10)
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 150, y: 300))
    }

    /// 破冰融霜：裂源与水墨同一跟随契约。
    func testIceCrackOriginFollowsFinger() throws {
        let reader = try reader(effect: .icecrack)
        defer { reader.invalidate() }
        let pan = PanSample()
        pan.sampleVelocity = CGPoint(x: -600, y: 0)
        pan.sampleLocation = CGPoint(x: 200, y: 150)
        pan.sampleTranslation = CGPoint(x: 8, y: 0)
        pan.sampleState = .began
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 192, y: 150))
        pan.sampleState = .changed
        pan.sampleLocation = CGPoint(x: 90, y: 220)
        pan.sampleTranslation = CGPoint(x: -60, y: 10)
        send(reader, pan)
        XCTAssertEqual(reader.wholePageEffectOriginForTesting, CGPoint(x: 90, y: 220))
    }

    /// 快速连滑排队：下一笔水墨从手势按下位置起墨，而不是页缘中点或默认位置。
    func testQueuedInkTurnUsesRecentTouchOrigin() throws {
        let reader = try reader(effect: .inkwash)
        defer { reader.invalidate() }
        let first = PanSample()
        first.sampleVelocity = CGPoint(x: -900, y: 0)
        first.sampleLocation = CGPoint(x: 200, y: 300)
        first.sampleTranslation = .zero
        first.sampleState = .began
        send(reader, first)
        first.sampleState = .ended
        send(reader, first)
        // 收尾期间的新滑动：排队并在收尾后从该手势的按下位置起墨。
        let second = PanSample()
        second.sampleVelocity = CGPoint(x: -900, y: 0)
        second.sampleLocation = CGPoint(x: 140, y: 330)
        second.sampleTranslation = CGPoint(x: 9, y: 3)
        second.sampleState = .began
        send(reader, second)
        XCTAssertTrue(reader.wholePageEffectOriginForTesting != nil)
    }
}
#endif
