import Foundation
import XCTest
@testable import BonePageTurnKit

@MainActor
final class ContinuousLoadCoordinatorTests: XCTestCase {
    /// 同方向同版本在加载和准备安装阶段均去重，拒绝请求不接管其回调。
    func testDuplicateRequestDoesNotTakeOwnership() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = makeToken()
        let window = try makeWindow()
        var originalOutcomes: [ContinuousLoadOutcome] = []
        var originalCancellations = 0
        var rejectedCallbacks = 0
        let ticket = try coordinator.begin(direction: .next, token: token,
                                           cancel: { originalCancellations += 1 },
                                           completion: { originalOutcomes.append($0) })
        for accepted in [false, true] {
            if accepted { try coordinator.accept(ticket, window: window, anchor: nil) }
            assertError(.interactionInProgress) {
                try coordinator.begin(direction: .next, token: token,
                                      cancel: { rejectedCallbacks += 1 },
                                      completion: { _ in rejectedCallbacks += 1 })
            }
            XCTAssertEqual(coordinator.activeCount, 1)
        }
        coordinator.finish(ticket, outcome: .cancelled)
        XCTAssertEqual(originalCancellations, 1)
        XCTAssertEqual(originalOutcomes, [.cancelled])
        XCTAssertEqual(rejectedCallbacks, 0)
    }

    /// 两个方向可以并行；其他协调器拥有的同方向同版本请求不能提交或结束任务。
    func testDirectionsAreIndependentAndForeignTicketsAreRejected() throws {
        let coordinator = ContinuousLoadCoordinator()
        let other = ContinuousLoadCoordinator()
        let token = makeToken()
        let window = try makeWindow()
        var outcomes: [ContinuousLoadOutcome] = []
        let previous = try coordinator.begin(direction: .previous, token: token, cancel: {},
                                             completion: { outcomes.append($0) })
        let next = try coordinator.begin(direction: .next, token: token, cancel: {},
                                         completion: { outcomes.append($0) })
        let foreign = try other.begin(direction: .previous, token: token, cancel: {}, completion: { _ in })
        XCTAssertEqual(previous.direction, .previous)
        XCTAssertEqual(next.token, token)
        XCTAssertNotEqual(previous.id, next.id)
        XCTAssertNotEqual(previous, foreign)
        assertError(.staleWindow) { try coordinator.accept(foreign, window: window, anchor: nil) }
        coordinator.finish(foreign, outcome: .cancelled)
        XCTAssertEqual(coordinator.activeCount, 2)
        XCTAssertTrue(outcomes.isEmpty)
        coordinator.finish(previous, outcome: .cancelled)
        XCTAssertEqual(coordinator.activeCount, 1)
        try coordinator.accept(next, window: window, anchor: nil)
        XCTAssertEqual(coordinator.preparedUpdate?.ticket, next)
        coordinator.invalidate()
        other.invalidate()
    }

    /// 同方向跨窗口版本或展示代际替换时，旧任务先结束，新任务随后建立。
    func testNewTokenSupersedesSameDirectionBeforeTakingOwnership() throws {
        for changesPresentation in [false, true] {
            let coordinator = ContinuousLoadCoordinator()
            let originalToken = makeToken()
            let nextToken = ContinuousUpdateToken(presentationID: changesPresentation ? UUID() : originalToken.presentationID,
                                                 revision: changesPresentation ? originalToken.revision : 1)
            var events: [String] = []
            let original = try coordinator.begin(direction: .next, token: originalToken, cancel: {
                XCTAssertEqual(coordinator.activeCount, 0)
                XCTAssertNil(coordinator.preparedUpdate)
                events.append("取消旧任务")
            }, completion: { outcome in
                XCTAssertEqual(coordinator.activeCount, 0)
                XCTAssertEqual(outcome, .superseded)
                events.append("结束旧任务")
            })
            try coordinator.accept(original, window: makeWindow(), anchor: nil)
            let replacement = try coordinator.begin(direction: .next, token: nextToken, cancel: {}, completion: { _ in })
            XCTAssertEqual(events, ["取消旧任务", "结束旧任务"])
            XCTAssertNotEqual(original.id, replacement.id)
            XCTAssertEqual(replacement.token, nextToken)
            XCTAssertEqual(coordinator.activeCount, 1)
            XCTAssertNil(coordinator.preparedUpdate)
            coordinator.finish(original, outcome: .cancelled)
            XCTAssertEqual(events.count, 2)
            coordinator.invalidate()
        }
    }

    /// 完整窗口只保留最新准备结果，被覆盖请求和重复提交均不可再次安装。
    func testLatestPreparedWindowSupersedesPreviousResult() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = makeToken()
        let originalWindow = try makeWindow("original")
        let latestWindow = try makeWindow("latest")
        let anchor = ContinuousAnchor(identity: latestWindow.items[0].identity, offsetInItem: 20)
        var cancellations = 0
        var outcomes: [ContinuousLoadOutcome] = []
        let previous = try coordinator.begin(direction: .previous, token: token, cancel: { cancellations += 1 },
                                             completion: { outcomes.append($0) })
        let next = try coordinator.begin(direction: .next, token: token, cancel: {}, completion: { _ in })
        try coordinator.accept(previous, window: originalWindow, anchor: nil)
        assertError(.staleWindow) { try coordinator.accept(previous, window: latestWindow, anchor: anchor) }
        XCTAssertEqual(coordinator.preparedUpdate?.window, originalWindow)
        try coordinator.accept(next, window: latestWindow, anchor: anchor)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(outcomes, [.superseded])
        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertEqual(coordinator.preparedUpdate?.ticket, next)
        XCTAssertEqual(coordinator.preparedUpdate?.window, latestWindow)
        XCTAssertEqual(coordinator.preparedUpdate?.anchor, anchor)
        assertError(.staleWindow) { try coordinator.accept(previous, window: originalWindow, anchor: nil) }
        assertError(.staleWindow) { try coordinator.accept(next, window: latestWindow, anchor: nil) }
        coordinator.invalidate()
    }

    /// 安装成功仅回调一次且不取消，回调观察到的所有权和准备结果均已清除。
    func testInstalledCompletionRunsOnceWithoutCancellation() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = makeToken()
        let installedToken = ContinuousUpdateToken(presentationID: token.presentationID, revision: 1)
        var cancellations = 0
        var outcomes: [ContinuousLoadOutcome] = []
        var ownedTicket: ContinuousLoadTicket?
        let ticket = try coordinator.begin(direction: .next, token: token, cancel: { cancellations += 1 },
                                           completion: { outcome in
            XCTAssertEqual(coordinator.activeCount, 0)
            XCTAssertNil(coordinator.preparedUpdate)
            outcomes.append(outcome)
            if let ownedTicket { coordinator.finish(ownedTicket, outcome: .cancelled) }
        })
        ownedTicket = ticket
        try coordinator.accept(ticket, window: makeWindow(), anchor: nil)
        coordinator.finish(ticket, outcome: .installed(installedToken))
        coordinator.finish(ticket, outcome: .installed(installedToken))
        coordinator.invalidate()
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(outcomes, [.installed(installedToken)])
    }

    /// 取消和拒绝均先取消再完成，重复终止以及迟到结果不能再次触发回调。
    func testCancellationAndRejectionDeliverCallbacksOnceInOrder() throws {
        for outcome: ContinuousLoadOutcome in [.cancelled, .rejected(.staleWindow)] {
            let coordinator = ContinuousLoadCoordinator()
            let window = try makeWindow()
            var events: [String] = []
            var ownedTicket: ContinuousLoadTicket?
            let ticket = try coordinator.begin(direction: .next, token: makeToken(), cancel: {
                XCTAssertEqual(coordinator.activeCount, 0)
                XCTAssertNil(coordinator.preparedUpdate)
                events.append("取消")
                if let ownedTicket { coordinator.finish(ownedTicket, outcome: .cancelled) }
            }, completion: { result in
                XCTAssertEqual(result, outcome)
                events.append("完成")
            })
            ownedTicket = ticket
            try coordinator.accept(ticket, window: window, anchor: nil)
            coordinator.finish(ticket, outcome: outcome)
            coordinator.finish(ticket, outcome: outcome)
            assertError(.staleWindow) { try coordinator.accept(ticket, window: window, anchor: nil) }
            coordinator.invalidate()
            XCTAssertEqual(events, ["取消", "完成"])
        }
    }

    /// 过期任务在任何回调前批量清除，同版本的活动任务和准备结果仍被保留。
    func testDiscardClearsOldTokensBeforeCallbacksAndPreservesCurrentToken() throws {
        for preservesNext in [false, true] {
            let coordinator = ContinuousLoadCoordinator()
            let oldToken = makeToken()
            let currentToken = ContinuousUpdateToken(presentationID: oldToken.presentationID, revision: 1)
            let expectedCount = preservesNext ? 1 : 0
            var cancellations = 0
            var outcomes: [ContinuousLoadOutcome] = []
            let cancel: () -> Void = {
                XCTAssertEqual(coordinator.activeCount, expectedCount)
                XCTAssertEqual(coordinator.preparedUpdate != nil, preservesNext)
                cancellations += 1
                coordinator.discard(except: currentToken)
            }
            _ = try coordinator.begin(direction: .previous, token: oldToken, cancel: cancel,
                                      completion: { outcomes.append($0) })
            let next = try coordinator.begin(direction: .next, token: preservesNext ? currentToken : oldToken,
                                             cancel: cancel, completion: { outcomes.append($0) })
            try coordinator.accept(next, window: makeWindow(), anchor: nil)
            coordinator.discard(except: currentToken)
            XCTAssertEqual(coordinator.activeCount, expectedCount)
            XCTAssertEqual(cancellations, preservesNext ? 1 : 2)
            XCTAssertEqual(outcomes, Array(repeating: .superseded, count: preservesNext ? 1 : 2))
            if preservesNext {
                XCTAssertEqual(coordinator.preparedUpdate?.ticket, next)
                coordinator.finish(next, outcome: .installed(currentToken))
            }
            coordinator.invalidate()
        }
    }

    /// 失效幂等，加载和准备中的任务均终止；迟到请求及结果统一报告 inactive。
    func testInvalidationRejectsLateRequestsAndResults() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = makeToken()
        let window = try makeWindow()
        var cancellations = 0
        var outcomes: [ContinuousLoadOutcome] = []
        let cancel: () -> Void = {
            XCTAssertEqual(coordinator.activeCount, 0)
            XCTAssertNil(coordinator.preparedUpdate)
            cancellations += 1
            coordinator.invalidate()
        }
        let previous = try coordinator.begin(direction: .previous, token: token, cancel: cancel,
                                             completion: { outcomes.append($0) })
        let next = try coordinator.begin(direction: .next, token: token, cancel: cancel,
                                         completion: { outcomes.append($0) })
        try coordinator.accept(next, window: window, anchor: nil)
        coordinator.invalidate()
        coordinator.invalidate()
        coordinator.finish(previous, outcome: .cancelled)
        coordinator.finish(next, outcome: .installed(token))
        assertError(.inactive) {
            try coordinator.begin(direction: .next, token: token,
                                  cancel: { XCTFail("拒绝请求不能被接管") },
                                  completion: { _ in XCTFail("拒绝请求不能完成") })
        }
        assertError(.inactive) { try coordinator.accept(next, window: window, anchor: nil) }
        XCTAssertEqual(cancellations, 2)
        XCTAssertEqual(outcomes, [.invalidated, .invalidated])
        XCTAssertEqual(coordinator.activeCount, 0)
        XCTAssertNil(coordinator.preparedUpdate)
    }

    /// 取消和完成回调期间拒绝 begin/accept，嵌套终止其他任务也不会提前解除保护。
    func testSynchronousCallbacksRejectReentryAcrossNestedCleanup() throws {
        let coordinator = ContinuousLoadCoordinator()
        let token = makeToken()
        let window = try makeWindow()
        var nextTicket: ContinuousLoadTicket?
        var events: [String] = []
        let checkBlocked: () -> Void = {
            self.assertError(.interactionInProgress) {
                try coordinator.begin(direction: .previous, token: token,
                                      cancel: { XCTFail("重入请求不能被接管") },
                                      completion: { _ in XCTFail("重入请求不能完成") })
            }
            if let nextTicket {
                self.assertError(.interactionInProgress) {
                    try coordinator.accept(nextTicket, window: window, anchor: nil)
                }
            }
        }
        let previous = try coordinator.begin(direction: .previous, token: token, cancel: {
            XCTAssertNil(coordinator.preparedUpdate)
            events.append("取消前向")
            checkBlocked()
            if let nextTicket { coordinator.finish(nextTicket, outcome: .cancelled) }
            checkBlocked()
        }, completion: { outcome in
            XCTAssertEqual(outcome, .cancelled)
            events.append("完成前向")
            checkBlocked()
        })
        nextTicket = try coordinator.begin(direction: .next, token: token, cancel: {
            events.append("取消后向")
            checkBlocked()
        }, completion: { outcome in
            XCTAssertEqual(outcome, .cancelled)
            events.append("完成后向")
            checkBlocked()
        })
        try coordinator.accept(previous, window: window, anchor: nil)
        coordinator.finish(previous, outcome: .cancelled)
        XCTAssertEqual(events, ["取消前向", "取消后向", "完成后向", "完成前向"])
        XCTAssertEqual(coordinator.activeCount, 0)
        let resumed = try coordinator.begin(direction: .previous, token: token, cancel: {}, completion: { _ in })
        try coordinator.accept(resumed, window: window, anchor: nil)
        XCTAssertEqual(coordinator.preparedUpdate?.ticket, resumed)
        coordinator.invalidate()
    }

    /// 替换请求或准备结果时，旧任务的任一回调失效协调器都不能使新任务复活。
    func testInvalidationDuringReplacementCannotReviveRequestsOrPreparedResults() throws {
        for replacesRequest in [false, true] {
            for invalidatesOnCancel in [false, true] {
                let coordinator = ContinuousLoadCoordinator()
                let token = makeToken()
                let window = try makeWindow()
                var previousCancellations = 0
                var nextCancellations = 0
                var previousOutcomes: [ContinuousLoadOutcome] = []
                var nextOutcomes: [ContinuousLoadOutcome] = []
                let previous = try coordinator.begin(direction: .previous, token: token, cancel: {
                    previousCancellations += 1
                    if invalidatesOnCancel { coordinator.invalidate() }
                }, completion: { outcome in
                    previousOutcomes.append(outcome)
                    if !invalidatesOnCancel { coordinator.invalidate() }
                })
                let next = try coordinator.begin(direction: .next, token: token,
                                                 cancel: { nextCancellations += 1 },
                                                 completion: { nextOutcomes.append($0) })
                try coordinator.accept(previous, window: window, anchor: nil)
                if replacesRequest {
                    let newerToken = ContinuousUpdateToken(presentationID: token.presentationID, revision: 1)
                    assertError(.inactive) {
                        try coordinator.begin(direction: .previous, token: newerToken,
                                              cancel: { XCTFail("失效后不能接管替换请求") },
                                              completion: { _ in XCTFail("失效后不能完成替换请求") })
                    }
                } else {
                    assertError(.inactive) { try coordinator.accept(next, window: window, anchor: nil) }
                }
                XCTAssertEqual(coordinator.activeCount, 0)
                XCTAssertNil(coordinator.preparedUpdate)
                coordinator.invalidate()
                XCTAssertEqual(previousCancellations, 1)
                XCTAssertEqual(nextCancellations, 1)
                XCTAssertEqual(previousOutcomes, [.superseded])
                XCTAssertEqual(nextOutcomes, [.invalidated])
            }
        }
    }

    // MARK: - 测试数据与断言

    /// - Returns: 独立展示代际的初始窗口版本。
    private func makeToken() -> ContinuousUpdateToken {
        ContinuousUpdateToken(presentationID: UUID(), revision: 0)
    }

    /// - Parameter id: 测试窗口的单元标识。
    /// - Returns: 包含一个有效单元的完整窗口。
    /// - Throws: 测试数据不符合窗口约束时的错误。
    private func makeWindow(_ id: String = "item") throws -> ContinuousWindow {
        try ContinuousWindow(items: [ContinuousItem(identity: PageItemIdentity(sourceID: "source", unitID: id),
                                                     sectionID: "section", extent: 200)])
    }

    /// - Parameters: expected: 预期错误；file: 调用文件；line: 调用行；operation: 应当失败的操作。
    private func assertError<T>(_ expected: PageTurnError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PageTurnError, expected, file: file, line: line)
        }
    }
}
