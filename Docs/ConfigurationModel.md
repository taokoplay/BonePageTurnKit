# 翻页配置模型：效果、轴向与展示模式

## 已明确的设计方向

用户提出将动画效果与方向分别建模，例如“平移”是一种效果，“左右/上下”是两种方向。本设计采用 `PageTurnEffect` 与 `PageTurnAxis` 表达这一点，不再为横向、纵向各建立一组重复的效果枚举。

当前实现 none/slide/curl/arch 横纵、cover 横向与 continuous 纵向；分页和连续自动阅读是独立驱动。分页增加 single/spread 编排与显式 LTR/RTL，单页纸张支持 automatic/minimum/maximum，双页纸张支持 automatic/center。完整能力见 `supportedPresentations`、`supportedSpines(for:layout:)` 和 [双页、漫画与缩放](SpreadComicAndZoom.md)。

## 三个概念

| 概念 | 候选类型 | 含义 |
| --- | --- | --- |
| 动画效果 | PageTurnEffect | 页面切换时如何呈现：无效果、平移、覆盖、仿真、拱页 |
| 翻动轴向 | PageTurnAxis | 手势/位移沿水平还是垂直轴运行 |
| 展示模式 | PageTurnPresentation | 固定分页，或可以停在任意正文位置的连续滚动 |

左右/上下在API中称为axis，避免与“上一页/下一页”的逻辑方向混淆。后者仍由previous/next操作表达，宿主定义内容顺序；阅读顺序、界面RTL和用户手势方向不能隐式混成一个枚举。

## 类型草案

```swift
public enum PageTurnEffect: Sendable, Equatable {
    case none
    case slide
    case cover
    case curl
    case arch
}

public enum PageTurnAxis: Sendable, Equatable {
    case horizontal
    case vertical
}

public enum PageTurnPresentation: Sendable, Equatable {
    case paged(effect: PageTurnEffect, axis: PageTurnAxis)
    case continuous(axis: PageTurnAxis)
}
```

采用关联值表达两个展示模式，避免出现“连续滚动＋仿真动画”等没有定义的组合。自动阅读是驱动方式，可作用于分页或连续容器，不加入效果枚举。

使用示意：

```swift
let horizontalSlide = PageTurnPresentation.paged(
    effect: .slide, axis: .horizontal
)
let verticalSlide = PageTurnPresentation.paged(
    effect: .slide, axis: .vertical
)
let verticalContinuous = PageTurnPresentation.continuous(axis: .vertical)
```

纵向平移仍是按固定页面切换，纵向连续滚动则能停在任意位置，两者保留不同的数据供给、窗口和锚点机制。

## 当前支持组合与实现依据

以下与实际配置校验一致；原 App 模式到新宿主的适配尚未实施。

| 展示/效果 | 横向 | 纵向 | 实现边界 |
| --- | --- | --- | --- |
| paged + none | 已实现 | 已实现 | 无过渡动画，轴向影响手势与相邻页动作映射 |
| paged + slide | 已实现 | 已实现 | 两个真实页面沿所选轴向一起平移 |
| paged + cover | 已实现 | 明确拒绝 | 当前覆盖几何基于 x 轴 |
| paged + curl | 已实现 | 已实现 | 单页卷曲或中央真实双页；轴向几何与采样成对映射 |
| paged + arch | 已实现 | 已实现 | 单页／中央双页拱起曲面；保留真实页面及受预算约束的临时快照 |
| continuous | 明确拒绝 | 已实现 | 异高块窗口、任意像素位置、锚点补偿与按可读高度补屏 |

效果与轴向独立不等于所有组合都有效。SDK应提供可查询的支持范围，并在应用配置时统一验证；验证失败保持当前展示与配置，返回明确错误，不静默降级。

旧配置的兼容回退由宿主明确处理。扩展轴向不新增重复的 verticalCurl/verticalArch 枚举，支持范围与实际后端一致；当前仍拒绝纵向覆盖及水平连续滚动。

## 与旧App配置的映射

