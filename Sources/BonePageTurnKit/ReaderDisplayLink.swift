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

    /// 创建尚未启动的时钟，不注册系统观察。
    init() { target.owner = self }

    /// 开始每帧回调；重复调用不重置时间基准。
    func start() {
        guard lifetime.link == nil else { return }
        lastTimestamp = nil
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
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
