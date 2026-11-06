# 连续内容块衔接与可读高度补屏

本轮按讨论结果优化 BonePageTurnKit：保留展示与交互容器定位，不接入 ParsingBook，不增加解析器或跨层内容缓存。工作覆盖内容块交付契约、可读高度需求、自动补屏限额、短内容场景与真实 CoreText 接缝验收。

## 连续内容块的交付契约

固定分页的“页”和连续模式的“内容块”不能直接按整屏高度互换。内容侧决定如何分页／分块、如何解释样式；SDK 按最终几何排列。

`ContinuousItem.extent` 表示从本块原点到下一块原点的最终占用高度：

```text
nextOrigin = currentOrigin + current.extent
lineLocalY = lineGlobalY - blockOrigin
```

- 不包含固定分页的页眉页脚，也不包含为了填满整页而保留的多余空白。
- 跨块行距、段距只计一次，建议由前块 extent 承担；SDK 不额外添加间距。
- 同段续行应保持原行基线关系，不重复应用首行缩进／段前距；段落交界和章节交界按内容侧样式计算。
- 测量与绘制使用同一宽度、字体、段落样式和附件尺寸；切分范围连续，不能漏字或重复字。
- 混合字号、emoji 和上下伸展字形要保留实际绘制范围。占用框与字形墨迹框不一定相同；宿主需安排正确本地原点和足够绘制区域，不要让 opaque 背景或 clipsToBounds 截断相邻行。
- 保留小数高度，不对每块单独 ceil；独立取整会使大量块产生累计空隙。容器保留累计几何，自动滚动的屏幕像素对齐不改块排版高度。
- 内容侧可以对有界章节或窗口做一次排版再分行，也可以采用保持续段上下文的增量排版；无需一次加载整本书。
- 原始章节、排版结果与图片解码缓存仍由内容侧管理；SDK 只管理窗口元数据、挂载视图及复用池。

字体／宽度或内容发生变化时推进对应版本。跨重排使用内容侧重新解析的语义锚点；上方尺寸改变而当前块布局未变时，SDK 自动补偿当前位置。窗口首尾的可滚动范围仍会限制可恢复的像素位置。

## 数据单元数量不等于一屏

例如视口高 300 point，每个数据单元最终高 75 point：

| 已安装内容 | 布局高度 | SDK 行为 |
| --- | --- | --- |
| 4 个 ready 块 | 300 | 刚好覆盖一屏；若后方 available，继续请求下方余量 |
| 8 个 ready 块 | 600 | 默认满足当前一屏＋下方一屏目标，停止继续补入 |
| 4 个 20 point 短块 | 80 | 每次安装后重新检查，不以“已取 4 页”为停止条件 |
| 一个 8000 point loading 块 | 8000 | 仅占位，不贡献 ready 高度，优先补齐该块 |
| 确认全书只有 75 point | 75 | 保留真实剩余空白，不为填满屏幕无限请求 |

SDK 不需要将四个块合并成一个对象。保留各自稳定身份，沿共同布局自然显示在一屏内。页码和阅读进度继续使用独立语义，不能按已安装块数推断。

## 结构化补屏接口

`ContinuousReaderViewController.readableCoverage` 可查询当前可见的 ready 高度、视口缺口、顶部前后连续可读距离和最近未就绪块。内部使用 ready 高度前缀和未就绪索引，查询复杂度为 O(log n)。

接入方推荐使用：

```swift
reader.onContentDemand = { demand in
    // demand.direction：前／后方向
    // demand.target：.edge 或 .item(PageItemIdentity)
    // demand.missingReadyExtent：达到覆盖目标尚缺的可读高度
    // demand.coverage：当前可见及连续 ready 覆盖
    // demand.token：本轮窗口安装前置版本
    // 按目标从宿主读取／排版，再通过 beginLoading → submit 安装。
}
```

`onContentDemand` 设置后优先于旧 `onEdgeApproach`，同一需求不会重复通知两个入口。旧接口保留物理边缘语义，无法指出内部占位目标；需要准确补齐占位时应迁移到结构化入口。两种自动入口都应用预算。

登记任务可显式传入 `beginLoading(demand.direction, token: demand.token, target: demand.target, cancel:..., completion:...)`。省略 target 时关联最近已发出的同方向同版本需求。活动 `.item(identity)` 在两个方向之间去重，用户跨过同一占位后不会再启动第二份任务；`.edge` 仍允许前后各一个任务。

- 当前视口存在 loading 缺口时，优先请求对应 `.item`，不绕过占位继续扩张更远的内容。
- ready 块内的正常段落留白属于已排好的几何；SDK 不通过像素颜色判断可读性。
- `loading` 状态在这里表示尚未就绪，不表示 SDK 自动拥有一个网络任务；宿主可将需求连接到已有共享任务或新任务。
- `failed` 块不自动反复请求。重试由宿主决定，可自行登记任务，或把有效状态更新为 loading 后重新提交。
- 完整窗口安装确认后才评估下一次需求，保留原可见锚点；预加载尾部不会自动变成当前阅读位置。
- 真实 endOfBook、latestAvailable、unknown、loading、failed 或旧 end 边界不会当作 available 自动拉取。自动阅读仍按其独立状态等待／结束。

## 自动补入预算

`ContinuousFillPolicy` 默认：前后各 1 屏余量、每方向每周期最多 16 次自动需求、最多连续 2 次无可读进展结果、累计新增最多 256 个内容块。余量允许 0...8 屏，计数预算必须为正数。

前后余量设为 0 只关闭预取，不关闭当前屏补齐。若后方已到书尾、当前 ready 内容不足一屏而前方 available，仍会向前提出当前屏缺口；两端都确认无更多内容才保留剩余空白。

