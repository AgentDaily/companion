# 无路由器连接诊断（2026-10-05）

状态：未修复/待同场景实机验证。0.5.2 是诊断增强，不能称为无路由器直连修复。

用户复现：Mac Wi-Fi 开着但未加入网络，手机 Companion 一直寻找附近的 Mac 后失败。核对代码：NWBrowser、发起连接和 Mac NWListener 均已启用 includePeerToPeer，没有用互联网 reachability 限制附近连接。Mac 正在监听，Quenda/Ollama 的服务健康不是设备发现的前置条件。

Mac 真实日志：09:48:17 出现 awdl0 入站连接，约 0.533 秒完成 TLS 握手并 ready；09:48:28 路由变为 No network route，09:49:03 超时。该记录证明曾建立 AWDL 传输，不能证明应用请求或稳定直连成功。09:55 用户再次复现的无网络期间没有新的入站连接；09:56 网络恢复后 en0 上有已认证连接及应用字节收发。不能将 en0 连接当成 AWDL 验收，也不能单凭 Mac 日志确定手机发现失败的原因。

已排查的假设：未启用点对点参数（代码及实际 AWDL 握手不支持此假设）；旧网络路径/链路丢失（日志确有该现象，根因未定）；十秒超时过短（已有握手在一秒内完成的证据，尚不能证明延长超时可解决）。未盲目调整超时、强绑私有接口、关闭 TLS 或切换其他传输。

诊断版区分寻找、已发现正在连接、连接成功；记录浏览 ready/waiting/failed、结果数量、匹配接口、握手超时、网络错误码及设备阶段。手机 `Library/Caches/Companion/connection-diagnostics.json` 最多 80 条，原子替换；没有配对密钥、端点地址、原始请求、音频或文字。仅 iPhone App 启用落盘，测试使用隔离临时文件。设备连接与配对页面可分享记录；此功能不自动上传。缓存写失败不能影响连接。启动新进程后从本轮记录开始。

复现流程：安装诊断版；手机解锁保持 Companion 前台；Mac 保持 Wi-Fi 开关打开但不加入网络；手机点重新连接 Mac，等约 20 秒；读取诊断文件，与 Mac 同时段 Network 日志比对。可用 `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.quenda.companion.ios --source Library/Caches/Companion/connection-diagnostics.json --destination /tmp/companion-connection-diagnostics.json` 获取指定文件，不需要导出全部用户资料。

0.5.2 验证：Conda kora 下 104 项测试，98 通过、6 项可选测试跳过；覆盖连接阶段顺序、诊断记录上限及写失败隔离。Mac release 与 iPhone SDK 构建通过。这些测试未验证无网络的无线发现，不能代替上述实机复现。

Apple 官方参考：[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework) 要求发现目标后先停止浏览再发起连接；当前实现遵循该流程。[Apple DTS 关于接口选择](https://developer.apple.com/forums/thread/817831) 说明默认浏览/监听所有允许接口，禁止 Wi-Fi 同时开启 peer-to-peer 是矛盾配置；本次未采用该做法。

设备交付：0.5.2（build 18）签名构建和 iPhone 14 Pro 安装成功；自动启动被锁屏拒绝，等待用户解锁复现后读取手机诊断。Mac 新包尚未重启，不影响当前系统日志取证；Quenda Gateway 未重启或修改。
