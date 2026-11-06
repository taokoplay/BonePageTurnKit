# 双页、纵向纸张、漫画切片与缩放交接

> 本文保留双页与漫画扩展阶段的验收记录。后续增加可选动态视口、Duo 保留区域和书脊留白，见 [iPhone Duo 适配](iPhoneDuo.md)；当前测试数以最新记录为准。

本阶段扩展 BonePageTurnKit 的展示能力，保持 iOS 15、Swift tools 5.9、Swift 5 语言模式、UIKit、无第三方依赖。未接入 ParsingBook，也不加入正文解析、图片／PDF 解码缓存、书库或同步业务。

## 配置与明确顺序

`PageTurnConfiguration` 增加 `layout: ReaderPageLayout` 和 `readingOrder: ReaderReadingOrder`，默认 `.single`、`.leftToRight`，旧调用方式兼容。

| 能力 | 水平 | 垂直 |
| --- | --- | --- |
| 无动画／平移 | 单页、双页 | 单页、双页 |
| 覆盖 | 单页、双页 | 仍明确拒绝 |
| 仿真／拱页 | 单页边缘书脊、双页中央书脊 | 单页边缘书脊、双页中央书脊 |
| 连续内容块 | 仍明确拒绝 | 保留已有异高连续滚动 |

- 单页纸张支持 automatic/minimum/maximum；双页纸张支持 automatic/center。单页不能直接配置中央书脊，双页也不能默认为边缘整图翻动。
- automatic 在双页纸张解析成 center，在水平 RTL 单页纸张解析成 maximum，其余单页纸张解析成 minimum。可读取 `resolvedSpine`。
- 水平 LTR 默认向左拖动表示 next，RTL 向右；显式 minimum/maximum 纸张书脊优先决定几何方向。纵向默认向上表示 next，minimum/maximum 为上／下。
- 阅读顺序改变物理布局、手势和点击区域，不改变 `pageProvider` 中 previous/next 的逻辑含义；不从系统界面 RTL 隐式推断。
- `supportedSpines(for:layout:)` 与实际校验共用声明。continuous 只接受 single 配置，双页编排属于分页容器。

```swift
let config = PageTurnConfiguration(
    presentation: .paged(effect: .curl, axis: .horizontal),
    layout: .spread,
    readingOrder: .rightToLeft
)
try config.validate()
// config.resolvedSpine == .center
```

## 两个真实页面组成一组

`PageSpreadViewController` 承载两个普通 `PageContent`，通过标准 UIKit containment 保留真实、可交互的子控制器。`first`、`second` 表示逻辑先后；水平 RTL 时 first 在右、second 在左，纵向始终 first 在上。两侧各占轴向一半，nil 侧留白，不拉伸另一页，也不创造虚假源页码。

```swift
let spread = try PageSpreadViewController(
    first: firstContent,
    second: secondContent,
    axis: .horizontal,
    readingOrder: .rightToLeft
)
let content = PageContent(
    identity: PageItemIdentity(sourceID: "book", unitID: "spread-12"),
    controller: spread,
    readingInfo: hostProvidedInfo
)
let reader = try container.showPaged(page: content, configuration: config)
```

组身份用于现有翻页、替换、版本和终态协议，子页身份通过 `visiblePageIdentities` 和 `spread.pages` 保留。页码和全书边界继续由宿主提供；翻动一组不能自动算作只翻过一个源页。单页／双页控制器、轴向或阅读顺序不匹配会被拒绝，创建下一页和当前页回填都接受同样校验。

`ReaderSpreadLayout(pageCount:firstPageIsCover:)` 提供按需分组，不为全书创建巨大数组。`spread(at:)`、`spreadIndex(containingPage:)` 使用零基源页索引；默认封面位于逻辑第二侧，另一侧为空，书尾不足两页时保留真实空侧。单双页切换时先保存源页／字符位置，再在新分组中定位，不能沿用旧组索引。

初始化、加载和挂载回调后会重新核对子页归属。已被其他视图或控制器接管的页面被拒绝；失败候选不会偷走另一个宿主的视图。

## 中央书脊与纵向采样

中央书脊铰链固定在视口中线。LTR 下一组的固定底层为“当前左页＋目标右页”，移动纸页正面为“当前右页”、背面为“目标左页”；RTL 镜像物理侧，previous 交换源／目标并反转时间。背面使用目标真实子页的完整内容，不复用原页的淡色镜像。

