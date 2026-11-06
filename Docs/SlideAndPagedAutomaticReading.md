# 横纵平移与分页自动阅读

> 本文为平移阶段的验收快照。后续已实现单页横向 curl/arch、左右书脊及当前页替换，见 [纸张曲面与原位替换](PaperAndPageReplacement.md)；下文的未实现项和测试数保留为当时记录。

本轮继续补齐 BonePageTurnKit 的展示能力：新增 slide 横向／纵向后端，以及驱动已支持分页效果的自动阅读。仍保持 Swift tools 5.9、iOS 15、UIKit、无第三方依赖；未接入当前 App，也未增加正文解析或内容缓存。

## 平移效果

```swift
let horizontal = PageTurnConfiguration(presentation: .paged(effect: .slide, axis: .horizontal))
let vertical = PageTurnConfiguration(presentation: .paged(effect: .slide, axis: .vertical))
```

效果与轴向继续分离，不创建 horizontalSlide／verticalSlide 枚举。当前页与相邻目标页使用真实控制器视图同时平移，稳定状态可以继续执行内容交互与异步渲染，不永久截图化。

- next 向轴的最小端移动：水平向左、垂直向上；previous 反向。
- 手势按主轴位移／速度工作，另一轴坐标与容器 bounds 原点保持。
- 当前页和目标页在同一进度下保持连续相邻；完成时只保留目标页，取消时恢复原页。
- 松手沿用 SDK 统一策略：半屏归一化进度 0.17、方向速度 500 point/s，快速反向甩动优先取消。这是当前 SDK 的策略，不声称完全复刻旧 UIScrollView 平移模式的惯性手感。
- 收尾动画 0.25 秒；单次 animated=false 或系统 Reduce Motion 时直接结束事务。
- 触摸、点击和程序翻页共用既有事务；过渡中重复请求明确拒绝，不建立无界队列。
- 横向 cover 和 none 横纵仍保留原行为；cover 纵向、curl、arch 及显式书脊位置继续拒绝。

固定页眉页脚、背景可由宿主放在容器外，SDK 只移动传入的页面。若要求“只移动文字”，宿主应提供正文区域视图并设置合适背景层，而不是另建一个效果枚举。尚未完成旧 App 对应模式的集成验收。

## 分页自动驱动

```swift
try paged.startAutomaticReading(interval: 5, animated: true)
paged.pauseAutomaticReading()
try paged.resumeAutomaticReading()
paged.stopAutomaticReading()
```

每页停留时间为有限的 0.1...3600 秒。自动驱动调用同一 `turn(.next)` 事务，不是一种新的翻页效果，支持 none、cover、slide。

`automaticReadingState`／`onAutomaticReadingStateChange` 区分：

| 状态 | 含义 |
| --- | --- |
| stopped | 已停止；进度清零，需要显式 start |
| running | 正在计算当前页停留时间 |
| turning | 正在执行已开始的翻页事务，计时器停止 |
| paused | 用户主动暂停，或受到菜单／选区／离屏／后台等限制 |
| waiting(boundary) | 邻页或新布局未就绪，停止时钟并等待显式通知 |
| finished(endOfBook) | 本页停留结束并确认全书结尾 |

`automaticReadingProgress` 为当前页 0...1 的计时进度。只有实际可见、应用可交互且未被暂停时才计时。每个时钟 tick 最多计入 0.1 秒，一次最多发起一笔翻页，不追赶后台积压时间。

成功提交新页后清零计时；动画期间的时间不算下一页阅读时间。手动翻页或取消交互后重新计时。用户 pause 保留当前进度；stop 清零。暂停／停止只控制自动驱动，不撤销已经开始的页面事务；需要撤销交互可调用 cancelTransition，外壳 suspension 也会按既有规则取消当前翻页。

临时暂停只恢复原先仍为播放意图的会话；用户主动暂停不会被后台回到前台、解除菜单或迟到数据结果唤醒。视口尺寸变化会使当前计时归零，并等待宿主确认新布局准备完成。

当前页面内异步文字／图片是否已经适合阅读由宿主负责。SDK 不从任意 UIView 推测渲染完成；宿主可用独立暂停原因，例如 `setSuspended(true, reason: "content-rendering")`，在渲染完成后配对解除。

## 异步邻页与独立就绪令牌

