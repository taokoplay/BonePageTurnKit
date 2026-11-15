#if canImport(UIKit)
import UIKit

/// 装饰工厂只接收中性内容信息；章节名、时间、电量等业务值仍由宿主提供。
public struct ReaderSurfaceContext: Sendable, Equatable {
    public let identity: PageItemIdentity?
    public let readingInfo: ReaderPageInfo

    /// - Parameters: identity: 当前页或顶部块；readingInfo: 对应页码与边界。连续首帧尚无锚点时 identity 为 nil。
    public init(identity: PageItemIdentity? = nil, readingInfo: ReaderPageInfo = .init()) {
        self.identity = identity
        self.readingInfo = readingInfo
    }

    /// - Parameter status: renderer 已确认的当前状态；返回对应装饰上下文。
    internal init(status: ReaderStatus) {
        self.init(identity: status.identity,
                  readingInfo: .init(pagination: status.pagination, before: status.before, after: status.after))
    }
}

/// 一组真实装饰视图。工厂须交付尚未挂载且互不重复的实例。
@MainActor
public struct ReaderSurfaceDecorationViews {
    public let header: UIView?
    public let footer: UIView?
    public let background: UIView?

    /// - Parameters: header: 页眉；footer: 页脚；background: 主题背景。nil 表示不创建该视图。
    public init(header: UIView? = nil, footer: UIView? = nil, background: UIView? = nil) {
        self.header = header
        self.footer = footer
        self.background = background
    }

    internal var all: [UIView] { [background, header, footer].compactMap { $0 } }

    /// - Parameter excluding: 不能作为装饰的正文根视图。
    /// - Throws: 已被挂载、重复、正文自身或其子视图。
    internal func validate(excluding root: UIView? = nil) throws {
        var identities = Set<ObjectIdentifier>()
        for view in all {
            guard view.superview == nil, identities.insert(ObjectIdentifier(view)).inserted else {
                throw ReaderSurfaceError.invalidDecoration
            }
            if let root, view === root || view.isDescendant(of: root) || root.isDescendant(of: view) {
                throw ReaderSurfaceError.invalidDecoration
            }
        }
    }
}

/// 工厂在创建展示页时调用；固定装饰不随每次滚动重建，使用 update 更新同一实例。
@MainActor
public struct ReaderSurfaceDecorations {
    public let makeHeader: ((ReaderSurfaceContext) -> UIView)?
    public let makeFooter: ((ReaderSurfaceContext) -> UIView)?
    public let makeBackground: ((ReaderSurfaceContext) -> UIView)?
    public let update: ((ReaderSurfaceDecorationViews, ReaderSurfaceContext) -> Void)?

    /// - Parameters: makeHeader: 页眉工厂；makeFooter: 页脚工厂；makeBackground: 主题背景工厂；update: 当前内容身份或统计改变后更新已有装饰。
    /// 非隔离初始化：允许作为 MainActor 类型的默认参数表达式求值。
    public nonisolated init(makeHeader: ((ReaderSurfaceContext) -> UIView)? = nil,
                makeFooter: ((ReaderSurfaceContext) -> UIView)? = nil,
                makeBackground: ((ReaderSurfaceContext) -> UIView)? = nil,
                update: ((ReaderSurfaceDecorationViews, ReaderSurfaceContext) -> Void)? = nil) {
        self.makeHeader = makeHeader
        self.makeFooter = makeFooter
        self.makeBackground = makeBackground
        self.update = update
    }

    /// - Parameters: context: 待创建的页；chrome: 是否创建页眉页脚；background: 是否创建背景。
    /// - Returns: 未挂载的视图；后续统一验证归属。
    internal func make(context: ReaderSurfaceContext, chrome: Bool, background: Bool) -> ReaderSurfaceDecorationViews {
        .init(header: chrome ? makeHeader?(context) : nil,
              footer: chrome ? makeFooter?(context) : nil,
              background: background ? makeBackground?(context) : nil)
    }
}

/// 装饰页内部使用真实控制器承载正文。这里的正文坐标从零开始，外部位置由布局结果描述。
@MainActor
final class ReaderSurfacePageViewController: UIViewController {
    let bodyPage: PageContent
    let decorations: ReaderSurfaceDecorationViews
    private(set) var surfaceLayout: ReaderSurfaceLayout
    private let canvasColor: UIColor
    private let bodyClip = UIView()

