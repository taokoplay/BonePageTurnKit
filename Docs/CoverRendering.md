# 覆盖翻页的圆角与阴影

`CoverRenderingOptions` 为 `.paged(effect: .cover, axis: .horizontal)` 提供可选的瞬时装饰。默认 `.standard` 的圆角与阴影透明度均为零，保持原 SDK 的平面外观，不修改宿主页面 layer，也不额外插入视图。

```swift
let configuration = PageTurnConfiguration(
    presentation: .paged(effect: .cover, axis: .horizontal),
    cover: CoverRenderingOptions(
        cornerRadius: 50,
        shadowOpacity: 0.4,
        shadowRadius: 50,
        shadowOffsetX: 50,
        shadowOffsetY: 0
    )
)
try configuration.validate()
let reader = try PagedReaderViewController(page: firstPage, configuration: configuration)
```

以上参数参考 ParsingBook 旧覆盖控制器的圆角和阴影尺寸，供宿主按阅读主题调整。旧控制器使用过超出 `0...1` 的阴影透明度；SDK 明确拒绝这种值，示例采用合法的 `0.4`。此处仅提供外观配置，不引入 App 的主题、菜单或自动阅读业务。

`cover` 是 `PageTurnConfiguration.init` 末尾新增的默认参数，原有调用方式继续有效。类型由 `Double` 字段构成，符合 `Sendable`、`Equatable`，不依赖 `CGSize` 的并发标注；UIKit 装饰在主线程执行，支持 iOS 15、Swift 5／Swift tools 5.9，不新增依赖。

| 字段 | 单位与约束 | 行为 |
| --- | --- | --- |
| `cornerRadius` | point，有限且非负 | 大于零时临时裁剪移动页全部四角；零保留宿主裁剪样式 |
| `shadowOpacity` | 有限的 `0...1` | 黑色阴影最大透明度；零不创建阴影视图 |
| `shadowRadius` | point，有限且非负 | 阴影模糊半径 |
| `shadowOffsetX` | point，有限，可正可负 | LTR 下的物理横向偏移；RTL 自动镜像 |
| `shadowOffsetY` | point，有限，可正可负 | 纵向物理偏移，RTL 不改变 |

`CoverRenderingOptions.validate()` 分别抛出 `CoverRenderingError.invalidCornerRadius`、`.invalidShadowOpacity`、`.invalidShadowRadius` 或 `.invalidShadowOffset`。`PageTurnConfiguration.validate()` 调用该校验；即便当前选择其他翻页模式，也会拒绝非法字段，不会静默钳制参数。

## 过渡与层级

next 移动当前页，previous 移动目标页。LTR 和 RTL 使用相同的逻辑页序，只镜像横向移动及阴影偏移；阴影视图始终位于移动页正后方、静止页前方。圆角裁剪真实页面，阴影使用独立、透明且不接收点击的视图，其 layer 设置显式 `shadowPath`，避免被移动页的裁剪边界截断。

阴影有效透明度为 `shadowOpacity × (1 - progress)`，其中 `progress` 是 SDK 的 `0...1` 事务进度。两个逻辑方向都在接近成功终点时衰减；反向取消时随进度回退，收尾结束后立即移除。阴影视图的 `alpha` 和页面 `frame` 由同一个 UIKit animator 插值。SDK 不创建页面位图、不调用快照 API，也不启用 layer 光栅化缓存，因此不占用纸张动画的快照预算。

只有实际 cover 事务安装装饰；等待邻页、边界拒绝、稳定页面以及 none／slide／curl／arch 都不安装。圆角与阴影可独立启用。即时完成的 cover 事务也通过同一条安装与清理路径，结束时没有残留视图。

## 样式归还与所有权

`CoverTransitionDecoration` 独立管理一次事务。启用圆角时保存移动页的 `cornerRadius`、`masksToBounds`、`maskedCorners` 和 `cornerCurve`；不改写宿主的 `mask`、阴影参数、transform 或 rasterize 设置。收尾时逐项比较，只恢复仍与本次写入值一致的属性，保留宿主在过渡中主动改过的新样式。与任何基于值比较的恢复一样，宿主再次写入完全相同的值无法与装饰原值区分；建议在事务结束后设置持久页面样式。

成功、取消、尺寸变化、布局失效、暂停、退出可见区域、进入后台和 `invalidate()` 都通过统一路径清理。当前页替换保持既有的空闲安装规则，等待中的替换在事务结束后执行；切换模式时按原接口先 `invalidate()` 旧 renderer。快速翻页只保留一个活动 helper，终态事件发出前即恢复 layer 并移除阴影。

宿主同步回调可能取消事务或把页面交给其他容器。安装和每次布局均重新核对事务、controller parent 与根视图 superview；失去所有权后取消事务，不继续提交、移动或隐藏外部页面。清理只撤销仍属于本次装饰的 layer 值，不把外部页面移回 reader。helper 弱持有页面和容器，容器直接释放时也在主线程归还仍持有的装饰资源；宿主退出时仍应使用已有的 `invalidate()` 生命周期入口。

## 验证范围

`Tests/BonePageTurnKitTests/CoverDecorationTests.swift` 使用 XCTest，包含配置校验、真实 layer、阴影层级与进度、next／previous／RTL、原样式恢复、按钮命中、各种中断、页面回填与模式切换、重入取消、外部接管、快速连续翻页及弱释放断言。配置测试可在无 UIKit 环境运行，视图测试使用 `#if canImport(UIKit)` 和 `@MainActor`。

本次仅编写测试，未启动构建或执行测试，由集成方统一验证。layer 几何断言不替代真机对模糊阴影观感的确认。
