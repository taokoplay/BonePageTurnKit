# BonePageTurnKit

面向 iOS 15+ 的 UIKit 阅读展示 SDK。宿主提供页面或异高内容块，SDK 管理展示、翻页、连续滚动与当前布局锚点。

## 当前状态

已实现无动画、横纵平移、横向覆盖、横纵仿真／拱页及纵向连续阅读，另提供系统卷页容器 `SystemCurlReaderViewController`（能力边界见 [系统仿真](Docs/SystemCurl.md)），并提供真实双页／中央书脊、显式 LTR／RTL、漫画切片、通用缩放与分页边缘交接、当前页原位替换、分页／连续自动阅读和补屏管理。Swift tools 5.9，无第三方依赖；未接入 ParsingBook 宿主。

| 展示方式 | 水平 | 垂直 |
| --- | --- | --- |
| 无动画 `none` | 已实现 | 已实现 |
| 覆盖 `cover` | 已实现 | 明确拒绝 |
| 平移 `slide` | 已实现 | 已实现 |
| 仿真 `curl`／拱页 `arch` | 已实现单页／中央双页 | 已实现单页／中央双页 |
| 连续 `continuous` | 明确拒绝 | 已实现，可停在任意位置 |

`supportedPresentations`、`supportedSpines(for:layout:)` 与实际校验共用能力列表。单页纸张接受 automatic/minimum/maximum，双页纸张接受 automatic/center；automatic 按布局和显式阅读顺序解析。非纸张只接受 automatic；非法组合不会静默换效果。详见 [双页、漫画与缩放](Docs/SpreadComicAndZoom.md)。

## 目录与示例

- `Sources/BonePageTurnKit/`：中性身份、配置、几何、展示容器、双页／切片与缩放交接。
- `Tests/BonePageTurnKitTests/`：纯逻辑测试和 iOS UIKit 行为测试。
- `Examples/ReaderDemo.xcodeproj`：独立可运行的示例 App，本地引用此包。
- `Docs/`：抽离分析、设计依据、后续兼容验收要求。

用 Xcode 打开 `Examples/ReaderDemo.xcodeproj`，选择 `ReaderDemo` 运行，默认进入全屏阅读，也可显式使用 `--fullscreen-reader`。正文样本为 218 页长文（`LongArticle.txt`，《三國演義》前十回节选，宿主自动分页）。分页模式下轻点左右两侧直接上一页／下一页，轻点中央展开／隐藏顶部导航和底部菜单，菜单显隐不缩小阅读画布。右上设置提供九组共 64 项配置和搜索，底部翻页方式采用六种类型网格和横向／纵向独立选择，另有三种自动阅读路径及 SDK 调试操作；包含真实文字、宽图／长图、双页、RTL、缩放、主题、装饰与加载预算。设置采用草稿应用／取消，拒绝不支持的组合，并保存已应用配置。入口、映射和验证范围见 [全屏 Demo](Docs/FullScreenDemo.md)。

旧基础示例通过 `--legacy-reader` 打开，保留小说／漫画、完整内容／连载快照和模拟更新。小说按段落块计数，不冒充生产排版页；漫画按源页计数。`--comic --serial --last` 可直接查看漫画最新页，追加 `--continuous` 可检查连续书尾。

启动参数 `--paged-modes` 可查看五种分页效果，追加 `--auto-start` 启动分页自动阅读。`--paper-curl`／`--paper-arch` 直接展示纸张效果，`--right-spine` 选择右书脊，`--paper-preview` 停在半翻状态；界面可执行当前页异步回填和取消。详见 [纸张曲面与原位替换](Docs/PaperAndPageReplacement.md) 及 [平移与分页自动阅读](Docs/SlideAndPagedAutomaticReading.md)。

新增 `--expanded-reader` 打开双页和漫画扩展示例，可追加 `--spread --rtl --vertical --arch --slice-wide --slice-long --long-scroll --preview --auto-start` 等参数。界面包含单双页、两轴、LTR/RTL、切片策略、双击／捏合缩放和边缘交接。工程内 `ReaderDemoUITests` 使用真实触摸测试这些组合。

