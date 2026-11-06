import Foundation
import XCTest
@testable import BonePageTurnKit

final class ReaderSpreadLayoutTests: XCTestCase {
    func testCoverAndOddTailDoNotInventSourcePages() throws {
        let cover = try ReaderSpreadLayout(pageCount: 6)
        XCTAssertEqual(cover.spreadCount, 4)
        XCTAssertEqual(try cover.spread(at: 0), .init(first: nil, second: 0))
        XCTAssertEqual(try cover.spread(at: 1), .init(first: 1, second: 2))
        XCTAssertEqual(try cover.spread(at: 3), .init(first: 5, second: nil))
        let paired = try ReaderSpreadLayout(pageCount: 5, firstPageIsCover: false)
        XCTAssertEqual(try paired.spread(at: 2), .init(first: 4, second: nil))
        XCTAssertEqual(try paired.spread(at: 0), .init(first: 0, second: 1))
    }

    func testSourceIndexRoundTripsAcrossSingleAndSpreadIncludingExtremeCounts() throws {
        for count in [0, 1, 2, 3, 150, Int.max] {
            for cover in [false, true] {
                let layout = try ReaderSpreadLayout(pageCount: count, firstPageIsCover: cover)
                if count == 0 { XCTAssertEqual(layout.spreadCount, 0); continue }
                for page in Set([0, count / 2, count - 1]) {
                    let pair = try layout.spread(at: layout.spreadIndex(containingPage: page))
                    XCTAssertTrue(pair.first == page || pair.second == page)
                }
            }
        }
        XCTAssertThrowsError(try ReaderSpreadLayout(pageCount: -1))
        XCTAssertThrowsError(try ReaderSpreadLayout(pageCount: 0).spread(at: 0))
        XCTAssertThrowsError(try ReaderSpreadLayout(pageCount: 1).spreadIndex(containingPage: 1))
    }

    func testLayoutAndSpineCapabilityMatrix() throws {
        for effect in [PageTurnEffect.none, .cover, .slide, .curl, .arch] {
            for axis in [PageTurnAxis.horizontal, .vertical] {
                for layout in [ReaderPageLayout.single, .spread] {
                    let presentation = PageTurnPresentation.paged(effect: effect, axis: axis)
                    for spine in [PageSpinePlacement.automatic, .minimum, .maximum, .center] {
                        let config = PageTurnConfiguration(presentation: presentation, spine: spine, layout: layout)
                        let expected = !(effect == .cover && axis == .vertical) &&
                            ((effect == .curl || effect == .arch)
                             ? (layout == .single ? spine != .center : (spine == .automatic || spine == .center))
                             : spine == .automatic)
                        if expected { XCTAssertNoThrow(try config.validate()) }
                        else { XCTAssertThrowsError(try config.validate()) }
                        XCTAssertEqual(PageTurnConfiguration.supportedSpines(for: presentation, layout: layout).contains(spine), expected)
                    }
                }
            }
        }
        XCTAssertThrowsError(try PageTurnConfiguration(presentation: .continuous(axis: .vertical), layout: .spread).validate())
    }

