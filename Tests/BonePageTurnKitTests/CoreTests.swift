import Foundation
import XCTest
@testable import BonePageTurnKit

final class CoreTests: XCTestCase {
    /// 验证异高窗口前插、前方重排和裁剪后，同一锚点仍位于原屏幕坐标。
    func testAnchorKeepsScreenPositionAcrossPrependResizeAndTrim() throws {
        let leading = item("leading", extent: 120)
        let preceding = item("preceding", extent: 75)
        let focus = item("focus", extent: 240)
        let trailing = item("trailing", extent: 900)
        let original = try ContinuousWindow(items: [leading, preceding, focus, trailing])
        let captured = try XCTUnwrap(original.anchor(at: 295, viewportExtent: 200))
        XCTAssertEqual(captured.identity, focus.identity)
        XCTAssertEqual(captured.offsetInItem, 100)
        let anchor = ContinuousAnchor(identity: captured.identity, offsetInItem: captured.offsetInItem,
                                      viewportOffset: 60)
        let prepended = try ContinuousWindow(items: [item("new-a", extent: 33), item("new-b", extent: 87)]
                                            + original.items)
        let resized = try ContinuousWindow(items: [item("new-a", extent: 33), item("new-b", extent: 87),
                                                   item("leading", extent: 180, layoutVersion: 2),
                                                   preceding, focus, trailing])
        let trimmed = try ContinuousWindow(items: [preceding, focus, trailing])
        let updates: [(ContinuousWindow, Double)] = [
            (original, 235), (prepended, 355), (resized, 415), (trimmed, 115)
        ]
        var previous = original
        for (window, expectedOffset) in updates {
            try window.validateReplacement(of: previous)
            let restoredOffset = try window.offset(for: anchor, viewportExtent: 200)
            let origin = try XCTUnwrap(window.origin(of: "focus"))
            XCTAssertEqual(restoredOffset, expectedOffset, accuracy: 0.000_001)
            XCTAssertEqual(origin + anchor.offsetInItem - restoredOffset, 60, accuracy: 0.000_001)
            XCTAssertEqual(window.anchor(at: restoredOffset + 60, viewportExtent: 200), captured)
            previous = window
        }
    }

    /// 验证锚点自身重排或删除后必须重新解析，不能继续套用旧像素偏移。
    func testRelayoutAndRemovalInvalidateAnchor() throws {
        let original = try ContinuousWindow(items: [item("focus", extent: 240), item("tail", extent: 500)])
        let anchor = try XCTUnwrap(original.anchor(at: 100, viewportExtent: 200))
        let relayout = try ContinuousWindow(items: [item("focus", extent: 300, layoutVersion: 2),
                                                   item("tail", extent: 500)])
        let removed = try ContinuousWindow(items: [item("tail", extent: 500)])
        for replacement in [relayout, removed] {
            XCTAssertNoThrow(try replacement.validateReplacement(of: original))
            assertError(.anchorUnavailable) { try replacement.offset(for: anchor, viewportExtent: 200) }
        }
    }

    /// 验证回弹取锚点时被钳制，恢复锚点也受到首尾可滚动范围限制。
    func testBounceClampingAndAnchorRestorationRespectContentEnds() throws {
        let first = item("first", extent: 100)
        let middle = item("middle", extent: 200)
        let last = item("last", extent: 400)
        let window = try ContinuousWindow(items: [first, middle, last])
        XCTAssertEqual(window.totalExtent, 700)
        XCTAssertEqual(window.clampedOffset(-80, viewportExtent: 250), 0)
        XCTAssertEqual(window.clampedOffset(900, viewportExtent: 250), 450)
        XCTAssertEqual(window.clampedOffset(125, viewportExtent: 250), 125)
        XCTAssertEqual(window.clampedOffset(80, viewportExtent: 800), 0)
        XCTAssertEqual(window.anchor(at: -80, viewportExtent: 250),
                       ContinuousAnchor(identity: first.identity, offsetInItem: 0))
        XCTAssertEqual(window.anchor(at: 900, viewportExtent: 250),
                       ContinuousAnchor(identity: last.identity, offsetInItem: 150))
        let tailAnchor = ContinuousAnchor(identity: last.identity, offsetInItem: 350)
        XCTAssertEqual(try window.offset(for: tailAnchor, viewportExtent: 250), 450)
        let headAnchor = ContinuousAnchor(identity: first.identity, offsetInItem: 10, viewportOffset: 60)
        XCTAssertEqual(try window.offset(for: headAnchor, viewportExtent: 250), 0)
        XCTAssertEqual(try window.offset(for: tailAnchor, viewportExtent: 800), 0)
    }