`--duo-reader` 打开 iPhone Duo 自适应示例，可追加 `--duo-source=5` 验证源页保位。菜单可隐藏系统控制栏，正文使用摄像头下方释放出的空间，右上角按钮恢复控制栏；显示与隐藏时均保持全屏纸张背景。它使用非对称安全区和 iOS 27.1 保留区域，宿主按可读空间在单双页间重建。接口、构建层级与姿态验证边界见 [iPhone Duo 适配](Docs/iPhoneDuo.md)。

新增启动参数 `--async-styles` 可打开与测试共用的复杂样式异步宿主，追加 `--continuous` 查看连续模式。包括富文本、链接、行内附件、独立图片，以及加载中翻页、字号／主题重排和图片失败重试。新增 11 项真实 UIKit 渲染测试后，该阶段全量 93 项回归通过；新增用例在 ASan 下 11 项通过，配套正式测试为 `AsyncStyledRenderingTests`。延迟模拟任务完成顺序，不能代替原 App CoreText、真实网络与大图解码验收。

仿真 `curl` 的原生拖动支持四角起翻和二维斜拖；手指主要沿翻页轴平移时按整页平翻呈现（不锁纸角），只有明显斜拉才翻起纸角。新增宿主触点输入接口，接入与边界见 [四角跟手仿真](Docs/CornerCurl.md)。 原生四角绘制已使用 Metal 批量提交、触点按刷新合并，统一纸背材质；iPhone 13 Pro 的 Release 测量方法、结果和适用范围见 [性能与材质](Docs/CornerCurlPerformance.md)。

拱页 `arch` 使用固定材料书脊与圆柱／圆锥可展曲面，按原材料弧长求解圆滑拱面，保持三维纸面的长宽与夹角。正翻弯曲当前页；回翻让上一页沿原书脊展开，当前页保留在下面，取消则收回上一页。斜推时平整区域整体转动，超出材料可达范围的触点连续限位。自由纸边带柔和投影，随抬升变化，落平时淡出。横纵方向沿用原生 Metal 跟手与完整收尾。物理推导、接入和验收范围见 [拱页方向跟随](Docs/ArchDirectionalTurn.md)。

高刷新率屏幕使用实际窗口的最高帧率申请，Demo 已显式启用 ProMotion。宿主配置、120Hz 测量与适用范围见 [高刷新率](Docs/HighRefresh.md)。

排查卡顿或动画中途消失时，可开启 [动画参数与实时帧率诊断](Docs/AnimationDiagnostics.md)：分别观察屏幕上限、申请 Hz、翻页回调 FPS、Metal 呈现 FPS，并复制有界的时长、队列、准备耗时及结束原因日志。

## 固定分页接入

所有 UIKit 类型与回调均在 `@MainActor`。宿主页面是普通 `UIViewController`，无需继承 SDK 基类。以下代码在主 actor 的宿主控制器内使用：

```swift
let page = PageContent(
    identity: PageItemIdentity(sourceID: "chapter-1", unitID: "page-0"),
    controller: firstPageController
)
let container = PageTurnViewController()
let paged = try container.showPaged(
    page: page,
    configuration: .init(presentation: .paged(effect: .cover, axis: .horizontal))
) { paged in
    paged.pageProvider = { identity, direction in
        // 宿主返回 .page / .waiting / .failed / .boundary(.endOfBook / .latestAvailable 等)。
        pageStore.neighbor(of: identity, direction: direction)
    }
    paged.onTransition = { event in
        // 只有 didCommit 表示成功；didSettle 包含成功与取消。
        // 用事件中的不可变 from/to/presentationID 处理进度。
    }
}
// 宿主按标准 UIKit containment 挂载 container。
try paged.turn(.next)
```

`beginInteractiveTurn/updateInteractiveTurn/endInteractiveTurn` 也可供宿主自定义驱动使用。快速重入返回 `interactionInProgress`。覆盖手势沿用旧实现的半屏归一化阈值：进度 0.17、方向速度 500 point/s，快速反向甩动优先取消。

