# Tailscale 运行证据

Line、setup session、Underlay 与 Commit 的语义见 [ARCHITECTURE.md](../../ARCHITECTURE.md)。
桌面 setup 是 helper 中的配置会话，Provider 中的 active / prepared-switch runtime
属于连接事务；它们共享持久身份，但状态和生命周期不同。

## 结构化来源

| 来源 | 表达的事实 |
|---|---|
| 设置页 Line 卡片 → `GoEngine.tailscaleStatus` → helper 的 `tailscale-status` | setup session 的 LocalAPI 登录态与可选 exit node；不是 Provider 已连接的证明 |
| `Libbox.TailscaleStatus` / `PreparedSwitchTailscaleStatus` | 对应 runtime 的 LocalAPI 状态，以及 control、magicsock 的有限诊断 |
| `exit_nodes` | `online`、`selected`、`in_network_map`、`in_magic_sock`、`in_engine`、收发计数和 `has_handshake` |
| `readiness.control` / `readiness.derp`、节点的 `derp_path` | control generation、Home DERP 状态与连接 generation，以及收发、失效、关闭等 sequence |
| `ProbeTailscalePeer` / `ProbePreparedSwitchTailscalePeer` | 对单个 peer 发起真实 Disco / TSMP 探测，返回路径类别、延迟和错误类别 |
| 当前 `ConnectionReport` 与 Debug 路由探针 | 连接提交结果，以及具体流量的 Line 归因；HTTP 入口见 [debug-server.md](../agent/debug-server.md) |

setup IPC 见 [GoEngine.swift](../../macos/Sources/XDial/GoEngine.swift) 与
[daemon.go](../../cmd/xdial/daemon.go)。Provider 数据定义与读取见
[tailscale_status_gvisor.go](../../core/libbox/tailscale_status_gvisor.go)；消费与证据投影见
[EmbeddedSingBoxRuntime.swift](../../macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift)
和 [TailscaleReadiness.swift](../../macos/Shared/TailscaleReadiness.swift)。这些 Libbox 方法不是
Debug Server HTTP 动作。

## 结论范围

`has_handshake` 仅表示 LocalAPI 的 `LastHandshake` 非零，不表示本轮 fresh handshake。
exit node 在线、已选中且存在于三份运行结构中，仍可能出现 `tx > 0 / rx = 0` 的 peer
handshake 失败；该组合本身不定位到登录、Underlay 或某个外部服务。

NetInfo 本地调用返回、control HTTP 接受、远端消费 map、fresh handshake 与真实出口是
不同证据。DERP ready/client 数是点时快照；相同汇总不能排除采样间的重连，sequence 与
generation 才能表达期间变化。单端状态不证明远端已消费同一张 map。

出口 IP、单次 HTTPS 和路由表分别只覆盖各自观察；TCP、系统 DNS 和普通 UDP 的实际
Scenario 出口需要对应流量证据。远端进程重启后的成功属于新的运行现场。