    /// 验证空窗口及跨来源、跨版本重复的展示单元 ID 均被拒绝。
    func testEmptyWindowAndDuplicateUnitIDsAreRejected() {
        assertError(.invalidWindow) { try ContinuousWindow(items: []) }
        let first = item("duplicate", extent: 100)
        let second = item("duplicate", extent: 200, sourceID: "another-source", contentVersion: 2)
        assertError(.duplicateUnitID("duplicate")) { try ContinuousWindow(items: [first, second]) }
    }

    /// 验证单块非法高度、累计溢出以及无法推进累计坐标的高度被拒绝。
    func testInvalidExtentsAndUnrepresentableCumulativeGeometryAreRejected() {
        for extent in [Double.nan, .infinity, -.infinity, 0, -1] {
            assertError(.invalidExtent("invalid")) {
                try ContinuousWindow(items: [item("invalid", extent: extent)])
            }
        }
        assertError(.invalidExtent("overflow")) {
            try ContinuousWindow(items: [item("large", extent: .greatestFiniteMagnitude),
                                         item("overflow", extent: .greatestFiniteMagnitude)])
        }
        assertError(.invalidExtent("lost")) {
            try ContinuousWindow(items: [item("large", extent: 1e20), item("lost", extent: 1)])
        }
    }

    /// 验证可见区间为半开区间，且超长块内部的视口只命中该块。
    func testHalfOpenIntersectionsAndVeryLongItem() throws {
        let window = try ContinuousWindow(items: [item("first", extent: 100),
                                                  item("long", extent: 10_000),
                                                  item("last", extent: 50)])
        let cases: [(Double, Double, Range<Int>)] = [
            (-20, 100, 0..<1), (0, 100, 0..<1), (100, 10_100, 1..<2),
            (99, 101, 0..<2), (2_000, 2_200, 1..<2), (10_099, 10_101, 1..<3),
            (10_100, 10_150, 2..<3), (-20, 20_000, 0..<3)
        ]
        for (lower, upper, expected) in cases {
            XCTAssertEqual(window.indices(intersecting: lower, upper), expected,
                           "查询区间 [\(lower), \(upper))")
        }
        XCTAssertEqual(window.anchor(at: 100, viewportExtent: 50)?.identity.unitID, "long")
        XCTAssertEqual(window.anchor(at: 100, viewportExtent: 50)?.offsetInItem, 0)
        XCTAssertEqual(window.anchor(at: 10_100, viewportExtent: 50)?.identity.unitID, "last")
        XCTAssertEqual(window.origin(of: "last"), 10_100)
        XCTAssertNil(window.origin(of: "missing"))
    }

    /// 验证空、反向、窗口外及非有限查询区间不命中任何块。
    func testInvalidAndOutsideIntersectionRangesAreEmpty() throws {
        let window = try ContinuousWindow(items: [item("only", extent: 100)])
        let cases: [(Double, Double)] = [
            (20, 20), (30, 20), (-20, 0), (100, 120), (120, 150),
            (.nan, 50), (0, .nan), (-.infinity, 50), (0, .infinity)
        ]
        for (lower, upper) in cases {
            XCTAssertTrue(window.indices(intersecting: lower, upper).isEmpty)
        }
    }

    /// 验证块内偏移和屏幕偏移必须有限，并落在各自的半开范围内。
    func testInvalidAnchorGeometryIsRejected() throws {
        let focus = item("focus", extent: 100)
        let window = try ContinuousWindow(items: [focus, item("tail", extent: 500)])
        for offset in [Double.nan, .infinity, -.infinity, -1, 100, 101] {
            let anchor = ContinuousAnchor(identity: focus.identity, offsetInItem: offset)
            assertError(.anchorUnavailable) { try window.offset(for: anchor, viewportExtent: 200) }
        }
        for viewportOffset in [Double.nan, .infinity, -.infinity, -1, 200, 201] {
            let anchor = ContinuousAnchor(identity: focus.identity, offsetInItem: 10,
                                          viewportOffset: viewportOffset)
            assertError(.anchorUnavailable) { try window.offset(for: anchor, viewportExtent: 200) }
        }
        let missing = ContinuousAnchor(identity: item("missing", extent: 100).identity, offsetInItem: 0)
        assertError(.anchorUnavailable) { try window.offset(for: missing, viewportExtent: 200) }
    }

