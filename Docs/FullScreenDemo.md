# 全屏阅读 Demo

打开 `Examples/ReaderDemo.xcodeproj` 的 `ReaderDemo`，默认进入全屏阅读；显式启动参数为 `--fullscreen-reader`。目标保持 iOS 15、Swift tools 5.9、Swift 5，界面使用 UIKit，不增加第三方依赖。

## 操作入口

- 轻点正文左右两侧直接上一页／下一页（默认开启，比例为前／后三分之一）；轻点中央显示顶部导航和底部菜单，再次轻点中央或点击左上收起按钮隐藏。菜单覆盖阅读视图，显示和隐藏均不缩小正文画布。
- 右上设置按钮打开原生设置面板，九组共 64 项，可按中文名称或字段名搜索。修改先写入草稿；“应用”成功后保存，“取消”丢弃草稿。不支持的组合显示原因并保留旧阅读器。
- 底部提供上下页、阅读位置滑块、自动阅读、翻页方式和调试操作。关闭阅读点击或设置空中央点击区时，会保留右上菜单恢复按钮。
- 文字、宽幅漫画、长图均为真实内容视图；文字可选中，分页正文固定在页内，横纵拖动直接交给翻页器；连续阅读仅由外层容器滚动。漫画支持整数像素分片、原生捏合和双击缩放。文字样本来自 `Examples/ReaderDemo/LongArticle.txt`（Project Gutenberg #23950《三國演義》前十回节选，约 4.7 万字），由宿主按章节与句读自动分页为 218 页，便于长时间翻页与性能观察；资源缺失时回退到内置原创短篇。
- 设置和源页号保存在 Demo 自身。切换模式时保留源页，图片切片用源图归一化位置对应，连续窗口重建保留块内相对位置。此样本不代替生产宿主的 UTF-16、PDF 页内等语义锚点解析。
- 菜单或设置展开时临时暂停自动阅读，用户主动暂停保持独立。重启后自动模式保持暂停，避免打开 Demo 即自动翻动。

`--reset-demo-settings` 仅供测试从默认配置启动；普通图标启动保留已保存设置。旧示例保留其显式启动参数，旧基础界面可用 `--legacy-reader`。

## 翻页与调试覆盖

| 入口 | 可选择内容 |
| --- | --- |
| 翻页方式 | 类型七宫格：无动画、平移、覆盖、仿真、系统仿真、拱页、连续滚动；系统仿真直接打开 `UIPageViewController(.pageCurl)` 基准视图，不经过 SDK 事务；独立方向分段：横向／纵向。覆盖仅横向，连续仅纵向，不支持方向禁用并显示说明。同一面板含“手感”开关（翻页动画、点击两侧翻页、拖动翻页），随“应用”一起提交 |
| 完整设置 | 翻页面板内“全部阅读设置…”直接进入同一套 64 项设置：三种外壳运动范围，单页／双页／自适应，LTR／RTL，自动／两端／中央书脊，封面留白及间距；右上按钮仍是同一入口 |
| 自动阅读 | 定时翻页、连续自动滚屏、外部翻页命令；间隔、速度、动画和独立暂停可设置 |
| 内容与外观 | 文字字号、宽图／长图、切片、缩放和边缘交接、浅色／深色、背景纹理、页眉页脚和正文边距 |
| 调试菜单 | 半翻预览、完成／取消翻页、原位内容回填、等待／占位、失败重试、取消加载、独立安装暂停、图片缩放、身份及几何查询、可取消退出与重开 |

翻页面板以当前类型及方向初始化，选中态高亮；选择仅修改草稿，点击“应用”才更新阅读器，“取消”或下滑关闭保留原配置。无动画、平移保留兼容的正文运动范围；覆盖、仿真及拱页采用整页运动，连续采用单页正文滚动并关闭缩放。兼容的单双页布局继续保留，其他参数仍可在完整设置中调整。应用翻页方式后切换为手动阅读。

