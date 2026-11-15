# 连续内容查询、交互与自动阅读接入

所有 UIKit API 和闭包在主 actor 执行。本文对应当前公开接口；SDK 不持有内容解析器、摄像头、业务菜单或持久化服务。

## 连续可见内容

```swift
let visible = continuous.visibleContents(in: host.view)
for content in visible {
    // frame 是完整块，visibleFrame 是实际可见部分，均为 host.view 坐标。
    showSelectionOverlay(for: content.binding, in: content.visibleFrame)
}
let hit = continuous.visibleContent(at: point, in: host.view)
if let hit, continuous.isCurrent(hit.binding) {
    let view = continuous.contentView(for: hit.binding)
}
```

查询只包含当前视口实际相交的块，不包含前后预取块。顺序与内容一致；未完成初始定位、失效或视图被移走时不返回。`visibleContents(in: nil)` 和 `visibleContent(at:in: nil)` 使用 reader.view 坐标。`visibleContent` 返回的 frame 始终为 reader.view 坐标。

`contentView(for:)` 可以返回预取区中仍挂载的视图，必须传完整 PageViewBinding。结果是瞬时快照，不赋予长期所有权；复用、窗口换代后旧绑定失效，宿主异步使用前仍须 isCurrent。不要移走返回的视图、竞争设置 frame 或缓存整个快照作为长期内容源。

## 点击与原生滚动门禁

```swift
continuous.shouldBeginPan = { [weak host] pan in
    host?.allowsReaderPan(pan) ?? false
}
continuous.shouldHandleTap = { [weak host] context in
    // point 是 reader.view 坐标；pointInContent 是命中正文视图的局部点。
    !(host?.consumeLinkOrImage(context) ?? false)
}
continuous.onTap = { [weak host] context in
    host?.handleNineGridTap(context.point)
}
```

点击默认为关闭，设置任一点击回调后启用。内建 tap 等待原生 pan 失败，并避让 UIControl。`shouldHandleTap` 返回 false 后不再调用 onTap。宿主也可显式调用 `handleTap(at:)`。查询/拦截回调期间禁止同步 apply/restore 等重入；可暂停或失效容器，SDK 在回调后复核生命周期。异步请求仍可登记和提交，真正安装在空闲时进行。

滚动使用 UIScrollView 自己的 pan 和 delegate；SDK 只在原生开始问询上追加 shouldBeginPan，不暴露可被替换的 delegate。

## 独立暂停目标

`setSuspended(_:reason:)` 继续暂停全部目标，兼容现有代码。新增 `setSuspended(_:targets:reason:)` 可按同一原因累加/移除目标：

| 目标 | 影响 |
| --- | --- |
| `.userScrolling` | 禁止用户拖动并停止原生减速；不直接改写自动阅读意图 |
| `.taps` | 禁止 SDK 内建/显式点击分发 |
| `.automaticReading` | 临时暂停自动时钟；解除后仅恢复原播放意图 |
| `.contentInstallation` | 拒绝立即 apply/restore，延期加载窗口安装 |
| `.all` | 上述全部 |

```swift
// 有选区仍允许用户滚动；自动驱动和业务点击暂缓。
continuous.setSuspended(true, targets: [.automaticReading, .taps], reason: selectionID)
// 拖光标时还需要稳定正文及窗口。
continuous.setSuspended(true, targets: [.userScrolling, .contentInstallation], reason: dragID)
continuous.setSuspended(false, reason: dragID)
continuous.setSuspended(false, reason: selectionID)
```

`suspendedTargets` 返回各原因的并集，不包含用户主动 pause 的意图。解除一个原因不影响另一个原因。只暂停窗口安装不会冻结用户滚动、可见视图复用或布局更新；需要稳定选区视图时应一起暂停用户滚动和自动驱动。`onInteractionIdle` 可以同步重试导航，但不要形成无进展循环。

## 自动阅读的三种宿主模式

