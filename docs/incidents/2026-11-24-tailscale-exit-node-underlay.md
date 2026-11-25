# Tailscale 出口节点开关后 XDial 直连长时间超时

## 现场与边界

时间为本机 PST，取自系统统一日志；App 日志用 UTC，对应 2026-11-24 19:03Z 与
2026-11-25 03:50Z。Debug 连着 US 场景（默认 Direct，另有一条 AnyConnect Line）。
同机运行独立安装的 Tailscale（system extension 形态的 packet tunnel provider），
出口节点是同一局域网里的另一台 Mac。

看到的：
- 11:03:06 命令行启动 Tailscale 并选中出口节点，默认路由从 `en0` 移到 `utun4`。
  11:03:07 宿主记录 `underlay changed en0 -> utun4`，epoch 2 的 Switch 在 11:03:17 提交，
  新 generation 的 `route.default_interface` 是 `utun4`。
- 同一秒 Tailscale 报 `sendto: broken pipe`、`ReceiveIPv4 is not running`，之后 netcheck
  的 UDP 一直 `recvfrom: socket is not connected`；magicsock 的 UDP socket 接收队列积压
  约 1.8 MB 无人读取，peer 只走 DERP 中继。
- Provider 的 NE 日志：30 分钟内约 2400 条 flow 来自 Tailscale 的 network extension 进程，
  包括绑定 `en0` 的 DERP TCP、到路由器 5351 的 NAT-PMP UDP 和经 `utun4` 的 peer 连接，
  全部被 `provider accepted`。Provider 自己的一条到 DERP 的 TCP 连接收发各约 10 GB。
- 11:00 之前 Direct `i/o timeout` 每 10 分钟 0–10 条；之后稳定在约 60 条，另有约 40–60 条
  原 resolver 读超时，持续到 19:50。
- 19:50:12 关掉出口节点，默认路由回到 `en0`，`utun4` 仍在且保留 scoped default 路由。
  epoch 3 的 Switch 候选在 19:50:25 以 `line-readiness-transient` 失败并进入重试；旧
  generation 仍绑 `utun4`，Direct 报 `no route to host` 与 `can't assign requested address`。
- 19:50:42 AnyConnect 会话被对端结束，Provider 掉线后完整恢复，19:50:53 在 `en0` 上提交。
  此后系统 DNS 仍是 Tailscale 的 `100.100.100.100` / `fd7a:115c:a1e0::53`，查询 flow 都标为
  `utun4(bound)`，Provider 转发原查询却报 `read original DNS response: i/o timeout` 与
  `dial original DNS resolver ... no route to host`。19:52:38 用户退出 XDial 后恢复。

推的：
- Tailscale 的隧道和控制流量被 XDial 接管，相当于把 Tailscale 叠在 XDial 之上；出口节点
  打开时 Direct 又走 `utun4`，流量绕成 应用 → XDial → Tailscale → DERP → XDial → `en0`。
  UDP 打洞失效来自被接管的 UDP flow，具体是哪一次关流未单独取证。
- “旧默认接口仍在就保留旧 generation”在 VPN 撤掉全局路由的场景不成立：接口还在，
  默认路径已不在它上面。若 AnyConnect 未掉线，重试耗尽后会一直停在 `utun4`。
- 原查询转发用的是 local transport 自己的 dialer，绑在默认接口上，丢了 flow 绑定的
  `utun4`，所以分域 VPN 的 resolver 不可达。

20:07 装上前三项修复后重连，Tailscale 的 flow 已放行（`underlay-provider-flow released`），
DNS 仍同样超时，用户再次退出 XDial。本地用真实数据面复现：经 relay socket 发出绑定
`utun4`、目标 `100.100.100.100:53` 的 UDP 关联，路由时 `XDialBoundInterface` 为空。
sing 的 SOCKS5 服务端处理 UDP ASSOCIATE 时把首个数据报的目标交给 inbound，丢弃了请求
地址，而 Provider 正是把绑定接口编码在这个地址里；所以绑定 UDP flow 从未恢复过接口，
TCP（CONNECT 地址照常传入）不受影响。补上后同一探测经 `utun4` 拿到应答，不绑定的对照
仍超时。

11-25 12:39 唤醒后（出口节点关闭、默认接口 `en0`），用户反馈仍不正常。Chrome 自带的 DNS
客户端不经 mDNSResponder，直接向 `100.100.100.100` 与 `fd7a:115c:a1e0::53` 发 UDP/TCP
查询；这些 socket 未绑定，内核按路由表标为 `utun4`，Provider 只传已绑定 flow 的接口，
原查询于是经 `en0` 发出，报 `no route to host` 与读超时（10:46–10:52 约 180 条）。同样，
不绑定的 TCP 连 Tailnet 主机时 relay 已对应用建连，出站却经 `en0` 超时，应用看到的是
连上后没有任何数据：XDial 开着时 Tailnet 访问一直不通，上一轮只列为未验证。

## 修复

- 另一个 Network Extension provider 进程的 flow 原样放行，按内核给出的进程路径与
  Network Extension 授权判断，见 [UnderlayProviderFlowPolicy](../../macos/Shared/UnderlayProviderFlowPolicy.swift)。
- Switch 最终失败后，旧 generation 的默认接口不再是当前默认接口也升级为完整恢复，见
  [StaleCommittedGenerationPolicy](../../macos/Shared/NetworkEpochSwitchCoordinator.swift)。
- 原查询转发沿用 flow 绑定的接口，见
  [sing-box 补丁 0020](../../patches/sing-box/0020-bind-original-dns-to-flow-interface.patch)。
- relay socket 从握手读回 UDP ASSOCIATE 请求，恢复绑定 UDP flow 的接口，见
  [sing-box 补丁 0021](../../patches/sing-box/0021-keep-bound-udp-association-interface.patch)。
- 未绑定接口的 flow 沿用系统路由表给它选的接口，见
  [FlowSystemInterface](../../macos/Shared/TransparentProxyFlowMetadata.swift)。

## 实机验证

20:53 装上四项修复（Debug 构建 1795582378），同一台机器、Tailscale 运行且系统 DNS 为 MagicDNS：
- 连接后新名称解析 59–377 ms，HTTPS 正常；`read/dial original DNS` 错误为 0（修复前约每分钟数百条）。
  mDNSResponder 等发往 `100.100.100.100` 的 flow 由 Provider 接管并应答。
- Tailscale 自己的 flow 全部放行，健康检查无告警，magicsock 接收队列为 0，到出口节点走局域网直连。
- 打开出口节点：epoch 切换重试一次后 14 s 提交，Direct 改经 `utun4`，Tailscale 仍直连，无环路。
- 关掉出口节点：12 s 提交到 `en0`，此后 DNS 与 HTTPS 正常；切换准备期间约 10 s 探测失败，
  因为旧 generation 仍绑在已无默认路径的 `utun4` 上。这段空窗未处理。

11-25 12:52 装上第五项修复（Debug 构建见提交）：
- 不绑定的 TCP 连 Tailnet 主机 SSH 6/6 次拿到握手（约 410 ms）；修复前连上后无数据。
- `dig` 直接问 `100.100.100.100`、`fd7a:115c:a1e0::53`（UDP 与 TCP）都有应答；修复前超时或
  `no route to host`。普通 flow 仍带 `en0`，公网 HTTPS 与新名称解析正常。