外部手势通过上下页按钮或公开交互入口模拟；Demo 没有摄像头识别。连续回填由会话按完整身份路由内容工厂，待安装版本和旧版本绑定分别保留到对应任务或绑定结束。任务完成后清理票据，实际安装完成才更新当前工厂。

## 模型与宿主契约

`FullScreenDemoSettings: Codable, Equatable` 保存 64 个输入字段。默认配置为横向平移、从左到右、单页、自动书脊、整页运动及文字内容。字符串保存稳定选项值，设置列表显示中文名称；所有数字、所有枚举值都需要验证，包括当前模式未使用的参数。

宿主在创建 SDK 对象前调用 `validationMessage()`，返回非空字符串时保留当前阅读配置。验证成功后可使用以下入口：

| 模型入口 | SDK 类型或行为 |
| --- | --- |
| `sdkEffect` | `PageTurnEffect`；`continuous` 对应 `.none` 占位，连续分支必须使用连续容器，不能据此建立分页容器 |
| `sdkAxis` | `PageTurnAxis` |
| `sdkOrder` | `ReaderReadingOrder` |
| `sdkSpine` | `PageSpinePlacement` |
| `sdkMotion` | `ReaderSurfaceMotion` |
| `sdkSliceMode` | `ComicSliceMode` |
| `sdkZoomFit` | 主执行器上的 `ReaderZoomFit` |
| `pageConfiguration(layout:) throws` | 使用实际 `.single` 或 `.spread` 组装 `PageTurnConfiguration` 并调用 `validate()`；连续输入生成 `.continuous(axis:)` |
| `surfaceMetrics` | `ReaderSurfaceMetrics`；关闭的页眉、页脚不占高度及对应间距 |
| `adaptivePolicy` | `ReaderAdaptiveLayoutPolicy`；真实传入 `prefersSpread`，不以固定偏好替代 |
| `fillPolicy() throws` | `ContinuousFillPolicy`；通过 SDK 的可抛错初始化器验证 |
| `validationMessage()` | 返回首个中文原因；检查所有值、组合、SDK 翻页配置、外壳度量、点击分区及补屏策略；自适应同时验证单页和双页形态 |

枚举映射属性以通过验证为前提，未知字符串会触发编程前置条件，不回退成其他合法选项。`validationMessage()` 对未知值返回可显示的错误，设置面板始终先验证再调用宿主。自适应策略没有独立公开的 `validate()`，模型通过小型视口值调用 `layout(for:)` 检查策略；真实设备布局仍由宿主提供的当前视口决定。

设置层只拥有数值及校验，不实现阅读计时器、动画渲染器、图片解码或网络请求。定时翻页和自动滚动由 SDK 执行；外部进度由宿主操作公开交互入口。

## 逐字段映射

下表记录实际输入映射和适用条件。每个字段在设置表中都有独立入口；运行验收范围另见文末。

### 翻页布局

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `effect` | `slide` | `PageTurnConfiguration.presentation`；`none/slide/cover/curl/arch` 使用 `.paged`，`continuous` 使用连续容器 |
| `axis` | `horizontal` | `PageTurnAxis`，传入展示配置和双页容器；支持 `horizontal/vertical` |
| `readingOrder` | `ltr` | `PageTurnConfiguration.readingOrder`、`PageSpreadViewController.readingOrder`、`ComicPageSlicing` 的 `readingOrder`；`rtl` 不镜像源图片 |
| `pageLayout` | `single` | `ReaderPageLayout.single/spread`；`adaptive` 由 `ReaderAdaptiveLayoutPolicy.layout(for:)` 解析实际单双页 |
| `spine` | `automatic` | `PageTurnConfiguration.spine`；值为 `automatic/minimum/center/maximum`，由 SDK 检查效果及单双页支持情况 |
| `motion` | `wholePage` | `ReaderSurfaceViewController` 的 `motion`；支持 `contentOnly/contentAndChrome/wholePage` |
| `safeArea` | `true` | 宿主处理 `ReaderViewportEnvironment` 的系统安全距离；关闭时不应用保留区域水平安全区策略 |
| `reservedRegions` | `false` | `ReaderAdaptiveLayoutPolicy.horizontalSafeArea` 的 `.reservedRegions` 意图；需工具链及系统支持，旧系统由宿主使用 `.system` |
| `prefersSpread` | `true` | 原样传入 `ReaderAdaptiveLayoutPolicy(prefersSpread:)` |
| `minimumPageWidth` | `280` | `ReaderAdaptiveLayoutPolicy.minimumPageWidth`，单位为点 |
| `minimumPageHeight` | `240` | `ReaderAdaptiveLayoutPolicy.minimumPageHeight`，单位为点 |
| `spreadGap` | `16` | `ReaderAdaptiveLayoutPolicy.spreadGap`；宿主将实际间距传入 `PageSpreadViewController(gutter:)` |
| `firstPageIsCover` | `false` | `ReaderSpreadLayout(pageCount:firstPageIsCover:)`；封面所在双页的另一侧是真实空白 |

