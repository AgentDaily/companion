# Mac / iPhone 近距离连接：BLE 与点对点 Wi-Fi

调研日期：2026-10-03。只核对 Apple 官方资料；没有进行手机实测，以下选型判断不能当作吞吐量、断线率或耗电测试结果。

## 结论与适用范围

工程判断：Quenda Companion 的主要数据通道优先验证 Apple 点对点 Wi-Fi；BLE 作为低频控制、发现和重连的候选。前者适合把聊天、录音、文件放在统一网络协议中，后者适合小量、间歇数据。不能据此宣称 Wi-Fi 一定更稳定或更省电：用户关心的后台恢复、网络共存和最终能耗都需要真机对照测试。[Apple 网络 API 选型](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)、[网络与蓝牙节能建议](https://developer.apple.com/documentation/xcode/reducing-networking-and-bluetooth-power-usage)

## 先区分三种技术

| 技术 | 对本项目的含义 |
|---|---|
| BLE / Core Bluetooth | 自定义数据通信方案。本次比较不把耳机播放音频的 Classic 蓝牙模式等同于 App 间传录音。Core Bluetooth 当前也列出 BR/EDR 支持，但这不意味着可以把手机和 Mac 自动当作普通耳机链路。 |
| Apple peer-to-peer Wi-Fi | Apple 设备间无需配置共同 Wi-Fi 网络的连接；Network framework 可显式启用，通常与 AWDL 相关。官方未公开其通信协议供第三方实现，不能当成通用 Wi-Fi Direct。 |
| Wi-Fi Aware / NAN | 标准化的另一种点对点 Wi-Fi 技术。当前公开 framework 仅列 iOS / iPadOS 26+，支持 iPhone 12+ 等设备，未列原生 macOS；暂不作为 Mac / iPhone 方案。 |

来源：[Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)、[TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)、[Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware)。

## 稳定性：按负载和系统状态判断

| 场景 | BLE | Apple 点对点 Wi-Fi |
|---|---|---|
| 前台文字聊天 | 可以实现；需设计分包、流控、消息确认。 | 适合使用 TCP / TLS / WebSocket 等网络协议，减少自定义传输协议工作。 |
| 压缩录音持续上传 | 不先否定可行性，实际码率、系统调度、链路吞吐量必须实测。 | 工程上优先验证，能覆盖音频和文件；传输任务仍需队列、校验与断点恢复。 |
| 锁屏、切换 App | 有特定后台事件支持，恢复能力不能等同前台。 | 网络能力不自动授予 App 持续后台运行时间。 |
| 离开后返回、断线重连 | 可用连接请求和状态保存恢复机制。 | 应恢复发现、连接和应用会话，避免依赖一条永不关闭的连接。 |

上表前两行的“适合”属于工程判断，尚无本项目对照结果；接口能力参考 [Core Bluetooth 数据传输示例](https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices)、[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)。后台能力参考 [Core Bluetooth 后台指南](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)、[选择后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)。

BLE 后台扫描会合并发现事件，扫描间隔可能变长；iPhone 当 peripheral 时后台广播也有限制。建议先验证 **Mac peripheral、iPhone central** 的方向，不能先承诺手机后台广告可被 Mac 稳定发现。[后台指南](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)

iOS 26 的 Live Activity 能放宽部分 Bluetooth 后台扫描限制，但 Apple 工程师确认：锁屏且屏幕关闭后仍受扫描限制，不能把 Live Activity 当成全天后台保证。[当前 Core Bluetooth 文档](https://developer.apple.com/documentation/corebluetooth)、[Apple 工程师答复](https://developer.apple.com/forums/thread/815189)

Wi-Fi 点对点与普通 Wi-Fi 共存也有成本。Apple 明确提醒，启用它可能影响本 App 和其他 App 的网络性能；发现选定设备后应先停止浏览，再连接，不应一直后台搜索。[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)

两者都可能受到拥挤频段、遮挡和无线干扰影响。不要预先指定 AWDL 总能运行在理想频段，或把“能传大文件”解释为“在任何环境都更稳定”。[Apple 无线干扰说明](https://support.apple.com/en-us/102319)

## 功耗：待机与每次任务分开测试

低频通知、待机控制优先验证 BLE 的能耗优势；持续扫描、频繁唤醒、重试和短连接都可能消耗电量。对于一次录音或大文件，Wi-Fi 更快完成后关闭链路有机会节省总能量，但这只是待测假设。比较时同时记录空闲增量能耗、任务完成能耗、完成时间，不能只比较瞬时功率或电池百分比。[Apple 节能指南](https://developer.apple.com/documentation/xcode/reducing-networking-and-bluetooth-power-usage)、[Bluetooth 最佳实践](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/BluetoothBestPractices.html)

录音、编码、屏幕和 Quenda 模型计算也会消耗能量；测通信差异时需要固定这些因素。Wi-Fi Aware 官方提供 bulk / real-time 模式的能耗和延迟取舍，但不能把这些参数直接移植到 AWDL。[WWDC25 Wi-Fi Aware](https://developer.apple.com/videos/play/wwdc2025/228/)

## 实现边界与兼容性

建议结构：`iPhone App → 原生近距离传输 → Mac Companion → 本机 Quenda Gateway`。蓝牙和 Wi-Fi 的发现、配对、传输、重连属于 Companion；Quenda 保留独立 Gateway。启用 `includePeerToPeer` 不代表现有 Python HTTP 服务自动支持该发现或链路，更不能假设 `URLSession` 自动选择 AWDL；先用原生 Network listener / connection 打通，再转发到本机 Gateway。[TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)

`NWParameters.includePeerToPeer` 从 iOS 12、macOS 10.14 可用。新 Swift Network API 示例以 iOS 26 及对应版本为基线，旧 `NWConnection` / `NWListener` / `NWBrowser` 仍可表达同类功能。Apple 已说明 Xcode 27 弃用整个 Multipeer Connectivity framework，因此新项目优先采用 Network framework。[API 可用性](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)、[迁移说明](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)

Companion 仍需设备身份与配对认证；Bonjour 服务名只用于发现。Apple 的迁移文档建议明确 TLS 身份和对端信任策略。[安全规划](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework#Plan-for-security)

Mac 端服务持续可用以前提“电脑保持唤醒”为准。蓝牙无线功能、网络唤醒或特殊系统后台功能，不构成任意自定义 App 与 Gateway 在睡眠时持续执行的保证；睡眠 / 唤醒作为中断恢复测试，而不是首版可用性承诺。

## 可重复的真机比较

以下是拟定实验，不是已完成测试：

1. 固定同一部 iPhone / Mac、OS 版本、距离、温度、屏幕状态、录音编码、VPN 状态；对 BLE、Apple 点对点 Wi-Fi、同网局域网做相同负载。BLE 记录分包大小和协商结果，Wi-Fi 记录链路类型，不能把走路由器的流量当点对点成绩。
2. 独立测三种负载：间歇文字往返；相同预录压缩音频的连续发送；相同文件的批量发送。先用预录文件隔离录音和编码功耗，再增加真实录音测试。
3. 测状态变化：前台 → 后台 → 锁屏黑屏；离开范围 → 返回；开关无线；VPN 开关；Mac 睡眠 → 唤醒；Wi-Fi 拥挤与蓝牙耳机共存。
4. 指标：发现成功率 / 用时、首次认证连接成功率、往返延迟 p50 / p95、有效吞吐量、断线次数、恢复时间、最终数据完整性、排队录音积压。将发现、重连和消息恢复分别计时。
5. 能耗使用无传输基线、重复试验和系统能耗分析；待机和传输分别统计，测试顺序交替，排除充电、屏幕、编码和 CPU 差异。不输出未经测量的“省电百分比”或“稳定多少倍”。
6. 优先跑通点对点 Wi-Fi 的一次发现、配对、聊天、录音传输与锁屏恢复，再加入 BLE 做同协议对照；是否采用双通道由实际结果决定。

当前缺口：真实手机型号和系统、当前 VPN 对发现 / 数据路径的影响、Mac 合盖运行条件，以及两种传输的真机稳定性和耗电结果。
