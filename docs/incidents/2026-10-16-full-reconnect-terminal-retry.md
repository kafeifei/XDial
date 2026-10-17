# 完整自动重连对终止错误重试满五次

## 现场与边界

正式版 App 日志 2026-09-26 02:19:03Z 与 2026-10-13 17:43:09Z（UTC）各有一次启动自动连接失败，
code 为 `scenario-switch-prepare-failed`。随后按 2 / 5 / 10 / 20 / 30 秒连续安排五次重试，
分别在约 112 秒、124 秒后才显示最终错误“内置 Tailscale 需要重新登录”。
本机重连事故记录中两次都是 `exhausted`，五个 `retry-scheduled` 事件的 code 均为空。

同期 Debug 日志有 437 条 `underlay-path-update-missing` 捕获超时，其中 215 条出现在一次已记录的
成功捕获后 4 秒内；其余调用点成功时不写日志，无法逐条区分真假。

## 确定的缺口

`AutomaticReconnectRetryPolicy` 对启动自动连接与意外断线两类完整恢复不看错误码，
任何失败都消耗预算，违反 ARCHITECTURE 5.4“凭据 / 证书 / 配置等终止错误不自动循环”。

Provider 的 `RuntimeError.reportCode` 没有为 Tailscale 需要登录、后端不可用、状态无效
三个分支给出专用 code，它们在完整连接里也落入切换专用的泛化码 `scenario-switch-prepare-failed`。

Host 安排重试时只记录延迟，不记录上一笔失败事务的 code。Underlay 捕获的 3 秒计时器
在捕获完成后仍先写超时日志，再由 `finish` 去重。

## 修复

完整恢复按 `AutomaticReconnectFailurePolicy` 分类，只读结构化 code 与结构化证据：

- 瞬态：Line 就绪瞬态集合（复用 `AutomaticLineReadinessFailurePolicy`）、Host Underlay
  捕获原因、Provider / 数据面丢失、Line 路径不可达或网络中途变化、AnyConnect TLS 传输关闭，
  以及对端以空闲 / 会话超时、重新协商密钥、服务端错误为类别的断开。
- 终止：凭据、策略、重复会话、Tailscale 登录 / 后端状态等，立即结束并保留原错误。
- 未知：与 Scenario Switch 一致，不重试。没有结构化证据证明是瞬态时，重复同一事务只会把
  同一结论推迟约一分钟，期间还要反复接管、撤销系统网络；展示文字不参与判定。

Tailscale 的三个分支改为 `tailscale-login-required`、`tailscale-unavailable`、
`tailscale-status-invalid`。每次 `retry-scheduled` 事件与日志带上一笔失败事务的 code；
code 只接受小写 kebab 标识，其余记为 `unstructured-failure`，失败文字不进入该事件。
最后一次尝试若是终止错误，事故结果记为 `failed` 而非 `exhausted`。计时器只在捕获未完成时记超时。

## 剩余边界

AnyConnect 拨号失败（包括网络不可达、超时）目前以 `prepare-failed` 上报，属于未知码，
修复后不再自动重试。本机事故记录中该码进入的重试没有一次恢复；若要恢复其重试资格，
应由 Go 侧给出结构化分类，而不是在 Host 匹配文字。