默认 next 向轴最小端拖动，水平 RTL 改为向右；显式纸张书脊优先决定几何方向。provider 的 previous/next 始终表示内容逻辑顺序，不继承系统界面语言。普通内层 UIScrollView 默认避让；SDK 缩放容器自动登记边缘交接，宿主可通过 `registerScrollableContent` 登记自己的滚动内容。

## 正文、页眉页脚和背景

`ReaderSurfaceViewController` 是可选的阅读页面外壳，支持“只动正文”“正文和页眉页脚移动”“整页连背景移动”三档。连续模式固定为只滚正文。宿主仍提供真实正文控制器和业务装饰视图，背景可以使用图片并始终覆盖外壳全幅。

`layout` 和 `onLayoutChange` 输出同一坐标系中的 `bodyFrame/headerFrame/footerFrame/backgroundFrame/rendererFrame`，可直接取得 origin、size 或用 bodyFrame.size 排版；关闭的页眉页脚槽位为 nil。`layout(in:)` 转换为宿主坐标，`currentPageFrames(in:)` 查询平移／覆盖时的当前页平面位置；纸张曲面过渡期间返回 nil，不把隐藏原页矩形冒充实际曲面。改变装饰高度时统一重算正文，并使旧排版回填失效。

启动 `--surface-reader` 查看带纹理背景的组合示例和实时矩形数值；支持 `--surface-chrome`、`--surface-whole`、`--continuous`、`--vertical`。接口、坐标含义和本轮单页支持范围见 [页面外壳接入](Docs/ReaderSurface.md)。

## 动态视口与 iPhone Duo

`PageTurnViewController.adaptiveLayoutPolicy` 是可选策略，默认 nil 保持原有视口行为。启用后读取实际 bounds、四边安全区、尺寸类别及可用系统保留区域，返回 `contentFrame/pageLayout/spreadGap`；书本折痕两侧等宽留白，tabletop 正文在上方。`onAdaptiveLayoutChange` 合并快速变化，宿主按已保存源页／字符锚点准备新内容；`PageSpreadViewController.gutter` 接收书脊留白。保持 iOS 15 基线，iOS 27.1 原生区域由编译器与运行时双门禁保护，较旧环境退回安全区和尺寸类别。详情见 [Duo 接入与验收](Docs/iPhoneDuo.md)。

## 双页、切片与缩放

`PageSpreadViewController` 以两个真实 PageContent 组成一组，配置 `layout: .spread`，可留空侧承载封面或书尾；`ReaderSpreadLayout` 提供源页到双页组的索引转换。`visiblePageIdentities` 保留子页身份，宿主单独提供源页码。

`ComicPageSlicing` 提供整图、宽图切半和纵向分段，按整数像素完整覆盖原图并保留源身份；`ComicSliceView` 显示已解码、已转正的 UIImage 区域。`ReaderZoomViewController` 承载真实内容控制器，提供适宽／完整适配、双击／捏合、局部缩放与 resize 中心恢复。分页边缘交接只消费内层滚动后剩余的拖动距离，默认高倍缩放时不翻页，手势期间暂停自动阅读和回填。接入示例与约束见 [双页、漫画与缩放](Docs/SpreadComicAndZoom.md)。

## 纸张效果与原位回填

仿真和拱页共享现有分页事务。稳定状态保留真实、可交互的正文；动画临时捕获当前／目标展示单元，结束或取消即释放。`PaperRenderingOptions` 默认限制两张原图合计 4,194,304 像素、128 条带；条带、绘图缓冲及宿主内容仍有额外开销。内存告警取消纸张并暂停自动阅读。纸张按视口主轴长度的 17% 或 500 point/s 判定完成，反向快速拖动优先取消；快照失败明确报错。

当前页异步回填使用请求开始时的 `currentPageBinding`。稳定时可 `replaceCurrentPage(_:expectedBinding:)`；需要等待翻页／暂停结束时使用 `submitCurrentPage(_:expectedBinding:completion:)`。提交不等于安装，最新请求可覆盖旧请求，每项有唯一终态；成功切页后的旧绑定必须被拒绝。替换保持 renderer 不变，只发 `onPageReplacement`，不伪造翻页 commit。完整示例和约定见 [纸张曲面与原位替换](Docs/PaperAndPageReplacement.md)。

