# D35 Transparent Proxy 证据档案

本文保存 Transparent Proxy 入口演进中的历史现场、失败实验与当时的验收范围。
部分记录没有保留源码提交或运行构建号，结果只属于所述现场，不代表当前版本。
现行契约见 [架构与边界](../../ARCHITECTURE.md)。

## 1. 接口作用域与已绑定 flow

2026-08-21 实机中，`remotepairingd` 在四分钟内向 `fe80::/10` 产生 15,173 个被 Provider
接管后立即失败的 flow，Provider 持续约 39% CPU。IPv4/IPv6 link-local、multicast 与
limited broadcast 依赖当前接口或二层广播域，穿过回环 SOCKS 后无法保留 scope ID 与广播
语义。这证明严格接口作用域地址应由 `excludedNetworkRules` 留在启动前 Underlay；排除规则
只能按地址语义定义，不能按进程、端口、品牌或接口名定义。RFC1918、IPv6 ULA、Tailnet 和
企业单播地址仍必须进入 active Scenario。

同轮现场中，本地地址 `192.168.68.114/20` 到同一 `en0` 直连网段的 `192.168.69.26` 被
macOS 标记为 `en0(bound)`。旧 relay 丢失 `NEAppProxyFlow.isBound` 与
`networkInterface` 后，TCP/UDP 配对连接持续失败并高频重试。这证明已绑定 flow 的接口事实
必须作为经过认证、长度受限的 metadata 进入 sing-box，但只能在 Scenario 最终选择 Direct
后恢复；命中 AnyConnect、Tailscale 或其他代理 Line 时不得继承。

## 2. Underlay 入口演进

首次试验正确签名、嵌入并激活了 System Extension，但 Provider 进程内捕获的 `NWPath` 把
已有全流量 VPN `utun14` 折叠成物理接口 `en0`。后续试验能收到宿主传入的虚拟默认接口
快照，但生成配置尚未把它写入 `route.default_interface`。这些结果只证明安装、激活与失败
关闭，不能证明数据通路。最终只有 Provider 收到的宿主快照与 sing-box `direct` outbound
的真实 HTTPS 探测同时成功，才证明盒内出站延续了启动前 Underlay。

`NWPath.availableInterfaces.first` 也不是默认路由契约，实机切换时曾错误返回 `en0`。因此
宿主必须在请求连接前同时取得内核默认路由、完整候选接口和系统 DNS 快照；Go 侧只能补齐
MTU、状态标志与地址，不能选择或重排 Underlay。

## 3. MagicDNS 系统接入事故

一个已提交事务中，Tailscale endpoint 和当时内部的 `dns:mode` tag（现领域名为 Scenario）
都显示 ready，但系统解析器仍把启动前 Wi-Fi resolver 作为查询目的地，成员短名得到
NXDOMAIN。ready 状态因此不能证明系统 DNS 已进入 XDial。

Apple 为 Transparent Proxy 提供的受支持 DNS 捕获入口是 destination-domain network
rule；`NEDNSSettings` 会被该 Provider 类型忽略。后续实现从同一 endpoint 的实时
`DNS Config` 导入有界的域名后缀、完整主机名和单标签别名，生成 port 53 的
destination-host rules；直发 DNS 得到成员地址，新成员短名也可由 `dscacheutil` 解析。
macOS 可能保留修复前的 NXDOMAIN 负缓存，所以验收应使用新名称，或在获得用户授权后刷新
`mDNSResponder`，不能把旧缓存当成当前数据面失败。

## 4. Tailscale peer / DERP 状态事故

初始取证显示所选 exit node 已进入 netmap、magicsock 和 engine，发送计数持续增加，但
接收为零且没有握手。同时间双端取证确认：本地 control client 已收到 NetInfo 发布调用，
Home DERP 在采样时刻 ready；远端 `tailscaled` 收到每次 WireGuard initiation 并生成
response，却把 response 发往已过期的 peer DERP，DERP 返回“不认识该 peer”。这不是
XDial Underlay、登录态或出口探测超时。

确定的状态一致性链是：远端完整 peer 快照指向 relay A，增量 mutation 只把实时 endpoint
改为 relay B，没有同步完整快照；下一张 full map 再报告 relay A 时，因为输入等于旧快照，
`updateNodes` 的无变化 fast path 提前返回，实时 endpoint 永久留在 relay B。重启远端
`tailscaled` 会从当前 full map 同时重建快照和 endpoint，所以曾让链路立即恢复；这只是在
清除错误的进程内状态，不是产品修复或验收步骤。

本地 vendored 补丁因此记录“实时 endpoint 已收到增量 mutation”。下一张 full map 即使
与快照相等，也必须完成 endpoint upsert 和 relay candidate 重算后才能清除 dirty 状态。
回归形状固定为 `snapshot=A / endpoint=A → delta(B) → full(A)`，最终 endpoint 必须回到
A，随后才能恢复 fast path。远端仍有脏状态时，XDial 必须报告
`tailscale-peer-handshake-failed` 并在 Transparent Proxy Commit 前回滚，不能自动重启
远端、固定或遍历 DERP、回落 Direct 来掩盖故障。

相同代码、官方 Tailscale Underlay、Exit Node 和 Scenario 下，旧持久身份持续发送但接收
为零，独立临时身份数秒内完成握手并通过真实出口探测。这把该轮失败收窄到旧身份关联的
peer / DERP 会话状态，而不是 RuleSet、DNS 或其他 Underlay VPN。换身份能清除状态但不是
协议修复；不能在连接事务中静默轮换身份，旧身份应保留供取证。

