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

## 0.5.3 名称匹配修正（实机结果待确认）

11:45–11:47 用户关闭个人热点后复现失败：手机连续多轮浏览 ready、results count=1，却没有 matched，随后十秒超时。恢复热点后匹配成功，连接仍走 bridge100。可据此排除“完全收不到任何 Companion 广播”的笼统判断；旧诊断未记录未匹配候选的标识，不能确定候选是同一台 Mac 的名称变体还是另一设备，不能把热点认定为根因。

代码原先用 `name == service` 区分大小写比较 UUID。新增真实 Bonjour 回归：Mac 广播大写 UUID，客户端保留相同 UUID 的小写形式，原实现十秒报未发现；改用 UUID 值比较后，真实发现、TLS 握手和应用目录请求约一秒通过。这证明匹配实现存在大小写缺陷，但尚未证明该缺陷就是用户无线场景的根因。

0.5.3 只接受相同 UUID，仍拒绝其他设备及带改名后缀的名称；TLS 密钥验证不变。候选诊断新增 exact / case-only / possible-rename / different、标识短哈希与接口名称，不记录原始名称或密钥。发现已结束后忽略排队的浏览回调，避免重复 matched 记录。下一次实机复现将据此区分大小写、系统改名或不同标识，不盲目扩大匹配范围。

0.5.3 交付：Conda kora 全量 106 项测试，100 通过、6 项可选测试跳过；Mac release、iPhone SDK、签名设备构建通过。iPhone 14 Pro 已安装并启动 0.5.3（build 19），等待相同无网络条件复测。匹配修正只需手机新版本，未重启 Mac Companion 或 Quenda Gateway。


## 0.5.3 实机复测：发现已修复，连接仍失败

11:57–11:59 手机多次记录 `relation=case-only`、同一标识哈希、`interfaces=awdl0`、`matched`。这确认原大小写比较确实阻止了用户场景中的发现；0.5.3 之后发现成功。随后每次十秒连接建立超时，Mac 同时段没有对应的新入站连接。11:58:19 Mac 旧进程退出，11:58:33 新进程重建 AWDL 监听，仍然超时；11:59:11 恢复热点网络后才通过 bridge100/en0 建立连接。Mac 应用防火墙关闭。不能把“建立连接超时”直接解释为 TLS 密钥或握手错误。

0.5.4 增加每次连接的随机诊断编号、目标类型（不含地址）、系统路径状态/不可用原因、接口、解析后目标类型，以及连接期间系统提供的包计数。路径回调只在建立期间去重记录。包报告为空时明确记作 unavailable，不能视为发包为零；本机“接受 TCP 但不回答 TLS”的真实超时测试就会出现这种情况。连接超时阶段改名为 transport.connect.timeout，避免错误暗示 TLS 已开始。未调整超时、接口选择、重试或加密策略。

下一次实机目标：确认失败时是否已有解析后 IP 端点及可用 AWDL 路径。报告只用于缩小原因，不保证单次即可定位系统内部故障。正常连接的自动测试和本地超时诊断测试均不能替代无网络实机复测。

0.5.4 验证与交付：Conda kora 全量 107 项测试，101 通过、6 项可选测试跳过；新增 TCP 接受/TLS 停滞的真实诊断测试，加入记录前失败、加入后通过。Mac release、iPhone SDK 和签名构建通过；iPhone 14 Pro 已安装并启动 build 20。无网络 AWDL 连接仍需实机取证。

0.5.4 启动记录：初始路径 satisfied、interfaces=utun3、remote=service，随后 transport.ready=bridge100。该线索说明手机连接初期经过系统隧道路径评估，不能据此断言 VPN 阻断 AWDL；下一次要求关闭手机 VPN/代理隧道与热点进行受控复测。系统包报告即使连接 ready 也可能返回零计数，不能独立作为没有传输的证据。


## 0.5.4 关闭手机 VPN 复测与 0.5.5 接口范围修正

