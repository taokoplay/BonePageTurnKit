import UIKit
import BonePageTurnKit

/// 系统仿真基准：把 SDK 的 `SystemCurlReaderViewController` 挂进示例，
/// 与本库自研 `curl` 用同一份长文做逐帧对比。仅做对照，不参与 SDK 事务。
@MainActor
final class SystemCurlDemoViewController: UIViewController {
    private let factory: FullScreenDemoContentFactory
    private let reader: SystemCurlReaderViewController
    private let indicator = UILabel()
    private let autoplayInterval: TimeInterval?
    private var autoplay: Timer?

    /// - Parameter autoplayInterval: 非 nil 时按该间隔自动翻页，便于无人值守录制对比。
    init(autoplayInterval: TimeInterval? = nil) {
        var settings = FullScreenDemoSettings()
        settings.effect = "curl"
        let factory = FullScreenDemoContentFactory(settings: settings, layoutVersion: 1)
        self.factory = factory
        self.autoplayInterval = autoplayInterval
        reader = SystemCurlReaderViewController(pageCount: factory.units.count)
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持归档构造。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 建立系统翻页容器、页码与自动翻页。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = FullScreenDemoContentFactory.paperColor
        reader.pageProvider = { [weak self] index in
            guard let self, index < self.factory.units.count else { return nil }
            let controller = try? self.factory.page(at: index).controller
            controller?.view.backgroundColor = FullScreenDemoContentFactory.paperColor
            return controller
        }
        reader.onPageChange = { [weak self] _ in self?.updateIndicator() }
        addChild(reader)
        reader.view.frame = view.bounds
        reader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(reader.view)
        reader.didMove(toParent: self)
        indicator.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        indicator.textColor = .secondaryLabel
        indicator.textAlignment = .center
        indicator.accessibilityIdentifier = "system-curl-position"
        indicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        updateIndicator()
    }

    /// 按启动参数里的自动翻页间隔启动时钟。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let interval = autoplayInterval, autoplay == nil else { return }
        autoplay = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    /// 停止自动翻页时钟。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        autoplay?.invalidate(); autoplay = nil
    }

    private func updateIndicator() {
        indicator.text = "\(reader.currentIndex + 1)/\(factory.units.count)"
    }

    /// 自动翻页：交给系统容器的切换接口，正在播放时跳过本帧。
    private func advance() {
        guard !reader.isTransitioning else { return }
        _ = reader.setCurrentIndex(reader.currentIndex + 1, animated: true)
    }
}