    /// 验证非法视口和输入偏移不会生成可用锚点，恢复非法视口则明确报错。
    func testInvalidViewportAndOffsetInputsAreHandled() throws {
        let focus = item("focus", extent: 500)
        let window = try ContinuousWindow(items: [focus])
        let anchor = ContinuousAnchor(identity: focus.identity, offsetInItem: 0)
        for viewport in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertNil(window.anchor(at: 20, viewportExtent: viewport))
            XCTAssertEqual(window.clampedOffset(20, viewportExtent: viewport), 0)
            assertError(.anchorUnavailable) { try window.offset(for: anchor, viewportExtent: viewport) }
        }
        for offset in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(window.anchor(at: offset, viewportExtent: 200))
            XCTAssertEqual(window.clampedOffset(offset, viewportExtent: 200), 0)
        }
    }

    /// 验证同版本已就绪内容不能被加载中或失败状态覆盖。
    func testReadyContentCannotRegressAtSameVersion() throws {
        let previous = try ContinuousWindow(items: [item("focus", extent: 300)])
        for state in [ContinuousContentState.loading, .failed] {
            let replacement = try ContinuousWindow(items: [item("focus", extent: 300, state: state)])
            assertError(.staleContent("focus")) { try replacement.validateReplacement(of: previous) }
        }
    }

    /// 验证内容和布局版本各自单调递增，同一单元也不能更换源身份。
    func testVersionRollbackAndSourceChangesAreRejected() throws {
        let previous = try ContinuousWindow(items: [item("focus", extent: 300,
                                                         contentVersion: 3, layoutVersion: 4)])
        let invalidItems = [
            item("focus", extent: 300, contentVersion: 2, layoutVersion: 4),
            item("focus", extent: 300, contentVersion: 3, layoutVersion: 3),
            item("focus", extent: 300, contentVersion: 4, layoutVersion: 3),
            item("focus", extent: 300, contentVersion: 2, layoutVersion: 5),
            item("focus", extent: 300, sourceID: "different-source", contentVersion: 4, layoutVersion: 5)
        ]
        for invalidItem in invalidItems {
            let replacement = try ContinuousWindow(items: [invalidItem])
            assertError(.staleContent("focus")) { try replacement.validateReplacement(of: previous) }
        }
    }

    /// 验证新内容版本可以替换旧内容，但必须丢弃旧版本像素锚点。
    func testNewContentVersionCanReplaceReadyContentButInvalidatesOldAnchor() throws {
        let previous = try ContinuousWindow(items: [item("focus", extent: 500)])
        let oldAnchor = try XCTUnwrap(previous.anchor(at: 100, viewportExtent: 200))
        for state in [ContinuousContentState.loading, .failed, .ready] {
            let replacement = try ContinuousWindow(items: [item("focus", extent: 500,
                                                                 contentVersion: 2, state: state)])
            XCTAssertNoThrow(try replacement.validateReplacement(of: previous))
            assertError(.anchorUnavailable) { try replacement.offset(for: oldAnchor, viewportExtent: 200) }
            let newAnchor = try XCTUnwrap(replacement.anchor(at: 100, viewportExtent: 200))
            XCTAssertEqual(newAnchor.identity.contentVersion, 2)
            XCTAssertEqual(try replacement.offset(for: newAnchor, viewportExtent: 200), 100)
        }
    }

    /// 验证同版本加载完成、失败重试和就绪刷新均为有效替换。
    func testContentCompletionRetryAndReadyRefreshRemainAllowed() throws {
        let transitions: [(ContinuousContentState, ContinuousContentState)] = [
            (.loading, .ready), (.loading, .failed), (.failed, .loading), (.failed, .ready), (.ready, .ready)
        ]
        for (oldState, newState) in transitions {
            let previous = try ContinuousWindow(items: [item("focus", extent: 300, state: oldState)])
            let replacement = try ContinuousWindow(items: [item("focus", extent: 300, state: newState)])
            XCTAssertNoThrow(try replacement.validateReplacement(of: previous))
        }
    }

    /// 验证能力矩阵只包含实际后端，纸张支持横纵轴。
    func testPresentationSupportMatrixMatchesImplementedBackends() {
        let expected: [PageTurnPresentation] = [
            .paged(effect: .none, axis: .horizontal), .paged(effect: .none, axis: .vertical),
            .paged(effect: .slide, axis: .horizontal), .paged(effect: .slide, axis: .vertical),
            .paged(effect: .curl, axis: .horizontal), .paged(effect: .arch, axis: .horizontal),
            .paged(effect: .curl, axis: .vertical), .paged(effect: .arch, axis: .vertical),
            .paged(effect: .cover, axis: .horizontal), .continuous(axis: .vertical)
        ]
        XCTAssertEqual(PageTurnConfiguration.supportedPresentations.count, expected.count)
        for presentation in expected {
            XCTAssertTrue(PageTurnConfiguration.supportedPresentations.contains(presentation))
        }
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for effect in [PageTurnEffect.none, .slide, .cover, .curl, .arch] {
                let presentation = PageTurnPresentation.paged(effect: effect, axis: axis)
                let configuration = PageTurnConfiguration(presentation: presentation)
                if expected.contains(presentation) {
                    XCTAssertNoThrow(try configuration.validate())
                } else {
                    assertError(.unsupportedPresentation) { try configuration.validate() }
                }
            }
        }
        XCTAssertNoThrow(try PageTurnConfiguration(presentation: .continuous(axis: .vertical)).validate())
        assertError(.unsupportedPresentation) {
            try PageTurnConfiguration(presentation: .continuous(axis: .horizontal)).validate()
        }
    }

    /// 纸张后端只接受左右书脊，其他模式仅 automatic；中央／不支持轴向明确拒绝。
    func testSpineCapabilitiesMatchImplementedSinglePageBackends() {
        for presentation in PageTurnConfiguration.supportedPresentations {
            for spine in [PageSpinePlacement.automatic, .minimum, .center, .maximum] {
                let config = PageTurnConfiguration(presentation: presentation, spine: spine)
                if PageTurnConfiguration.supportedSpines(for: presentation).contains(spine) {
                    XCTAssertNoThrow(try config.validate())
                } else { assertError(.unsupportedSpine) { try config.validate() } }
            }
        }
    }

    /// 验证进度按半屏归一化，达到 0.17 即提交，阈值下方则取消。
    func testReleaseDistanceUsesHalfViewportAndInclusiveThreshold() {
        for extent in [200.0, 1_000.0] {
            let threshold = extent * 0.5 * 0.17
            XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: threshold - 0.001,
                                                               extent: extent, velocity: 0))
            XCTAssertTrue(PageTurnReleasePolicy.shouldComplete(displacement: threshold,
                                                              extent: extent, velocity: 0))
            XCTAssertTrue(PageTurnReleasePolicy.shouldComplete(displacement: threshold + 0.001,
                                                              extent: extent, velocity: 0))
        }
    }

    /// 验证正向速度 500 的边界，以及反向快速甩动优先于已达标位移取消。
    func testReleaseVelocityThresholdAndFastReverseCancellation() {
        XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 0, extent: 1_000, velocity: 499.999))
        XCTAssertTrue(PageTurnReleasePolicy.shouldComplete(displacement: 0, extent: 1_000, velocity: 500))
        XCTAssertTrue(PageTurnReleasePolicy.shouldComplete(displacement: 0, extent: 1_000, velocity: 800))
        XCTAssertTrue(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: 1_000, velocity: -499.999))
        XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: 1_000, velocity: -500))
        XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: 1_000, velocity: -800))
        XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: -400, extent: 1_000, velocity: 0))
    }

    /// 验证释放策略对非有限输入以及非正视口长度统一返回取消。
    func testReleasePolicyRejectsInvalidGeometryAndVelocity() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: invalid, extent: 1_000, velocity: 600))
            XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: invalid, velocity: 600))
            XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: 1_000, velocity: invalid))
        }
        for extent in [0.0, -1.0] {
            XCTAssertFalse(PageTurnReleasePolicy.shouldComplete(displacement: 400, extent: extent, velocity: 600))
        }
    }
}