curl 对材料切线角积分得到卷曲圆弧，arch 在旋转纸面叠加拱形；两种曲面有不同投影和明暗。纵向同时变换几何、裁条方向及正反面采样方向，稳定文字保持正向。端点直接绘制当前／目标快照，落定仍显示真实子页面。

沿用两张原始快照的合计像素预算及 4096 最长边。中央快照沿轴长度向下取偶数，最多少一个像素，以便两侧公平分配。正反条带在开始时预裁，保留采样边界，不在每帧裁图；条带、显示缓冲和宿主内容仍在原图预算之外。退出、取消、尺寸变化和内存告警均按已有事务释放资源。

## 漫画切片与源身份

```swift
let slices = try ComicPageSlicing.slices(
    for: sourceIdentity,
    pixelSize: uprightPixelSize,
    mode: .splitWide,
    readingOrder: .rightToLeft
)
```

- `.whole`：完整源图。
- `.splitWide`：宽大于高时二等分，奇数宽度按整数像素边界划分，不丢列；LTR 左先、RTL 右先。普通竖图保持完整。
- `.vertical`：按 `maximumHeightToWidth` 分段，默认 1.5，始终由上至下，最后的短片保留，不凑高或拉伸。
- 每边必须为有限正整数，最大 1e9；单次最多 256 片，超过预算抛错，不先分配巨数组。
- `sourceIdentity`、`sourcePixelRect`、`normalizedRect`、逻辑 `index/count` 均显式保留。派生 unitID 包含无歧义源 unitID 和物理矩形；重排 LTR/RTL 只改变顺序，同一物理切片身份不变。源内容及布局版本原样保留。

`ComicSliceView(image:slice:)` 用 clipping＋绘制宿主提供的 UIImage 显示该区域，不创建额外裁剪位图或全图缓存。要求已转正的 `.up` 图片，实际像素尺寸必须与切片计划一致；失败明确抛错。图片加载、转正、降采样、PDF 光栅化及共享解码缓存仍由内容侧承担。连续模式可由宿主 provider 复用这些区域信息，并按切片实际比例提供 extent。

## 通用真实内容缩放

```swift
let zoom = try ReaderZoomViewController(
    content: contentController,
    contentSize: logicalContentSize,
    fit: .aspectFit,
    maximumZoomFactor: 4
)
try zoom.setZoomFactor(2, centeredAt: contentPoint, animated: true)
zoom.resetZoom()
```

缩放容器不限定漫画，也可承载宿主的 PDF 或图片视图。`.aspectFit` 完整适配，`.width` 适宽并允许长内容在最小倍率继续上下滚动。`zoomFactor` 相对于适配倍率；双击在局部放大和复位之间切换，捏合与滚动使用原生 UIScrollView。resize 保留归一化可见中心和相对倍率，边缘按合法范围钳制。

`centeredAt` 使用固定 `contentSize` 坐标，不是窗口坐标。缩放不会创建内容快照；初始化和挂载回调后会验证真实子控制器归属，失败会回滚。公开的 `scrollView` 用于接入手势与观察，宿主不能替换其 delegate。

## 同一次拖动到边缘后交接

分页容器会自动登记页面及双页子页面中的 `ReaderZoomViewController`。普通宿主 UIScrollView 可显式调用：

```swift
let registration = try paged.registerScrollableContent(
    scrollView,
    policy: .init(threshold: 18, allowsPagingWhileZoomed: false)
)
// 不再需要时 registration.invalidate()；离开当前页或 reader.invalidate() 也会自动注销。
```

1. 内容内部可滚动的距离优先由 UIScrollView 消耗，达到边界后继续拖动超过阈值才开始翻页，进度只计算超出门槛的距离。
2. 在调用 willBegin 前登记事务所有权，宿主回调内注销可以立即取消；外部 cancelTransition 也同步归还属性，不依赖下一次手势变化。
3. 交接后保持边缘 offset，临时关闭回弹；完成／取消恢复原值。登记期间启用对应轴的 alwaysBounce，使刚好适屏的内容也能启动原生 pan；注销时恢复原设置，不修改 scroll delegate、zoom 或滚动启用状态。
4. 默认高倍缩放时禁止翻页交接；可以显式允许到边缘后翻页。双指 pan、pinch、跨轴占优时不启动翻页。所有实际拖动／捏合仍占用展示，自动阅读暂停，当前页回填延期，直到相应手势终态。
5. 纸张交接时当前真实滚动视图留在不透明快照层下，避免 isHidden 使 UIKit 取消正在驱动的 pan；普通程序翻页仍隐藏真实页。
6. 邻页尚未就绪时同一次手势只请求一次，不逐帧轮询。取消、暂停、resize、离场、后台和失效会终止交接。手动结束后重置自动阅读停留时间，保留播放意图。