| 宿主模式 | SDK 接口 | 宿主职责 |
| --- | --- | --- |
| 手势翻页（含空中手势） | `paged.turn(.next/.previous, animated:)` | 摄像头权限/识别、当前模式和会话校验；过渡忙时明确丢弃或保留最新指令 |
| 自动滚屏 | `continuous.startAutomaticReading(pointsPerSecond:)` | 生产纯正文连续块、加载下一章、将旧速度换为 point/s |
| 定时左右翻阅 | 横向分页 + `paged.startAutomaticReading(interval:animated:)` | 提供当前选择的 slide/cover/curl 等效果、速度到单页时长的映射 |

不新增第二套自动阅读时钟。手势模式应停止计时翻页；切换分页/连续时宿主先保存字符/源页位置，准备新内容后安装新 renderer，再启动其驱动。SDK 无法从分页画面反推生产字符或连续块。

```swift
paged.onAutomaticReadingProgress = { [weak indicator] fraction in
    indicator?.updateProgress(fraction) // 0...1，动画期间不累积本页停留时间
}
try paged.updateAutomaticReadingInterval(8)
try continuous.updateAutomaticReadingSpeed(pointsPerSecond: 45)
```

进度闭包设置时交付当前值，之后变化时通知；成功/取消翻页后的归零在终态事件之后交付。闭包内允许 pause/stop/invalidate，禁止同步重入翻页、开始或变速；若需要新命令，排到下一主线程轮并确认会话。进度到 1 的回调主动暂停会阻止该帧自动翻页。

`updateAutomaticReadingInterval` 保留已读百分比；`updateAutomaticReadingSpeed` 保留位置与窗口令牌。两者均保留用户主动暂停/停止/等待状态，不等价于重新 start。参数非法时旧设置不变。间隔范围 0.1...3600 秒，滚动速度 (0, 2000] point/s。

ParsingBook 的定时翻页可沿用 `clamp(12 / clamp(speed, 0.1, 10), 2, 120)` 秒的映射。旧滚屏是每 display-link 帧移动 speed 点，应确定稳定的每秒速度标定后迁移，不随设备刷新率放大。业务进度指针、渐变遮罩和设置面板留在 App，通过上述回调更新。

临时菜单使用 setSuspended，用户暂停使用 pause/resume。原始 `.auto = 10` 逐步揭页属于历史兼容，不在这三种正常模式中，本轮未新增该效果。横向 continuous、纵向 cover 和双页 Surface 仍不支持。

## 示例

独立 ReaderDemo 使用 `--automatic-reader` 启动。提供三模式切换、上下页外部事件、原生左右拖动、暂停/恢复、速度和菜单暂停。自动滚屏与定时翻页真实运行 SDK 时钟；没有摄像头识别或网络请求。

Surface 退出使用公开 beginExit/cancelExit/finishExit/onExitFinalized，参见 [外壳退出协议](ReaderSurface.md)。确认退出只尝试提交有效稳定位置，宿主仍保留最后有效来源位置。

## 本轮验收

本轮增补退出转发、覆盖样式、连续交互与自动阅读进度／变速接口后：

- SDK 完整模拟器测试 417 项通过，0 失败、0 跳过（iPhone 16 Pro / iOS 18.6）。
- 新增 47 项在 Address Sanitizer 开启时通过；测试启动环境记录 ASan runtime 注入，未报告 ASan 错误。独立 Leaks 未执行，不能据此宣称零泄漏。
- 纯逻辑 macOS 测试 120 项通过。
- 独立示例的 3 项原生 UI 测试通过（iPhone Duo / iOS 27.1）：真实左右滑动、原生滚动门禁、主动暂停后调速／开关菜单、定时翻页、模式切换及覆盖样式取消恢复；导出并检查了 5 张截图。未运行摄像头识别，也未驱动 Duo 折叠姿态。
- 严格 Swift 并发检查、Swift 警告视为错误的构建通过；最终 Release 示例实际包含 arm64 和 x86_64。运行最低版本继续为 iOS 15，Swift tools 5.9，无新增依赖。

这些是 SDK 与独立示例结果；ParsingBook 尚未接入，生产 CoreText/PDF、业务选区、TTS、摄像头和数据库链路仍需后续集成验收。测试环境有 Xcode 元数据/系统版本提示，以及覆盖生命周期测试直接触发消失回调的 UIKit 提示，均未计为 Swift 编译错误或测试失败。