private extension CoreTests {
    /// 构造测试块。
    /// - Parameters:
    ///   - id: 展示单元 ID。
    ///   - extent: 块高度。
    ///   - sourceID: 源身份，默认共享同一源。
    ///   - contentVersion: 内容版本，默认从 1 开始。
    ///   - layoutVersion: 布局版本，默认从 1 开始。
    ///   - state: 内容状态，默认就绪。
    /// - Returns: 指定身份、几何和状态的窗口单元。
    func item(_ id: String, extent: Double, sourceID: String = "source", contentVersion: UInt64 = 1,
              layoutVersion: UInt64 = 1, state: ContinuousContentState = .ready) -> ContinuousItem {
        ContinuousItem(identity: PageItemIdentity(sourceID: sourceID, unitID: id,
                                                   contentVersion: contentVersion, layoutVersion: layoutVersion),
                       sectionID: "section", extent: extent, state: state)
    }

    /// 断言操作抛出准确的领域错误，并将失败位置归到调用点。
    /// - Parameters:
    ///   - expected: 预期错误。
    ///   - file: 断言调用文件。
    ///   - line: 断言调用行号。
    ///   - operation: 应抛出错误的操作。
    /// - Returns: 无返回值；错误不匹配时记录 XCTest 失败。
    func assertError<T>(_ expected: PageTurnError, file: StaticString = #filePath, line: UInt = #line,
                        operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PageTurnError, expected, file: file, line: line)
        }
    }
}