## 通用点击、自动阅读与退出

新增连续可见视图/绑定查询、点击与原生 pan 门禁、四类独立暂停目标，以及分页实时进度、保留意图的变速接口。`--automatic-reader` 示例覆盖外部手势、自动滚屏、定时左右翻阅。完整接入契约见 [连续交互与三种自动阅读](Docs/HostInteractionAndAutomaticReading.md)。Surface 也公开可取消退出协议，最终完成以 `onExitFinalized` 为准。覆盖效果可配置过渡圆角和阴影，见 [覆盖样式](Docs/CoverRendering.md)。

分页可配置 `tapConfiguration = try ReaderTapConfiguration()`，默认前／中／后三区。`shouldHandleTap` 让宿主先消费图片、链接或选区命中；`onCenterTap` 仅发出中心操作通知。内置 tap 等待 pan 失败。过渡中的连续轻点与原生滑动按序排队（上限 32 笔），上一笔完整落定后继续，手指仍按住拖动时仍拒绝第二个事务。仿真／拱页的整页播放采用系统缓入缓出曲线，普通约 360ms、最快连翻约 288ms；手速倍率不低于 0.8，队列深度不再额外压缩时长，避免卷曲中段被跳过。拖动松手保留原有收尾曲线。平移／覆盖保留原来的手速倍率；宿主可开启 `handsOverActiveTransitionOnNewIntent` 立即接管。低层 `beginInteractiveTurn` 仍允许宿主显式接管 curl 收尾，原生手势与 `turn` 不主动截断纸张动画。暂停、挂载和同步回调期间继续拒绝重入。

连续模式提供 `startAutomaticReading(pointsPerSecond:)`、`pauseAutomaticReading()`、`resumeAutomaticReading()`、`stopAutomaticReading(commitPosition:)`。真实 CADisplayLink 推进不会改变窗口令牌；占位、加载、失败、最新内容与未知边界先等待，只有明确 endOfBook 才结束。临时拖动／减速／离屏／后台／外部暂停后恢复原播放意图，用户主动暂停不会被异步结果自动唤醒。显式 restore 停止自动阅读。

分页模式提供 `startAutomaticReading(interval:animated:)`、`pauseAutomaticReading()`、`resumeAutomaticReading()`、`stopAutomaticReading()`。本页停留时间不包含翻页动画；等待时停止查询，宿主完成供给后使用独立 `contentRequestToken` 调用 `notifyContentAvailable(expectedToken:)`。新页、邻页请求和尺寸变化会使旧令牌失效，统计更新不会。手动翻页／取消后重新计时；当前页内部渲染完成与否由宿主暂停原因协调。

外壳 `PageTurnViewController` 的 `setSuspended(_:reason:)` 可跨 renderer 保留独立暂停原因；`beginExit/cancelExit/finishExit` 用令牌协调可取消退出。`finishExit` 在通知回调内调用时会延后提交有效位置和失效，宿主以 `onExitFinalized` 作为实际完成信号，再执行导航。

示例启动参数 `--interactions --auto-start` 可直接体验连续自动阅读、延迟补入、点击和退出协同。最终完整回归 124 项、相关 ASan 29 项、纯逻辑 36 项通过；详见 [通用交互与连续自动阅读](Docs/InteractionAndAutomaticReading.md)。这些机制不包含业务菜单、选区绘制、生产排版器或实际导航。

## 连续块衔接与按高度补屏

连续内容不能直接堆叠带页尾空白的固定页。`ContinuousItem.extent` 是接入方按统一布局计算的最终占用高度，包含一次跨块行／段间隔；SDK 不叠加块间距，也不逐块取整。续段缩进、字体／附件测量和文字范围由内容侧保证，版本改变后重新解析语义锚点。已有 8 项真实 CoreText 接缝测试，对比未拆分章节的行坐标与渲染结果。

新增 `readableCoverage` 与 `onContentDemand`：按实际 ready 高度检查可见区及前后余量，区分 `.edge` 与 `.item(identity)`。四个 75 point 数据块在 300 point 视口中只够一屏，仍会请求下一批；一个很高的 loading 占位不会被当作可读正文。

