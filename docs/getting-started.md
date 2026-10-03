# 安装与使用

Mac / iPhone 的应用宿主，共用设备配对、加密连接和恢复逻辑。打开首页的应用列表，再进入对应应用；当前已接入 Quenda，录音转录尚未实现。

```text
Mac Companion                           iPhone Companion
  应用列表 / 独立应用设置                   应用列表 / 独立应用设置
  Quenda → 本机 Gateway                   Quenda → 共享设备连接
          ApplicationRegistry ← TLS → CompanionLink
                     附近点对点 Wi-Fi 优先
                     Tailscale 远程回退
```

## 使用

需要 macOS 14+、iOS 17+、Swift 6 编译工具。附近连接无需 Tailscale、个人热点或外网；两台设备开启 Wi-Fi，并允许本地网络访问。Network framework 可使用 Apple 点对点链路，也可走共同局域网。

```sh
cd companion
scripts/build-apps.sh
open 'build/Companion.app'
```

1. Mac 首页打开「设备连接与配对」，点击「开启手机连接」。Companion 可以在 Quenda Gateway 未运行时独立接受连接。
2. 若需要远程回退，开启 Tailscale 选项并确认地址。Mac 同时启动附近监听器和私有 Tailnet 映射；远程启动失败时，附近连接继续可用。该选项启动后修改需先关闭手机连接。
3. iPhone 扫描配对码，或粘贴链接。一次设备配对供所有应用共用。手机先尝试附近发现和 TLS 握手，失败后才尝试配对中保存的远程地址。
4. 两端在应用列表点击「Quenda」进入会话。Mac 的 Quenda 设置配置本机 Gateway 地址及是否向手机开放；两端分别配置新会话的默认 Agent。更改 Quenda 配置会更新手机应用列表并重建 Quenda 适配器，不关闭其他应用的设备连接。

Quenda Gateway 独立运行，Companion 不嵌入 Python、不启动或停止它。初次配置沿用此前的 Gateway 地址；找不到时从 `$QUENDA_HOME/gateway/gateway.json` 或 `~/.quenda/gateway/gateway.json` 发现端口，默认 `http://127.0.0.1:8000`。

附近监听器使用动态端口。远程监听器仅绑定 `127.0.0.1:8766`，Tailscale Serve 把 Tailnet 的 `8765` 转发过来。不会启用公网 Funnel，也不会重置其他 Serve 配置。关闭连接或正常退出时停止本次监听和映射。Mac 需保持唤醒。

旧配对链接仍可解析，但只含一种地址的旧链接不具备双通道回退；重新扫描新版 Mac 的二维码可保存两个地址。密钥保存在钥匙串，二维码和复制链接包含密钥。重置密钥使所有旧配对失效。

## Quenda 应用

支持 Agent / 项目 / 会话列表、创建会话、分页历史、流式聊天、停止、工具活动、权限确认、交互回复和活动流恢复。新会话采用这台设备配置的默认 Agent，不可用时选择列表首项。

设备连接失败与 Quenda 不可用分别显示。连接恢复和通道回退均不自动重发聊天消息、停止、权限决定或交互答案；发送状态不确定时先检查会话历史。进入后台后暂停设备连接，返回前台恢复；任务由应用自己的 Mac 实现管理。

## iPhone 安装

Xcode 工程 `Apps/iOS/QuendaCompanion.xcodeproj`，scheme `QuendaCompanion`。在 Xcode Apple Accounts 登录并选择开发 Team，开启 iPhone 开发者模式，保持解锁；可以在 Xcode Run，或执行：

```sh
scripts/install-iphone.sh YOUR_TEAM_ID
scripts/install-iphone.sh YOUR_TEAM_ID '你的 iPhone 名称'
```

`build/iOS-SDK/QuendaCompanion.app` 仅是未签名 SDK 编译产物，不能直接安装。

## 验证

```sh
conda run -n kora swift test
conda run -n kora scripts/test.sh
conda run -n kora scripts/build-apps.sh
```

自动测试覆盖：配对、TLS 错误密钥、帧大小限制、应用目录与隔离、禁用/未知应用、单应用配置更新、不依赖 Quenda 的设备连接、附近优先、失败回退、取消搜索、Quenda 流式聊天与重连不重复发送。自动测试中的附近/回退选型使用真实 TLS 本机连接与可注入的发现结果，不代表无线距离、后台持续运行或耗电实测。

无共同 Wi-Fi 的真实点对点路径、地铁干扰、锁屏恢复仍需真机测试。未来全天录音应另行实现手机本地持久化、分段传输、业务确认和后台策略；通用连接模块不会自动提供这些能力。

## 工程结构

- `CompanionCore/Applications.swift`：应用描述、Mac 端注册与应用会话接口。
- `CompanionCore/CompanionLink.swift`：设备连接、附近优先/远程回退、按应用分发消息；不请求 Quenda 接口。
- `CompanionCore/RelayServer.swift`：通用 Mac 宿主，按应用路由并发布应用目录。
- `CompanionCore/QuendaApplicationSession.swift` / `QuendaClient.swift` / `GatewayClient.swift`：Quenda 两端适配器与本机 Gateway 接口。
- `CompanionUI/DeviceConnectionStore.swift` / `MacConnectionStore.swift`：设备级生命周期。
- `CompanionUI/QuendaStore.swift` / `QuendaConfiguration.swift`：Quenda 会话与独立配置。
- `Sources/QuendaCompanionMac` / `Apps/iOS`：两端应用列表、应用入口和宿主设置。

[应用接入结构](application-architecture.md) · [连接协议](connection-protocol.md) · [附近连接调研](research/nearby-transports.md)
