# iPhone Duo 与动态视口适配

BonePageTurnKit 提供可选的自适应视口层，用同一套逻辑处理 iPhone Duo、普通 iPhone、iPad 及窗口宽度变化。它按实际 bounds、四边安全区、水平尺寸类别和系统保留区域布局，不判断设备型号，不使用设备宽高表，也不从物理方向推断内容形状。

## 构建与运行基线

本次开发环境为 Xcode 27.1 / iOS SDK 27.1，已用 Swift 编译探针核验 `UIView.reservedRegions(kind:options:)`、`.division`、`.occlusion`、`frame` 和 `isActive` 的实际签名。SDK 最低部署仍为 iOS 15，Swift tools 5.9／Swift 5 语言模式，无新增依赖。

- 宿主 App 用 iOS 27.1 SDK 构建时，可以进入 Duo 的全幅与系统侧边栏适配层级；库本身不能替代宿主的 SDK 选择和布局接入。
- iOS 27.1 上通过正式 UIKit 保留区域 API 获取折痕和摄像头区域，新符号同时受 `#if compiler(>=6.4)` 与 `#available(iOS 27.1, *)` 保护。
- 较旧系统／工具链走安全区和尺寸类别路径，不引用缺失的新系统符号。保留旧工具链源兼容门禁，但未用真实 Swift 5.9 编译器运行本轮测试。
- 示例使用 `UIWindow(windowScene:)`、`UINavigationController` 及容器提供的工具栏。按钮同时提供标题和 SF Symbol，让系统选择横栏、侧栏与溢出形式。

## 启用自适应

默认 `adaptiveLayoutPolicy == nil`，现有宿主自己指定视口的行为不变。需要折叠适配时：

```swift
container.adaptiveLayoutPolicy = ReaderAdaptiveLayoutPolicy(
    prefersSpread: true,
    minimumPageWidth: 280,
    minimumPageHeight: 240,
    spreadGap: 0
)
container.onAdaptiveLayoutChange = { [weak host] layout in
    // 使用宿主持有的已确认源位置，不把旧双页组索引或变化后的像素位置当作源位置。
    guard let host else { return }
    host.preparePresentation(at: host.currentSemanticLocation, layout: layout)
}
container.onAdaptiveLayoutError = { [weak host] error in
    // 无效策略或几何不会静默作为成功；修正后才恢复适配暂停。
    host?.showLayoutError(error)
}
```

示意中的 host 方法由接入方实现。最小页宽／高表示正文可读性要求，不是某个设备断点。`onAdaptiveLayoutChange` 在下一主队列事务交付最新布局，合并快速连续变化；回调可以安全调用 `showPaged`，不会在 UIKit 的约束更新内部重建正文。

`ReaderAdaptiveLayout` 提供：

| 字段 | 含义 |
| --- | --- |
| `contentFrame` | 容器坐标中的可读矩形，保留非零 bounds 原点 |
| `pageLayout` | 推荐 single 或 spread，内容生产仍由宿主决定 |
| `axis` | 推荐的页面排列／翻页轴，当前阅读策略为 horizontal |
| `spreadGap` | 双页中间需要避开的宽度，传入 PageSpreadViewController 的 gutter |
| `auxiliaryFrame` | tabletop 下方的可用辅助区域；宿主可在此放置与正文相关的控件 |

开启策略后，容器将当前分页／连续 reader 放入 `contentFrame`，背景仍可由外壳全幅绘制。单页／双页配置不会被 SDK 猜测性地替换；宿主应依照推荐布局准备合适的真实页面，并通过已有版本协议安装。

## 布局策略

1. 分别处理 top、left、bottom、right 安全距离，不将某一侧乘二。区域查询和布局计算始终使用同一个视图坐标系。
2. 完全展开或没有活动折痕时，regular 且空间足够才推荐横向双页；compact、未指定类别或空间不足时使用单页。
3. 书本姿态的纵长 division 将空间分为左右两块。两块都能承载最小页尺寸时，围绕真实折痕中心取得对称的正文视口，两侧页宽相同，中间 `spreadGap` 覆盖曲面和其系统安全边距。折痕不必位于安全区矩形的中线。
4. tabletop 的横长 division 使用上方单页正文，下方返回为辅助区域，正文不跨折痕。
5. 活动 occlusion 保守裁剪可读矩形；多个 division 中选主分割，其余继续按遮挡处理。inactive 区域保留在环境快照中，但不阻挡当前布局。
6. 原生 `frame` 已包含系统 margins，不额外叠加一遍。屏外或零面积区域忽略；无效数值、负安全距离和超过 64 个区域明确报错，零可用空间返回安全的空矩形。

`ReaderViewportEnvironment.capture(from:)` 可供其他宿主使用。`ReaderViewportView` 在 `updateConstraints` 查询系统保留区域以建立 UIKit 变化观察，同时响应 bounds、safe area、trait 和窗口变化；环境值相同不重复通知。没有铰链的设备自然使用无 division 路径。

## 双页与折痕

```swift
let spread = try PageSpreadViewController(
    first: firstSourcePage,
    second: secondSourcePage,
    axis: layout.axis,
    readingOrder: readingOrder,
    gutter: layout.spreadGap
)
```

`gutter` 默认 0，必须有限且非负；两页在留白两侧等宽排列，LTR／RTL 只改变逻辑先后侧。分页快照包含这段留白，中央书脊仍使用原先的真实正反页内容。过渡画面是临时曲面，落定后恢复避开折痕的真实可交互页面。