provider 返回 waiting、failed、窗口 end、latestAvailable 或其他暂不可继续边界时，自动驱动只查询一次，随后停止时钟，避免每帧或每个间隔反复发请求。只有确认 endOfBook 才结束；最新内容和加载失败不会当作完结。

`contentRequestToken` 与页码用的 `metadataToken` 分开：

- 新的邻页查询、成功切页和实际视口变化会更新内容令牌。
- 单纯更新页码／边界统计不改变内容令牌。
- 当前内容身份、renderer 代际、请求代际全部匹配时，才接受就绪通知。

典型接法是在 `onUnavailable` 返回后续任务时保存当前内容令牌：

```swift
// 在宿主读取／排版前捕获，而不是完成后读取一个新令牌冒充旧请求。
let expected = paged.contentRequestToken
// 宿主异步工作结束，回到主 actor 并验证自己的源数据版本：
try paged.notifyContentAvailable(expectedToken: expected)
```

该调用允许等待状态继续查询 provider；已消耗本页停留时间时会在下一次时钟 tick 尝试翻页，不在通知函数内同步强行跳页。主动暂停或停止意图不变；已经 finished 的会话仍需要显式 start。

在 onUnavailable、onTransition 或自动状态通知的同步回调内部直接重新开始／恢复／通知就绪会被门禁拒绝；异步结果应在回调结束后的主 actor 事务处理。所有真正的数据读取、排版、取消与缓存仍由宿主完成。

## 生命周期与退出

分页自动驱动复用已有 ReaderDisplayLink 弱代理和资源析构策略。离屏或应用失活停钟；invalidate 会停钟、清理系统观察和回调。多原因暂停以及 `PageTurnViewController` 的退出令牌机制同时适用于分页模式。

计时结束触发的页面提交仍先发送 commit／settle，再发布新页状态。宿主在这些通知中暂停或退出时，不应再被自动驱动的外层调用恢复。

## 验证与示例

新增分页自动测试覆盖实际时钟推进、一次性等待、主动暂停、多原因暂停、计时保留与清空、动画时间排除、手动翻页重置、末页与最新区分、请求令牌、后台／离屏、尺寸变化、新布局就绪、非法间隔、provider 错误和可取消退出。

最终验证：**182 项完整 iOS Simulator 测试、25 项本轮 ASan 测试、46 项 macOS 纯逻辑测试全部通过，零失败、零跳过**。25 项包括分页自动阅读 13、平移 10、自动状态回归 2。平移的真实动画完成和中途失效用例实际运行，未触发 Reduce Motion 跳过。SDK complete 严格并发、Swift 警告视为错误构建和示例构建均通过，无 Swift 源码编译警告。

本轮一次复核后修复两项具体问题：目标页在挂载回调中取消后自动状态可能停在 turning；provider 添加临时暂停被错误记为内容失败。新增测试分别直接检查取消后的真实时钟恢复，以及解除临时暂停后继续查询并完成翻页。

ASan 库与测试模块带 sanitize=address 编译，测试进程实际注入 ASan 动态库，未报告内存访问错误。该检测不等于独立泄漏分析。Xcode 仍有未使用 AppIntents 的工具提示及内部 invalidDigitCount 诊断；旧富文本测试有 TextKit 兼容模式提示，均未导致失败。运行设备为 iOS 18.6 iPhone 16 Pro Simulator，部署基线未升级。

已检查 6 张测试中间帧：横纵 next／previous，以及两张真实异步富文本平移。独立示例实际启动自动阅读，并经过第三页延迟供给后到达 8/8 页，显示“已到全书末尾”。这些验证不代表真机触摸手感或全部渲染器兼容。

会话 scratch 证据：`page-turn-paged-full.log`／`.xcresult`、`page-turn-paged-asan.log`／`.xcresult` 及诊断目录、`page-turn-paged-core.log`、`page-turn-paged-strict-final.log`、`page-turn-paged-demo.log`。平移截图位于 `page-turn-slide-attachments/`，示例截图为 `page-turn-paged-demo.png`。证据文件不作为 SDK 发布资源。

独立示例入口为 `ReaderDemo --paged-modes`，可选择平移／覆盖／无动画及方向，提供自动阅读操作，并模拟邻页延迟供给。无效组合显示错误并保持原配置，不静默降级。添加 `--auto-start` 可启动演示计时。

本轮不包含仿真与拱页实现、真实 App 适配、生产字符／PDF 锚点转换或真机手感／性能承诺。
