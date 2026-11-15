#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import MetalKit
import XCTest
@testable import BonePageTurnKit

/// 独立测量宿主启用；常规回归不把模拟器提交次数当作硬件呈现 FPS。
@MainActor
final class ReaderSmoothnessBenchmarks: XCTestCase {
    private func requireBenchmarkHost() throws {
        let enabled = Bundle.main.bundleIdentifier?.hasPrefix("com.bone.page-turn-smoothness") == true
            || ProcessInfo.processInfo.environment["BONE_RUN_SMOOTHNESS_BENCHMARKS"] == "1"
        try XCTSkipUnless(enabled, "仅在独立丝滑度测量宿主或显式环境开关下采样")
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        try XCTSkipUnless(PaperCornerMetalRenderer.isSupported)
    }

    private func page(_ index: Int, size: CGSize) -> PageContent {
        let controller = UIViewController()
        controller.view = UIView(frame: CGRect(origin: .zero, size: size))
        controller.view.backgroundColor = index.isMultiple(of: 2) ? .white : .systemTeal
        let label = UILabel(frame: controller.view.bounds.insetBy(dx: 24, dy: 36))
        label.font = .systemFont(ofSize: 20)
        label.numberOfLines = 0
        label.text = String(repeating: "第 \(index) 页 · 完整翻页的原生提交与呈现节奏\n", count: 12)
        controller.view.addSubview(label)
        return .init(identity: .init(sourceID: "smoothness", unitID: String(index)), controller: controller)
    }