纸张快照倍率改为从当前视图的 `traitCollection.displayScale` 读取，避免两个显示区域或离屏内容错误依赖 `UIScreen.main`。

## 保位、取消和异步内容

- 环境变化导致可读布局变化时，立即添加独立适配暂停。它会取消在途纸张／翻页及滚动交接，即使外层 bounds 的尺寸未变而只是折痕或摄像头区域改变。
- 快速变化会合并到最新结果；最终又回到已发布布局时，也会正常结算临时暂停，不留下永远忙碌的 reader。
- 回调内修改策略后，按返回时的最新验证结果收尾。无效策略的暂停不会被旧回调解除；已修正策略的过期错误不会迟到覆盖新状态。
- 退出期间延期交付；取消退出后可继续通知，最终失效会丢弃旧队列并清理失败缓存。
- 单双页转换的源位置由宿主保留。单页第 5 页展开后可能位于一组的第二侧，合上仍应回到第 5 页，不能直接取该组第一侧。
- 正文宽度变化需要新的排版版本。异步重排时宿主添加自己的加载暂停原因，保存本次语义锚点和目标布局；结果回来后检查最新布局和源版本，再用 `showPaged` 或现有回填协议安装。SDK 的一次布局通知不会替宿主等待任意解析任务。
- 自动阅读的用户播放意图应与临时 `.paused` 状态分开保存；示例在重新创建 reader 后按宿主意图恢复。文字选择、持久化及真实章节解析仍属于接入方。

## 独立示例

运行 `ReaderDemo`，添加 `--duo-reader`，可用 `--duo-source=5` 从第 5 源页开始。该页面采用系统导航／工具栏，提供前后翻页、自动阅读、自动单双页／始终单页、RTL 和半翻预览／取消。源码为 `Examples/ReaderDemo/DuoReaderDemoViewController.swift`。

建议在 Device Hub 中分别观察外屏、展开、书本半折、tabletop，以及不同宽度的窗口。不要把普通窗口改宽、旋转或 fixture 注入称为实际折叠姿态。

## 验证记录

最终结果：**330 项完整 SDK Simulator 测试、53 项本轮 ASan、97 项 macOS 纯逻辑，以及 iPhone Duo / iOS 27.1 上的 3 项原生 UI 测试全部通过，零失败、零跳过**。SDK 全量和本轮测试启用 complete 严格并发与 Swift 警告视为错误检查；独立示例 Release 的 arm64／x86_64 Simulator 构建通过，部署基线仍为 iOS 15。

本轮新增 40 项：自适应布局几何 19、UIKit 环境观察 9、视口／书脊／倍率与宿主保位 8、通知重入和失败恢复回归 4。原生 UI 测试验证源页保持、系统控制可达、菜单切换编排、预览取消后继续翻页。检查中修复了快速 A→B→A 布局变化残留暂停、回调内无效策略被解除暂停、会话失效后失败缓存复用及过期错误通知。

实际设备观测：本次 Duo 模拟器处于外屏状态，物理旋转请求前后 `duo-reader` 仍为 `(0, 0, 466, 678)`。原测试将每次旋转都当作布局变化，因而失败；读取 AX 与前后 frame 后，改为按实际几何验收：形状改变才要求自动取消，形状不变则保持源锚点并验证手动取消后可继续。真实布局变化取消仍有独立 UIKit 动态用例覆盖。这不构成开合或半折姿态实测。

| 场景 | 证据与状态 |
| --- | --- |
| Duo 外屏运行、旋转请求、系统栏／菜单及源页保持 | 原生 iOS 27.1 UI 测试通过，已导出截图和 AX 记录 |
| 非对称安全区、偏心书本折痕、tabletop、camera、多分割、窄窗口 | 确定性几何及 UIKit 注入测试通过 |
| 真实开合、书本半折、tabletop、帐篷、内屏摄像头激活、左右 Split View | 本轮未完成原生姿态驱动，不声称已验证 |
| 公开可调整窗口会话 | 已尝试，当前模拟器拒绝，CoreDevice 24001：`Resizing is not available on this device right now`；未计作通过 |

ASan 运行日志确认加载检测库，未报告内存访问错误；独立泄漏扫描未启用。测试和构建证据位于本次 session scratch：`page-turn-duo-full.log/.xcresult`、`page-turn-duo-full-summary.json`、`page-turn-duo-asan.log/.xcresult`、`page-turn-duo-asan-summary.json`、`page-turn-duo-core.log`、`page-turn-duo-ui-final.log/.xcresult`、`page-turn-duo-ui-summary.json`、`page-turn-duo-release.log`。视口诊断见 `page-turn-duo-ui-geometry.log` 及对应附件；有效外屏截图清单为 `page-turn-duo-ui-attachments/manifest.json`，已实际查看正文与系统侧栏。独立命令行捕获的 `duo-closed-source5.png` 是黑帧，未用作验收证据。最初 60 秒命令的结果包未完整封口，没有用于最终通过证明。

验证层次分开：纯几何用例检查偏心折痕、非对称安全区、camera、tabletop、窄窗口及不重叠输出；UIKit 用例检查观察、通知、取消和单双页源位置；原生 Duo UI 用例检查运行时实际布局、控制区和阅读位置。实际开合、半折、摄像头激活或分屏左右侧若未驱动，则必须标为未验证，不从静态代码推断已通过。真机手感、长期性能和独立泄漏检查仍不在模拟器结果的证明范围内。
