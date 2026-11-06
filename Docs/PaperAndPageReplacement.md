# 纸张曲面与当前页原位替换

> 本文保留单页纸张与回填阶段的验收快照。后续已实现纵向纸张、中央双页、漫画切片与缩放交接，最新能力和测试数见 [扩展阶段记录](SpreadComicAndZoom.md)；下文的拒绝组合和测试数是当时状态。

本阶段补齐 BonePageTurnKit 的单页横向仿真 `curl`、拱页 `arch` 和当前页回填。保持 iOS 15、Swift tools 5.9、Swift 5 语言模式、UIKit、无第三方依赖。所有改动位于 SDK、独立示例和测试；尚未接入 ParsingBook。

## 支持范围

| 配置 | 当前行为 |
| --- | --- |
| `paged(curl, horizontal)` | SDK 自有 CoreGraphics 圆柱卷曲，包含背面、曲面明暗和边缘阴影 |
| `paged(arch, horizontal)` | 整页压缩、拱起和波形投影，不与 slide 共用平面位移 |
| 纸张 `automatic` | 按 `minimum` 解释 |
| 纸张 `minimum` / `maximum` | 左／右书脊；镜像几何及 pan、tap 映射，不反转宿主的 previous/next 内容关系 |
| 纸张 `center` | 明确抛出 `unsupportedSpine`；双页编排尚未实现 |
| 纵向 curl / arch | 明确抛出 `unsupportedPresentation` |
| 非纸张显式书脊 | 明确拒绝，仍只接受 automatic |

`PageTurnConfiguration.supportedSpines(for:)` 与 `validate()` 共用能力声明。该后端不使用私有 UIKit API，也不承诺与系统 pageCurl 或原 App Metal 拱页逐像素、帧率一致。采用有限条带近似；真机交互手感和帧率仍需专项验收。

```swift
let configuration = PageTurnConfiguration(
    presentation: .paged(effect: .curl, axis: .horizontal),
    spine: .minimum,
    paper: PaperRenderingOptions(
        maximumSnapshotPixels: 4_194_304,
        stripCount: 128
    )
)
try configuration.validate()
```

## 事务、真实页面与快照

纸张效果复用 `PagedReaderViewController` 的唯一翻页事务，不再建立第二套页面状态机。开始时挂载真实当前页和目标页，布局后捕获临时快照；动画期间隐藏真实视图，由曲面显示固定的捕获结果。异步内容仍可在真实视图内更新，但不会在同一纸张动画途中突然换图。成功后展示目标真实视图，取消后恢复原真实视图，立即释放快照、条带、overlay 与动画时钟。

- `willBegin` 表示已建立事务；只有成功提交才有 `didCommit`，成功／取消均有一次 `didSettle`。
- 纸张交互按整页宽度归一化，位移达到 17% 或正向速度达到 500 point/s 可完成；反向速度不高于 -500 point/s 优先取消。
- 收尾使用 CADisplayLink 和三次 ease-out，单帧时间最多计入 0.1 秒；不追赶后台积压。
- `animated: false` 与系统 Reduce Motion 路径不创建纸张快照。Reduce Motion 不改变配置选择。
- resize、外部暂停、离场、退后台、失效都会取消纸张事务；内存告警同时主动暂停自动阅读，避免马上再次分配快照。
- 快照失败抛出 `snapshotUnavailable` 并取消事务，保留原页，不静默切换为 cover 或 slide。
- 使用 `CALayer.render(in:)` 捕获。常规 UIKit 文字、图片、附件已验证；视频、Metal、远程合成图层等不保证可以完整捕获，宿主需预先提供可捕获的页面或显式选择其他效果。

两个端点直接绘制原始快照。卷页未弯曲的平面区域也直接采样整图，保持静止文字；弯曲区的核心材料条带按整数源像素划分，左右各保留最多两个采样像素，关闭逐条几何边缘抗锯齿，避免底页从接缝透出。右书脊只镜像投影；稳定文字方向保持正确，卷到背面的淡纹理才水平反向。

## 资源预算

`maximumSnapshotPixels` 是两张原始快照的合计像素数，默认 4,194,304，允许 65,536...16,777,216；最长边不超过 4096，倍率不超过屏幕 scale。先计算整数像素计划再分配画布，过大页面先降采样。`stripCount` 默认 128，允许 32...256；位图极窄时实际条数会减少。

标准 RGBA 下默认两张原图的像素数据约 16 MiB。CGImage 条带可能共享原图，也可能另建存储，后者增加约一张移动页、两侧采样像素和行对齐开销；CoreGraphics 上下文、显示缓冲和宿主真实内容不包含在此预算中。SDK 不缓存跨页纸张位图，也不承担宿主图片／PDF 解码预算，不能将这个配置当成整个阅读器的内存上限。

## 当前页原位替换

`currentPageBinding` 专用于当前内容回填，与统计用的 `metadataToken`、邻页就绪用的 `contentRequestToken` 分开。单纯邻页查询或页码更新不会使当前绑定失效；成功切页、替换和视口尺寸变化会换代。

候选页必须未挂载、不是当前控制器或容器祖先；源 ID 必须相同，内容和布局版本不得倒退。允许重新分页后的 unitID 改变，但新页应当是宿主解析语义位置后的当前内容。SDK 不计算字符位置，也不判断同源中哪个章节位置应该作为回填结果。