重复登记同一视图返回已有登记，保留原策略。要在自动登记后更改策略，应注销旧登记再登记；也可在 provider 准备目标页面时预先登记自定义策略，只有成为当前页后才响应。该交接接口属于分页容器，连续容器中的复杂嵌套缩放仍由宿主协调，不能把两套滚动所有权直接叠加。

## 示例和验证

启动 `ReaderDemo` 并传入 `--expanded-reader`。支持 `--spread`、`--vertical`、`--rtl`、`--arch`、`--slide`、`--slice-wide`、`--slice-long`、`--long-scroll`、`--preview`、`--auto-start`。界面可以切换各组合、放大／复位、前后翻页、停在中间帧及自动阅读。素材由示例自行绘制，SDK 不依赖外部图片。

工程新增 `ReaderDemoUITests`，通过真正的拖动、双击和捏合验证边缘交接。它与 SDK 的数值／像素／生命周期测试分开：程序化调用手势状态机不冒充原生手势通过。

```bash
xcodebuild -project Examples/ReaderDemo.xcodeproj -scheme ReaderDemo \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test CODE_SIGNING_ALLOWED=NO
```

最终结果（2026-11-06）：**290 项完整 SDK Simulator 测试、64 项本轮 ASan 测试、78 项 macOS 纯逻辑测试、5 项独立原生 UI 测试全部通过**。SDK 与 UI 测试构建启用 `SWIFT_STRICT_CONCURRENCY=complete`、`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`，ReaderDemo Release 多架构构建通过。运行设备为 iPhone 16 Pro / iOS 18.6 Simulator，Swift 6.4 编译器以 Swift 5 语言模式、iOS 15 部署基线构建。

新增的 64 项 SDK 测试涵盖：双页编排／配置 4、真实双页容器 6、手势交接 11、挂载与交接重入回归 6、漫画切片 7、真实裁图 5、缩放几何 5、缩放容器 10、扩展纸张几何 6、真实绘图 4。原生 UI 测试另覆盖长图内部滚动至边缘、LTR/RTL、适屏边缘拖动、中央双页、纵向拱页、放大后保留浏览、双击／捏合及复位后继续翻页。

验收中修复了适屏 UIScrollView 无原生边缘拖动、回调内注销遗留 pending、外部取消未立即归还 bounces、双指 pan／pinch 交错丢失占用，以及缩放／双页子视图被同步回调移走的问题。完成一次限定范围静态复核，并对已确认缺陷追加运行测试。

ASan 运行日志确认加载 `libclang_rt.asan_iossim_dynamic.dylib`，64 项零失败、零跳过、无内存访问错误报告；`leaksCheckingMode` 为 off，未做独立泄漏扫描。完整 SDK 摘要为 290 项零失败、零跳过，无运行时警告。纸张新增 126 张截图附件，实际查看了中央固定半页、正反面内容、纵向文字、RTL 和端点；独立 UI 测试另保存实际触摸后的示例截图。

本次会话 scratch 证据：`page-turn-expanded-final.log/.xcresult`、`page-turn-expanded-final-summary.json`、`page-turn-expanded-asan.log/.xcresult`、`page-turn-expanded-asan-summary.json`、`page-turn-expanded-asan-diagnostics/`、`page-turn-expanded-core.log`、`page-turn-expanded-release.log`、`page-turn-expanded-ui-final.log/.xcresult`、`page-turn-expanded-ui-summary.json`、`page-turn-expanded-attachments/manifest.json` 和 `page-turn-expanded-ui-attachments/manifest.json`。文档链接和宿主依赖／并发绕过扫描通过；未修改原 App，未初始化 SDK Git 仓库或提交。

功能实现与生产验收分开：真机长期帧率、复杂 PDF／超大图解码峰值、独立 Instruments Leaks，以及原 App 的业务适配尚未完成。现有通过结果仅覆盖记录的模拟器、示例和测试内容，不承诺所有宿主渲染器均可直接替换。
