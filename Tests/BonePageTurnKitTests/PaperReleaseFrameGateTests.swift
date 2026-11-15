#if canImport(CoreGraphics)
import Foundation
import XCTest
@testable import BonePageTurnKit

final class PaperReleaseFrameGateTests: XCTestCase {
    /// 无参数；首帧到来前不累计隐形动画时间。无返回值。
    func testMissingFirstFrameDoesNotAdvanceTimeline() {
        var gate = PaperReleaseFrameGate(waitsForGPU: true, submittedFrameCount: 0)
        for _ in 0..<100 { XCTAssertNil(gate.step(elapsed: 0.1, submittedFrameCount: 0)) }
        XCTAssertEqual(gate.step(elapsed: 1.0 / 60, submittedFrameCount: 1), 1.0 / 60)
        XCTAssertNil(gate.step(elapsed: 1.0 / 120, submittedFrameCount: 1))
        XCTAssertEqual(gate.step(elapsed: 1.0 / 120, submittedFrameCount: 2), 1.0 / 60)
    }

    /// 无参数；只有新提交可推进，长停顿最多推进既有一帧上限，正常双驱动频率不会减半速度。无返回值。
    func testSubmissionAcknowledgementAndBoundedCatchup() throws {
        var gate = PaperReleaseFrameGate(waitsForGPU: true, submittedFrameCount: 8)
        for _ in 0..<100 { XCTAssertNil(gate.step(elapsed: 0.1, submittedFrameCount: 8)) }
        XCTAssertEqual(try XCTUnwrap(gate.step(elapsed: 0.1, submittedFrameCount: 9)),
            PaperCornerDragFollower.maximumFrameStep, accuracy: 1e-9)
        XCTAssertNil(gate.step(elapsed: 1.0 / 120, submittedFrameCount: 9))
        XCTAssertEqual(try XCTUnwrap(gate.step(elapsed: 1.0 / 120, submittedFrameCount: 10)), 1.0 / 60, accuracy: 1e-9)
    }

    /// 无参数；离屏和标量保留原 0.1 秒上限，非法时间不推进。无返回值。
    func testManualTimingAndInvalidDeltas() {
        var gate = PaperReleaseFrameGate(waitsForGPU: false, submittedFrameCount: 0)
        for value in [Double.nan, .infinity, -1, 0] { XCTAssertNil(gate.step(elapsed: value, submittedFrameCount: 0)) }
        XCTAssertEqual(gate.step(elapsed: 1, submittedFrameCount: 0), 0.1)
        XCTAssertEqual(gate.step(elapsed: 0.05, submittedFrameCount: 0), 0.05)
    }

    /// 原生暂时空闲只放行当前步，下一张姿态仍须等 GPU，且不重复计算同一段时间。
    func testIdleSubmissionDoesNotDisableFutureFrameAcknowledgements() throws {
        let tick = 1.0 / 120
        var gate = PaperReleaseFrameGate(waitsForGPU: true, submittedFrameCount: 3)
        XCTAssertEqual(try XCTUnwrap(gate.step(elapsed: tick, submittedFrameCount: 3, framesExhausted: true)),
                       tick, accuracy: 1e-9)
        XCTAssertNil(gate.step(elapsed: tick, submittedFrameCount: 3, framesExhausted: false),
                     "已请求下一姿态后必须恢复等帧，不能继续隐形跑时间")
        XCTAssertEqual(try XCTUnwrap(gate.step(elapsed: tick, submittedFrameCount: 4, framesExhausted: false)),
                       tick * 2, accuracy: 1e-9)
    }

    func testIdleThenDelayedGPUStillUsesVisibleFrameStepLimit() throws {
        var gate = PaperReleaseFrameGate(waitsForGPU: true, submittedFrameCount: 7)
        _ = gate.step(elapsed: 1.0 / 120, submittedFrameCount: 7, framesExhausted: true)
        XCTAssertNil(gate.step(elapsed: 0.2, submittedFrameCount: 7, framesExhausted: false))
        let step = try XCTUnwrap(gate.step(elapsed: 0.2, submittedFrameCount: 8, framesExhausted: false))
        XCTAssertLessThanOrEqual(step, PaperCornerDragFollower.maximumFrameStep)
    }
}
#endif