`ContinuousFillPolicy` 默认前后各 1 屏、每方向周期最多 16 次需求／连续 2 次无可读进展／256 个新增块。超限通过 `onFillLimitReached` 明确暂停，允许 `resumeContentFilling()` 显式开始新周期；预算不等于宿主图片解码或缓存的内存上限。原 `onEdgeApproach` 保留物理边缘语义，结构化需求启用后优先使用新回调。详情及接缝约定见 [连续内容块与补屏](Docs/ContinuousContentContract.md)。

示例启动 `--filling`，可切换“四块一屏／占位补齐／无进展”，观察覆盖高度、块数与请求次数。

## 连续滚动接入

1. 宿主实现 `ContinuousContentProvider`，提供 `makeContentView/bind/unbind`，并在外部保留 provider。容器弱引用工厂，宿主兼任工厂时不会形成持有环。
2. 构造 `ContinuousWindow`：稳定身份、章节、正有限高度、复用类别和内容状态。可以是文本块、图片页或占位内容，不要求等高。
3. 通过 `showContinuous(window:provider:anchor:prepare:)` 安装。所有数据、几何与锚点校验失败时保持原 renderer。
4. 异步窗口结果携带请求开始时的 `updateToken`；同一版本只能成功安装一次。视口尺寸变化、显式定位和窗口安装均推进修订号。拒绝旧窗口、源身份变化、内容／布局版本倒退，以及同版本 ready 被 loading/failed 覆盖。

```swift
let token = continuous.updateToken
// 宿主在后台读取、排版；结果回到主 actor 后：
try continuous.apply(updatedWindow, expectedToken: token)
```

省略 `anchor` 表示保持当前布局锚点。前插、锚点上方高度变化、裁剪上方远端内容都会补偿偏移；如果锚点被删除或其内容／布局版本改变，调用会失败，宿主必须提供重新解析的新锚点。受窗口首尾可滚动范围限制时会钳制偏移。

首次布局前可提供带非零 `viewportOffset` 的锚点。真实视口确定后如果该屏幕位置无法容纳，触发 `onAnchorRestorationFailure`，解析完成前不发布可见／稳定位置；宿主通过显式 `restore` 或 `apply(anchor:)` 提供新目标，旧初始目标随之失效。

`PageItemIdentity` 区分源 ID、展示单元 ID、内容版本和布局版本；窗口内展示 ID 唯一。字体／宽度重排应推进布局版本，正文改变应推进内容版本。`ContinuousAnchor` 是当前布局像素位置，不是长期保存的语义位置。

容器只挂载可见区域与前后各半屏内容，复用池最多保留 8 个视图；并不加载整本书到视图树。每次 `bind` 产生新 `PageViewBinding`，异步图片／排版结果在主线程安装前调用 `isCurrent(binding)`。`unbind` 时先使绑定失效，再通知宿主取消任务。

## 当前页码、总数与末页

`ReaderPagination` 分别提供 `book` 全书计数和 `section` 本章计数。每项 `ReaderPageMetrics` 的 `current` 从 1 开始，未知用 nil；`total` 为 unknown／estimated／exact，`unit` 区分 layoutPage／sourcePage／contentBlock。窗口块数、当前已加载页数都不能自动当作全书总页数。

分页通过 `PageContent.readingInfo` 提供统计与前后边界；只有成功提交才更新当前号码，取消保留原页。统计异步补齐或连载追加时，用 `updateReadingInfo(_:expectedToken:)` 携带先前的 `metadataToken`；新页、尺寸变化或另一次统计更新会使旧令牌失效。尺寸变化后旧排版统计不再使用，宿主准备新布局后重新提供。

成功翻页先交付完整 commit／settle，再发布新页状态。邻页从等待／失败恢复可用后，即使取消翻页，也保留已确认的 available 边界，页码仍停在原页。

连续内容通过 `ContinuousItem.pagination` 提供与身份／布局版本匹配的计数。`readingStatus` 和 `onReadingStatus` 取视口顶部块作为当前位置，独立计算是否已滚到真实窗口末端。占位内容不冒充可读页码，回弹不宣布到达书尾。