可在 `ContinuousReaderViewController` 或外壳 `showContinuous` 初始化时传入：

```swift
let policy = try ContinuousFillPolicy(
    leadingViewports: 1,
    trailingViewports: 1,
    maximumRequests: 16,
    maximumNoProgressResults: 2,
    maximumAddedItems: 256
)
```

达到限额后：

- 不再自动提出该方向的新需求。
- `fillLimit(in:)` 返回 requestBudget／noReadableProgress／addedItemBudget。
- `onFillLimitReached` 在每个周期对同一限额只通知一次；不把它当作书尾。
- 已完成安装的内容保持可读；不裁剪或丢弃已接受结果。
- 手动 `beginLoading` 不受自动需求预算拦截。实际网络／解析／像素预算仍归宿主，单次巨大结果不能靠此计数限额证明内存有界。

无进展依据实际可读距离增长或目标占位变 ready 判断。只增加窗口 revision、改变页码元数据、增大占位高度或附加更多占位不算可读进展。SDK 不解释宿主游标；宿主发现重复游标或空批次应先在内容侧停止，避免把旧窗口换一个 token 反复提交。

显式定位、真实视口尺寸变化，或累计实际移动至少一屏后开启新周期。净移动距离跨窗口安装与同尺寸布局保留；前插／裁剪／高度补偿只更新坐标基准，不被当作用户移动来自动清预算。

用户重试或宿主确认允许更多读取时调用 `resumeContentFilling()`；它重置补屏周期但不推进窗口版本，也不把失败内容自动改成 ready。正在 UI 回调或仍有未终止任务时会拒绝，宿主在任务结束后的下一主线程事务处理。真实外部数据回填可解除无进展阻塞；总请求与新增块预算仍需新周期。

## 专项验收

纯逻辑与容器用例覆盖四块恰好一屏、连续七批短内容、巨型占位、窗口内缺口、反向补入、失败与末尾、无进展限额、请求／新增块预算、显式重试、选择中延期、窗口尺寸变化与迟到结果拒绝。

另有 8 项 CoreText 接缝测试：

1. 同段完整行切分后，基线、X 坐标与 UTF-16 范围匹配未拆分排版。
2. 段末到下一段首行间距只计一次，不重新应用缩进。
3. 大量小数行高的累计位置一致，输入足以暴露逐块 ceil 偏差。
4. 真实 SDK 挂载 frame 与相邻行接缝符合最终 extent。
5. 前插、上方估算高度回填、裁剪保持当前行屏幕位置。
6. 真实视图复用后只绘制新绑定的行。
7. 改宽度／字号后拒绝旧锚点，宿主按原文位置解析新行恢复。
8. 拼接与未拆分的真实窗口截图对照，检查末行 gyp 下伸部实际像素。

fixture 使用有界 CoreText 布局、混合小数字号、行距、段前后距、首行缩进、引用底色和 emoji。几何容差 1/3 point。它不覆盖图片附件、双向文字或完整跨块选择；图片异步回填和版本失效继续由此前异步渲染测试覆盖。fixture 只存在于 Tests，不构成 SDK 排版器。

最终验证：**157 项完整 iOS Simulator 测试、33 项本轮相关 ASan 测试、46 项 macOS 纯逻辑测试全部通过，零失败**。33 项包括补屏逻辑 10、补屏容器 10、方向／预算回归 5、CoreText 接缝 8。SDK 严格并发 complete 且 Swift 警告视为错误构建通过；示例 Debug 构建、安装与启动通过。

本轮一次复核后修复了三项具体问题：实际移动距离在安装／同尺寸布局后丢失；同一占位从不同方向重复登记；零预取时书尾短窗口未向前补足当前屏。对应 5 项回归已通过，包括安装补偿不能冒充用户移动、占位去重不影响双向边缘并发。

接缝两张真实 CoreText 截图已核对，拼接与未拆分的行距、段距、缩进、引用底色与末行显示一致。最终示例画面显示：四块一屏场景补到 8 块、请求 1 次；高占位场景先回填再补到 9 块、请求 3 次；无进展场景保持 4 块、请求 2 次后暂停。截图只是相应示例的显示核对，不代表真实书籍样式或真机性能验收。

ASan 构建与测试进程均实际启用地址检测，未报告内存访问错误；leaksCheckingMode 为 off，不包含独立泄漏扫描。运行时为 iOS 18.6 iPhone 16 Pro Simulator，部署基线仍是 iOS 15／Swift tools 5.9。测试工具存在未使用 AppIntents 的提示、Xcode 内部 invalidDigitCount 诊断，以及旧异步样式测试的 TextKit 兼容提示，均未影响通过。

最终会话 scratch 证据：`page-turn-filling-final.log`／`.xcresult`、`page-turn-filling-final-asan.log`／`.xcresult` 及诊断目录、`page-turn-filling-final-core.log`、`page-turn-filling-final-strict.log`、`page-turn-filling-final-demo.log`。接缝图片位于 `page-turn-typography-attachments/`；示例截图为 `page-turn-fill-four.png`、`page-turn-fill-placeholder.png`、`page-turn-fill-stalled.png`。证据不作为 SDK 资源分发。

## 独立示例

ReaderDemo 启动参数 `--filling` 显示四块一屏；追加 `--fill-placeholder` 启动大占位场景，或 `--fill-stalled` 查看相同内容返回两次后的暂停。每批最多四个块，显示视口、实际可读高度、块数和请求次数，提供“允许新一轮补屏”。

当前 App 未接入。本轮不实现网络获取、书籍格式解析、全书内容缓存、原 App 排版迁移或其余翻页效果。
