# 正文、页眉页脚与背景外壳

`ReaderSurfaceViewController` 将宿主正文、页眉、页脚和阅读主题背景组合成一个阅读外壳，复用既有分页／连续容器。所有 UIKit 对象和回调位于主 actor；不解析正文，不计算章节标题、时间、电量或数据库进度。

## 输出的位置与大小

组件公开只读 `layout: ReaderSurfaceLayout?` 和 `layoutRevision`。尚未布局时为 nil；布局后每个 CGRect 均包含 origin 和 size，单位为 point，默认坐标系为 `surface.view`，非零 bounds 原点保留。

| 字段 | 含义 |
| --- | --- |
| `backgroundFrame` | 外壳的整个 bounds，不扣页眉页脚或安全区 |
| `readingFrame` | 安全区／保留区域策略得出的可读区域 |
| `bodyFrame` | 扣除页眉页脚、间距及正文四边内边距后的正文区域 |
| `headerFrame` | 页眉槽位，headerHeight 为 0 时 nil |
| `footerFrame` | 页脚槽位，footerHeight 为 0 时 nil |
| `rendererFrame` | 实际翻页／滚动容器区域，由移动策略决定 |

`onLayoutChange` 在主队列合并交付最新的稳定布局，支持在通知内创建展示页。尺寸、安全区、系统保留区域或 `updateMetrics` 改变布局时会再次通知；没有变化不重复交付。用 `layout(in: host.view)` 将全部矩形转换到指定宿主视图坐标，nil 目标表示窗口坐标。

`layout` 是排版依据，不会跟着动画移动。需要选区浮层、调试或命中定位时，调用 `currentPageFrames(in:)` 查询当前页的平面显示矩形；存在 Core Animation presentation layer 时会使用其位置。该方法返回当前页，不返回目标页或每个正文块的内部位置。curl／arch 曲面过渡期间无法用一个矩形描述当前内容，查询明确返回 nil，稳定排版几何仍可从 layout 读取；不提供卷曲后字符的逐点投影。连续模式的 bodyFrame 表示固定正文视口，块内位置继续通过 continuousReader 的锚点获取。

正文排版直接使用 `layout.bodyFrame.size`，不再减同一组页眉页脚高度或 padding。纯几何调用不必先创建 UIKit 容器：

```swift
let metrics = ReaderSurfaceMetrics(
    headerHeight: 38,
    footerHeight: 30,
    headerGap: 8,
    footerGap: 8,
    bodyInsets: .init(top: 6, left: 20, bottom: 6, right: 20)
)
let layout = try metrics.layout(
    in: outerBounds,
    readingFrame: availableReadingRect,
    motion: .contentOnly
)
let bodySize = layout.bodyFrame.size
```

所有高度、间距和 inset 要求有限非负，readingFrame 必须完整位于 bounds 中。小窗口依次钳制装饰与正文区域，不产生重叠或负尺寸；没有启用的装饰不会保留对应间距，小数尺寸不逐项取整。非零高度表示启用槽位，即使工厂没有提供视图仍会为该槽位留出空间；关闭槽位应将高度设为零。

## 三档移动策略

| `ReaderSurfaceMotion` | 正文 | 页眉／页脚 | 阅读主题背景 | rendererFrame |
| --- | --- | --- | --- | --- |
| `.contentOnly` | 随页移动 | 固定在外壳 | 固定全幅 | bodyFrame |
| `.contentAndChrome` | 随页移动 | 随页移动 | 固定全幅 | readingFrame |
| `.wholePage` | 随页移动 | 随页移动 | 每页背景一起移动 | backgroundFrame |

正文中的段落底色、CSS 背景、附件和图片仍属于正文。阅读主题壁纸由 `makeBackground` 提供，不能把正文背景也移到外壳。组件保证自己的中间容器透明；宿主提供的正文或块视图若绘制了不透明底色，会按宿主绘制结果遮住后方壁纸。

三档共享同一个稳定正文与装饰布局，只改变翻页容器及装饰所属层。固定背景始终覆盖外壳完整 bounds，随动背景每页各自拥有一个视图；任何模式都有 `backgroundColor` 作为全幅兜底，不会把正文留白当成白色默认底板。

`motion` 在外壳创建时确定。切换移动策略时，宿主保存源位置并准备新的外壳；不要在进行中的事务里搬动同一页眉视图。已有 `PageTurnViewController` 和原始分页／连续接口保持可用。

## 固定／随动装饰工厂

```swift
let decorations = ReaderSurfaceDecorations(
    makeHeader: { context in makeHeader(for: context.identity) },
    makeFooter: { context in makeFooter(info: context.readingInfo) },
    makeBackground: { _ in makeReadingWallpaper() },
    update: { views, context in
        updateHeader(views.header, identity: context.identity)
        updateFooter(views.footer, info: context.readingInfo)
    }
)
let surface = try ReaderSurfaceViewController(
    metrics: metrics,
    motion: .contentOnly,
    decorations: decorations,
    backgroundColor: readingBackgroundColor
)
```

`makeHeader/makeFooter/makeBackground` 必须返回未挂载且互不重复的视图；不能把同一个视图同时交给当前页和下一页，也不能返回正文自己的视图。只有正文的 UIViewController 参与标准 containment，稳定状态可正常选字和交互。

固定装饰每次安装展示方式时创建，之后使用 update 更新同一个实例，支持宿主自己的时钟／电量观察。随动装饰每页独立创建，工厂获得该页不可变身份与 readingInfo。切页成功或连续可见位置改变后更新当前装饰；翻页取消不提前显示目标页码。切换模式时仍转发旧事务的 didSettle 取消结果。

