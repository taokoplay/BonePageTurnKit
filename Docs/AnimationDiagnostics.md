# 翻页动画参数与刷新率诊断

Demo 中选择 **调试 → 帧率诊断（翻页时观察）** 开关浮层。它只统计当前翻页期间的回调，翻完后保留上一页结果。**调试 → 复制动画诊断日志** 可复制最近 200 条参数和回调帧率摘要。启动参数 `--frame-diagnostics` 可直接开启，不重置阅读设置。

浮层分别显示：

- **屏幕上限 / 申请 Hz**：设备能力及诊断时钟的申请值，不是实际帧率。
- **回调 FPS**：翻页期间主线程 CADisplayLink 实际回调间隔的统计；翻页中显示最近 240 个间隔，结束后显示整次平均。仅统计连续收到的回调，不把翻页结束后的宿主处理、空闲时间或开关诊断的间隔算入；不足两个回调时显示“—”。
- **GPU 呈现 FPS**：原生 Metal drawable 呈现时间戳的最近 512 帧统计，呈现总数持续累加。模拟器、软件绘制或样本不足时显示“—”，不伪造为 120FPS。当前只对自定义 Metal 纸角路径提供此数据，系统仿真及 UIKit 平移／覆盖不提供 GPU 呈现统计。
- **avg / p95窗 / max**：回调帧间隔，单位毫秒。avg、max、超预算与估计缺帧保留整次翻页累计，p95窗使用最近 240 个间隔；长拖动不会丢失早期的最大尖峰。
- **超预算 / 估计缺帧**：按申请帧率估算。120Hz 预算约为 8.33ms；系统主动降频也会造成超预算，因此它不是卡顿原因的自动判定。
- **动画参数**：效果、方向、进度、队列长度、计划时长、准备耗时（内容提供者、排版和快照／纹理准备）、更新次数、GPU 提交次数、结束原因。

## SDK 使用

```swift
reader.animationDiagnosticsEnabled = true
let latest = reader.animationDiagnostic
let recent = reader.recentAnimationDiagnostics
reader.animationDiagnosticsEnabled = false
```

默认关闭，关闭后停止采集呈现数据并保留最近记录。重新开启从新采样代次开始，不跨越未采集的时间计算 GPU FPS，并拒绝旧代次的迟到回调。SDK 最多保留 180 条；高频进度和等待记录限为约每 100ms 一条，不改变动画时长、队列或推进规则。页面准备耗时另列，不混入回调 FPS；这些统计帮助定位原因，不能自动断定卡顿来自哪一层。

控制台可按子系统 `com.bone.BonePageTurnKit`、类别 `PageTurnAnimation` 过滤；主线程回调摘要位于 `com.bone.page-turn-demo` / `AnimationFrames`。日志不包含正文和业务凭据。

## 如何判断动画为何不完整

同一段翻页的日志使用相同编号，依次记录 `began → prepared → releaseStarted → frame → finished`；入队时额外记录 `queued`，等不到 GPU 新帧时记录 `waitingForFrame`。

- `finished reason=completed`：正常完成；可对照时长、推进时间、更新／提交／呈现次数。
- `reason=cancelled/suspended/viewportChanged/offscreen/applicationInactive`：在对应进度被取消或中断。
- `reason=handoff`：宿主显式接管；可解释为何上一段未播放到底。
- `reason=snapshotFailure/memoryWarning/invalidated`：资源失败、内存告警或容器失效。
- `reason=unanimated/reducedMotion`：该次有意不播放动画。
- `waitingForFrame` 持续出现且进度不前进：查看 GPU 提交数是否增长。浮层在松手收尾超过 500ms 无进度变化时提示停滞，但不会替宿主取消动画。

GPU 提交与实际呈现是不同口径，不能用主线程回调 FPS 代替呈现 FPS，也不能据模拟器结果宣称真机已达到 120Hz。