当前 `ReaderSurfaceViewController.showPaged` 只接受单页。双页及自适应双页应通过公开的 `PageSpreadViewController` 组合两侧独立阅读外壳，并在外层应用翻页配置，不能将双页直接塞入单页 Surface。该 Demo 对双页和自适应统一要求 `wholePage`。自适应布局算法输出水平几何轴；宿主必须明确区分视口解析结果和用户选择的翻页轴，不暗中修改保存的输入。

### 外壳度量

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `headerEnabled` | `true` | 宿主选择 `ReaderSurfaceDecorations.makeHeader`；关闭时模型将有效页眉高度和间距设为零 |
| `footerEnabled` | `true` | 宿主选择 `ReaderSurfaceDecorations.makeFooter`；关闭时模型将有效页脚高度和间距设为零 |
| `headerHeight` | `24` | `ReaderSurfaceMetrics.headerHeight` |
| `footerHeight` | `24` | `ReaderSurfaceMetrics.footerHeight` |
| `headerGap` | `10` | `ReaderSurfaceMetrics.headerGap` |
| `footerGap` | `10` | `ReaderSurfaceMetrics.footerGap` |
| `insetTop` | `16` | `ReaderSurfaceMetrics.bodyInsets.top` |
| `insetLeft` | `24` | `ReaderSurfaceMetrics.bodyInsets.left` |
| `insetBottom` | `16` | `ReaderSurfaceMetrics.bodyInsets.bottom` |
| `insetRight` | `24` | `ReaderSurfaceMetrics.bodyInsets.right` |

关闭装饰保留用户输入，仅有效布局不占槽位。实际视口大小不足时仍由 SDK 的布局逻辑处理；输入限额不保证任意小视口均能保留可读正文。

### 自动阅读

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `automaticMode` | `manual` | `manual` 为手动；`timed` 使用分页 `startAutomaticReading(interval:animated:)`；`scroll` 使用连续 `startAutomaticReading(pointsPerSecond:)`；`external` 使用分页 `beginInteractiveTurn`、`updateInteractiveTurn(displacement:)`、`endInteractiveTurn` 或取消入口，由宿主提供进度 |
| `pageInterval` | `5` | 分页 `startAutomaticReading(interval:animated:)` 或 `updateAutomaticReadingInterval(_:)`，单位为秒，不包含动画时间 |
| `scrollSpeed` | `40` | 连续 `startAutomaticReading(pointsPerSecond:)` 或 `updateAutomaticReadingSpeed(pointsPerSecond:)` |
| `animated` | `true` | 分页 `turn(_:animated:)`、自动翻页及宿主结束交互时的动画参数；不把 `none` 效果改成其他动画 |

### 覆盖样式

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `coverCorner` | `36` | `CoverRenderingOptions.cornerRadius` |
| `shadowOpacity` | `0.32` | `CoverRenderingOptions.shadowOpacity`，范围 `0...1` |
| `shadowRadius` | `24` | `CoverRenderingOptions.shadowRadius` |
| `shadowX` | `12` | `CoverRenderingOptions.shadowOffsetX`；SDK 在 RTL 下镜像水平偏移 |
| `shadowY` | `0` | `CoverRenderingOptions.shadowOffsetY`，不随阅读顺序改变 |