```swift
let binding = paged.currentPageBinding
// 内容侧异步读取／排版，回到主 actor：
let ticket = try paged.submitCurrentPage(
    replacementPage,
    expectedBinding: binding
) { outcome in
    switch outcome {
    case .installed(let installedBinding):
        // 此时实际安装完毕，可以更新宿主状态。
        print(installedBinding.identity)
    case .superseded, .cancelled, .invalidated:
        break
    case .rejected(let error):
        // 例如用户已经切页，或视口改变；按新语义位置重新准备，不复用旧绑定。
        print(error)
    }
}
// 在真正开始安装前可取消，已安装的请求返回 false：
// paged.cancelPageReplacement(ticket)
```

- `replaceCurrentPage(_:expectedBinding:)` 是立即、原子的替换。交互、暂停、宿主同步回调或挂载期间返回 `interactionInProgress`，提交前失败保持旧页。
- `submitCurrentPage` 只保留最新一项已准备页面。被新请求覆盖者立即收到 `superseded`；其他终态为 installed/cancelled/invalidated/rejected，均只有一次。
- 翻页、暂停或通知期间提交会延期，所有暂停原因解除并且事务稳定后才安装。取消翻页仍是原绑定，可安装回填；翻页成功后旧回填被拒绝。
- 提交成功后发送独立 `onPageReplacement`，不伪造翻页 `didCommit`，renderer 身份不变。回调中的失效不会把已经成功的替换改写为 invalidated。
- 候选加载／挂载阶段重新检查活跃状态、尺寸、暂停和绑定；捕获旧版结果不能通过改读当前 token 强行安装。
- 替换重置本页停留时间、清除旧等待，保留用户 running/paused/stopped 意图。提交回填后的 loading 等待是展示协调，不会替宿主启动网络请求。
- completion 是主 actor 同步终态通知，禁止在其中立即发起另一笔替换；需要重试时安排到下一主队列事务。宿主仍需取消自己的解析任务，且闭包应使用弱捕获。

## 独立示例

`Examples/ReaderDemo.xcodeproj` 中的分页示例提供五种效果、两个轴向、四个书脊选项、自动阅读及以下操作：

- **回填本页**：捕获当前绑定，一秒后提交新版本，展示成功、过期、覆盖或取消结果。
- **半翻预览**：启动真实交互事务并停在 45% 进度，便于观察曲面或模拟回填。
- **取消翻页**：恢复真实当前页，同时让待安装回填继续处理。

启动参数 `--paper-curl`、`--paper-arch` 直接打开相应模式；`--right-spine` 选右书脊，`--paper-preview` 停在中间帧，`--auto-start` 开启定时翻页。`--paged-modes` 仍从横向平移开始。非法组合显示错误并恢复上次成功配置。

## 验证与限制

覆盖配置／预算纯逻辑、真实 UIKit 绘图、容器事务、异步当前页回填四部分。包含两效果 × 双方向 × 左右书脊、唯一终态、真实 CADisplayLink、pan/tap 映射、反向取消、非零 bounds、捕获失败／重入、resize／内存告警／离场／后台、120 次成功取消、延迟回填、自动阅读、异步富文本与图片、时钟和资源释放。另以像素比较验证平面文字及条带无底页透缝。

最终结果（2026-11-06）：**226 项完整 iOS Simulator 测试、44 项本轮 ASan 测试、56 项 macOS 纯逻辑测试通过，零失败、零跳过**。完整 iOS 测试构建同时启用 `SWIFT_STRICT_CONCURRENCY=complete` 和 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`；SDK 独立严格并发构建及 ReaderDemo Release 严格并发构建也通过。运行环境为 iPhone 16 Pro / iOS 18.6 Simulator，编译器 Swift 6.4，以 Swift 5 语言模式和 iOS 15 部署基线构建。

本轮新增 44 项：原位替换 12、纸张几何 10、真实绘图 9、纸张容器 13。通过实际截图发现并修复条带抗锯齿透缝、平面文字采样失真及阴影半像素漏列；通过一次静态复核修复 `willMove(toSuperview:)` 内取消造成的孤立目标视图，并追加动态回归。ASan 运行日志确认注入 `libclang_rt.asan_iossim_dynamic.dylib`，未报告内存访问错误；`leaksCheckingMode` 为 off，不能据此保证无泄漏。系统 Reduce Motion 开关未单独启用验收，实际动画用例均正常执行。

证据保存在本次会话 scratch：`page-turn-paper-verified.log/.xcresult`、`page-turn-paper-test-summary.json`、`page-turn-paper-asan-verified.log/.xcresult`、`page-turn-paper-asan-summary.json`、`page-turn-paper-asan-diagnostics/`、`page-turn-paper-core.log`、`page-turn-paper-strict.log`、`page-turn-paper-demo-release.log` 与 `page-turn-paper-attachments-final/manifest.json`。可按 README 的构建命令重跑，测试截图由 XCTest 附件生成。

独立 Release 示例已在同一模拟器实际启动：仿真左书脊和拱页右书脊均停在 45% 交互状态并截图；仿真定时自动阅读最终到达 8/8 页，状态为“已到全书末尾”。截图为 `page-turn-paper-demo-curl.png`、`page-turn-paper-demo-arch.png`、`page-turn-paper-demo-finished.png`，浏览页为 `page-turn-paper-demo-preview.html`。目标异步内容在动画开始时尚未就绪，预览保留当时的占位快照；落定后的真实页面显示完成内容，这与冻结快照契约一致。

测试附件保存 37 张中间帧／端点／深色／大尺寸预算截图，并通过浏览器查看实际输出。Simulator 和 Address Sanitizer 不等价于真机帧率、iOS 15 运行时、长期内存压力或独立泄漏检查；原 App CoreText／PDF 生产内容、选区业务、内层缩放以及中央双页编排仍未验收。内容解析、排版、解码缓存、持久化及同步继续由内容侧或 App 负责。
