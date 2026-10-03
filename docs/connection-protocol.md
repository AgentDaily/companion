# Companion 连接协议 v2（兼容 v1 配对与 Quenda 帧）

## 边界

Quenda 是独立 Gateway。Mac 客户端只使用它现有的 HTTP / WebSocket 接口，不嵌入 Python、不控制 Gateway 生命周期。默认及自定义 Gateway 地址均限制为本机 HTTP / HTTPS，避免把配对 Relay 变成任意 URL 代理。

Mac 的 TLS Relay 监听 127.0.0.1:8766，Tailscale Serve 在前台将 Tailnet 的 8765 TCP 转发过来。Serve 不终止内层 TLS。测试此机器直接绑定 Tailscale IP 后访问自身地址会超时；改用 Serve 后同一 TLS / Gateway 链路通过。这个结果仅说明本机部署路径，真实手机链路需设备测试。

Serve 生命周期由 Mac 应用持有。开启前读取 Serve 状态，拒绝占用既有 8765；关闭时中断自己的前台进程，不调用 reset / Funnel / --bg。异常退出后可能需要清理孤立子进程。

## 配对和加密

二维码包含 `quenda-companion://pair?host=…&port=8765&key=…`。key 是 Security 框架 CSPRNG 生成的 32 字节随机值，十六进制编码。Mac 与 iPhone 均存入 Keychain；不写入 UserDefaults、日志或代码仓库。复制的配对链接包含访问凭据，属于敏感信息。

Network.framework 使用 TLS 1.2 PSK，套件 `TLS_PSK_WITH_AES_128_GCM_SHA256`（IANA 0x00A8）；PSK identity 为 `quenda-companion-v1`。共享随机密钥用于 TLS 认证和加密，无自签名证书或证书验证绕过。此静态 PSK 套件没有前向保密，外层仍有 Tailscale 加密；不能将它的属性描述为 TLS 1.3。首版所有手机共用一个密钥，只支持整体轮换，不提供单设备吊销。

## 应用目录与路由

设备握手后发送无 applicationID 的 `catalog`，响应 body 为已注册应用数组（id/name/summary/symbol/enabled）。此过程不检查 Quenda。应用请求和事件带 `applicationID`，宿主只实例化已启用应用；未知/禁用应用返回错误。未指定 applicationID 的旧客户端消息映射到 Quenda。响应复制请求的 applicationID；客户端拒绝跨应用响应。

`catalog_changed` 由宿主推送，applicationID 指定配置已变化的应用。客户端刷新目录并重建此应用适配器，其他应用与底层连接保留。Quenda 只允许观察一个会话的约束属于 Quenda 适配器，不是通用宿主约束。

## 消息

每帧：4 字节网络序 unsigned length + UTF-8 JSON `RelayPacket`。最大 JSON 帧 4 MiB；HTTP / Gateway WebSocket 响应上限 2 MiB；未消费事件最多 256 条。超界或错误帧断开连接。TCP 分片按长度累积，不假设一次 receive 得到整帧。

- `request`：`id`、`method`、`path`、可选 Base64 `body`。
- `response`：匹配 `id`、HTTP `status`、Base64 `body` 或 `error`。
- `watch`：`sessionID`，连接 `/ws/sessions/{id}`。
- `event`：`sessionID`、编码后的 Gateway 事件；客户端丢弃其他会话的旧事件。
- `command`：`sessionID`、Gateway 命令。Relay 要求它与当前 watch 会话相同。
- `unwatch`：关闭当前 WebSocket，Gateway 的后台任务仍由 Quenda 管理。

每个手机仅观察一个会话。允许的 HTTP 接口：health、agents、workspaces、sessions 列表，创建 session，session 详情、message-pages、interactions。禁止文件读写、配置修改、删除和任意工具端点。允许的 WebSocket 命令：user_message、interrupt、permission_response、interaction_response、pong。

RPC 响应仅确认转发层完成这次发送 / 请求，**不等于 Agent 执行完成或业务持久化确认**。出现发送状态不确定时，界面保留草稿并要求先检查历史，不自动补发。

## 恢复

握手等待 URLSessionWebSocketDelegate 的 didOpen 回调。初版采用 `sendPing` 等待连接，在 Gateway 先发送活动流恢复记录时可死锁；回归测试覆盖此场景。

设备连接失败暂以 2 秒间隔重新尝试（每次另有发现及握手超时）；Quenda 的应用流恢复以 1、2、4、8、15 秒的间隔重试。重连创建新 Backend，重新加载会话历史 / 待答交互，再重新 watch。Gateway 若仍在执行，重放活动流；若已完成，HTTP 历史是结果来源。已有 sequence 用于去重；旧 connection / session generation 不能覆盖新状态。

消息、停止、权限决定和交互答案都不自动重发。切换会话时命令带上原 sessionID，防止旧页面的操作落到新会话。

监听器取消是异步过程；重置密钥先等待取消完成，避免旧端口尚未释放导致 Address already in use。

## Nearby transport

Pairing links optionally contain `nearby=<UUID>`. Legacy links without this field retain direct Tailscale host/port dialing. Nearby links resolve only the exact paired Bonjour name under `_companion._tcp` in `local.` and dial the returned service endpoint with peer-to-peer enabled. Discovery stops on match, error, cancellation or a ten-second timeout; reconnect performs fresh discovery. Discovery is not authentication: the existing TLS PSK remains required. No secret is advertised. The nearby listener binds available interfaces on a dynamic port, whereas the Tailscale listener remains loopback-bound behind Serve. A nearby connection may use infrastructure LAN when available; device evidence is required to establish an AWDL path.

当 nearby 和远程 host 同时存在时，先完成附近发现和 TLS 握手；失败且未取消时才尝试远程地址。host=nearby 表示没有远程地址。只在建立设备连接时回退，不对已提交的应用消息作自动重发。Mac 同时开启动态端口附近监听与可选的 loopback Serve 监听；远程失败不关闭附近监听。TLS tickets 与 session resumption 关闭，确保每次连接使用当前配对密钥重新认证。
