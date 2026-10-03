# Companion 应用宿主

Companion 提供设备发现、配对、TLS 帧传输、应用目录、消息分发和设备恢复；应用提供两端界面、自己的配置、Mac 任务执行、持久化和业务恢复。Quenda 是第一个内置应用，Gateway 仍是独立运行的程序。

## 模块接口

`ApplicationRegistry.register(descriptor, makeSession:)` 注册应用。每个已认证设备、每个应用拥有独立 `CompanionApplicationSession`；宿主调用 `handle(packet)` 并将返回值作为该应用响应，`emit(packet)` 将事件发送给该设备且强制填入对应的 applicationID。`close()` 清理该设备的观察资源，不应自动停止应用的持久任务。

`CompanionLink.connect()` 先尝试附近发现及握手，再回退远程；`applications()` 获取 Mac 实际注册列表；`request(packet)` 发出一次请求；`events(applicationID:)` 为调用方提供该应用的事件。请求和响应使用相同 applicationID，订阅事件按 applicationID 分开，即使两个应用使用相同 sessionID 也不会串流。通用模块不解释录音分段、转写模型或 Quenda Agent。

`QuendaBackend` / `QuendaRelayClient` 将 Quenda HTTP 与会话操作转换为 applicationID=quenda 的消息；`QuendaApplicationSession` 是 Mac 端实现。Quenda 健康检查在打开 Quenda 时执行，失败不会关闭共享设备连接。旧 `Backend` / `RelayClient` / `ClientStore` 名称保留为类型别名以兼容现有调用。

## 生命周期与配置

手机 `DeviceConnectionStore` 负责配对、目录、连接恢复和前后台暂停。每次设备连接恢复时重新执行附近优先选型，但已建立的远程连接不会周期性强制切换，避免打断应用任务。附近会包括共同 LAN，界面不宣称已经确认 AWDL。

Mac `MacConnectionStore` 持有两个监听器和可选 Tailscale Serve。它依赖应用注册表，不依赖 Quenda 的可用状态。两个监听器使用相同设备身份、密钥和注册表。

Quenda 设置使用 `app.quenda.*` 的 UserDefaults 命名空间，旧 `gateway` 设置迁移读取。设备级偏好在 `connection.*`；密钥与配对链接仍只进入钥匙串。手机默认 Agent 是手机本地偏好；Gateway 地址及共享开关在 Mac 管理，不作为手机远程设置写入接口暴露。

应用配置生效后调用 `applicationChanged(id)`：宿主只关闭此应用的设备会话，并发出 `catalog_changed`。手机刷新目录和此应用的 revision；设备连接及其他应用会话保留。Quenda 的历史和正在运行的任务仍由 Gateway 管理。

## 新应用接入

新增应用需要同时实现：

1. 稳定的应用 ID、名称、摘要、图标和 Mac 注册项。
2. Mac 的 `CompanionApplicationSession`，限定允许的操作及应用配置。
3. iPhone 对共享 `CompanionLink` 的适配器与界面；Mac 对应界面和配置。
4. 在两端首页的应用入口分发中注册该界面。Mac 发布新应用不代表旧 iPhone 已包含界面；旧客户端显示需要更新。
5. 应用自己的任务标识、持久化、进度恢复和自动化测试。

当前是随 Companion 编译发布的内置应用架构，不涉及运行时下载或执行第三方插件。应用描述来自 Mac 的注册表，目录包含已启用和未启用应用。

录音转录尚未实现。未来应先在手机持久化录音分段，通过应用消息传递分段 ID、校验值和确认状态，再由 Mac 本地 ASR 执行；4 MiB 帧上限仍适用，大文件需分段。业务完成确认、断点续传和录音后台权限属于该应用，不能把通用 RPC 转发成功当作录音持久化成功。
