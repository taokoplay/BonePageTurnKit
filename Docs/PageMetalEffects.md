# 整页 GPU 翻页效果（burn / glitch / fold / shatter / inkwash / icecrack / wave）

七个整页 GPU 效果共用统一渲染器 `PaperEffectMetalRenderer`（MetalKit）：
当前页与目标页快照各上传一张纹理，全屏两三角形一次 draw call；动画全部在
fragment shader 内计算，每帧只更新 uniform——CPU 无逐像素工作。视觉参数
与 [page-turn-lab](../../../page-turn-lab/) 的 `video-study/effects.js` 参考
实现逐项对齐；着色库由 `PaperEffectMetalShaderTests` 在 Metal 设备上编译验证。

## 效果一览

| 效果 | 标识 | 参考实现 | 拖动减速 | 收尾倍率 | 方向语义 |
| --- | --- | --- | --- | --- | --- |
| 火焰烧穿 | `burn` | `createBurn` | 0.5× | ×1.75（约 630ms） | 触点即起火点 |
| 电视故障 | `glitch` | `createGlitch` | 1× | ×2.95（约 1.07s） | 上一页播放整段镜像：条带交接次序上下颠倒、扰动反向，正文不翻转 |
| 折纸翻页 | `fold` | `drawFold` | 1× | ×1.55（约 560ms） | 反向播放整体镜像（折面向右），正文不翻转 |
| 碎片飞散 | `shatter` | `drawShatter` | 1× | ×1.55（约 560ms） | 碎片纯沿翻页方向飞散（下一页向左、上一页向右，不坠落），纵向沿上下飞散；几何路径渲染保证满帧 |
| 水墨晕染 | `inkwash` | `createInkWash` | 0.5× | ×2.08（约 750ms） | 触点即落墨点（两方向都不镜像），拖动中原点跟随手指；墨锋半径始终包含手指 |
| 破冰融霜 | `icecrack` | `createIceCrack` | 0.5× | ×2.22（约 800ms） | 触点即裂源（两方向都不镜像），冰缝放射蔓延；拖动中原点跟随手指——手指滑到哪里裂到哪里 |
| 浪潮 | `wave` | `createRipple` | 0.6× | ×2.35（约 850ms） | 浪锋与浪花跟随手指（取指尖与扫过锋线中更靠前者），松手后锋线继续推进完成交接；水纹翻页更名为浪潮 |

## 交互与时长

- 无角点姿态：不构造 `PaperCornerDrag`、不使用 `PaperCornerMetalRenderer`，
  全部走位移驱动的整页事务（与火焰烧穿既有契约一致）。
- 触点原点：拖动＝手指按下位置；点击分区／按钮／自动阅读＝移动方向侧的
  页缘中点。水墨与破冰的原点全程跟随手指（`originFollowsFinger`），分区点击
  与快速连滑排队也从最近触点起墨／起裂；火焰始终从运动侧页缘中点起火。
- 拖动减速与提交门槛同比缩小（门槛 = 0.17 × 减速系数），保持相同的物理
  提交距离；快速点击默认按序排队不丢弃，宿主开启 `handsOverActiveTransitionOnNewIntent` 后立即衔接（仿真／拱页另有幽灵堆叠：旧收尾层继续播完），翻页节奏与系统卷页一致。
- 原生收尾：`driveNativeRelease` 由 GPU 图层时钟驱动（与仿真／拱页同一机制）。
- 设备不支持 Metal 时：`hasResources == false`，翻页自动降级为无动画跳页。

## 快照

两张整页快照受 `PaperRenderingOptions.maximumSnapshotPixels` 预算约束
（示例默认机型自适应，见 FullScreenDemo.md），纹理按快照原生分辨率上传，
正文全程清晰。折纸／故障／浪潮等镜像类效果只在着色器内部镜像动画坐标，
页面正文保持正向，不做纹理翻转。
