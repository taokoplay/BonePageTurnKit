#if canImport(UIKit)
import UIKit

/// 资源句柄只由主线程时钟访问；ARC 析构仅失效系统资源，不读取任何 UI 状态。
private final class DisplayLinkLifetime {
    var link: CADisplayLink?
    deinit { link?.invalidate() }
}

/// 弱代理打断 displayLink→target→时钟的持有环，离屏／等待时彻底停止时钟。
@MainActor
final class ReaderDisplayLink {
    @MainActor
    private final class Target: NSObject {
        weak var owner: ReaderDisplayLink?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    private let target = Target()
    private let lifetime = DisplayLinkLifetime()
    private var lastTimestamp: CFTimeInterval?
    var onTick: ((TimeInterval) -> Void)?
    var isRunning: Bool { lifetime.link != nil }
    /// 当前向系统申请的范围；不代表系统实际交付或屏幕实测刷新率。
    var activeFrameRateRange: CAFrameRateRange? { lifetime.link?.preferredFrameRateRange }

    /// 创建尚未启动的时钟，不注册系统观察。
    init() { target.owner = self }

    /// - Parameter maximumFramesPerSecond: 当前窗口屏幕的最高帧率；nil 或非正值时读取主屏幕。
    /// - Returns: 无返回值；重复调用更新申请范围而不重置时间基准，空闲仍由 stop() 停止。
    func start(maximumFramesPerSecond: Int? = nil) {
        let requested = maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        let maximum = Float(requested > 0 ? requested : max(1, UIScreen.main.maximumFramesPerSecond))
        // ProMotion 优先申请高帧率；普通屏幕按其实际上限，不使用固定设备型号分支。
        let range = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        if let link = lifetime.link {
            let active = link.preferredFrameRateRange
            if active.minimum != range.minimum || active.maximum != range.maximum || active.preferred != range.preferred {
                link.preferredFrameRateRange = range
            }
            return
        }
        lastTimestamp = nil
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = range
        lifetime.link = link
        link.add(to: .main, forMode: .common)
    }

    /// 停止并清空时间基准，恢复时不补偿后台或暂停期间的时间。
    func stop() {
        lifetime.link?.invalidate()
        lifetime.link = nil
        lastTimestamp = nil
    }

    /// - Parameter link: 系统帧时钟；时间跳变由推进端再次钳制。
    private func tick(_ link: CADisplayLink) {
        let interval = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        onTick?(interval)
    }
}
#endif
