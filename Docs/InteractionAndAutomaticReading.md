# SDK 通用交互与连续自动阅读

本轮在 BonePageTurnKit 内补充通用能力，未接入 ParsingBook，也未搬入 CoreText、图片解码或 PDF 排版业务。新增连续自动阅读、可配置分页点击和可取消退出协同；已有异步窗口、内容绑定和稳定位置机制继续使用。

本文保留连续自动阅读与通用交互阶段的记录。后续已实现 [横纵平移与分页自动阅读](SlideAndPagedAutomaticReading.md)，文末“分页定时驱动未实现”是本阶段结束时的历史状态，当前接口以链接记录与 README 为准。

## 连续自动阅读

```swift
try continuous.startAutomaticReading(pointsPerSecond: 30)
continuous.pauseAutomaticReading()
try continuous.resumeAutomaticReading()
continuous.stopAutomaticReading(commitPosition: true)
```

- 只沿纵向向后推进，速度为有限的 `(0, 2000]` point/s。
- 使用真实 CADisplayLink；有独立高精度累计位置，再按屏幕像素对齐显示，避免低速时逐帧舍入损失。
- 每帧积压最多计入 0.1 秒；暂停、离屏或后台恢复不补跑过去时间。
- 正常推进不调用 restore、不增加窗口 revision，也不会使正在加载的票据每帧过期。
- 显式 restore 是新的导航意图，会停止自动阅读并按既有规则使旧窗口请求失效。
- 内部查询下一未就绪块的边界采用二分索引；不会每帧扫描整本窗口。
- 视口变化后等待宿主安装新布局；已被隐藏的旧排版统计不会作为新布局继续推进的依据。

### 状态与边界

`automaticReadingState` 和 `onAutomaticReadingStateChange` 提供：

| 状态 | 行为 |
| --- | --- |
| stopped | 用户已停止；加载或恢复前台不会启动 |
| running | 正在推进真实内容视图 |
| paused | 用户主动暂停，或因交互／外部原因暂时暂停 |
| waiting(boundary) | 等待内容或边界处理；停止时钟，保留继续阅读意图 |
| finished(endOfBook) | 已到宿主确认的全书结尾；需要显式 start 才开启新会话 |

`available`、`loading`、`failed`、`unknown`、旧窗口 `end`、章节末尾及 `latestAvailable` 都属于等待，不能当作全书结束。连载追加内容或占位变 ready 后，仍为播放意图的会话会继续；用户主动 pause 后则保持暂停。

自动阅读会停在窗口内未就绪内容前。可见区已经包含占位时不会倒退，也不会自动跳过它读取后面的块。真正结束的判断保留一个物理像素的几何容差，避免不可整除的内容高度造成末端空转。

### 暂停与保存

- 手动拖动、减速、离屏、应用失活会暂停实际时钟；这些原因解除后只恢复原本仍有播放意图的会话。
- `setSuspended(_:reason:)` 可为菜单、选区、缩放、外部退出分别设置原因。解除一个原因不会覆盖其他原因。
- `pauseAutomaticReading()` 是用户主动暂停；临时原因解除或迟到加载结果不能将它唤醒。
- `stopAutomaticReading(commitPosition: true)` 尝试提交有效稳定位置；全书结束也尝试提交。自动每帧只发布可见位置，不逐帧保存。
- 回弹、拖动、未就绪内容仍不能成为稳定保存位置。SDK 不写数据库，宿主把有效锚点转换为语义位置并保存。
- 原 SDK 的暂停文案“恢复不会自动开始滚动”仍适用于此前未启动过的会话；对于正在自动阅读后被临时暂停的会话，本轮明确支持恢复原播放意图。

CADisplayLink 使用弱 target 代理；私有资源生命周期对象在析构时失效系统时钟，不读取 UIKit 状态。没有使用 unchecked Sendable 或关闭并发检查。

## 分页点击

默认关闭点击分区，宿主显式启用：

```swift
paged.tapConfiguration = try ReaderTapConfiguration()
paged.shouldHandleTap = { point in
    // 宿主先检查链接、图片或选区；已消费时返回 false。
    true
}
paged.onCenterTap = { point in
    // 向宿主通知中心区域动作，SDK 不创建业务菜单。
}
```

默认前 1/3 为 previous、中间为 center、后 1/3 为 next。沿当前分页 axis 归一化，支持横向和纵向；可用 previousEnd、nextStart 配置边界。非法、非有限或倒置分区明确报错，非法点击坐标不消费。

程序入口 `handleTap(at:animated:)` 与内置 UITapGestureRecognizer 使用同一处理路径；tap 等待 pan 失败。分页忙碌、挂载、回调或多原因暂停期间不接受重入。宿主 veto 回调返回后再次验证生命周期、暂停及配置，不能在失效后继续翻页。

