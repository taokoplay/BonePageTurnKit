# 高刷新率与 ProMotion

Reader Demo 与 BonePageTurnKit 的活动显示时钟现在向系统申请当前窗口屏幕支持的最高刷新率。目标仍为 iOS 15、Swift 5、Swift tools 5.9；没有新增依赖或按设备名称判断。

## 启用方式

应用必须在最终 Info.plist 中包含布尔值：

```xml
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

Demo 使用显式 `Examples/ReaderDemo/Info.plist`，Debug 与 Release 都指向此文件，并由 Xcode 合并其余自动生成的应用字段。仅设置任意 `INFOPLIST_KEY_CADisableMinimumFrameDurationOnPhone` 在本项目的自动生成方式下没有输出到包内，因此验收必须检查实际构建产物，不能只查 build setting。

SDK 的 `ReaderDisplayLink` 读取实际屏幕的 `maximumFramesPerSecond`。120Hz 屏幕申请 `minimum: 80 / maximum: 120 / preferred: 120`；60Hz 屏幕申请 `60 / 60 / 60`。窗口移动或运行中重新申请时只更新帧率范围，不重建时钟、不重置上一个时间戳；空闲、暂停与退出仍彻底停止显示时钟。

四角 GPU 提交、纸张松手收尾、分页自动阅读以及连续自动滚动都传入当前窗口屏幕的上限。翻页动画仍按秒推进，自动滚动仍按点／秒推进；帧率提高不会让翻页停留时间或滚动速度翻倍。内容、阴影、快照预算、复用和业务门禁保持原有契约。

## 申请与实测

帧率范围是向系统提出的调度请求。系统仍可根据设备能力、电量、温度及系统限制调整交付频率；`maximumFramesPerSecond == 120` 或 `preferred == 120` 均不能替代实际呈现数据。

`testRecordMetalHighRefreshCadence` 是独立的高刷真机用例：检查应用实际 Info.plist 布尔值与屏幕最高能力，按最高值驱动三秒（iPhone 13 Pro 为 360 次输入），记录 CADisplayLink 的真实帧间隔、Metal 的 `presentedTime`、CPU 编码耗时、电量模式和温度状态。它不会用原有固定 60Hz 测量结果充当 120Hz 验收。每帧预算在 120Hz 时约为 8.33 ms。

旧 `testRecordMetalDisplayCadence` 保留固定最高 60Hz 的输入，用于与此前结果对比。硬件测试在模拟器跳过，不从模拟器录像或离屏绘图耗时推导真机帧率。

## 本轮验证

完整 SDK 回归共 452 项：448 通过、0 失败、4 项真机性能测试在模拟器按条件跳过（`reader-high-refresh-sdk-full`）。新增三个高刷时钟检查通过，Release 的全屏启动及菜单显隐流程另有 1 项原生 UI 检查通过（`reader-high-refresh-ui`）。构建启用严格并发及 Swift 警告视为错误。

Release 真机包构建和严格签名验证通过；最终 Info.plist 的高刷键经解析确认为 Bool true，最低系统保持 iOS 15，Scene Manifest 保留。40 个 SDK／Demo 源码文件及源 Info.plist、PBX 的构建前后哈希一致；包中同时包含前一轮最新接触阴影修复。

首次设备连接不可用时，高刷新率真机测试未启动，安装尝试返回 CoreDevice 4016。设备重新连接后，最新版高刷 Release 包已成功安装到 iPhone 13 Pro，以 `--fullscreen-reader` 启动，并在设备进程列表中核对到同一本次安装路径及进程标识；保留 Demo 设置。本包同时包含最新接触阴影。安装、启动及进程证据为 `reader-high-refresh-phone-install-v2.json`、`reader-high-refresh-phone-launch-v2.json`、`reader-high-refresh-phone-processes-v2.json`。本次完成安装，重新连接后没有额外执行硬件帧率测试；尚无 120Hz 实测数据，此前 60Hz 数据保留其原构建与工作负载范围。scratch 的 ProMotion hosted 测量工程和独立高刷测试保持可用。

结果文件为 `reader-high-refresh-sdk-summary.json`、`reader-high-refresh-ui.summary.json`、`reader-high-refresh-package-verification.json`、`reader-high-refresh-hardware-status.json` 与 `reader-high-refresh-phone-install.log`。

## 渐变投影版本的真机状态

当前渐变投影版本通过 33 项针对性回归，并完成签名 Release 构建、包内高刷键和 54 项构建输入哈希核对。新包已以更新方式安装到 iPhone 13 Pro，未重置设置；启动因设备密码锁定返回 CoreDevice 10002／Locked。

独立 ProMotion hosted 测试已完成 Release 编译与签名，但 Xcode 在运行前提示 deviceprep -3／Unlock to Continue；随后 CoreDevice 的新鲜 `lockState` 查询仍为 `passcodeRequired: true`。结束等待后，xcresult 将宿主错误 `Testing was canceled` 记录为 1 项失败；实际测试体未启动，360 次输入与 drawable 呈现采样均未执行。因此本轮仍无 120Hz 实测数据。完整阻塞、原日志和结果包均保留在 `corner-shadow-taper-hardware-status.json`、`corner-shadow-taper-high-refresh.log` 及 `.xcresult`；临时测量宿主已卸载。