装饰只在覆盖翻页事务内生效，不创建纸张快照；即使当前未选择覆盖效果，也验证全部装饰输入。

### 纸张快照

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `paperPixels` | `4194304` | `PaperRenderingOptions.maximumSnapshotPixels`，当前页与目标页两张原始快照的合计像素上限。4 MP 保证翻页时文字清晰；2 MP 可把松手尖峰从 293 ms 降到 84 ms，但 13 Pro 上整页快照会被放大约 0.58 倍、文字发粗 |
| `paperStrips` | `128` | `PaperRenderingOptions.stripCount`，纸张几何预切条带数 |

### 漫画缩放

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `sliceMode` | `whole` | `ComicPageSlicing.slices` 的 `mode`，支持 `whole/splitWide/vertical` |
| `sliceRatio` | `1.5` | `ComicPageSlicing.slices` 的 `maximumHeightToWidth`，控制纵向切片比例 |
| `zoomEnabled` | `false` | 宿主在分页图片外建立 `ReaderZoomViewController`；不能用于本 Demo 的文字或连续阅读 |
| `zoomFit` | `aspectFit` | `ReaderZoomViewController` 的 `fit`，支持 `.aspectFit/.width` |
| `maximumZoom` | `4` | `ReaderZoomViewController(maximumZoomFactor:)`，相对适配倍率 |
| `initialZoom` | `1` | `ReaderZoomViewController.setZoomFactor(_:centeredAt:animated:)`，不得大于最大倍率 |
| `handoffThreshold` | `18` | `ReaderScrollHandoffPolicy.threshold`；宿主使用 `PagedReaderViewController.registerScrollableContent(_:policy:)` 登记实际缩放滚动视图 |
| `allowPagingWhileZoomed` | `false` | `ReaderScrollHandoffPolicy.allowsPagingWhileZoomed` |

SDK 负责切片规划和缩放几何，宿主负责受控尺寸的图片输入与解码。纵向分片仍受 SDK 最多 256 片限制，实际源图尺寸需在调用时验证。本 Demo 使用有界的程序绘制图片，不读取相机或相册，不包含图像识别。

### 点击暂停

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `tapTurns` | `true` | 宿主为分页设置 `tapConfiguration: ReaderTapConfiguration?`。默认开启：沿分页轴前／后三分之一轻点直接翻页，中央区仍交给菜单；关闭后所有轻点只负责菜单显隐 |
| `previousEnd` | `0.33` | `ReaderTapConfiguration.previousEnd`，上一页开区间终点 |
| `nextStart` | `0.67` | `ReaderTapConfiguration.nextStart`，下一页闭区间起点；两者之间是中央区 |
| `panEnabled` | `true` | 分页或连续容器的 `shouldBeginPan` 门禁 |
| `userScrollEnabled` | `true` | 连续容器 `setSuspended(_:targets:reason:)` 的 `.userScrolling` 目标，反向表达是否暂停 |
| `tapsEnabled` | `true` | 分页 `shouldHandleTap`；连续使用点击门禁或 `.taps` 暂停目标 |
| `pauseAutomatic` | `false` | SDK 的 `pauseAutomaticReading()`／`resumeAutomaticReading()`；连续亦可使用 `.automaticReading` 暂停目标，保留运行意图 |
| `deferInstallation` | `false` | 连续 `setSuspended(_:targets:reason:)` 的 `.contentInstallation`；加载准备完成与安装提交保持区分 |

打开设置面板的临时暂停必须使用独立原因，由宿主持有并在 `onClose` 时释放，不能覆盖上表的用户设置。取消或侧滑关闭不调用 `onApply`。

