#if canImport(UIKit)
import UIKit
import CoreText
import XCTest
@testable import BonePageTurnKit

/// 在真实 CoreText 字形和 UIKit 容器上验收接缝，不使用逐像素 golden。
@MainActor
final class ContinuousTypographySeamTests: XCTestCase {
    // 以三倍绘制比例计，一个像素为 1/3 pt；全套几何断言不放宽到整点。
    private let tolerance: CGFloat = 1.0 / 3.0

    /// 同一段落在行间切分后，不重新缩进、加段前距或改变字形范围。
    func testWholeChapterAndInParagraphBlocksKeepEveryBaselineXAndRange() throws {
        let fixture = try ContinuousTypographyFixture(repetitions: 2)
        let blocks = try fixture.blocks(lineCounts: [2, 3, 1])
        let whole = try XCTUnwrap(fixture.blocks(lineCounts: [fixture.lines.count]).first)
        let reference = ContinuousTypographyBlockView(frame: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
        reference.configure(fixture: fixture, block: whole)
        let container = UIView(frame: reference.frame)
        container.addSubview(reference)
        let window = try ContinuousWindow(items: blocks.map(\.item))
        var ranges: [NSRange] = []
        var continuationCount = 0
        for block in blocks {
            let origin = try XCTUnwrap(window.origin(of: block.item.identity.unitID))
            let view = ContinuousTypographyBlockView(frame: CGRect(x: 0, y: origin, width: fixture.width, height: block.item.extent))
            view.configure(fixture: fixture, block: block)
            container.addSubview(view)
            let first = fixture.lines[block.lineIndices.lowerBound]
            if !first.startsParagraph { continuationCount += 1 }
            for line in fixture.lines[block.lineIndices] {
                let actual = view.convert(view.localBaseline(for: line), to: container)
                let expected = reference.convert(reference.localBaseline(for: line), to: container)
                XCTAssertEqual(actual.x, expected.x, accuracy: tolerance)
                XCTAssertEqual(actual.y, expected.y, accuracy: tolerance)
                let drawnLine = view.canvas.lines[line.index - block.lineIndices.lowerBound]
                XCTAssertEqual(drawnLine.range, line.range)
                XCTAssertEqual(CTLineGetGlyphCount(drawnLine.ctLine), CTLineGetGlyphCount(line.ctLine))
                XCTAssertTrue(drawnLine.ctLine === line.ctLine, "切分必须保留原始 CTLine")
                ranges.append(drawnLine.range)
            }
        }
        XCTAssertGreaterThan(continuationCount, 5)
        XCTAssertEqual(ranges, fixture.lines.map(\.range))
        assertCompleteTextCoverage(ranges, length: fixture.text.length)
        let firstParagraph = Array(fixture.lines.prefix { !$0.endsParagraph })
        XCTAssertGreaterThan(firstParagraph.count, 2)
        let paragraphFirst = try XCTUnwrap(firstParagraph.first)
        let continuation = try XCTUnwrap(firstParagraph.dropFirst().first)
        XCTAssertGreaterThan(paragraphFirst.baseline.x - continuation.baseline.x, 20)
        XCTAssertEqual(continuation.baseline.x, 12, accuracy: tolerance)
    }

    /// 段末到下一段首行的距离，与整章排版一致且保留真实段距。
    func testParagraphBoundarySpacingIsConsumedExactlyOnce() throws {
        let fixture = try ContinuousTypographyFixture(repetitions: 2)
        let compact = try ContinuousTypographyFixture(paragraphSpacing: 0, paragraphSpacingBefore: 0, repetitions: 2)
        XCTAssertEqual(fixture.lines.map(\.range), compact.lines.map(\.range))
        var counts: [Int] = []
        var start = 0
        for line in fixture.lines where line.endsParagraph {
            counts.append(line.index + 1 - start)
            start = line.index + 1
        }
        let blocks = try fixture.blocks(lineCounts: counts)
        let window = try ContinuousWindow(items: blocks.map(\.item))
        XCTAssertEqual(blocks.count, counts.count)
        for index in 1..<blocks.count {
            let previous = blocks[index - 1]
            let next = blocks[index]
            let lastLine = fixture.lines[previous.lineIndices.upperBound - 1]
            let firstLine = fixture.lines[next.lineIndices.lowerBound]
            XCTAssertTrue(lastLine.endsParagraph)
            XCTAssertTrue(firstLine.startsParagraph)
            let previousOrigin = CGFloat(try XCTUnwrap(window.origin(of: previous.item.identity.unitID)))
            let nextOrigin = CGFloat(try XCTUnwrap(window.origin(of: next.item.identity.unitID)))
            let stitchedGap = nextOrigin + firstLine.baseline.y - next.origin
                - (previousOrigin + lastLine.baseline.y - previous.origin)
            let chapterGap = firstLine.baseline.y - lastLine.baseline.y
            let compactGap = compact.lines[firstLine.index].baseline.y - compact.lines[lastLine.index].baseline.y
            XCTAssertEqual(stitchedGap, chapterGap, accuracy: tolerance)
            XCTAssertGreaterThan(chapterGap - compactGap, 10, "fixture 必须实际产生段前／段后留白")
            XCTAssertEqual(nextOrigin - previousOrigin, CGFloat(previous.item.extent), accuracy: tolerance)
        }
        XCTAssertEqual(CGFloat(window.totalExtent), fixture.height, accuracy: tolerance)
    }

    /// 大量小数行高逐块累加，不能对每块高度单独向上取整。
    func testFractionalSmallTypographyDoesNotAccumulatePerBlockRounding() throws {
        let fixture = try ContinuousTypographyFixture(width: 241, fontSize: 11.375, lineSpacing: 2.1875,
                                                       paragraphSpacing: 7.4375, paragraphSpacingBefore: 3.3125,
                                                       repetitions: 24)
        let blocks = try fixture.blocks(lineCounts: [1])
        let window = try ContinuousWindow(items: blocks.map(\.item))
        XCTAssertGreaterThan(blocks.count, 200)
        let roundedTotal = blocks.reduce(0.0) { $0 + ceil($1.item.extent) }
        XCTAssertGreaterThan(roundedTotal - window.totalExtent, 10, "输入必须能暴露逐块 ceil 的累积误差")
        var measuredBaselines: [CGFloat] = []
        for block in blocks {
            let line = fixture.lines[block.lineIndices.lowerBound]
            let origin = CGFloat(try XCTUnwrap(window.origin(of: block.item.identity.unitID)))
            measuredBaselines.append(origin + line.baseline.y - block.origin)
            XCTAssertEqual(origin, block.origin, accuracy: tolerance)
            XCTAssertEqual(measuredBaselines[measuredBaselines.count - 1], line.baseline.y, accuracy: tolerance)
        }
        XCTAssertEqual(CGFloat(window.totalExtent), fixture.height, accuracy: tolerance)
        XCTAssertEqual(measuredBaselines.count, fixture.lines.count)
        assertCompleteTextCoverage(blocks.flatMap { fixture.lines[$0.lineIndices].map(\.range) }, length: fixture.text.length)
    }

    /// SDK 挂载真实视图后仍然只按 extent 排列，不插入边距或像素取整。
    func testMountedSDKFramesAndLineSeamsFollowOnlyItemExtents() throws {
        let fixture = try ContinuousTypographyFixture(repetitions: 2)
        let blocks = try fixture.blocks(lineCounts: [2, 3])
        let provider = ContinuousTypographyProvider()
        provider.register(fixture, blocks: blocks)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: blocks.map(\.item)), provider: provider)
        let host = mount(reader, size: CGSize(width: fixture.width, height: 220))
        defer { reader.invalidate(); close(host) }
        var visited: Set<String> = []
        var seamCount = 0
        for block in blocks {
            try reader.restore(.init(identity: block.item.identity, offsetInItem: 0), expectedToken: reader.updateToken)
            visited.formUnion(provider.views.keys)
            seamCount += try assertMountedGeometry(reader, provider: provider)
        }
        XCTAssertEqual(visited, Set(blocks.map { $0.item.identity.unitID }))
        XCTAssertGreaterThan(seamCount, blocks.count)
        XCTAssertEqual(reader.scrollView.contentSize.height, fixture.height, accuracy: tolerance)
    }

    /// 前插、上方占位高度回填和窗口裁剪都保持同一原文行的屏幕位置。
    func testPrependHeightBackfillAndTrimmingPreserveCurrentLineScreenY() throws {
        let fixture = try ContinuousTypographyFixture(repetitions: 4)
        let blocks = try fixture.blocks(lineCounts: [3])
        XCTAssertGreaterThan(blocks.count, 20)
        let target = blocks[blocks.count / 2]
        let targetLine = fixture.lines[target.lineIndices.lowerBound + 1]
        let anchor = try fixture.anchor(atUTF16: targetLine.range.location, in: blocks, viewportOffset: 72)
        let provider = ContinuousTypographyProvider()
        provider.register(fixture, blocks: blocks)
        let initial = try ContinuousWindow(items: Array(blocks.dropFirst(4)).map(\.item))
        let reader = try ContinuousReaderViewController(window: initial, provider: provider, anchor: anchor)
        let host = mount(reader, size: CGSize(width: fixture.width, height: 240))
        defer { reader.invalidate(); close(host) }
        let originalY = try screenY(of: targetLine, unitID: target.item.identity.unitID, reader: reader, provider: provider)
        XCTAssertEqual(originalY, 72, accuracy: tolerance)
        let initialOffset = reader.scrollView.contentOffset.y
        var estimatedItems = blocks.map(\.item)
        let first = try XCTUnwrap(estimatedItems.first)
        estimatedItems[0] = ContinuousItem(identity: first.identity, sectionID: first.sectionID,
                                           extent: first.extent - 7.375, reuseIdentifier: first.reuseIdentifier, state: .loading)
        try reader.apply(ContinuousWindow(items: estimatedItems), expectedToken: reader.updateToken)
        let prependedHeight = estimatedItems.prefix(4).reduce(0) { $0 + $1.extent }
        XCTAssertEqual(reader.scrollView.contentOffset.y - initialOffset, CGFloat(prependedHeight), accuracy: tolerance)
        XCTAssertEqual(try screenY(of: targetLine, unitID: target.item.identity.unitID, reader: reader, provider: provider), originalY, accuracy: tolerance)
        let beforeBackfill = reader.scrollView.contentOffset.y
        try reader.apply(ContinuousWindow(items: blocks.map(\.item)), expectedToken: reader.updateToken)
        XCTAssertEqual(reader.scrollView.contentOffset.y - beforeBackfill, 7.375, accuracy: tolerance)
        XCTAssertEqual(try screenY(of: targetLine, unitID: target.item.identity.unitID, reader: reader, provider: provider), originalY, accuracy: tolerance)
        let beforeTrimming = reader.scrollView.contentOffset.y
        let trimmed = Array(blocks.dropFirst(6).dropLast(3))
        try reader.apply(ContinuousWindow(items: trimmed.map(\.item)), expectedToken: reader.updateToken)
        let removedHeight = blocks.prefix(6).reduce(0) { $0 + $1.item.extent }
        XCTAssertEqual(beforeTrimming - reader.scrollView.contentOffset.y, CGFloat(removedHeight), accuracy: tolerance)
        XCTAssertEqual(try screenY(of: targetLine, unitID: target.item.identity.unitID, reader: reader, provider: provider), originalY, accuracy: tolerance)
        XCTAssertGreaterThan(try assertMountedGeometry(reader, provider: provider), 0)
    }

    /// 真实复用后绘制记录、绑定和接缝全部属于新块；不依赖异步延迟。
    func testRecycledViewsDrawOnlyTheirNewLinesAndKeepSeams() throws {
        let fixture = try ContinuousTypographyFixture(repetitions: 4)
        let blocks = try fixture.blocks(lineCounts: [4])
        let provider = ContinuousTypographyProvider()
        provider.register(fixture, blocks: blocks)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: blocks.map(\.item)), provider: provider)
        let host = mount(reader, size: CGSize(width: fixture.width, height: 180))
        defer { reader.invalidate(); close(host) }
        let originalViews = Set(provider.views.values.map { ObjectIdentifier($0) })
        let originalBindings = Array(provider.bindings.values)
        _ = snapshot(host)
        let distant = blocks[blocks.count / 2]
        try reader.restore(.init(identity: distant.item.identity, offsetInItem: 0), expectedToken: reader.updateToken)
        XCTAssertTrue(originalBindings.allSatisfy { !reader.isCurrent($0) })
        XCTAssertFalse(originalViews.isDisjoint(with: Set(provider.views.values.map { ObjectIdentifier($0) })))
        _ = snapshot(host)
        for (id, view) in provider.views {
            let block = try XCTUnwrap(view.block)
            XCTAssertEqual(block.item.identity.unitID, id)
            XCTAssertEqual(view.canvas.drawnRanges, fixture.lines[block.lineIndices].map(\.range))
            XCTAssertTrue(reader.isCurrent(try XCTUnwrap(provider.bindings[id])))
        }
        XCTAssertGreaterThan(try assertMountedGeometry(reader, provider: provider), 0)
        XCTAssertLessThan(provider.createdViewCount, blocks.count)
    }

    /// 新宽度与字号必须拒绝旧像素锚点，宿主以原文 UTF-16 位置解析新行。
    func testNewLayoutVersionRejectsOldAnchorAndRestoresOriginalTextPosition() throws {
        let old = try ContinuousTypographyFixture(width: 320, fontSize: 17.25, repetitions: 4, layoutVersion: 1)
        let oldBlocks = try old.blocks(lineCounts: [3])
        let oldLine = old.lines[old.lines.count / 2]
        let position = oldLine.range.location
        let oldAnchor = try old.anchor(atUTF16: position, in: oldBlocks, viewportOffset: 64)
        let provider = ContinuousTypographyProvider()
        provider.register(old, blocks: oldBlocks)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: oldBlocks.map(\.item)),
                                                        provider: provider, anchor: oldAnchor)
        let host = mount(reader, size: CGSize(width: old.width, height: 240))
        defer { reader.invalidate(); close(host) }
        let originalY = try screenY(of: oldLine, unitID: oldAnchor.identity.unitID, reader: reader, provider: provider)
        let new = try ContinuousTypographyFixture(width: 262, fontSize: 22.625, repetitions: 4, layoutVersion: 2)
        let newBlocks = try new.blocks(lineCounts: [3])
        let newWindow = try ContinuousWindow(items: newBlocks.map(\.item))
        XCTAssertEqual(old.text.string, new.text.string)
        XCTAssertGreaterThan(new.lines.count, old.lines.count)
        XCTAssertThrowsError(try newWindow.offset(for: oldAnchor, viewportExtent: 240)) {
            XCTAssertEqual($0 as? PageTurnError, .anchorUnavailable)
        }
        host.frame.size.width = new.width
        reader.view.frame = host.bounds
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        let token = reader.updateToken
        let previousWindow = reader.window
        XCTAssertThrowsError(try reader.apply(newWindow, expectedToken: token, anchor: oldAnchor)) {
            XCTAssertEqual($0 as? PageTurnError, .anchorUnavailable)
        }
        XCTAssertEqual(reader.window, previousWindow)
        XCTAssertEqual(reader.updateToken, token)
        provider.register(new, blocks: newBlocks)
        let newAnchor = try new.anchor(atUTF16: position, in: newBlocks, viewportOffset: originalY)
        try reader.apply(newWindow, expectedToken: token, anchor: newAnchor)
        let newLine = try XCTUnwrap(new.lines.first { NSLocationInRange(position, $0.range) })
        XCTAssertNotEqual(newLine.index, oldLine.index)
        XCTAssertEqual(try screenY(of: newLine, unitID: newAnchor.identity.unitID, reader: reader, provider: provider), originalY, accuracy: tolerance)
        XCTAssertEqual(reader.visibleAnchor?.identity.layoutVersion, 2)
        XCTAssertGreaterThan(try assertMountedGeometry(reader, provider: provider), 0)
    }

    /// 使用真实窗口与 layer.render 附件；检查末行含下伸部的字形确实绘出且未被块边界裁切。
    func testLastLineIsNotClippedAndAttachWholeAndStitchedWindows() throws {
        let fixture = try ContinuousTypographyFixture(width: 280, repetitions: 1)
        let blocks = try fixture.blocks(lineCounts: [1, 2, 3])
        let provider = ContinuousTypographyProvider()
        provider.register(fixture, blocks: blocks)
        let reader = try ContinuousReaderViewController(window: ContinuousWindow(items: blocks.map(\.item)), provider: provider)
        let size = CGSize(width: fixture.width, height: ceil(fixture.height) + 2)
        let stitchedHost = mount(reader, size: size)
        defer { reader.invalidate(); close(stitchedHost) }
        let wholeBlock = try XCTUnwrap(fixture.blocks(lineCounts: [fixture.lines.count]).first)
        let wholeView = ContinuousTypographyBlockView(frame: CGRect(origin: .zero, size: size))
        wholeView.configure(fixture: fixture, block: wholeBlock)
        let reference = UIViewController()
        reference.view = UIView(frame: CGRect(origin: .zero, size: size))
        reference.view.backgroundColor = .white
        reference.view.addSubview(wholeView)
        let wholeHost = mount(reference, size: size)
        defer { close(wholeHost) }
        let stitchedImage = snapshot(stitchedHost)
        let wholeImage = snapshot(wholeHost)
        attach(stitchedImage, name: "完整行分块拼接-中文混合字号引用底色emoji")
        attach(wholeImage, name: "未拆分章节-相同CTFrame原始行对照")
        XCTAssertEqual(provider.views.count, blocks.count)
        var drawnRanges: [NSRange] = []
        for block in blocks {
            let view = try XCTUnwrap(provider.views[block.item.identity.unitID])
            XCTAssertFalse(view.clipsToBounds)
            XCTAssertEqual(view.canvas.drawnRanges, fixture.lines[block.lineIndices].map(\.range))
            drawnRanges.append(contentsOf: view.canvas.drawnRanges)
            for (index, line) in fixture.lines[block.lineIndices].enumerated() {
                let localPaint = line.paintBounds.offsetBy(dx: 0, dy: -view.canvas.globalOriginY)
                XCTAssertGreaterThanOrEqual(localPaint.minY, 0)
                XCTAssertLessThanOrEqual(localPaint.maxY, view.canvas.bounds.height)
                let drawn = try XCTUnwrap(view.canvas.drawnBaselines.dropFirst(index).first)
                XCTAssertEqual(drawn.y + view.canvas.frame.minY,
                               line.baseline.y - block.origin, accuracy: tolerance)
            }
        }
        XCTAssertEqual(drawnRanges, wholeView.canvas.drawnRanges)
        assertCompleteTextCoverage(drawnRanges, length: fixture.text.length)
        let last = try XCTUnwrap(fixture.lines.last)
        XCTAssertTrue((fixture.text.string as NSString).substring(with: last.range).contains("gyp"))
        XCTAssertLessThan(last.paintBounds.maxY, fixture.height)
        let descenders = CGRect(x: last.paintBounds.minX, y: last.baseline.y + 0.5,
                                width: last.paintBounds.width, height: max(1, last.descent - 0.5))
        XCTAssertGreaterThan(try darkPixelCount(stitchedImage, in: descenders), 0, "末行下伸部应在拼接截图中实际可见")
        XCTAssertGreaterThan(try darkPixelCount(wholeImage, in: descenders), 0, "对照截图也必须绘出末行下伸部")
        XCTAssertGreaterThan(try assertMountedGeometry(reader, provider: provider), 0)
    }

    // MARK: - 几何断言与真实窗口绘制

    /// - Parameters: ranges: 按显示顺序收集的 UTF-16 行范围；length: 完整章节长度。
    private func assertCompleteTextCoverage(_ ranges: [NSRange], length: Int) {
        var cursor = 0
        for range in ranges {
            XCTAssertEqual(range.location, cursor, "不允许丢行、重行或跳过 emoji 的 UTF-16 单元")
            XCTAssertGreaterThan(range.length, 0)
            cursor = NSMaxRange(range)
        }
        XCTAssertEqual(cursor, length)
    }

    /// - Parameters: controller: 待挂载容器；size: 本次布局统一外宽和视口高度。
    /// - Returns: 调用方持有并在结束时关闭的真实窗口。
    private func mount(_ controller: UIViewController, size: CGSize) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.backgroundColor = .white
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return window
    }

    /// - Parameter window: 当前测试创建的真实窗口。
    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// - Parameters: line: 原文行；unitID: 拥有该行的块；reader: SDK 容器；provider: 当前绑定视图。
    /// - Returns: 实际 UIKit 坐标转换后的屏幕基线 Y。
    private func screenY(of line: ContinuousTypographyFixture.Line, unitID: String,
                         reader: ContinuousReaderViewController, provider: ContinuousTypographyProvider) throws -> CGFloat {
        let view = try XCTUnwrap(provider.views[unitID])
        return view.convert(view.localBaseline(for: line), to: reader.view).y
    }

    /// - Parameters: reader: 实际容器；provider: 当前宿主视图。
    /// - Returns: 已验证的相邻块接缝数量；直接比较真实视图坐标与整章行距。
    @discardableResult
    private func assertMountedGeometry(_ reader: ContinuousReaderViewController,
                                       provider: ContinuousTypographyProvider) throws -> Int {
        var seams = 0
        for item in reader.window.items {
            guard let view = provider.views[item.identity.unitID] else { continue }
            let origin = CGFloat(try XCTUnwrap(reader.window.origin(of: item.identity.unitID)))
            let block = try XCTUnwrap(view.block)
            let fixture = try XCTUnwrap(view.fixture)
            XCTAssertEqual(view.frame.minY, origin, accuracy: tolerance)
            XCTAssertEqual(view.frame.height, CGFloat(item.extent), accuracy: tolerance)
            XCTAssertEqual(view.frame.width, fixture.width, accuracy: tolerance)
            for line in fixture.lines[block.lineIndices] {
                let actual = view.convert(view.localBaseline(for: line), to: reader.view)
                XCTAssertEqual(actual.x, line.baseline.x, accuracy: tolerance)
                XCTAssertEqual(actual.y, origin + line.baseline.y - block.origin - reader.scrollView.contentOffset.y,
                               accuracy: tolerance)
            }
        }
        for (previousItem, nextItem) in zip(reader.window.items, reader.window.items.dropFirst()) {
            guard let previous = provider.views[previousItem.identity.unitID],
                  let next = provider.views[nextItem.identity.unitID] else { continue }
            let previousBlock = try XCTUnwrap(previous.block)
            let nextBlock = try XCTUnwrap(next.block)
            let fixture = try XCTUnwrap(previous.fixture)
            XCTAssertTrue(fixture === next.fixture)
            XCTAssertEqual(previousBlock.lineIndices.upperBound, nextBlock.lineIndices.lowerBound)
            let lastLine = fixture.lines[previousBlock.lineIndices.upperBound - 1]
            let firstLine = fixture.lines[nextBlock.lineIndices.lowerBound]
            let lastY = previous.convert(previous.localBaseline(for: lastLine), to: reader.view).y
            let firstY = next.convert(next.localBaseline(for: firstLine), to: reader.view).y
            XCTAssertEqual(firstY - lastY, firstLine.baseline.y - lastLine.baseline.y, accuracy: tolerance)
            XCTAssertEqual(next.frame.minY, previous.frame.maxY, accuracy: tolerance)
            seams += 1
        }
        return seams
    }

    /// - Parameter view: 要执行真实绘制的窗口及其子视图。
    private func displayTree(_ view: UIView) {
        view.layoutIfNeeded()
        view.layer.displayIfNeeded()
        for child in view.subviews { displayTree(child) }
    }

    /// - Parameter window: 已挂载的真实窗口。
    /// - Returns: 三倍比例、标准色域的 layer.render 截图，不写入项目文件。
    private func snapshot(_ window: UIWindow) -> UIImage {
        displayTree(window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(window.bounds)
            window.layer.render(in: context.cgContext)
        }
    }

    /// - Parameters: image: 真实窗口截图；name: 测试结果中的附件名。
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// - Parameters: image: 白底窗口截图；rect: 点坐标下的末行下伸部区域。
    /// - Returns: 具有深色分量的像素数量，仅断言确实绘出，不比较平台相关的抗锯齿 golden。
    private func darkPixelCount(_ image: UIImage, in rect: CGRect) throws -> Int {
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        XCTAssertEqual(cgImage.bitsPerComponent, 8)
        guard cgImage.bitsPerPixel == 32, cgImage.bitsPerComponent == 8 else { return 0 }
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = [UInt8](data as Data)
        XCTAssertGreaterThanOrEqual(bytes.count, cgImage.bytesPerRow * cgImage.height)
        guard bytes.count >= cgImage.bytesPerRow * cgImage.height else { return 0 }
        let x0 = max(0, Int(floor(rect.minX * image.scale)))
        let x1 = min(cgImage.width, Int(ceil(rect.maxX * image.scale)))
        let y0 = max(0, Int(floor(rect.minY * image.scale)))
        let y1 = min(cgImage.height, Int(ceil(rect.maxY * image.scale)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = y * cgImage.bytesPerRow + x * 4
                // 至少两个通道为深色，避免把不透明位图中值为零的保留通道误判成字形。
                if bytes[offset..<(offset + 4)].filter({ $0 < 160 }).count >= 2 { count += 1 }
            }
        }
        return count
    }
}
#endif