    func testReadingOrderAndSpineResolveWithoutSystemLocale() {
        for effect in [PageTurnEffect.none, .slide, .cover, .curl, .arch] {
            let rtl = PageTurnConfiguration(presentation: .paged(effect: effect, axis: .horizontal), readingOrder: .rightToLeft)
            XCTAssertEqual(rtl.forwardDisplacementSign, 1)
            let vertical = PageTurnConfiguration(presentation: .paged(effect: effect, axis: .vertical), readingOrder: .rightToLeft)
            XCTAssertEqual(vertical.forwardDisplacementSign, -1)
        }
        let center = PageTurnConfiguration(presentation: .paged(effect: .curl, axis: .horizontal), layout: .spread, readingOrder: .rightToLeft)
        XCTAssertEqual(center.resolvedSpine, .center)
        let explicit = PageTurnConfiguration(presentation: .paged(effect: .arch, axis: .horizontal), spine: .minimum, readingOrder: .rightToLeft)
        XCTAssertEqual(explicit.forwardDisplacementSign, -1)
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class ReaderSpreadContainerTests: XCTestCase {
    private func page(_ index: Int, version: UInt64 = 0) -> PageContent {
        let controller = UIViewController()
        controller.view.backgroundColor = index.isMultiple(of: 2) ? .systemYellow : .systemTeal
        let label = UILabel(frame: CGRect(x: 10, y: 10, width: 100, height: 80))
        label.text = "源页 \(index) →"
        controller.view.addSubview(label)
        return .init(identity: .init(sourceID: "book", unitID: "page-\(index)", contentVersion: version), controller: controller)
    }

    private func spread(_ index: Int, axis: PageTurnAxis = .horizontal, order: ReaderReadingOrder = .leftToRight, version: UInt64 = 0) throws -> PageContent {
        let child = try PageSpreadViewController(first: page(index * 2, version: version), second: page(index * 2 + 1, version: version), axis: axis, readingOrder: order)
        return .init(identity: .init(sourceID: "book", unitID: "spread-\(index)", contentVersion: version), controller: child)
    }

    private func reader(_ initial: PageContent, axis: PageTurnAxis = .horizontal, order: ReaderReadingOrder = .leftToRight, effect: PageTurnEffect = .curl) throws -> PagedReaderViewController {
        let reader = try PagedReaderViewController(page: initial, configuration: .init(presentation: .paged(effect: effect, axis: axis), layout: .spread, readingOrder: order))
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        initial.controller.view.layoutIfNeeded()
        return reader
    }

    func testRealTwoPageContainmentAndPhysicalOrderOnBothAxes() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for order in [ReaderReadingOrder.leftToRight, .rightToLeft] {
                let first = page(0)
                let second = page(1)
                let spread = try PageSpreadViewController(first: first, second: second, axis: axis, readingOrder: order)
                spread.loadViewIfNeeded()
                spread.view.bounds = CGRect(x: 19, y: 27, width: 600, height: 500)
                spread.view.setNeedsLayout(); spread.view.layoutIfNeeded()
                XCTAssertEqual(spread.children.count, 2)
                XCTAssertTrue(first.controller.parent === spread)
                XCTAssertTrue(second.controller.parent === spread)
                let a = first.controller.view.frame
                let b = second.controller.view.frame
                if axis == .horizontal {
                    XCTAssertEqual(a.width, 300)
                    XCTAssertEqual(a.minY, 27)
                    XCTAssertEqual(a.minX, order == .leftToRight ? 19 : 319)
                    XCTAssertEqual(b.minX, order == .leftToRight ? 319 : 19)
                } else {
                    XCTAssertEqual(a, CGRect(x: 19, y: 27, width: 600, height: 250))
                    XCTAssertEqual(b, CGRect(x: 19, y: 277, width: 600, height: 250))
                }
            }
        }
    }

    func testBlankCoverAndTailKeepHalfViewportAndOnlyRealIdentity() throws {
        for cover in [true, false] {
            let content = page(0)
            let child = try PageSpreadViewController(first: cover ? nil : content, second: cover ? content : nil)
            let initial = PageContent(identity: .init(sourceID: "book", unitID: "spread"), controller: child)
            let reader = try reader(initial)
            defer { reader.invalidate() }
            XCTAssertEqual(reader.visiblePageIdentities, [content.identity])
            XCTAssertEqual(content.controller.view.frame.width, 300)
            XCTAssertEqual(content.controller.view.frame.minX, cover ? 300 : 0)
            XCTAssertEqual(child.children.count, 1)
        }
    }