| 旧模式 | 新草案 | 额外适配 |
| --- | --- | --- |
| none (0) | paged(none, horizontal) | 保持原有手势基线；新纵向无效果另验 |
| cover (1) | paged(cover, horizontal) | 保留完成/取消规则 |
| simulation (2) | paged(curl, horizontal) | 采用 SDK 的单一事务及快照后端；与旧系统卷页的视觉和业务适配另验 |
| archPageTurn (13) | paged(arch, horizontal) | 当前为 CG 曲面；旧 Metal 性能及预加载策略不自动继承 |
| hTranslation (4) | paged(slide, horizontal) | 背景/装饰随原配置处理 |
| vTranslation (5) | paged(slide, vertical) | 同上 |
| hTranslationMoveText (6) | paged(slide, horizontal) | 宿主提供固定背景/页眉页脚 |
| vTranslationMoveText (7) | paged(slide, vertical) | 宿主提供固定背景/页眉页脚 |
| chunkScroll (12)，历史11 | continuous(vertical) | 章节窗口和语义锚点由宿主适配 |
| auto (10)与自动阅读设置 | 宿主选择展示模式＋自动驱动 | 不把旧rawValue直接强转为新效果；梳理旧覆盖式自动模式的兼容策略 |

“只移动文字”是背景/装饰的布局行为，不再独立编码成一种动画。初期通过容器区域与固定装饰插槽表达，具体配置类型待实现时收敛。

旧rawValue只在宿主转换，SDK不继承App历史编号。单次程序化定位是否播放动画也应与长期选择的效果分开，避免不动画跳转意外修改用户偏好。

## 内部实现原则

- 轴向用于选择主轴位移、速度、容器长度、坐标及边缘区域；尽量集中几何转换，减少横纵两份重复状态机。
- 各效果完成阈值与时长明确记录：覆盖／平移沿用半屏归一化，纸张采用整页 17% 及 500 point/s；不能声称新曲面与旧系统／Metal 后端手感完全相同。
- next/previous 由逻辑内容顺序定义；水平 LTR/RTL 显式映射手势与双页侧序，纵向仍为上到下，纸张显式边缘书脊优先决定拖动方向。
- 效果或轴向切换统一经过生命周期与展示版本切换。宿主先保存语义锚点，必要时重新排版，新renderer确认后再提交配置；不只修改一个枚举字段。
- 连续模式的位移和稳定锚点不强制改造成逐页成功事件。分页与连续共用基础身份和取消规则，各自保留适用的事件。
- 支持列表、设置界面和执行校验采用同一能力来源；主线程/主actor应用配置。

## 验收要求

1. slide沿horizontal/vertical得到对应平移，previous/next的逻辑含义一致。
2. 纵向slide和纵向continuous分别覆盖整页切换与任意位置停留。
3. 不支持的组合有明确返回，当前页面与阅读进度不被部分修改。
4. h/v只移动文字选项映射后，固定背景和装饰行为不丢失。
5. 方向/效果切换遇动画、加载、长按或自动阅读时，旧回调失效，锚点可恢复。
6. 旧设置rawValue11/12及其他已支持模式通过显式转换正确恢复。

最初设计依据为 ParsingBook 的 `ReadViewControllerDelegate.swift`、`BoneReader.swift`、`ReadTranslationController.swift`、`ReadSimulationController.swift` 与 `ArchPageTurnDynamics.swift` 的静态核查。当前 SDK 运行验证分别记录于 [横纵平移](SlideAndPagedAutomaticReading.md)、[连续内容](ContinuousContentContract.md) 和 [纸张曲面](PaperAndPageReplacement.md)；原 App 仍未集成。

## GitHub研究后的扩展候选

以下保留研究提出的扩展方向。现已实现显式阅读顺序、真实双页、宽图／长图切片、缩放和分页边缘交接，见 [本轮实现](SpreadComicAndZoom.md)；生产语义位置、解码和业务选择仍归宿主。

- **阅读顺序**：逻辑next/previous与沿轴布局的正向/反向分开；横向漫画RTL不应隐式倒置纵向列表，也不直接继承App界面语言。
- **展示编排**：源图单页、两张源图组成双页、一张宽图拆片保留回源映射。小说双栏由正文排版提供，不能直接套漫画配对规则。
- **内容交互**：缩放、内层pan、文字选择和交互控件的占用状态由内容适配器提供；SDK负责与翻页手势协调。最小缩放下的适宽长图也可能需要pan。
- **内容位置**：SDK保留当前布局锚点，宿主提供语义位置捕获/解析。小说可用字符位置或CFI，漫画可用源页与图像区域，核心不解释具体格式。
- **资源预算**：展示窗口、预取范围、解码图片与动画快照分别管理；可见与预取信号来自容器，读取/解码由宿主执行。

这些设计来自固定提交源码研究，各开源项目并不具有相同接口。当前 SDK 的已实现组合以运行记录与配置查询为准，首版连续纵向要求不变；普通小说调用方不必配置全部漫画策略。