    /// - Parameters: body: 宿主正文；decorations: 本页随动装饰；layout: 当前稳定布局；canvasColor: 整页底色。
    /// - Throws: 正文归属或装饰无效。
    init(body: PageContent, decorations: ReaderSurfaceDecorationViews, layout: ReaderSurfaceLayout,
         canvasColor: UIColor) throws {
        guard body.controller.parent == nil, body.controller.presentingViewController == nil,
              body.controller.viewIfLoaded?.superview == nil else { throw ReaderSurfaceError.invalidController }
        self.bodyPage = body
        self.decorations = decorations
        self.surfaceLayout = layout
        self.canvasColor = canvasColor
        super.init(nibName: nil, bundle: nil)
        body.controller.loadViewIfNeeded()
        guard body.controller.parent == nil, let content = body.controller.viewIfLoaded,
              content.superview == nil else { throw ReaderSurfaceError.invalidController }
        try decorations.validate(excluding: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用正文和装饰初始化") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = surfaceLayout.motion == .wholePage ? canvasColor : .clear
        root.clipsToBounds = true
        bodyClip.backgroundColor = .clear
        bodyClip.clipsToBounds = true
        view = root
    }

    /// - Throws: 宿主同步回调破坏归属；失败会回滚本包装器拥有的部分，不挪走外部接管视图。
    func prepare() throws {
        loadViewIfNeeded()
        let content = bodyPage.controller
        guard content.parent == nil, let body = content.viewIfLoaded, body.superview == nil else {
            throw ReaderSurfaceError.invalidController
        }
        try decorations.validate(excluding: body)
        var installed = false
        defer { if !installed { detachContents() } }
        if let background = decorations.background { view.addSubview(background) }
        view.addSubview(bodyClip)
        guard content.parent == nil, body.superview == nil else { throw ReaderSurfaceError.invalidController }
        addChild(content)
        guard content.parent === self, body.superview == nil else { throw ReaderSurfaceError.invalidController }
        bodyClip.addSubview(body)
        guard content.parent === self, body.superview === bodyClip else { throw ReaderSurfaceError.invalidController }
        content.didMove(toParent: self)
        for chrome in [decorations.header, decorations.footer].compactMap({ $0 }) {
            guard chrome.superview == nil, chrome !== view, !view.isDescendant(of: chrome) else { throw ReaderSurfaceError.invalidDecoration }
            view.addSubview(chrome)
        }
        guard hasValidContent else { throw ReaderSurfaceError.invalidController }
        installed = true
        apply(surfaceLayout)
    }

    var hasValidContent: Bool {
        bodyPage.controller.parent === self && bodyPage.controller.viewIfLoaded?.superview === bodyClip &&
            decorations.all.allSatisfy { $0.superview === viewIfLoaded }
    }

    /// - Parameter layout: 与外层同一版几何；转为包装器内部坐标后布局所有真实视图。
    func apply(_ layout: ReaderSurfaceLayout) {
        surfaceLayout = layout
        guard isViewLoaded else { return }
        let origin = layout.rendererFrame.origin
        func local(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        bodyClip.frame = local(layout.bodyFrame)
        bodyPage.controller.viewIfLoaded?.frame = bodyClip.bounds
        if let background = decorations.background { background.frame = local(layout.backgroundFrame) }
        for (chrome, frame) in [(decorations.header, layout.headerFrame), (decorations.footer, layout.footerFrame)] {
            chrome?.isHidden = frame == nil
            if let frame { chrome?.frame = local(frame) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        apply(surfaceLayout)
    }

    /// 回滚或拒绝延期替换时释放正文 containment，避免宿主保留的控制器仍属于被废弃包装器。
    func detachContents() {
        let content = bodyPage.controller
        if content.parent === self { content.willMove(toParent: nil) }
        if content.viewIfLoaded?.superview === bodyClip { content.viewIfLoaded?.removeFromSuperview() }
        if content.parent === self { content.removeFromParent() }
        for decoration in decorations.all where decoration.superview === viewIfLoaded { decoration.removeFromSuperview() }
    }
}
#endif