    func testRejectsEmptyDuplicateOccupiedAndMismatchedSpread() throws {
        XCTAssertThrowsError(try PageSpreadViewController(first: nil, second: nil))
        let a = page(0)
        XCTAssertThrowsError(try PageSpreadViewController(first: a, second: a))
        let parent = UIViewController()
        parent.addChild(a.controller)
        XCTAssertThrowsError(try PageSpreadViewController(first: a, second: nil))
        a.controller.removeFromParent()
        XCTAssertThrowsError(try PagedReaderViewController(page: page(1), configuration: .init(presentation: .paged(effect: .curl, axis: .horizontal), layout: .spread)))
        XCTAssertThrowsError(try reader(spread(0, axis: .vertical)))
        XCTAssertThrowsError(try reader(spread(0, order: .rightToLeft)))
        XCTAssertThrowsError(try PagedReaderViewController(page: spread(0), configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))))
    }

    func testSpreadCommitsAtomicallyAndCancellationKeepsBothRealPages() throws {
        for axis in [PageTurnAxis.horizontal, .vertical] {
            for effect in [PageTurnEffect.curl, .arch] {
                let initial = try spread(0, axis: axis)
                let reader = try reader(initial, axis: axis, effect: effect)
                defer { reader.invalidate() }
                let target = try spread(1, axis: axis)
                reader.pageProvider = { _, _ in .page(target) }
                var events: [PageTransitionEvent] = []
                reader.onTransition = { events.append($0) }
                XCTAssertTrue(try reader.beginInteractiveTurn(.next))
                XCTAssertEqual(reader.visiblePageIdentities.map(\.unitID), ["page-0", "page-1"])
                XCTAssertEqual(reader.activePaperView?.hasResources, true)
                reader.updateInteractiveTurn(displacement: 250)
                reader.cancelTransition()
                XCTAssertEqual(reader.visiblePageIdentities.map(\.unitID), ["page-0", "page-1"])
                XCTAssertNil(target.controller.parent)
                XCTAssertTrue(try reader.turn(.next, animated: false))
                XCTAssertEqual(reader.visiblePageIdentities.map(\.unitID), ["page-2", "page-3"])
                XCTAssertEqual(events.filter { if case .didCommit = $0 { return true }; return false }.count, 1)
                XCTAssertNil(initial.controller.parent)
                XCTAssertFalse(target.controller.view.isHidden)
            }
        }
    }

    func testSpreadReplacementRejectsSingleCandidateAndKeepsRendererIdentity() throws {
        let initial = try spread(0)
        let reader = try reader(initial)
        defer { reader.invalidate() }
        let binding = reader.currentPageBinding
        let presentation = reader.presentationID
        XCTAssertThrowsError(try reader.replaceCurrentPage(page(1), expectedBinding: binding))
        XCTAssertEqual(reader.currentPageBinding, binding)
        _ = try reader.replaceCurrentPage(spread(0, version: 1), expectedBinding: binding)
        XCTAssertEqual(reader.presentationID, presentation)
        XCTAssertEqual(reader.visiblePageIdentities.map(\.contentVersion), [1, 1])
        XCTAssertEqual(reader.children.count, 1)
    }

    func testRTLSlideAndTapUseLogicalNextWithoutMirroringText() throws {
        let initial = page(0)
        let reader = try PagedReaderViewController(page: initial, configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal), readingOrder: .rightToLeft))
        defer { reader.invalidate() }
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        reader.view.layoutIfNeeded()
        var requested: [PageTurnDirection] = []
        let target = page(1)
        reader.pageProvider = { _, direction in requested.append(direction); return .page(target) }
        reader.tapConfiguration = try ReaderTapConfiguration()
        XCTAssertTrue(try reader.beginInteractiveTurn(.next))
        reader.updateInteractiveTurn(displacement: 80)
        XCTAssertEqual(initial.controller.view.frame.minX, 80)
        XCTAssertEqual(target.controller.view.frame.minX, -240)
        XCTAssertEqual(initial.controller.view.transform, .identity)
        reader.cancelTransition()
        XCTAssertTrue(try reader.handleTap(at: CGPoint(x: 5, y: 200), animated: false))
        XCTAssertEqual(requested, [.next, .next])
    }
}
#endif