### 连续加载

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `leadingViewports` | `1` | `ContinuousFillPolicy.leadingViewports`，视口前可读余量 |
| `trailingViewports` | `1` | `ContinuousFillPolicy.trailingViewports`，视口后可读余量 |
| `maximumRequests` | `16` | `ContinuousFillPolicy.maximumRequests`，每方向每补屏周期自动请求上限 |
| `maximumNoProgress` | `2` | `ContinuousFillPolicy.maximumNoProgressResults`，连续无可读进展的结果上限 |
| `maximumAddedItems` | `256` | `ContinuousFillPolicy.maximumAddedItems`，每方向周期累计新增块上限 |
| `loadBatch` | `4` | 宿主示例数据源每次准备的块数；仍通过 SDK `beginLoading`／`submit` 管理请求和安装 |
| `loadDelay` | `0.8` | 宿主模拟数据准备延迟，单位为秒；不是阅读动画时钟 |
| `simulateFailure` | `false` | 宿主模拟失败结果或失败内容状态，并按公开加载入口处理票据；不伪造成功安装 |

### 内容显示

| 字段 | 默认值 | SDK 入口或宿主行为 |
| --- | --- | --- |
| `content` | `text` | 宿主示例内容工厂，支持 `text/wideImage/tallImage` |
| `fontSize` | `20` | 宿主文字排版字号，单位为点 |
| `wallpaper` | `true` | 宿主壁纸视图，通过 `ReaderSurfaceDecorations.makeBackground` 或每侧外壳组合安装 |
| `appearance` | `system` | 宿主 `overrideUserInterfaceStyle`：`.unspecified/.light/.dark`；值为 `system/light/dark` |
| `bookBoundary` | `endOfBook` | `ReaderPageInfo.after` 或 `ContinuousWindow.after` 的 `.endOfBook/.latestAvailable/.unknown`；只用于相应内容末端 |
| `paginationTotal` | `exact` | 宿主根据当前内容及布局填入 `ReaderPageTotal.exact/estimated/unknown`；页数本身来自实际内容快照 |

`PageItemIdentity`、`PageViewBinding`、当前页码、实际总数、版本、加载票据、锚点及活动暂停原因是运行状态，不进入设置模型，不将连续块数冒充排版页数。

## 明确拒绝的组合

| 条件 | 允许范围或错误处理 |
| --- | --- |
| 连续阅读 | 必须 `vertical + single + contentOnly`，且 `zoomEnabled == false` |
| 自动滚动 | 仅 `effect == continuous` |
| 定时翻页、外部进度 | 仅分页效果；连续允许 `manual/scroll` |
| 双页或自适应 | 当前示例仅允许 `wholePage`，通过公开双页容器组合每侧 Surface |
| 覆盖、卷曲、拱形 | 必须 `wholePage`；覆盖还要求横向 |
| 书脊 | 非纸张效果只能自动；纸张单页为自动、最小端或最大端；纸张双页为自动或中央；最终调用 SDK `validate()` |
| 自适应书脊 | 只允许自动，并分别验证 `.single` 与 `.spread`，避免旋转后产生不支持形态 |
| 图片缩放 | 仅分页图片；初始倍率不得超过最大倍率 |
| 点击分区 | `0 ≤ previousEnd ≤ nextStart ≤ 1`，允许空分区，不交换或钳制端点 |
| 非法值 | 未知字符串、非有限数字、范围外数字及非整数字符串均明确拒绝 |

表单允许在草稿中连续修改暂时不兼容的选项，最终应用时统一报告首个问题。错误不替换效果、不改轴、不更换运动范围，也不覆盖已应用配置。SDK 在真实布局、内容安装或尺寸验证时仍可能拒绝配置；宿主 `onApply` 返回原因并保持旧阅读器。

## 系统保留区域

原生区域读取由 SDK 同时使用 `#if compiler(>=6.4)` 和 `#available(iOS 27.1, *)` 保护。设置表在缺少任一能力时禁用 `reservedRegions` 开关并说明原因；模型允许保留该偏好，以便跨系统保存。

宿主必须在不支持读取区域的运行环境使用 `.system` 水平安全区策略，不以空区域列表冒充可用能力。`safeArea == false` 时，模型的 `adaptivePolicy` 已选择 `.system`，宿主还需提供关闭安全距离后的环境；`reservedRegions` 保存值不触发该策略。使用真实保留区域时，宿主应满足 SDK 关于系统栏和区域坐标的契约，不再次给区域叠加边距。

