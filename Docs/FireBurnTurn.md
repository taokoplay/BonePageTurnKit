# 火焰烧穿（burn）

火焰烧穿是新增的分页效果：旧页从起火点被烧穿，孔洞沿噪声畸变距离场向外扩大，
孔洞中直接显露相邻页正文，黄色火线与橙色辉光沿孔缘扩散，烧尽后保持完整目标页。
视觉参数与 [page-turn-lab](../../../page-turn-lab/video-study/effects.js) 的
`createBurn()` 参考实现逐项对齐。

## 渲染：Metal

- `PaperEffectMetalRenderer`（MetalKit，与电视故障／折纸／碎片／水墨／破冰／浪潮共用）：当前页与目标页快照各上传一张纹理，
  全屏两三角形一次 draw call；距离场、三级值噪声、火线与辉光配色全部在
  fragment shader 内计算，每帧只更新 40 字节 uniform——CPU 无逐像素工作。
- 起火点由宿主注入：拖动＝手指按下位置；点击分区／按钮／自动阅读＝
  移动方向侧的页缘中点（横向为左右缘、纵向为上下缘，与参考视频的右中起火同构）。
- `direction == .previous` 直接注入上一页纹理与真实触点，不做正文镜像、
  不交换来源、不倒放时间；上一页同样从触点侧烧向远端。
- 半径曲线：`基准边 ×(0.06 + 1.79 × phase^1.4)`，phase(进度, 0.02, 0.97)
  （横向基准为页宽、纵向为页高，孔洞比例两向一致）。起火相位 0.02 即现小火孔，
  火焰全程推进到收尾帧、无静止段，结束与落定自然衔接。孔缘 4.5pt 渐变直露
  目标页，2.5→10pt 橙色热边，10→45pt 渐弱辉光（alpha 68×glow²）。
- 设备不支持 Metal 时：`hasResources == false`，翻页自动降级为无动画跳页。

## 交互与时长

- 点击／按钮／自动阅读：收尾时长 ×1.75（整页点击约 630ms），保留排队、
  快速连翻与取消语义；诊断 HUD 显示 `burn next/previous 进度 … finished / completed`。
- 拖动：起火点＝按下位置，位移驱动，拖动进度减速 0.5×（只缩放本次手势的
  新增位移），提交门槛同比缩小为 0.085，保持与折纸相同的物理提交距离。
- 原生收尾：`driveNativeRelease` 由火焰图层时钟驱动（与仿真／拱页同一机制），
  Release 实测回调 114–121FPS 满帧。
- 无角点姿态：不构造 `PaperCornerDrag`、不使用 `PaperCornerMetalRenderer`；
  诊断浮层的 GPU 呈现字段对本效果显示 “—”。

## 快照

两张整页快照仍受 `PaperRenderingOptions.maximumSnapshotPixels` 预算约束
（示例默认机型自适应，见 FullScreenDemo.md），纹理按快照原生分辨率上传，
正文全程清晰。

## 无人值守录制

`--burn-autoplay` 启动参数：定时（0.45s 间隔）连续驱动火焰翻页，便于录屏与
逐帧验收；与 `--curl-autoplay` 同一机制。

## 验收（iPhone 15 Pro Max，Release）

- 双向点击翻页：`burn next 48%→100% finished/completed`、
  `burn previous 13%→100% finished/completed`，页码 1→2→1 同步更新。
- 平滑曲线冒烟：150/400/650ms 三帧火焰全程推进，100% 后 finished/completed
  与页码同步；全程回调 114–117FPS。
- 纵向冒烟：`burn next`（纵向推进、页缘起火）由 UI 冒烟测试覆盖，
  双页（spread）与单页共用全屏纹理管线，中缝无特殊处理。
- 回调帧率 114–121FPS（avg 8.2–8.8ms），无黑场，孔洞直露下一页，正文正向。
- 全量 SDK 回归 167 项：失败集与本改动前基线完全一致（macOS 目的地的
  SlidingSpreadContactTests 既有失败），零新增回归。