    private func record(_ values: [String: Any], name: String, marker: String) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print(marker + " " + String(decoding: data, as: UTF8.self))
    }

    private func distribution(_ samples: [Double]) -> [String: Any] {
        let values = samples.sorted()
        guard !values.isEmpty else { return ["count": 0] }
        return ["count": values.count, "p50": values[(values.count - 1) / 2],
                "p95": values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)],
                "max": values.last ?? 0]
    }

    func testRecordFullReaderNativeCadence() async throws {
        try requireBenchmarkHost()
        let size = CGSize(width: 390, height: 844)
        let reader = try PagedReaderViewController(page: page(8, size: size), configuration: .init(
            presentation: .paged(effect: .curl, axis: .horizontal), paper: .standard))
        reader.usesDisplayLinkForAutomaticReading = false
        reader.animationDiagnosticsEnabled = true
        reader.pageProvider = { [self] identity, direction in
            .page(page((Int(identity.unitID) ?? 8) + (direction == .next ? 1 : -1), size: size))
        }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
        window.rootViewController = reader; window.makeKeyAndVisible()
        reader.view.frame = window.bounds; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
        let observer = ReaderDisplayLink()
        defer { observer.stop(); reader.invalidate(); window.isHidden = true; window.rootViewController = nil }
        var ticks: [UUID: Int] = [:]
        var presented: [UUID: [TimeInterval]] = [:]
        var firstSubmissionObserved: [UUID: TimeInterval] = [:]
        observer.onTick = { [weak reader] _ in
            guard let reader, let id = reader.activeTransitionID, let paper = reader.activePaperView else { return }
            ticks[id, default: 0] += 1
            presented[id] = paper.metalPresentationTimes
            if paper.nativeCornerSubmittedFrameCount > 0, firstSubmissionObserved[id] == nil {
                firstSubmissionObserved[id] = CACurrentMediaTime()
            }
        }
        // 等待测试宿主完成前台激活，启动过程的 resignActive 不属于翻页性能样本。
        var stableActiveTicks = 0
        for _ in 0..<200 {
            stableActiveTicks = UIApplication.shared.applicationState == .active ? stableActiveTicks + 1 : 0
            if stableActiveTicks >= 20 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        observer.start(maximumFramesPerSecond: window.screen.maximumFramesPerSecond)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        var turns: [[String: Any]] = []
        var allIntervals: [Double] = []
        for direction in [PageTurnDirection.next, .next, .next, .previous, .previous, .previous] {
            XCTAssertTrue(try reader.turn(direction, animated: true))
            let id = try XCTUnwrap(reader.activeTransitionID)
            for _ in 0..<2_000 {
                if !reader.isTransitioning { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertFalse(reader.isTransitioning, "测量中翻页必须正常落定")
            let finished = try XCTUnwrap(reader.recentAnimationDiagnostics.last { $0.transitionID == id && $0.event == .finished })
            XCTAssertEqual(finished.endReason, .completed, "中断的翻页不能作为完整性能样本")
            XCTAssertEqual(finished.animationElapsed, finished.duration)
            XCTAssertEqual(finished.progress, 1, accuracy: 1e-9)
            let start = finished.timestamp - finished.wallElapsed
            let times = (presented[id] ?? []).sorted()
            let intervals = zip(times, times.dropFirst()).map { ($1 - $0) * 1_000 }
            allIntervals.append(contentsOf: intervals)
            let fps: Any = intervals.isEmpty ? NSNull() : 1_000 / (intervals.reduce(0, +) / Double(intervals.count))
            let firstPresented: Any = times.first.map { max(0, $0 - start) * 1_000 as Any } ?? NSNull()
            let firstSubmitted: Any = firstSubmissionObserved[id].map { max(0, $0 - start) * 1_000 as Any } ?? NSNull()
            turns.append(["direction": direction == .next ? "next" : "previous", "observerTicks": ticks[id] ?? 0,
                "submitted": finished.gpuSubmissionCount, "presentedSamples": times.count,
                "endReason": finished.endReason?.rawValue ?? "missing",
                "animationElapsedMS": (finished.animationElapsed ?? 0) * 1_000,
                "presentedFPS": fps, "presentationIntervalsMS": distribution(intervals),
                "preparationMS": (finished.preparationDuration ?? 0) * 1_000,
                "animationDurationMS": (finished.duration ?? 0) * 1_000, "wallMS": finished.wallElapsed * 1_000,
                "firstSubmissionObservedMS": firstSubmitted, "firstPresentedMS": firstPresented])
        }
        #if targetEnvironment(simulator)
        let hardware = false
        #else
        let hardware = true
        #endif
        try record(["hardware": hardware, "screenMaximumHz": window.screen.maximumFramesPerSecond,
            "proMotionInfoPlist": Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool ?? false,
            "size": [390, 844], "snapshotPixelBudget": PaperRenderingOptions.standard.maximumSnapshotPixels,
            "stripCount": PaperRenderingOptions.standard.stripCount, "lowPowerBefore": lowPower,
            "lowPowerAfter": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermalBefore": thermal,
            "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue,
            "turns": turns, "presentationIntervalsMS": distribution(allIntervals),
            "scope": "完整 PagedReader 原生收尾；observerTicks/submitted 不等于屏幕 presented FPS；首提交为观察时刻"],
            name: "reader-native-cadence.json", marker: "READER_NATIVE_CADENCE")
    }

    func testRecordCornerComputationCost() throws {
        try requireBenchmarkHost()
        var poses: [PaperCornerDrag] = []
        for axis in [PageTurnAxis.horizontal, .vertical] {
            let size = axis == .horizontal ? CGSize(width: 390, height: 844) : CGSize(width: 844, height: 390)
            for sign: CGFloat in [-1, 1] {
                for cross: CGFloat in [80, 422, 764] {
                    func point(_ primary: CGFloat, _ cross: CGFloat) -> CGPoint {
                        axis == .horizontal ? CGPoint(x: primary, y: cross) : CGPoint(x: cross, y: primary)
                    }
                    let seed = try XCTUnwrap(PaperCornerDrag(size: size, axis: axis, spread: false,
                        inwardSign: sign, origin: point(sign > 0 ? 20 : 370, cross)))
                    for fraction: CGFloat in [0.2, 0.4, 0.6, 0.8] {
                        let p = (sign > 0 ? 0 : 390) + sign * 390 * fraction
                        let c = cross + (cross < 422 ? 60 : -60)
                        poses.append(try XCTUnwrap(seed.moved(to: point(p, c))))
                    }
                }
            }
        }
        for pose in poses.prefix(6) {
            let patches = PaperCornerCurlGeometry.patches(for: pose, stripCount: 128)
            _ = PaperCornerShadowGeometry.vertices(for: pose, patches: patches)
        }
        var samples: [Double] = []
        var checksum: Double = 0
        for _ in 0..<4 {
            for pose in poses {
                let start = CACurrentMediaTime()
                let patches = PaperCornerCurlGeometry.patches(for: pose, stripCount: 128)
                let shadow = PaperCornerShadowGeometry.vertices(for: pose, patches: patches)
                checksum += Double(patches.count + shadow.count)
                checksum += Double(shadow.last?.point.x ?? 0) + Double(patches.last?.transform.a ?? 0)
                samples.append((CACurrentMediaTime() - start) * 1_000)
            }
        }
        XCTAssertGreaterThan(checksum, 0)
        try record(["samples": samples.count, "stripCount": 128, "computationMS": distribution(samples),
            "checksum": checksum, "scope": "曲面与阴影 CPU 计算，不包含 GPU、快照或呈现"],
            name: "corner-computation.json", marker: "CORNER_COMPUTATION")
    }
}
#endif