NetInfo 发布调用返回只证明当时的 control client 接受了同步调用；携带对应修订的 lite map
请求获得成功 HTTP 应答，也只证明 control HTTP 接口接受了请求。远端 peer 消费 map、fresh
WireGuard handshake 和真实出口是三层独立事实。DERP client / ready 数还是点时快照；若无
结构化 lifecycle sequence 或 generation，不能用前后相同汇总或日志缺失证明中间没有重连。

同轮证据还证明，本地 Home DERP 提升、NetInfo 调用返回和 lite map HTTP 接受，可以与持续
发送、零接收、无握手同时成立。因此 Home DERP 重选不能成为连接启动事务中的自动恢复动作；
未来若保留，也只能由用户显式触发，并仍需 fresh handshake 与真实出口验收。

## 5. 逐 flow 可观测性缺口

同一已提交事务中，两个保留域名的公网目标与 `corp.example` 企业目标的 TCP flow 都被
Provider 接收；企业域名从三个 resolver 入口得到相同私网答案，真实 HTTP 也成功。这分别
证明了 Transparent Proxy 接管、盒内 DNS 归因和企业线路可达，却不能证明三个 flow 实际
命中了哪个 RuleSet / outbound。当时版本没有逐 flow 的 matched RuleSet / outbound
结构化观察，active Scenario 只能表达期望，禁止据此倒推实际 Line。

这促成了 transaction-scoped Provider diagnostics 与 DEBUG route watch：后者必须由显式
目标和短时窗口启动，只观察认证会话的 `transparent-proxy-in` flow，返回固定闭集和有界
sequence，不得回传目标、原始规则、URL、凭据或普通浏览历史，也不得参与裁决。

## 6. Direct 系统解析事故与失败实验

同机、同网络、相邻时间窗口内，关闭 XDial 时 macOS 原生解析器把 Cindy 公网域名解析到
上海地址且 TLS 成功；开启 XDial 后，旧 `xdial-system-dns` 绕过 mDNSResponder，向捕获的
首选 resolver 裸发 UDP/53，得到台湾地址，而该地址在原生直连和 XDial Direct 上都 TCP
超时。相同地址经其他 Line 可以完成 TLS，只证明地址与出口组合不同，不能替代 Direct 修复。

把 Direct 公网解析硬编码为 `223.5.5.5` DoH 的两轮实验也未通过现场验收：第一版含非法空
Direct detour；第二版虽提交数据面，Cindy 与 Codex 仍失败，失联前没有完成 DNS 应答与
Direct TLS 的结构化核验。该方案不是已验证修复，不得进入分发版本，也不得增加 Cindy、
酒店或地域特例。

首个原生解析候选复用了 sing-box 面向普通进程的 mDNSResponder Unix socket 协议；普通
进程约 300ms 成功，但在 Transparent Proxy Provider 内，已接受的 DNS flow 八秒无应答，
真实 HTTPS 解析超时。第二个候选使用 Apple `DNSServiceGetAddrInfo`，结果相同。系统日志
确认该 flow 就是应用发往当时系统 resolver 的原查询，因此 Provider 对已接管 flow 再调用
系统解析器不是可用实现。正确边界是：sing-box 先完成 DNS 归属裁决，只有 Direct 才原样
转发 flow 已携带的查询与 resolver endpoint；raw Unix socket 不能用于该运行路径。

后续现场还发现，`酒店` Scenario 第一条 mixed“内部域名”曾在生成期关闭整个 DNS 规则链，
使后续“国内域名 → Direct”没有进入 `dns.rules`。Cindy 查询落到 Scenario 默认 Taiwan 1
resolver，连接仍由国内域名 route 送往 Direct；向不可达的名义 resolver 发同一查询仍立即
得到台湾地址，证明没有执行 Direct 原包 transport。生成器必须跳过 IP / mixed 的 DNS
分支但继续编译后续域名归属，回归测试固定“mixed 在前、Direct 域名在后、默认代理”。

## 7. 基础三出口验收

验收期间官方 Tailscale 保持 `Running`，默认接口仍是它的虚拟接口。相同 active Scenario
下，默认 Direct 与内置 Tailscale 得到不同公网出口；`corp.example` 经 AnyConnect 分域
解析获得私网地址并返回有效 HTTP 重定向。向公共 DNS、不可达测试地址和 MagicDNS 名义
地址发送该企业域名查询，三者返回相同私网应答，证明 DNS 包由盒内 `hijack-dns` 接管，
不是碰巧由 Underlay resolver 回答。

TCP、DNS UDP、保持 flow 存活的普通 UDP nonce 和立即关闭发送端的短命 UDP nonce 都真实
穿过 Provider。把 `flow.open` 提前到 UDP relay 准备之前，消除了短 flow 在接管确认前被
系统 reset 的错误风暴；后续 SOCKS relay 失败仍关闭 flow，不能回落直连。

## 8. 尚未完成的实机门禁

Underlay 自动重连有代码不等于完成实机验收。仍需分别验证下层默认接口切换、断网后恢复和
Provider 异常退出。UI 与自动化不能把 Network Extension 的 `connected` 单独当成策略生效
证据；还要分别核对 DNS 归因、规则归属和真实出口。