已有 UIControl、启用滚动的内层 UIScrollView 避让继续生效；`shouldBeginPan` 可由宿主进一步处理缩放、选区与内容优先级。精确文字命中、选区绘制、菜单、链接跳转属于渲染器／宿主；本轮没有新增这些业务实现。

## 统一暂停与可取消退出

`PageTurnViewController.setSuspended(_:reason:)` 将外壳原因传递给当前及准备中的 renderer，切换模式后也保留未解除原因。转发过程中如果回调同步改变原因，会重新读取最新集合，避免给候选容器留下旧暂停。

```swift
let token = container.beginExit()       // 暂停，保持 renderer 与已登记任务
container.cancelExit(token)            // 只解除此次退出暂停

container.onExitFinalized = { token in
    // 有效位置已尝试提交，renderer 已失效，宿主在这里执行导航。
}
container.finishExit(token)
```

示意代码中的 cancel 和 finish 是两条可选分支，不能先 cancel 再用同一 token finish。

- 重复 beginExit 返回当前同一令牌；不同容器或已经结束的旧令牌不能操作新会话。
- 确认退出期间不接受切换模式或重复结束；其他菜单／选区暂停在取消退出后仍保留。
- finishExit 返回值表示退出请求被接受。如果在状态或位置回调中调用，会等当前通知结束，再提交位置和失效容器。
- 实际完成以 `onExitFinalized` 为准；不能在通知中调用 finishExit 后立即假设 renderer 已失效。
- 显式 invalidate 仍表示立即失效，不承担先保存位置的承诺。
- SDK 不执行导航 pop、试读加入书架、关闭文件或数据库保存。宿主须保留自身异步业务的退出协调。

## 独立示例

打开 `Examples/ReaderDemo.xcodeproj`，ReaderDemo 启动参数加入：

```text
--interactions --auto-start
```

不加 `--auto-start` 时手动点“开始”。示例提供点击翻页／连续自动阅读、开始／暂停／恢复／停止、菜单暂停以及开始／取消／确认退出。边缘读取延迟 1 秒，分批安装至 8 段后显式标记 endOfBook，演示等待内容与最终结束。

## 验证与本轮修复

新增测试覆盖速度和窗口令牌保持、稳定提交、非法速度与长帧限制、占位阻挡、可加载边界、最新／失败／未知边界、主动暂停、多原因暂停、拖动和减速、离屏／后台、显式定位停止、实际 CADisplayLink、退出令牌、点击分区和回调重入。

开发中实际发现并修复：

1. 逐帧直接累加到 UIScrollView 会丢失小数位移：改用独立精确累计，验证 60／120 帧推进的距离一致。
2. 立即在同一调用片段断言窗口销毁会早于 UIKit 清理：将容器释放检查安排到下一主线程轮，另外独立验证运行中的时钟对象可释放。
3. 主 actor 时钟析构访问非 Sendable 系统句柄不符合严格并发检查：用私有资源生命周期对象收口释放。
4. 状态回调中解除暂停可能误拒绝待安装窗口：安装避让自动状态通知，最外层通知结束后重新安排。
5. 书尾回调中确认退出可能清掉待保存位置：先完成位置提交，再交付最终退出通知。
6. 暂停转发重入后可能给候选加回已解除原因：转发时重新读取当前原因集合。

最终验证：**完整模拟器回归 124 项、交互相关 ASan 29 项、macOS 纯逻辑 36 项全部通过**。29 项包括自动阅读 12、退出协同 4、分页点击 10、同步重入回归 3。库与测试采用 Swift 警告视为错误编译，无 Swift 源码警告；SDK 的 complete 严格并发构建和示例构建均通过。示例已在模拟器安装并启动。

ASan 构建和测试进程均实际启用地址检测，未报告内存访问错误；该检查不代替独立 Leaks 分析。测试工具仍有未使用 AppIntents 的元数据提示、Xcode 内部 invalidDigitCount 诊断，以及此前富文本测试的 TextKit 兼容模式提示，未影响测试通过。运行目标为 iOS 18.6 iPhone 16 Pro Simulator，部署基线保持 iOS 15／Swift tools 5.9。

最终会话 scratch 证据：`page-turn-interaction-final.log`／`.xcresult`、`page-turn-interaction-final-asan.log`／`.xcresult` 与诊断目录、`page-turn-interaction-final-core.log`、`page-turn-interaction-final-strict.log`、`page-turn-interaction-final-demo.log`。示例启动截图为 `page-turn-interaction-demo.png`。这些证据不作为库资源分发。

## 仍未包含

本轮不是现有 App 接入，也不是全部首版功能完成。其余翻页后端、生产字符／PDF 语义锚点适配、跨块选区绘制、复杂内层缩放策略、真机触摸和长篇／大图性能仍需后续实现或集成验收。分页的定时自动翻页驱动也未随本轮新增，当前自动阅读实现针对连续模式。
