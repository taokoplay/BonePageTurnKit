import UIKit
import BonePageTurnKit

@main
final class DemoAppDelegate: UIResponder, UIApplicationDelegate {
    /// - Parameters: application: 应用；connectingSceneSession: 新会话；options: 启动参数。
    /// - Returns: 使用演示窗口代理的场景配置。
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "ReaderDemo", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DemoSceneDelegate.self
        return configuration
    }
}

final class DemoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// - Parameters: scene: 窗口场景；session: 会话；connectionOptions: 启动参数。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        if ProcessInfo.processInfo.arguments.contains("--system-curl") {
            let autoplay: TimeInterval? = ProcessInfo.processInfo.arguments.contains("--autoplay") ? 0.45 : nil
            window.rootViewController = SystemCurlDemoViewController(autoplayInterval: autoplay)
        } else if ProcessInfo.processInfo.arguments.contains("--fullscreen-reader") {
            window.rootViewController = FullScreenReaderDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--automatic-reader") {
            window.rootViewController = AutomaticReadingDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--surface-reader") {
            window.rootViewController = ReaderSurfaceDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--duo-reader") {
            window.rootViewController = DuoReaderNavigationController(rootViewController: DuoReaderDemoViewController())
        } else if ProcessInfo.processInfo.arguments.contains("--expanded-reader") {
            window.rootViewController = AdvancedReaderDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains(where: { ["--paged-modes", "--paper-curl", "--paper-arch"].contains($0) }) {
            window.rootViewController = PagedModesDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--filling") {
            window.rootViewController = ContinuousFillingDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--interactions") {
            window.rootViewController = SDKInteractionDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains("--async-styles") {
            window.rootViewController = AsyncRenderingDemoViewController()
        } else if ProcessInfo.processInfo.arguments.contains(where: { ["--legacy-reader", "--comic", "--serial", "--last", "--continuous"].contains($0) }) {
            window.rootViewController = ReaderDemoViewController()
        } else {
            window.rootViewController = FullScreenReaderDemoViewController()
        }
        window.makeKeyAndVisible()
        self.window = window
    }
}