可通过 `headerView/footerView/backgroundView/currentBodyController` 读取当前真实视图，但布局由组件管理；业务内容可以修改，frame 不应由宿主竞争设置。工厂与状态更新闭包捕获宿主时使用弱引用。

## 分页接入

```swift
surface.onLayoutChange = { [weak surface] layout in
    // 按 layout.bodyFrame.size 排版；真实异步工作要保留源锚点与本次 layoutRevision。
}
surface.pageProvider = { identity, direction, layout in
    // 返回只包含正文的 PageContent；由外壳包装本页的随动装饰。
    makeAdjacentBody(identity, direction, layout.bodyFrame.size)
}
surface.onReadingStatus = { status in
    // 页码、章节等对外状态；不在此同步重入页面安装。
}
let paged = try surface.showPaged(
    page: initialBody,
    configuration: .init(presentation: .paged(effect: .slide, axis: .horizontal))
)
```

使用 `pagedReader` 调用翻页、自动阅读、暂停、点击或缩放交接。外壳拥有底层的 pageProvider、onTransition、onReadingStatus、onUnavailable 和 onPageReplacement 回调，宿主使用外壳同名回调，不覆盖这些内部连接。

原位替换使用 `surface.replaceCurrentPage` 或 `surface.submitCurrentPage`，传入纯正文和请求开始时的 `pagedReader.currentPageBinding`。外壳包装新装饰后继续使用既有唯一终态协议。改变 metrics 后即使外壳大小不变，只要正文尺寸变了也会使旧绑定失效，避免页眉变高后旧分页回填到更小正文区域。

`updateMetrics` 会取消在途翻页并输出新正文尺寸。宿主应按新尺寸重新准备内容，再替换当前页；固定源图片或能直接适应 bounds 的内容可在完成布局后显式调用底层 notifyContentAvailable。组件不声称自动执行字符级重排。

## 连续阅读

连续模式只接受 `.contentOnly`：

```swift
let continuous = try surface.showContinuous(
    window: bodyWindow,
    provider: bodyProvider,
    anchor: sourceMappedAnchor
)
```

provider 由宿主保留，块的 extent 只包含正文自身占用高度；不包括页眉、页脚或为了凑屏而添加的留白。SDK 连续容器放入 bodyFrame，固定页眉页脚和背景留在外壳。装饰显隐改变正文视口后仍使用既有连续锚点补偿，真正宽度重排则由宿主重新生产块与语义锚点。

## 安全区与当前范围

新外壳默认使用 `ReaderAdaptiveLayoutPolicy(prefersSpread: false)`，先避让安全区和实际保留区域，再计算装饰与正文。宿主已经限定好视口时可传 `viewportPolicy: nil` 使用整个 bounds，避免重复扣安全区；可以用 `updateViewportPolicy` 切换策略。沉浸阅读可按已有 Duo 接入规则选用 `.reservedRegions` 水平策略。背景始终位于完整 bounds，正文和装饰只占可读区域。

本轮外壳支持单页：none／横纵 slide 可用三档；cover、curl、arch 仅允许 wholePage，保持完整快照与覆盖遮挡语义。continuous 仅 contentOnly。不支持的组合、双页配置或产生 spread 的视口策略会明确报错，不静默变换效果。原有 SDK 的双页、纸张与连续能力保持不变；逐侧独立页眉页脚的双页外壳尚未纳入本轮。

## 示例与验收

`ReaderDemo` 启动参数 `--surface-reader` 打开组合示例。可追加 `--surface-chrome`、`--surface-whole`、`--continuous`、`--vertical`。界面提供三档移动、连续滚动、半翻预览、取消与装饰显隐，底部直接显示 body/header/footer/background 的位置与尺寸；纹理背景用于看清固定与随动。

本轮最终 SDK 全量 **370 项**、新外壳 ASan **37 项**、macOS 纯逻辑 **118 项**全部通过，零失败、零跳过。新外壳用例包括纯几何 18、UIKit 容器 14、复核缺陷回归 5。完整 SDK 和示例编译启用 `SWIFT_STRICT_CONCURRENCY=complete`、`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`；ReaderDemo Release 的 arm64／x86_64 Simulator 构建通过，保持 iOS 15／Swift 5 基线。

原生 UI 两项验证涵盖三档分页中间帧、固定装饰不动、随动装饰移动、取消后恢复、状态换页，以及连续滚动和关闭装饰后的矩形变化。五张实际截图已导出并查看；背景纹理和局部正文底色清楚地区分固定主题背景与随动内容。一次限定范围静态复核后，修复了延期回填沿用旧装饰位置、挂载回调抢回外部接管视图、初始状态重复通知，并明确纸张曲面期间实际位置查询返回 nil。每个修复均有动态回归。

ASan 结果确认加载检测库，没有内存访问错误报告；独立泄漏扫描仍未启用。证据位于本次 session scratch：`page-turn-surface-final.log/.xcresult`、`page-turn-surface-final-summary.json`、`page-turn-surface-asan-final.log/.xcresult`、`page-turn-surface-asan-summary.json`、`page-turn-surface-asan-diagnostics/`、`page-turn-surface-core.log`、`page-turn-surface-release.log`。示例初次通过记录为 `page-turn-surface-ui.log/.xcresult`，截图位于 `page-turn-surface-ui-attachments/manifest.json`；修复后的示例复测另记录为 `page-turn-surface-ui-final.log/.xcresult`。

原 App 未接入，也未改动现有业务页眉页脚。真实字符重排、CSS 全兼容、PDF 绘制、大图和持续运行性能仍需宿主验收；不可将本轮测试数作为这些未运行场景的通过证明。
