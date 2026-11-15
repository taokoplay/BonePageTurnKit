# 系统仿真翻页（SystemCurlReaderViewController）

`SystemCurlReaderViewController` 把 Apple 的 `UIPageViewController(.pageCurl)` 包进本库，
提供与自研 `curl` 并列的“系统卷页”实现，用于观感对照或最小接入。

## 能力边界

| 能力 | 自研 `curl`（`PagedReaderViewController`） | 系统仿真（本类） |
| --- | --- | --- |
| 页切换 | `turn(_:animated:)`、`show(from:)` | `setCurrentIndex(_:animated:)` |
| 交互进度 / 半翻预览 | 有（`updateInteractiveTurn`） | **无**（容器内部控制） |
| 程序化取消 / 完成 | 有（`cancelTransition`、`endInteractiveTurn`） | **无** |
| 事务事件三元组 | `willBegin / didCommit / didSettle` | 仅 `onTransitionStateChange(Bool)` 与 `onPageChange` |
| 快照像素预算、纸背/阴影参数 | 可配置（`PaperRenderingOptions`） | **不可配置** |
| 连翻排队与手速加速 | 有（32 笔队列 + 自适应时长） | **无**（系统固定节奏，实测约 467 ms/次） |
| 手势门禁（`shouldBeginPan`/`shouldHandleTap`） | 有 | **无**（全部交给系统容器） |
| 页码与总页数 | `readingStatus.pagination` | `currentIndex` / `pageCount` / `setPageCount(_:)` |

需要上表中任一“无”的能力时，用自研 `curl`；两者可以在同一 App 里并存，按场景选择。

## 最小接入

```swift
let reader = SystemCurlReaderViewController(pageCount: pages.count, initialIndex: saved)
reader.pageProvider = { index in pages[index] }
reader.onPageChange = { index in saved = index }
reader.onTransitionStateChange = { isTurning in controls.isHidden = isTurning }
addChild(reader); reader.view.frame = view.bounds; view.addSubview(reader.view); reader.didMove(toParent: self)
_ = reader.setCurrentIndex(3, animated: true)
```

示例工程里「翻页 → 系统仿真」与 `--system-curl [--autoplay]` 都使用这个类。