连续视口尺寸改变后，旧 layoutPage 统计暂时隐藏，直到宿主按新令牌安装对应窗口；源页和内容块计数不受排版变化影响。连续块跨越多个排版页时，宿主需根据字符／图内位置解析对应页码；SDK 不从块内像素距离猜算页数。

| 状态 | 含义 |
| --- | --- |
| `ReaderPageMetrics.isFirst/isLast` | 当前统计范围的第一／最后一项；只有确定总数才判断末项 |
| `.endOfSection(id)` | 到达指定章节末尾，后面可能仍有章节 |
| `.end` | 所供内容窗口结束，保留旧接口语义，不代表书籍完结 |
| `.endOfBook` | 宿主已确认全书结束 |
| `.latestAvailable` | 到达当前连载快照最新内容，可以继续更新 |
| `.unknown/.available/.loading/.failed` | 尚不确定、可供给、等待或失败，均不能当作读完 |

`hasReachedBookEnd` 与 `hasReachedLatestAvailable` 不互相代替；页码 N/N 也不等于用户已读完。连续视口可能顶部仍在倒数第二页、底部已到书尾，SDK 会如实保留两种状态。最新内容追加后，宿主提供新的总数与 available 边界，当前位置不自动跳到新末尾。

## 连续加载与延期安装

```swift
let token = continuous.updateToken
let ticket = try continuous.beginLoading(.next, token: token,
    cancel: { loadingTask.cancel() },
    completion: { outcome in
        // installed 表示 renderer 已安装；其余终态释放／重新调度宿主任务。
    })
// 宿主读取和排版完成，回到主 actor：
try continuous.submit(updatedWindow, for: ticket)
```

先登记任务，再执行工作；示例中的 `loadingTask` 代表宿主可取消任务句柄。同方向同窗口版本去重；双方向可以各有一个任务。只保留最近一个已就绪的完整窗口，覆盖旧结果会明确 superseded。一个窗口安装后，仍基于旧窗口版本的另一方向任务也会结束为 superseded，宿主应以新窗口重新合并，避免相互覆盖。

submit 不等于 installed：拖动／减速结束、全部暂停原因解除后，容器才捕获当时的可见锚点并安装。同步边界回调提交的结果在下一主队列事务处理，不在回调内部替换视图。显式导航、尺寸变化、直接窗口更新和退出会终止不再适用的任务；旧票据和重复结果被拒绝。

宿主主动取消用 `cancelLoading`，读取失败用 `rejectLoading`，具体错误文案／占位视图仍由宿主提供。在原子窗口提交点会锁定票据，provider 的 bind／unbind 中普通取消不能改写其安装终态；renderer 失效仍会终止它。终态回调在主 actor 同步执行，清理期间不接受新任务、apply 或 restore；需要重试或定位时安排到下一主队列事务。捕获宿主或容器请使用弱引用，并在宿主退出时调用 invalidate。

## 事件、交互与模式切换

- `onVisibleAnchor` 用于实时展示；`onStableAnchor` 用于宿主转换和保存语义位置。加载占位、回弹、拖动／减速不发布稳定位置，连续帧不应直接写数据库。
- 推荐 `onContentDemand` 获取边缘／内部占位目标和缺失可读高度；同一占位活动任务跨方向去重。兼容的 `onEdgeApproach` 只通知 available 物理边缘。自动需求受可配置预算约束，窗口末项不自动等于全书结尾。
- 立即安装 `apply` 在拖动、减速、暂停或同步事件回调中返回 `interactionInProgress`；异步加载改用 `beginLoading → submit`，容器在空闲后自动安装最新完整窗口。任务的 installed／superseded／cancelled／invalidated／rejected 终态只回调一次，详见下面的加载示例。
- `setSuspended(_:reason:)` 以独立原因集合协调菜单、选区与退出；解除一个原因不会覆盖其他暂停，只恢复原先仍有播放意图的会话，不会解除用户主动暂停。
- `invalidate()` 用于退出或模式切换，终止旧动画与旧绑定。`PageTurnViewController` 切换时自动失效旧 renderer。宿主不要强引用自己到事件闭包中。
- 跨模式先捕获语义位置，再按新布局准备页面／窗口与锚点，最后调用 `showPaged/showContinuous`。SDK 不解释正文字符、PDF 坐标或章节数据库，也不替宿主保存进度。

