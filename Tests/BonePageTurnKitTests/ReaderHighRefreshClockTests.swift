#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ReaderHighRefreshClockTests: XCTestCase {
    /// 同一时钟可在高刷与普通屏幕间调整，stop 后不残留资源或旧帧率申请。
    func testRequestMaximumRefreshAndReconfigureWithoutRestarting() throws {
        let clock = ReaderDisplayLink()
        defer { clock.stop() }
        clock.start(maximumFramesPerSecond: 120)
        let high = try XCTUnwrap(clock.activeFrameRateRange)
        XCTAssertEqual(high.preferred, 120); XCTAssertEqual(high.maximum, 120)
        XCTAssertGreaterThan(high.minimum, 60)
        XCTAssertTrue(clock.isRunning)
        clock.start(maximumFramesPerSecond: 60)
        let normal = try XCTUnwrap(clock.activeFrameRateRange)
        XCTAssertEqual(normal.minimum, 60); XCTAssertEqual(normal.maximum, 60); XCTAssertEqual(normal.preferred, 60)
        clock.stop()
        XCTAssertFalse(clock.isRunning); XCTAssertNil(clock.activeFrameRateRange)
    }

    /// 不指定屏幕或传入非法上限时，向当前屏幕申请合法范围，不硬编码某个型号。
    func testDefaultAndInvalidRequestUseCurrentScreenMaximum() throws {
        let clock = ReaderDisplayLink()
        defer { clock.stop() }
        for maximum in [nil, 0, -1] as [Int?] {
            clock.start(maximumFramesPerSecond: maximum)
            let range = try XCTUnwrap(clock.activeFrameRateRange)
            XCTAssertEqual(range.maximum, Float(max(1, UIScreen.main.maximumFramesPerSecond)))
            XCTAssertEqual(range.preferred, range.maximum)
            XCTAssertGreaterThan(range.minimum, 0); XCTAssertLessThanOrEqual(range.minimum, range.maximum)
        }
    }

    /// 原生时钟运行中调整申请仍连续交付正有限的真实帧间时间，不改变时间单位。
    func testLiveClockContinuesAfterChangingRefreshRequest() async throws {
        let clock = ReaderDisplayLink(), finished = expectation(description: "刷新申请切换后继续计时")
        defer { clock.stop() }
        var count = 0
        clock.onTick = { interval in
            XCTAssertTrue(interval.isFinite); XCTAssertGreaterThan(interval, 0); XCTAssertLessThan(interval, 0.5)
            count += 1
            if count == 1 { clock.start(maximumFramesPerSecond: 60) }
            if count == 4 { clock.stop(); finished.fulfill() }
        }
        clock.start(maximumFramesPerSecond: 120)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(count, 4)
        XCTAssertFalse(clock.isRunning)
    }
}
#endif
