#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import BonePageTurnKit

final class SlidingSpreadContactTests: XCTestCase {
    func testFlatTailFollowsFingerAcrossBindingAndSettles() throws {
        let size = CGSize(width: 390, height: 844)
        for direction in [PageTurnDirection.next, .previous] {
            let sign: CGFloat = direction == .next ? -1 : 1
            let origin = CGPoint(x: 195 - sign * 150, y: 422)
            var seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: true,
                inwardSign: sign, origin: origin, effect: .arch))
            seed.slidesOuterPaperFlat = true
            var peaks: [CGFloat] = []
            for pull: CGFloat in [24, 74, 150, 205] {
                let touch = CGPoint(x: origin.x + sign * pull, y: 422)
                let held = try XCTUnwrap(seed.moved(to: touch, direction: direction))
                let mesh = PaperArchGeometry.mesh(for: held, direction: direction, stripCount: 96)
                XCTAssertFalse(mesh.patches.isEmpty)
                let tail = mesh.samples.filter { $0.source.x >= 345 }
                XCTAssertGreaterThan(tail.count, 5)
                for p in tail {
                    XCTAssertEqual(p.height, 0, accuracy: 1e-6)
                    XCTAssertEqual(p.point.x, touch.x - sign * (p.source.x - 345), accuracy: 1e-6)
                    XCTAssertEqual(p.point.y, p.source.y, accuracy: 1e-6)
                }
                let peak = try XCTUnwrap(mesh.samples.max { $0.height < $1.height })
                XCTAssertGreaterThan(peak.height, 5)
                peaks.append((peak.worldPoint.x - 195) * -sign)
                for complete in [true, false] {
                    let end = held.released(completed: complete, fraction: 1, direction: direction)
                    let flat = PaperArchGeometry.mesh(for: end, direction: direction, stripCount: 96)
                    XCTAssertFalse(flat.patches.isEmpty)
                    for p in flat.samples {
                        XCTAssertEqual(p.height, 0, accuracy: 1e-6)
                        let reflected = (direction == .next) == complete
                        XCTAssertEqual(p.point.x, reflected ? 390 - p.source.x : p.source.x, accuracy: 1e-6)
                    }
                }
            }
            XCTAssertGreaterThan(peaks[0], 0)
            XCTAssertLessThan(peaks.last ?? 0, 0)
            for (a, b) in zip(peaks, peaks.dropFirst()) { XCTAssertLessThan(b, a) }
        }
    }
    func testCompletedReleaseCarriesCrestThroughHandoff() throws {
        let length: CGFloat = 195
        for direction in [PageTurnDirection.next, .previous] {
            let sign: CGFloat = direction == .next ? -1 : 1
            let origin = CGPoint(x: length - sign * 150, y: 422)
            var seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: length * 2, height: 844), axis: .horizontal,
                spread: true, inwardSign: sign, origin: origin, effect: .arch))
            seed.slidesOuterPaperFlat = true
            for pull: CGFloat in [74, 145, 205] {
                let held = try XCTUnwrap(seed.moved(to: CGPoint(x: origin.x + sign * pull, y: origin.y), direction: direction))
                var last: CGFloat?, steps: [CGFloat] = []
                for i in 20...80 {
                    let pose = held.released(completed: true, fraction: CGFloat(i) / 100, direction: direction)
                    let mesh = PaperArchGeometry.mesh(for: pose, direction: direction, stripCount: 96)
                    let crest = try XCTUnwrap(mesh.samples.max { $0.height < $1.height })
                    let x = crest.worldPoint.x * sign
                    if let last { steps.append(x - last) }
                    last = x
                }
                let slowest = try XCTUnwrap(steps.min())
                XCTAssertGreaterThan(slowest, length * 0.002, "中途拱顶不能停住再起步")
                for (a, b) in zip(steps, steps.dropFirst()) {
                    XCTAssertLessThan(abs(a - b), length * 0.002, "交接不能靠单帧变速越过")
                }
            }
        }
    }

    /// 松手后的回卷必须有两条不同高度的纸面；缩小原拱、让平尾直接穿过底页不能通过。
    func testSingleAndSpreadArchShareTheSameMaterialProfile() throws {
        for pull: CGFloat in [8, 24, 40, 74] {
            var single = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 195, height: 844), axis: .horizontal,
                spread: false, inwardSign: -1, origin: CGPoint(x: 150, y: 422), effect: .arch))
            var spread = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 390, height: 844), axis: .horizontal,
                spread: true, inwardSign: -1, origin: CGPoint(x: 345, y: 422), effect: .arch))
            single.slidesOuterPaperFlat = true; spread.slidesOuterPaperFlat = true
            let a = try XCTUnwrap(single.moved(to: CGPoint(x: 150 - pull, y: 422)))
            let b = try XCTUnwrap(spread.moved(to: CGPoint(x: 345 - pull, y: 422)))
            let ma = PaperArchGeometry.mesh(for: a, direction: .next, stripCount: 96)
            let mb = PaperArchGeometry.mesh(for: b, direction: .next, stripCount: 96)
            let peaks = try [ma, mb].map { mesh in
                try XCTUnwrap(mesh.samples.max { $0.height < $1.height }).height
            }
            XCTAssertGreaterThan(peaks[0], 0)
            XCTAssertGreaterThan(peaks[1], 0)
            XCTAssertEqual(peaks[0], peaks[1], accuracy: 0.75, "单双页应共享同一受压材料剖面，只允许书脊投影差异")
            for mesh in [ma, mb] {
                XCTAssertGreaterThan(mesh.samples.filter { $0.source.y == 422 }.count, 12)
                XCTAssertGreaterThanOrEqual(mesh.samples.map(\.height).min() ?? -.infinity, -1e-6)
            }
        }
    }
    func testRollingReleaseFormsSupportedHairpinBeforeTheTipLands() throws {
        let size = CGSize(width: 390, height: 844)
        for direction in [PageTurnDirection.next, .previous] {
            let sign: CGFloat = direction == .next ? -1 : 1
            let origin = CGPoint(x: 195 - sign * 150, y: 422)
            var seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: .horizontal, spread: true,
                inwardSign: sign, origin: origin, effect: .arch))
            seed.slidesOuterPaperFlat = true
            for pull: CGFloat in [74, 150, 205] {
                let held = try XCTUnwrap(seed.moved(to: CGPoint(x: origin.x + sign * pull, y: 422), direction: direction))
                var lastPeak = CGFloat.infinity, lastAspect = CGFloat.infinity
                func at(_ sample: PaperArchGeometry.Sample) -> CGFloat { (sample.worldPoint.x - 195) * -sign }
                for fraction: CGFloat in [0.6, 0.75, 0.88] {
                    let pose = held.released(completed: true, fraction: fraction, direction: direction)
                    let mesh = PaperArchGeometry.mesh(for: pose, direction: direction, stripCount: 96)
                    let row = mesh.samples.filter { $0.source.y == 422 }.sorted { $0.source.x < $1.source.x }
                    let tip = try XCTUnwrap(row.last), crest = try XCTUnwrap(row.max { $0.height < $1.height })
                    let upper = row.filter { abs($0.height - tip.height) < 1e-6 && $0.source.x > crest.source.x }
                    let upperStart = try XCTUnwrap(upper.first)
                    let lower = row.filter { $0.source.x < crest.source.x && abs($0.height) < 1e-6 }
                    let bottomEnd = try XCTUnwrap(lower.map(at).min())
                    let overlap = min(0, at(tip)) - max(bottomEnd, at(upperStart))
                    XCTAssertGreaterThan(overlap, 2, "第四笔上下两段需要有实际重叠宽度")
                    XCTAssertGreaterThan(tip.height, 0.1, "回卷上层不能与底页共面")
                    XCTAssertLessThan(tip.height, crest.height)
                    XCTAssertLessThan(crest.height, lastPeak)
                    let aspect = crest.height / max(1e-6, at(tip) - (row.map(at).min() ?? 0))
                    XCTAssertLessThan(aspect, lastAspect, "回卷应越来越扁，而非保持相同高宽比")
                    if fraction == 0.88 { XCTAssertLessThan(aspect, 0.23) }
                    for (a,b) in zip(row, row.dropFirst()) {
                        XCTAssertEqual(hypot(at(b) - at(a), b.height - a.height), b.source.x - a.source.x,
                            accuracy: max(1e-6, (b.source.x - a.source.x) * 0.002))
                    }
                    lastPeak = crest.height; lastAspect = aspect
                }
            }
        }
    }

    /// 保留等比例侧视截面，供对照手绘五阶段；坐标来自实际网格，不另算示意曲线。
    func testReleaseProfileSectionsFromRenderedMaterial() throws {
        var seed = try XCTUnwrap(PaperCornerDrag(size: CGSize(width: 390, height: 844), axis: .horizontal,
            spread: true, inwardSign: -1, origin: CGPoint(x: 345, y: 422), effect: .arch))
        seed.slidesOuterPaperFlat = true
        let held = try XCTUnwrap(seed.moved(to: CGPoint(x: 299, y: 422), direction: .next))
        var sections: [[[Double]]] = []
        for i in 0...100 {
            let pose = held.released(completed: true, fraction: CGFloat(i) / 100, direction: .next)
            let mesh = PaperArchGeometry.mesh(for: pose, direction: .next, stripCount: 96)
            let row = mesh.samples.filter { $0.source.y == 422 }.sorted { $0.source.x < $1.source.x }
            XCTAssertEqual(row.first?.source.x, 195); XCTAssertEqual(row.last?.source.x, 390)
            XCTAssertTrue(row.allSatisfy { $0.height.isFinite && $0.height >= -1e-6 })
            sections.append(row.map { [Double($0.source.x - 195), Double($0.worldPoint.x - 195), Double($0.height)] })
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(sections), uniformTypeIdentifier: "public.json")
        attachment.name = "hairpin-material-sections"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