12:14–12:15 手机在 awdl0 找到相同 UUID，但连接目标为 service(interface=any)。多次超时前 currentPath 仍显示 pdp_ip0（蜂窝路径）和未解析的 service。关闭 VPN 没有解决故障；这些路径记录不代表业务内容已经经蜂窝网络发送。另一次超时前出现 awdl0/ipv6，Mac 12:15:24 有一次 AWDL 入站且 TLS bad record MAC；当前无法仅凭两端时序确认它与全部解析超时同因。Mac 12:13:04 也曾有 AWDL TLS ready 后路由丢失。12:15:45 恢复热点后 bridge100/en0 成功。不能将故障笼统归为 VPN、TLS 或 AWDL 完全不可用。

优先验证假设：单一发现接口的信息在交给连接层时丢失，导致未加入网络时服务解析反复卡住。如果保留 scope 后仍然卡住，则继续检查该接口的服务解析/无线链路；如果解析成功后失败，则依据新的传输或 TLS 错误处理。第二候选为无线服务解析本身不稳定，第三候选为少数连接的独立认证问题，暂不更换密钥或降低认证。

0.5.5：仅当 Bonjour endpoint 未指定接口且发现结果恰有一个接口时，使用该 NWInterface 构造 scoped service endpoint。已有 scope、多接口、零接口或非 service endpoint 保持原样；不硬编码 awdl0，不使用私有 API，不修改超时。官方 API 依据：[发现接口](https://developer.apple.com/documentation/network/nwbrowser/result/interfaces)、[服务地址接口](https://developer.apple.com/documentation/network/nwendpoint/service(name:type:domain:interface:))。此修正是基于实机证据的待验证方案，不能提前认定无网络问题已解决。

新增测试使用真实 Bonjour 发现得到的接口，构造与手机记录一致的单接口输入，旧实现丢失 scope 断言失败，修正后保留 scope、TLS 和目录请求通过（约一秒）。这只验证接口信息和真实本地认证连接，不模拟 AWDL 无路由器环境。诊断历史上限从 80 增至 240 条，避免恢复网络前多轮自动重试覆盖失败起点。

0.5.5 交付：Conda kora 全量 108 项测试，102 通过、6 项可选测试跳过；Mac release、iPhone SDK 与签名构建通过。iPhone 已安装并启动 build 21，待相同无网络条件复测。


## 2026-10-06：0.5.5 仍无法可靠脱离共同网络

用户复测仍失败。读取本次手机 155 条记录及 Mac 对应时间段日志：19:35:29 首轮 scoped awdl0 服务解析超时；19:35:42 下一轮在约五秒后 transport.ready=awdl0。Mac 19:35:48 完成 TCP/TLS，随后汇总记录约 1.607 秒、1606/22961 字节收发、无重传。手机 19:35:49 首先记录 device.reconnect，接着旧连接关闭；没有先出现 transport.failed 或 device.suspend。19:35:49 至 19:38:14 多轮在 service(interface=awdl0) 阶段超时。19:38:23 en0 同网连接成功。

结论：scope 修正确实生效，但并未解决反复解析超时。也不能断言完全没有直连能力，因为这次两端均有 AWDL 握手和数据收发证据。实践上仍以同局域网/热点作为可用模式，不把偶发成功当成功能验收。

19:35:49 的主动重连来源尚未确定。代码中的显式按钮、首页下拉刷新、重新配对、恢复与自动重试均可进入 reconnect；目前日志没有记录调用来源。已询问用户是否手动触发；未据此归咎用户或自动重连逻辑，未再次更换框架、密钥、超时或安装新版本。下一步须先确定成功连接为何被关闭，并将连接重试与尚未成功的服务解析分别验证。


## 0.5.6：修复首页刷新断链，验证完整连接窗口

已核对 Apple TN3151：Apple peer-to-peer Wi-Fi 支持附近设备在不配置共同 Wi-Fi 网络时通信，Network framework 通过 includePeerToPeer 启用。官方支持不等于本项目已通过可靠性验收。来源：https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api 。

确定复现的 App 缺陷：首页 refreshable 无条件调用 reconnect，导致健康连接和应用会话被关闭，也会取消正在进行的发现。两项真实本地服务器测试在原逻辑下失败（连接对象替换、会话重建、发现启动两次）。现在刷新只更新目录，已有连接保持，进行中的操作等待完成；显式“重新连接 Mac”保留强制重连作用。恢复定时任务增加连接/操作检查，避免对已有连接再发起重连。每次重连记录 manual/pairing/resume/refresh/recovery 来源，并单独记录目录请求成功。该缺陷确实存在，但用户尚未确认 19:35:49 是否手动刷新，不能把它宣布为所有无线失败的根因。

待验证假设：10 秒截止时间同时覆盖服务解析、无线链路建立、TCP 和 TLS，而 10 月 6 日首次请求到成功跨了约 19 秒（中间有一次取消重试）。Bonjour 连接改为单次最多 30 秒，成功立即返回；远程 IP/主机连接、接受入站连接仍为 10 秒，取消仍立即生效。此为有界验证，不是已证实根因。新增延迟 11 秒才响应的真实 Bonjour/TLS 测试验证时间窗口；它不模拟 AWDL 内部解析，也不能代替无线实测。

0.5.6 交付：Conda kora 全量 111 项测试，105 通过、6 项可选测试跳过；刷新两项回归及延迟 Bonjour 建连测试通过。Mac release、iPhone SDK、签名设备构建通过，iPhone 已安装并启动 build 22。剩余无线服务解析原因须依赖同场景实机结果，未宣称已修复。


## 0.5.6 实机发现：超过十秒后成功，随后配对流程拆链

10 月 6 日 19:52:31 手机开始 scoped awdl0 连接，19:52:43 transport.ready=awdl0 且 device.catalog.ready count=3。该次约 12 秒完成，证明原十秒预算确实不足以容纳这类实际成功尝试。19:52:45 device.reconnect 明确标为 source=pairing，旧连接被关闭；下一次解析三十秒超时。系统读取确认手机已安装 0.5.6/build 22，运行记录也有新预算和重连来源，不是安装未更新。没有记录密钥或配对内容，尚不能从旧日志确定这次配对信息是否相同。

0.5.7 修复同一配对链接的重复处理：相同 host/port/key/UUID（UUID 比较不区分大小写）保持健康连接，或等待已有连接操作完成；断线状态可恢复连接；配对内容真正变化仍写入钥匙串并重新认证。新增连接保留、进行中合并、密钥变化重建三项测试；测试用注入的保存函数隔离真实钥匙串。前两项在修正前失败。日志新增 pairing unchanged/changed，不包含凭据；启动日志与手机设置页增加实际版本/build 显示。

此次修正针对可确定的“重复配对会拆掉连接”行为，不能在真机保持连接验收前声称所有 AWDL 解析问题已修好。

0.5.7 验证与交付：Conda kora 全量 114 项测试，108 通过、6 项可选测试跳过；Mac release、iPhone SDK、签名构建通过。设备安装成功，随后从设备应用清单回读 version=0.5.7、bundleVersion=23；自动启动因手机锁屏被 iOS 拒绝，尚未运行新版实机测试，需用户解锁打开 Companion。

## 0.5.7：直连成功后掉线，USB 隔离诊断（2026-10-06 晚）

手机回读确认 0.5.7/build 23。20:01:14 与 20:04:17 两次 awdl0 连接完成并收到应用目录。第一轮 20:01:41 有 device.suspend；第二轮 20:04:20 pairing unchanged 没有重建连接，但 20:04:46 断开。Mac 第二轮记录 20:04:32 No network route，20:04:52 路由重新可用，20:05:02 TCP keepalive timeout。这说明存在实际无线通路丢失，不能再归因于手机未更新或重复配对。原接收错误日志不足以还原手机提前断开的准确原因。

增加接收错误/EOF、连接关闭错误类型及连接建立后的路径变化记录；不记录应用内容、端点地址或凭据。DEBUG 可通过环境变量启用隔离试验，正常启动及 release 不启用：

```sh
conda run --no-capture-output -n kora bash scripts/diagnostics/awdl-probe.sh DEVICE_UDID idle scoped /tmp/awdl-idle.json
conda run --no-capture-output -n kora bash scripts/diagnostics/awdl-probe.sh DEVICE_UDID traffic scoped /tmp/awdl-traffic.json
```

第四个参数为诊断输出文件；第三个参数也可为 unscoped，比较服务端点是否指定发现接口。仅用配对信息建立连接并请求目录，跳过 24R 刷新；不启动录音、分析或 Quenda 会话。发现结果必须包含 awdl0，测试连接排除发现到的其他接口；每轮通过实际 transport.ready 接口再次验证，USB/LAN 成功不能算 AWDL 成功。该方法是调试限制，不宣称 Apple 提供稳定的“强制 AWDL”生产 API。Apple DTS 对接口选择的说明：https://developer.apple.com/forums/thread/817831 。

idle 连接后等待 90 秒再请求目录；traffic 每 5 秒请求目录，共 90 秒。一次进程只跑一轮；临时关闭手机自动锁屏，完成或进入后台时恢复。进入后台必须判为 inconclusive。脚本使用独立 run ID，避免把前一轮遗留结果当新结果。运行后应无环境变量重新启动 App，恢复正常使用。

本轮实际结果：20:19:56 scoped 地址解析到 20:20:28 超时，未握手；20:22:41 unscoped（当时额外限制 requiredInterfaceType=wifi）到 20:23:13 超时。后续去除接口类型限制，仅排除 USB 发现接口，20:29:13 开始试验，但手机再次锁屏、日志停止，最终设备接口确认 passcodeRequired=true，判为 inconclusive。因此尚未获得有效的 idle/traffic 保持连接对照，不增加生产心跳，也不认定接口限制是根因。Mac 系统还出现 AWDLDiscoveryTimeout 与 displayOn=false，属于待核实线索，不能据此断言屏幕熄灭就是根因。

本轮代码校验：第一次诊断版本全量 114 项测试、6 项可选跳过、无失败，Mac release/iPhone SDK 构建通过；最终诊断脚本与前后台中断处理另行校验。真机保持连接验收尚未通过。

最终前台复测：20:38:48 scoped 与 20:40:50 unscoped（只排除 USB 发现接口）分别于 20:39:20、20:41:22 解析超时，两轮记录均有 scene active，未建立 TCP/TLS。调试器附加检查时主线程处于正常 RunLoop 等待，无主线程死锁证据。最终 114 项测试、6 项可选跳过、无失败；Mac release、iPhone SDK、签名安装通过。测试路径为 DEBUG 显式 opt-in，未将 5 秒测试目录请求加入生产连接。

20:42 仅重启 Companion Mac 进程以重新发布服务（未操作 Quenda Gateway）；首轮 Mac 服务尚未 ready，不能计为无线失败。20:43:33 listener ready 后重新运行 scoped 试验。当前 Mac en0 已有 IPv4，networksetup 返回未关联网络不能单独证明处于无共同网络环境，后续验收需核实真实网络状态。


## 0.5.8：确认发现请求生命周期撤销了无线通路

通过 USB 的 `com.apple.os_trace_relay` 成功取得 iPhone 历史系统日志（本地临时目录，不提交完整系统日志）。20:04:10.928，App 的 `_companion._tcp` 浏览结束，wifip2pd 紧接着记录 `Stopping all datapaths because client removed all other services`；20:04:10.941 连接层才开始 resolve。之后系统自己的 `_companion-link._tcp` 服务短暂启用数据通路，恰好让我们的认证连接成功；该系统服务结束后又撤销数据通路，20:04:21 手机记录 peer absence，20:04:46 连接 Operation timed out。结合 Mac 对应的 No network route 和 keepalive timeout，解释了“偶尔成功一下，随后断开”的模式。这里的 User Requested 是服务调用的结束原因，不意味着用户按了断开。

20:54:54 的受控诊断仅改变浏览器生命周期，保持相同配对、端点 scope、TLS 和 USB 排除设置：保留发现请求后，iPhone wifip2pd 立即建立本应用的数据通路并提供 SRV/AAAA；20:54:55 transport.ready=awdl0、目录 count=3，之后每五秒目录请求持续成功约 50 秒。20:55:45 进入后台导致试验主动中断，不能把这轮记为完整 90 秒 PASS，但保留期间没有出现之前的解析超时或自行断开。须继续无流量空闲和反向对照，不能据此量化全天稳定性或耗电。

修复：`CompanionLink` 自己持有 `NearbyDiscoverySession`，发现服务后不撤销浏览需求。认证成功后根据实际路径决定是否保留：Wi-Fi 的 link-local 地址保留（不靠硬编码 awdl0 名称作生产路由选择）；USB、有线、路由地址连接释放；路径暂不确定时先保留。取消、连接失败、远程回退和正常关闭均释放该会话。单次查询的旧 `NearbyDiscovery.resolve` 仍会清理资源；生产连接不再使用这个单次查询接口。没有增加生产心跳或定时业务请求。

回归证据：真实 Bonjour 的会话生命周期测试在旧实现下失败（提前撤销发现）；真实 `CompanionLink` + 静默 TLS 对端测试用 DEBUG 旧行为开关复现，在握手未完成时检测到错误释放。新实现通过，两处测试都验证取消后释放。另测 USB/局域网路径释放以及取消会话不可重新开启。全量 118 项测试，112 通过、6 项可选跳过。真机对照开关仅存在于 DEBUG：

```sh
# 0.5.8 默认修复逻辑；USB 只收集日志，实际连接必须验证为 AWDL。
conda run --no-capture-output -n kora bash scripts/diagnostics/awdl-probe.sh DEVICE_UDID idle scoped /tmp/awdl-fixed.json
# 反向对照：仅恢复旧的过早释放行为。
COMPANION_PROBE_DROP_DISCOVERY=1 conda run --no-capture-output -n kora bash scripts/diagnostics/awdl-probe.sh DEVICE_UDID idle scoped /tmp/awdl-baseline.json
```

签名设备构建成功。21:03–21:06 Mac usbmuxd 连续报告设备断开，安装传输报 IXRemoteErrorDomain 6 / CoreDevice 4016；已请求用户重接 USB。因此当前不得声称手机已安装 0.5.8，需设备回读确认和最终真机验收。USB 故障与已确认的无线生命周期问题分开记录。


用户重新连接 USB 后，0.5.8/build 24 安装成功，并从设备应用清单回读确认。正式代码物理 A/B：21:09:55 AWDL 完成认证，21:11:28 空闲 93 秒后目录请求成功，脚本 PASS；仅开启 DROP_DISCOVERY 旧行为开关，21:12:08 浏览立即结束，系统再次停止全部数据通路，随后连接解析超时，脚本 FAIL。两轮相同手机、Mac、配对、认证与接口条件，连接判定要求 transport.ready 仅含 awdl0。该对照支持生命周期修正，不代表完成“未加入网络 + 全天后台 + 耗电”验收。Mac release/iPhone SDK/签名构建均通过。

补充确认：21:13:55 再次启动时 App 进入后台，该轮标为 inconclusive；之后一次启动命令超时，未计为无线试验失败。最终已停止手机实时日志采集，并请求无诊断环境变量重新启动；iOS 返回 Locked，需解锁后手动打开 App。因此验收证据为一轮修复后的 93 秒空闲 PASS 和一轮旧行为的解析超时 FAIL，不虚报第二轮 PASS。
