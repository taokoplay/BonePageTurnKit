#if canImport(UIKit)
import UIKit
import XCTest
@testable import BonePageTurnKit

@MainActor
final class AsyncStyledRenderingTests: XCTestCase {
    private func identity(_ id: String, version: UInt64 = 0) -> PageItemIdentity {
        .init(sourceID: id, unitID: id, contentVersion: version, layoutVersion: version)
    }
    private func item(_ id: String, height: Double = 2000, version: UInt64 = 0,
                      state: ContinuousContentState = .ready) -> ContinuousItem {
        .init(identity: identity(id, version: version), sectionID: "chapter", extent: height, state: state)
    }
    private func paged(_ page: AsyncStyledPageController) throws -> PagedReaderViewController {
        try PagedReaderViewController(page: .init(identity: page.identity, controller: page),
                                      configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal)))
    }
    /// - Parameter controller: 真实待测容器。
    /// - Returns: 持有真实 UIKit 窗口，调用方测试完成后隐藏并清空 root。
    private func mount(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 760))
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
    private func attachScreenshot(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func markerY(_ content: AsyncStyledContentView, marker: String) throws -> CGFloat {
        let text = content.textView
        text.layoutManager.ensureLayout(for: text.textContainer)
        let range = (text.attributedText.string as NSString).range(of: marker)
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { throw PageTurnError.anchorUnavailable }
        let glyphs = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return text.frame.minY + text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer).minY
    }

    func testCurrentPageRendersRealStylesTextThenImage() async throws {
        var plan = AsyncStyledRenderPlan()
        plan.title = "样式验收"
        plan.textDelay = 10_000_000
        plan.imageDelay = 120_000_000
        let page = AsyncStyledPageController(identity: identity("A"), plan: plan)
        let done = expectation(description: "当前页两个真实渲染阶段完成")
        done.expectedFulfillmentCount = 2
        var stages: [AsyncStyledRenderEvent.Stage] = []
        var imageWasPendingAtText = false
        page.onEvent = { event in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(event.result, .applied)
            stages.append(event.stage)
            if event.stage == .text {
                imageWasPendingAtText = page.content.imageView.image == nil
                page.content.textView.selectedRange = NSRange(location: 0, length: 4)
                self.attachScreenshot(page.content, name: "中间状态-正文就绪但图片等待")
            }
            done.fulfill()
        }
        let reader = try paged(page)
        let window = mount(reader)
        defer { reader.invalidate(); close(window); page.onEvent = nil }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(stages, [.text, .image])
        XCTAssertTrue(imageWasPendingAtText)
        XCTAssertEqual(page.content.textView.selectedRange, NSRange(location: 0, length: 4))
        XCTAssertTrue(page.content.textView.isSelectable)
        XCTAssertNotNil(page.content.imageView.image)
        let text = try XCTUnwrap(page.content.textView.attributedText)
        let string = text.string as NSString
        let heading = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let bodyRange = string.range(of: "清晨")
        let body = try XCTUnwrap(text.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
        XCTAssertNotNil(text.attribute(.link, at: string.range(of: "链接示例").location, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.backgroundColor, at: string.range(of: "引用段落").location, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.underlineStyle, at: string.range(of: "彩色标记").location, effectiveRange: nil))
        let bold = try XCTUnwrap(text.attribute(.font, at: string.range(of: "重点强调").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { XCTAssertNotNil(attachment.image); attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
        XCTAssertLessThanOrEqual(page.content.captionLabel.frame.maxY, page.content.bounds.height)
        XCTAssertTrue(page.content.textView.frame.width > 0 && page.content.imageView.frame.height > 0)
        attachScreenshot(reader.view, name: "当前页-多样式与异步图片")
    }

    func testImageFinishingBeforeTextIsNotErasedByLateRichText() async throws {
        var plan = AsyncStyledRenderPlan()
        plan.imageDelay = 10_000_000
        plan.textDelay = 100_000_000
        let page = AsyncStyledPageController(identity: identity("image-first"), plan: plan)
        let done = expectation(description: "乱序渲染完成")
        done.expectedFulfillmentCount = 2
        var earlyImage: UIImage?
        var wasTextPending = false
        page.onEvent = { event in
            if event.stage == .image { earlyImage = page.content.imageView.image; wasTextPending = !page.content.textReady }
            done.fulfill()
        }
        let reader = try paged(page)
        let window = mount(reader)
        defer { reader.invalidate(); close(window); page.onEvent = nil }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue(wasTextPending)
        XCTAssertNotNil(earlyImage)
        XCTAssertTrue(page.content.imageView.image === earlyImage)
        XCTAssertTrue(page.content.textView.text.contains("image-first"))
    }

    func testFastTurnRejectsUncooperativeOldPageResults() async throws {
        var oldPlan = AsyncStyledRenderPlan()
        oldPlan.ignoresCancellation = true
        oldPlan.textDelay = 100_000_000
        oldPlan.imageDelay = 160_000_000
        let old = AsyncStyledPageController(identity: identity("old"), plan: oldPlan)
        let next = AsyncStyledPageController(identity: identity("new"), plan: .init())
        let done = expectation(description: "旧结果和新页均返回")
        done.expectedFulfillmentCount = 4
        var discarded = 0
        old.onEvent = { event in XCTAssertEqual(event.result, .discarded); discarded += 1; done.fulfill() }
        next.onEvent = { event in XCTAssertEqual(event.result, .applied); done.fulfill() }
        let reader = try paged(old)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        reader.pageProvider = { _, _ in .page(.init(identity: next.identity, controller: next)) }
        XCTAssertTrue(try reader.turn(.next, animated: false))
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(discarded, 2)
        XCTAssertFalse(old.content.textReady)
        XCTAssertNil(old.content.imageView.image)
        XCTAssertTrue(next.content.textView.text.contains("new"))
        XCTAssertEqual(reader.currentPage.identity, next.identity)
    }

    func testCancellingTurnKeepsCurrentPageAsyncRenderingAlive() async throws {
        let current = AsyncStyledPageController(identity: identity("current"), plan: .init())
        var late = AsyncStyledRenderPlan()
        late.ignoresCancellation = true
        let target = AsyncStyledPageController(identity: identity("cancelled-target"), plan: late)
        let done = expectation(description: "当前页完成，取消目标被丢弃")
        done.expectedFulfillmentCount = 4
        current.onEvent = { event in XCTAssertEqual(event.result, .applied); done.fulfill() }
        target.onEvent = { event in XCTAssertEqual(event.result, .discarded); done.fulfill() }
        let reader = try paged(current)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        reader.pageProvider = { _, _ in .page(.init(identity: target.identity, controller: target)) }
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 100)
        reader.cancelTransition()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue(current.content.isFullyRendered)
        XCTAssertFalse(target.content.textReady)
        XCTAssertTrue(reader.currentPage.controller === current)
    }

    func testSamePageNewRenderGenerationRejectsOldFontAndTheme() async throws {
        var old = AsyncStyledRenderPlan()
        old.title = "旧样式"
        old.ignoresCancellation = true
        old.textDelay = 140_000_000
        old.imageDelay = 170_000_000
        let page = AsyncStyledPageController(identity: identity("restyled"), plan: old)
        let done = expectation(description: "新旧渲染代际返回")
        done.expectedFulfillmentCount = 4
        var discarded = 0
        page.onEvent = { event in if event.result == .discarded { discarded += 1 }; done.fulfill() }
        let reader = try paged(page)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        var current = AsyncStyledRenderPlan()
        current.title = "新样式"
        current.fontSize = 21
        current.theme = .dark
        page.renderPlan = current
        page.startRendering()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(discarded, 2)
        XCTAssertTrue(page.content.textView.text.hasPrefix("新样式"))
        let font = page.content.textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.pointSize, 26)
        XCTAssertEqual(page.content.plan?.theme, .dark)
        attachScreenshot(reader.view, name: "当前页-重排后的深色样式")
    }

    func testReusedContinuousViewRejectsLateResultsFromOldUnit() async throws {
        let provider = AsyncStyledContentProvider()
        provider.planForItem = { item in
            var plan = AsyncStyledRenderPlan()
            plan.ignoresCancellation = true
            plan.textDelay = item.identity.unitID == "0" ? 120_000_000 : 10_000_000
            plan.imageDelay = item.identity.unitID == "0" ? 160_000_000 : 20_000_000
            return plan
        }
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: (0..<8).map { item(String($0)) }), provider: provider)
        provider.reader = reader
        let done = expectation(description: "复用前后结果完成")
        done.expectedFulfillmentCount = 4
        var rejected = 0
        provider.onEvent = { event in
            if event.identity.unitID == "0" { XCTAssertEqual(event.result, .discarded); rejected += 1 }
            else { XCTAssertEqual(event.identity.unitID, "4"); XCTAssertEqual(event.result, .applied) }
            done.fulfill()
        }
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let reused = try XCTUnwrap(provider.contentView(for: "0"))
        try reader.restore(.init(identity: identity("4"), offsetInItem: 600), expectedToken: reader.updateToken)
        XCTAssertTrue(provider.contentView(for: "4") === reused)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(rejected, 2)
        XCTAssertTrue(reused.textView.text.contains("异步正文 · 4"))
        XCTAssertEqual(reused.renderedIdentity, identity("4"))
    }

    func testContentAndLayoutRevisionRejectOldAsyncResults() async throws {
        let provider = AsyncStyledContentProvider()
        provider.planForItem = { item in
            var plan = AsyncStyledRenderPlan()
            plan.title = "版本 \(item.identity.layoutVersion)"
            plan.ignoresCancellation = true
            plan.textDelay = item.identity.layoutVersion == 0 ? 140_000_000 : 10_000_000
            plan.imageDelay = item.identity.layoutVersion == 0 ? 160_000_000 : 20_000_000
            return plan
        }
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item("A")]), provider: provider)
        provider.reader = reader
        let done = expectation(description: "布局版本更新的异步结果")
        done.expectedFulfillmentCount = 4
        provider.onEvent = { event in
            XCTAssertEqual(event.result, event.identity.layoutVersion == 0 ? .discarded : .applied)
            done.fulfill()
        }
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let updated = try ContinuousWindow(items: [item("A", version: 1)])
        let token = reader.updateToken
        XCTAssertThrowsError(try reader.apply(updated, expectedToken: token))
        try reader.apply(updated, expectedToken: token, anchor: .init(identity: identity("A", version: 1), offsetInItem: 0))
        await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue(try XCTUnwrap(provider.contentView(for: "A")).textView.text.hasPrefix("版本 1"))
    }

    func testAsyncMeasuredHeightAboveViewportDefersThenPreservesScreenPosition() async throws {
        let provider = AsyncStyledContentProvider()
        provider.planForItem = { item in
            var plan = AsyncStyledRenderPlan()
            plan.textDelay = item.identity.unitID == "A" ? 60_000_000 : 5_000_000
            plan.imageDelay = item.identity.unitID == "A" ? 120_000_000 : 10_000_000
            return plan
        }
        let initial = try ContinuousWindow(items: [item("A", height: 200, state: .loading), item("B")])
        let reader = try ContinuousReaderViewController(window: initial, provider: provider,
                                                        anchor: .init(identity: identity("B"), offsetInItem: 80))
        provider.reader = reader
        let measured = expectation(description: "上方复杂样式完成并测出真实高度")
        let installed = expectation(description: "解除暂停后安装")
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        let target = try XCTUnwrap(provider.contentView(for: "B"))
        let screenY = target.convert(CGPoint(x: 20, y: 50), to: reader.view).y
        let ticket = try reader.beginLoading(.previous, token: reader.updateToken, cancel: {}) { result in
            if case .installed = result { installed.fulfill() } else { XCTFail("\(result)") }
        }
        reader.setSuspended(true, reason: "selection")
        var finalHeight: Double = 0
        provider.onHeight = { [weak reader] binding, height in
            guard binding.identity.unitID == "A", let reader, finalHeight == 0 else { return }
            finalHeight = height
            do {
                let updated = try ContinuousWindow(items: [self.item("A", height: height), self.item("B")])
                try reader.submit(updated, for: ticket)
            } catch { XCTFail("\(error)") }
            measured.fulfill()
        }
        await fulfillment(of: [measured], timeout: 3)
        XCTAssertGreaterThan(finalHeight, 200)
        XCTAssertEqual(reader.window, initial)
        XCTAssertEqual(reader.scrollView.contentOffset.y, 280, accuracy: 0.01)
        reader.setSuspended(false, reason: "selection")
        await fulfillment(of: [installed], timeout: 3)
        XCTAssertEqual(reader.visibleAnchor?.identity, identity("B"))
        XCTAssertEqual(reader.visibleAnchor?.offsetInItem ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(target.convert(CGPoint(x: 20, y: 50), to: reader.view).y, screenY, accuracy: 0.5)
    }

    func testVisibleRichTextReflowRestoresHostResolvedSentencePosition() async throws {
        let provider = AsyncStyledContentProvider()
        provider.planForItem = { item in
            var plan = AsyncStyledRenderPlan()
            plan.fontSize = item.identity.layoutVersion == 0 ? 17 : 24
            return plan
        }
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: [item("A"), item("B")]), provider: provider)
        provider.reader = reader
        let oldReady = expectation(description: "当前正文实际排版完成")
        oldReady.expectedFulfillmentCount = 2
        provider.onEvent = { event in if event.identity.unitID == "A" { oldReady.fulfill() } }
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        await fulfillment(of: [oldReady], timeout: 3)
        let oldContent = try XCTUnwrap(provider.contentView(for: "A"))
        let oldY = try markerY(oldContent, marker: "引用段落")
        try reader.restore(.init(identity: identity("A"), offsetInItem: Double(oldY), viewportOffset: 60), expectedToken: reader.updateToken)

        let prepared = AsyncStyledContentView(frame: CGRect(x: 0, y: 0, width: reader.view.bounds.width, height: 2000))
        let newItem = item("A", version: 1)
        let preparedReady = expectation(description: "宿主按新字号解析同一句话")
        preparedReady.expectedFulfillmentCount = 2
        prepared.render(identity: newItem.identity, plan: provider.planForItem(newItem), isCurrent: { true },
                        onEvent: { _ in preparedReady.fulfill() })
        await fulfillment(of: [preparedReady], timeout: 3)
        let newY = try markerY(prepared, marker: "引用段落")
        XCTAssertGreaterThan(newY, oldY)
        let newHeight = Double(prepared.measuredHeight(width: prepared.bounds.width))
        let replacement = try ContinuousWindow(items: [item("A", height: newHeight, version: 1), item("B")])
        let token = reader.updateToken
        XCTAssertThrowsError(try reader.apply(replacement, expectedToken: token))
        let visibleReady = expectation(description: "新布局真正显示完成")
        visibleReady.expectedFulfillmentCount = 2
        provider.onEvent = { event in
            if event.identity.unitID == "A", event.identity.layoutVersion == 1 {
                XCTAssertEqual(event.result, .applied)
                visibleReady.fulfill()
            }
        }
        try reader.apply(replacement, expectedToken: token,
                         anchor: .init(identity: newItem.identity, offsetInItem: Double(newY), viewportOffset: 60))
        await fulfillment(of: [visibleReady], timeout: 3)
        let displayed = try XCTUnwrap(provider.contentView(for: "A"))
        let actualY = try markerY(displayed, marker: "引用段落")
        XCTAssertEqual(displayed.convert(CGPoint(x: 20, y: actualY), to: reader.view).y, 60, accuracy: 1)
        XCTAssertEqual(displayed.renderedIdentity?.layoutVersion, 1)
    }

    func testImageFailureAndRetryPreserveCurrentPageIdentity() async throws {
        var plan = AsyncStyledRenderPlan()
        plan.imageFails = true
        let page = AsyncStyledPageController(identity: identity("retry"), plan: plan)
        let failed = expectation(description: "正文成功，图片失败")
        failed.expectedFulfillmentCount = 2
        page.onEvent = { _ in failed.fulfill() }
        let reader = try paged(page)
        let window = mount(reader)
        defer { reader.invalidate(); close(window) }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(page.content.textReady)
        XCTAssertTrue(page.content.imageFailed)
        XCTAssertNil(page.content.imageView.image)
        XCTAssertTrue(page.content.captionLabel.text?.contains("失败") == true)
        let retried = expectation(description: "重新异步渲染成功")
        retried.expectedFulfillmentCount = 2
        page.onEvent = { event in XCTAssertEqual(event.result, .applied); retried.fulfill() }
        page.renderPlan.imageFails = false
        page.startRendering()
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(reader.currentPage.identity, identity("retry"))
        XCTAssertNotNil(page.content.imageView.image)
        XCTAssertTrue(page.content.textView.text.contains("retry"))
        XCTAssertFalse(page.content.imageFailed)
    }

    func testRendererInvalidationRejectsDelayedVisiblePageRendering() async throws {
        var plan = AsyncStyledRenderPlan()
        plan.ignoresCancellation = true
        let page = AsyncStyledPageController(identity: identity("closed"), plan: plan)
        let discarded = expectation(description: "退出后的当前页结果被拒绝")
        discarded.expectedFulfillmentCount = 2
        page.onEvent = { event in XCTAssertEqual(event.result, .discarded); discarded.fulfill() }
        let reader = try paged(page)
        let window = mount(reader)
        defer { close(window) }
        reader.invalidate()
        await fulfillment(of: [discarded], timeout: 3)
        XCTAssertFalse(page.content.textReady)
        XCTAssertNil(page.content.imageView.image)
        XCTAssertNil(reader.readingStatus)
    }
}
#endif