## 快速操作与内存防护

无动画模式支持连续即时翻页；覆盖／平移／纸张动画或交互未结束时，重复请求明确返回 interactionInProgress，不无限排队。页面挂载、供给和事件回调期间禁止嵌套翻页，交互结束命令不能绕过挂载阶段。模式切换先加载验证候选，再停止旧容器；宿主退出也会终止准备中的候选。

连续容器在内存告警时释放离屏复用池，保留挂载视图和阅读锚点。库内不使用 try!、强制类型转换、unowned 或 Unsafe 指针；宿主仍需遵守 provider 生命周期、弱捕获和视图所有权约定，并单独管理图片解码、文件任务及缓存预算。

专项测试包含横纵各 1,000 次无动画翻页、300 次成功／取消交替、200 次忙碌重入、10,000 块／500 次定位、200 次模式切换和任务资源释放。该阶段普通与 Address Sanitizer 模拟器测试各 82 项通过，SDK 严格并发及 Swift 警告视为错误构建通过。ASan 未报告内存访问错误，但没有启用独立泄漏扫描；不能把这些结果等价为全应用零崩溃或无泄漏。配套正式测试包括 `RobustnessRegressionTests` 与 `RobustnessStressTests`。

## 验证

SDK 功能补齐阶段已通过 Simulator 417 项、相关 ASan 47 项、纯逻辑 120 项，以及三种自动阅读示例的 3 项原生 UI 测试。全屏 Demo 另以原生 UI 测试验证画布显隐、翻页组合、设置、双页、图片、自动阅读和连续回填，详见 [全屏 Demo 验收](Docs/FullScreenDemo.md)。本轮 Demo 保持 SDK 本体不变；各阶段证据分别保存在对应文档中。构建继续启用严格并发与 Swift 警告视为错误检查。

纯逻辑测试（macOS 不编译 UIKit 后端）：

```bash
swift test
```

iOS 容器测试，在包目录运行并替换为本机可用模拟器：

```bash
xcodebuild -scheme BonePageTurnKit \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test CODE_SIGNING_ALLOWED=NO
```

示例构建：

```bash
xcodebuild -project Examples/ReaderDemo.xcodeproj -scheme ReaderDemo \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

最新验证记录见 [页面外壳接入](Docs/ReaderSurface.md)。其他接口与阶段记录包括 [iPhone Duo 适配](Docs/iPhoneDuo.md)、[双页、漫画与缩放](Docs/SpreadComicAndZoom.md)、[纸张与回填](Docs/PaperAndPageReplacement.md)、[页码与加载](Docs/ReadingStatusAndLoading.md)、[内容接缝／补屏](Docs/ContinuousContentContract.md) 和 [平移与分页自动阅读](Docs/SlideAndPagedAutomaticReading.md)。模拟器测试不等于真机帧率、大图峰值、长期运行或完整折叠姿态验收。

ParsingBook 阅读展示层仍需真实宿主适配与兼容验收。SDK 已补目标单页效果、自动阅读、当前页回填和通用退出协同，但尚未接入当前 App；历史宿主替换评估作为本地资料保留。

## 后续边界

本轮已补双页、中央书脊、纵向纸张、漫画 RTL／切片与分页缩放交接。未开放组合仍有纵向覆盖和水平连续滚动。生产字符／PDF 语义位置、选区业务、连续容器的复杂嵌套缩放、真机帧率、长篇大图压力及独立泄漏验收仍需宿主专项验证。解析、排版、解码缓存和持久化继续由内容侧或宿主负责。

设计约定：[连续滚动兼容](Docs/ContinuousScrollCompatibility.md) · [配置模型](Docs/ConfigurationModel.md)。前期抽离分析、开源架构研究及独立阶段验收报告作为本地资料保留，不随源码提交。