## Demo 输入限额与 SDK 范围

这些上限用于控制示例的输入规模和图片相关内存风险，不等于 SDK 的理论极限，也不能替代宿主图片解码预算。

| 输入 | Demo 范围 | SDK 范围或区别 |
| --- | --- | --- |
| 最小页宽、最小页高 | `1...2048` 点 | SDK 要求有限正数 |
| 双页间距、正文四边距 | `0...200` 点 | SDK 要求有限非负数 |
| 页眉页脚高度、间距 | `0...160` 点 | SDK 要求有限非负数 |
| 圆角、阴影半径 | `0...100` 点 | SDK 要求有限非负数 |
| 阴影水平、垂直偏移 | `-100...100` 点 | SDK 允许有限有符号数 |
| 阴影透明度、点击端点 | `0...1` | SDK 同范围；点击端点还要有序 |
| 字号 | `12...40` 点 | 宿主内容排版输入 |
| 纵向切片比例 | `0.1...10` | SDK 要求有限正数，并限制最多 256 片 |
| 最大与初始倍率 | `1...20` | SDK 最大倍率允许到 `1e6`；初始倍率不得超过最大倍率 |
| 边缘交接距离 | `1...200` 点 | 与 SDK 范围一致 |
| 纸张快照像素 | `65536...16777216` | 与 SDK 范围一致；仅约束纸张快照，不包含源图解码 |
| 条带数 | `32...256` | 与 SDK 范围一致 |
| 翻页间隔 | `0.1...3600` 秒 | 与 SDK 范围一致 |
| 自动滚动速度 | `0.1...2000` 点／秒 | SDK 为有限 `(0, 2000]`，Demo 提供实用的正下限 |
| 前后补屏余量 | `0...8` 屏 | 与 SDK 范围一致 |
| 请求上限、无进展次数 | `1...256` | SDK 要求正整数 |
| 新增块上限 | `1...4096` | SDK 要求正整数 |
| 单次加载量 | `1...30` 块 | 宿主示例数据源限额 |
| 模拟加载延迟 | `0...10` 秒 | 宿主示例行为 |

## 原生设置面板接入

使用 `FullScreenDemoSettingsController(settings:onApply:)` 创建面板并放入 `UINavigationController`。面板使用 `insetGrouped` 表格，自己的导航标题为“阅读设置”，左侧“取消”、右侧“应用”。宿主回调返回 `nil` 才关闭；返回字符串则以系统警告框显示原因并保留面板及草稿。“恢复默认设置”只修改草稿。

`onClose` 在按钮关闭、完整侧滑关闭或选项页关闭时最多调用一次；取消的交互式关闭不通知。控制器遵循 `UIAdaptivePresentationControllerDelegate`，宿主可以指定其作为导航容器的展示代理；面板也观察真实关闭转场。宿主负责释放自己拥有的设置暂停原因。

| 元素 | 辅助功能标识 |
| --- | --- |
| 设置表 | `reader-settings` |
| 应用、取消 | `settings-apply`、`settings-cancel` |
| 字段行及开关 | `setting-字段名` |
| 选项 | `choice-字段名-原始值` |
| 数值输入框 | `number-字段名`，保存按钮文字为“确定” |
| 恢复默认 | `setting-resetDefaults` |

设置行至少提供 44 点点击区域，长中文换行，字体和颜色跟随系统，内容可滚动。数值编辑使用原生文本框，完整解析输入并显示范围或格式错误；非法输入保留在输入框内，同时禁用“确定”，不存入草稿。


## 本轮验证

环境为 Xcode 27.1、Swift 5 语言模式、iPhone 16 Pro / iOS 18.6 Simulator。构建启用 `SWIFT_STRICT_CONCURRENCY=complete` 和 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`。以下为七条不同 UI 流程的最近一次有效结果，来自初轮检查及修复后的针对性复测，不代表对所有 64 项数值的笛卡尔组合穷举。

| 原生 UI 流程 | 结果与证据 |
| --- | --- |
| 全屏画布、正文轻点、导航与底部菜单同时显隐，画布尺寸不变 | 通过；`fullscreen-demo-ui-v1` |
| 旧版 12 个预设逐一切换并实际翻页，连续模式实际滑动 | 历史通过；`fullscreen-demo-ui-v2`，现已替换为类型与方向两个维度 |
| 非法组合保留草稿、双页 RTL、中央书脊、封面留白及切回单页 | 通过；`fullscreen-demo-ui-v1` |
| 宽图／长图分片、缩放、深色内容及重启保存 | 通过；`fullscreen-demo-ui-v2` |
| 搜索、精确数值编辑、取消草稿、30 点正文与深色外观 | 通过；`fullscreen-demo-ui-v4`，并实际检查深色设置面板及键盘截图 |
| 定时阅读、菜单暂停、用户暂停、退出取消与确认重开 | 通过；`fullscreen-demo-ui-v2` |
| 连续内容延后安装、新版本正文绑定、恢复滚动与菜单轻点 | 通过；`fullscreen-demo-ui-v3` |

另已核对 64 个存储字段与 64 个表单入口一一对应、全部具有文档映射，所有新增示例文件均加入 Xcode 工程，工程格式和 `git diff --check` 通过。截图实际检查涵盖全屏显隐、双页、宽图／长图、深色正文、设置和退出恢复。30 点是 Demo 自身字号设置，本轮不宣称完成全部系统辅助功能字号验收。

真机 Debug 包已通过通用 iOS 目标构建与 `codesign --verify --deep --strict` 验证，最低系统仍为 iOS 15，开发签名包含已授权的 iPhone。最终包来自 `fullscreen-demo-phone-build-v4`，安装前已核对六个示例源码哈希与签名记录一致。首次安装因设备连接不可用返回 CoreDevice 4016。设备重新连接后，最终包已成功安装到 iPhone 13 Pro（iOS 26.5），以 `--fullscreen-reader` 启动，并在设备进程列表中核对到相同进程标识及本次安装路径；保留 Demo 已保存的设置。安装、启动和进程证据分别为 `fullscreen-demo-phone-install-v2.json`、`fullscreen-demo-phone-launch-v2.json`、`fullscreen-demo-phone-processes-v2.json`。

本轮未修改 SDK `Sources`、ParsingBook 工作区或 Git 暂存区。SDK 既有的 417 项回归不因本轮 Demo 界面改动重复执行。本次结果不代替生产 ParsingBook 接入、真机长时间性能或折叠屏全部物理姿态验收。


## 二维翻页与固定正文验证

翻页入口已改为六种类型网格与独立的横向／纵向方向选择。`mode-picker-ui-final` 两项原生 UI 测试通过，覆盖全部 10 组受支持的类型方向组合、实际翻页、方向禁用、取消与下滑关闭，以及浅色和深色界面；已查看两种外观截图。

分页文字视图关闭内部滚动，由外层分页器接收拖动；固定文字的轻点菜单由宿主与 TextKit 同时识别，SDK 避免重复分发。`fixed-page-text-ui-v1` 两项原生 UI 测试通过：30 点正文上下和左右滑动直接翻页，连续模式的外层滚动保持可用，正文轻点与导航菜单显隐正常且不改变全屏画布。测试环境为 iPhone 16 Pro / iOS 18.6 Simulator，重新编译启用严格并发及 Swift 警告视为错误。Demo 的固定样本不承担生产文本分页。

`fixed-page-text-phone-build-v1` 真机包构建与严格签名验证通过，保持最低 iOS 15。已安装到 iPhone 13 Pro 并以 `--fullscreen-reader` 启动，设备进程列表核对到相同可执行路径与进程标识。安装和启动证据为 `fixed-page-text-phone-install.json`、`fixed-page-text-phone-launch.json`、`fixed-page-text-phone-processes.json`；保留用户设置。本轮没有修改 SDK 本体、ParsingBook 或 Git 暂存区。
