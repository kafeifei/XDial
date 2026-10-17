# 预算耗尽后的恢复与强制门户网络（草案 v0.1）

2026-10-16 起草。依据工作树 `db9ddd6` 的代码、本机正式版与 Debug 的运行记录、
[架构 5.4 节](../../ARCHITECTURE.md#54-网络变化与恢复) 与
[酒店 Wi-Fi 事故](../incidents/2026-09-20-hotel-switch-retry-classification.md) 整理。
本稿只是待决定的设计，没有实现，也没有在真实门户网络上验证。

**结论：不识别门户。把完整恢复的预算从“进程内一个计数器”改成“属于一个网络 epoch”；
耗尽后停在可见的“等待网络变化”状态并继续观察 Underlay，下一个经过沉降的新 epoch
重新获得一次预算。** 门户登录后有没有可观察的网络事实变化目前没有证据，这决定是否还要
加一段有上限的慢速尾巴（3.7），需要先在真实门户网络上取证（第 6 节）。

## 1. 现状（看到的）

### 1.1 完整恢复耗尽后的路径

- Provider 断开时 `publishStatus` 先 `stopUnderlayMonitoring()`
  （[TransparentProxyManager.swift:2266](../../macos/Sources/XDial/TransparentProxyManager.swift:2266)）；
  监视只在 `.connected` 时由 `startUnderlayMonitoringIfNeeded` 重新启动（:2988）。
  `handleUnderlayChange` 本身也要求 NE 状态为 connected（:3024）。断开期间宿主不再观察
  NWPath，AppState 收不到任何 Underlay 变化。
- 五次耗尽后 `finishAutomaticReconnect` 只发布 `disconnected`（:3367）。
  `ConnectionDesiredState` 仍是 `.connected(owned)`，连接意图保留，但没有观察者会再用它。
- 之后能重新发起连接的只有三条路：完整唤醒 / 屏幕唤醒 / 会话激活触发的
  `reconcileDesiredConnection`（[AppState.swift:1118](../../macos/Sources/XDial/AppState.swift:1118)）；
  用户手动连接；SSID 沉降后选中**另一个**场景时，`driveScenarioSwitchIfPossible` 的断开分支
  直接 `connect()`（:1579）。最后这条走的是手动连接入口，失败不重试。SSID 选中的场景不变时，
  `NetworkEpochTransitionPolicy.decide` 因 `runtimeStatus != "connected"` 返回 `.none`
  （[NetworkEpochSwitchCoordinator.swift:426](../../macos/Shared/NetworkEpochSwitchCoordinator.swift:426)）。
- `AutomaticReconnectAttemptBudget`（[AutomaticReconnectRetryPolicy.swift:65](../../macos/Shared/AutomaticReconnectRetryPolicy.swift:65)）
  是进程内单个计数器，只在同一事务稳定五分钟后清零（:2767）。手动连接、唤醒重连都不清零。
  所以耗尽之后每次唤醒重连只得到一次尝试：`start` 失败 → 进入有界重试 → 发现预算已满 → 立即耗尽。
- `AutomaticReconnectTrigger.underlayChange` 在策略里有分支（:128），但生产代码没有任何地方
  传入它，是死分支。

### 1.2 本机运行记录

正式版 `reconnect-incidents.json` 有 11 笔 `exhausted`，Debug 有 4 笔。典型的一段在
2026-09-04（以下为北京时间，构建早于 `db9ddd6`，但 1.1 涉及的预算逻辑自 8 月 16 日后未变）：

- 17:33 启动自动连接失败（`line-address-family-unavailable`），2 / 5 / 10 / 20 / 30 秒五次
  重试后 17:36 耗尽。此时 Underlay 默认接口是 `utun12`（另一个 VPN 承载默认路由）。
- 17:51、18:46、19:08、19:42、20:07 五次 `screens_did_wake` 各触发一次重连，每次都是
  “失败 → 进入有界重试 → 立即耗尽”，事故记录只有两个事件。
- 20:11 起几次未伴随唤醒日志的连接（推断为手动点击）看到默认接口已是 `en0`，约 20:12 成功；
  20:17 才记录“稳定五分钟，预算清零”。默认接口从 `utun12` 变为 `en0` 的那一刻没有任何自动
  动作，因为监视已停。

另外两条与设计相关的记录：

- 2026-09-26 一次启动自动连接因“内置 Tailscale 需要重新登录”失败，仍被重试满五次。
  `.automaticConnection` 触发对任何失败码都重试（策略里 `case .automaticConnection: break`），
  与架构“凭据 / 证书 / 配置等终止错误不自动循环”不一致。
- 2026-09-21 Debug 在路径 unsatisfied 期间每约 5 秒记录一次“waiting for usable Underlay”，
  持续到路径恢复，不消耗预算。等待 Underlay 不算尝试，这是现有的正确先例。

酒店事故当天（09-20 18:13）的 epoch 26 记录为 `en0 -> en0 kinds=system-dns,connectivity-restored`。
那张网是不是门户，日志里没有证据。

### 1.3 已连接时 epoch Switch 失败之后

- 候选失败只有 `line-readiness-transient` 才按 2 / 5 / 10 秒重试三次；之后
  `terminalFailure`，协调器记下 `(场景, 指纹)`，同一元组不再触发（AppState.swift:1798 一带）。
- `TransparentProxyManager.handleUnderlayChange` 在发出 epoch 前就把监视的基线换成了**新**
  快照（:3053），而 committed generation 仍用旧的 `activeUnderlay`。此后相同快照被当成“无变化”，
  只有路径 unsatisfied → satisfied 的边沿或实质不同的快照才会开新 epoch。
- 旧 generation 的 `route.default_interface` 是旧默认接口；`xdial-system-dns` 是旧快照里首个
  系统 DNS 的 UDP 53，同时是 `route.default_domain_resolver`（线路服务器域名解析）和 IP 分类前的
  `resolve` 服务器（[generator.go:691](../../core/config/generator.go:691)、:1314）。换网后旧 DNS IP
  不可达时，旧 generation 里以域名为 endpoint 的线路无法重新解析。

### 1.4 门户相关

- 代码中没有任何 captive 处理（macos / core 无相关实现）。
- Transparent Proxy 的 include 规则是全部出站（前缀 0），排除只有 link-local、multicast、
  limited broadcast（[TransparentProxyProvider.swift:1907](../../macos/TransparentProxyExtension/TransparentProxyProvider.swift:1907)），
  没有按进程排除；`NETunnelProviderProtocol` 未设置任何 exclude 选项。只要 macOS 把门户检测的 flow
  交给 Provider，它就和普通流量一样由 Scenario 裁决；已绑定接口的 flow 只有最终走 Direct 时才恢复绑定。
- 本机 macOS 26.6.2 上门户检测组件是 `/usr/libexec/captiveagent` 与
  `Captive Network Assistant.app`（私有 `CaptiveNetwork.framework`）。
- 外部资料（未在本项目复现）：Apple DTS 在 2022 年表示 Network Extension 没有公开 API 判断
  “当前处于门户”，建议从经过隧道的流量自行推断（[论坛 708887](https://developer.apple.com/forums/thread/708887)）；
  有开发者报告 macOS 11 / 12 上运行 `NETransparentProxyProvider` 时 CNA 弹窗不出现，
  即使 `handleNewFlow` 一律返回 false 也一样，macOS 13 上未复现
  （[703588](https://developer.apple.com/forums/thread/703588)、[726534](https://developer.apple.com/forums/thread/726534)）。
- 尝试用当前 Debug 的 `begin-route-probe` 查看 `captive.apple.com` 的线路归属，对任意域名都
  返回 `matchCount 0`，这次不能作为证据。

## 2. 推断（需取证）

1. 已连接状态进入门户网络：路径大概率 satisfied、DNS 变化 → 新 epoch → 候选准备；代理线路的
   精确出口验证被门户拦截。失败码可能是超时（transient，重试三次）、DNS 劫持后的证书错误或连接
   重置（可能被分类为 terminal，一次都不重试）。最终停在旧 generation。
2. 旧 generation 在门户网络里能否承载门户登录，取决于：门户检测 / CNA 的 flow 是否被系统交给
   Provider；Scenario 把 `captive.apple.com` 和门户页面送到哪条 Line；这些 flow 是否绑定了接口
   （绑定且走 Direct 时恢复到新接口，未绑定的 Direct 用旧默认接口）。从以太网换到门户 Wi-Fi 时
   旧默认接口已不存在，未绑定的 Direct 必然失败。
3. 旧 generation 内线路持续失败，Line 局部预算耗尽后提升为完整恢复，五次后停在断开。断开后系统
   接管已移除，门户弹窗应能正常出现，用户可以登录。
4. 登录后同一 Wi-Fi、同一接口、同一 DHCP DNS，Underlay 指纹很可能不变；是否会出现
   unsatisfied → satisfied 边沿或其他宿主可观察的系统事实，没有证据。没有的话，即使实现了 3.3，
   门户登录后也不会自动连回。

## 3. 设计

### 3.1 预算属于网络 epoch

完整恢复的预算键为恢复 epoch：`(desired Scenario, Underlay 指纹, 连通性代数)`。
连通性代数在宿主观察到路径 unsatisfied → satisfied 时加一。同一 epoch 内仍是现在的五次
2 / 5 / 10 / 20 / 30 秒；等待 Underlay 仍不计次；同一事务稳定五分钟仍清零。

“新网络事实”只取宿主已经在用、且与产品无关的事实：默认接口、可用接口集合、系统 DNS 的指纹
变化，以及连通性恢复边沿。SSID 仍只用于选择场景，不进入指纹，也不单独证明网络变化；SSID
变化选中的场景经现有协调器与 Underlay 事实合并为同一个 epoch。

### 3.2 停泊态

耗尽后若连接意图仍在、且最后失败不是身份类终止错误（3.5），宿主进入**停泊态**：

- 运行状态仍是 `disconnected`，系统接管已移除，这是现在已有的失败结果，不是静默回落；
  `AutomaticReconnectRuntimeState` 增加 `parked`、停泊时的 epoch 与下一次允许授予的时间。
- 继续运行一个只读的 `HostUnderlayMonitor`，基线为耗尽时最后一次捕获的 Underlay。
  它不创建数据面、不发网络请求。
- 事件仍进入 AppState 现有的沉降窗口与 `NetworkEpochSwitchCoordinator`；
  `NetworkEpochTransitionPolicy` 增加动作 `.resumeParkedRecovery`：运行时断开、处于停泊、
  连接意图未被显式撤销时，沉降后的新 epoch 交给恢复，而不是返回 `.none` 或调用手动 `connect()`。
  SSID 选中另一场景时同样走这条路，获得完整预算并按自动意图重试。
- 显式断开、退出、Profile 删除目标场景立即结束停泊。

### 3.3 授予规则

| 事件 | 结果 |
|---|---|
| 沉降后指纹与停泊 epoch 不同 | 立即授予新预算 |
| 指纹相同，只有连通性恢复边沿 | 距该指纹上次授予满 5 分钟才授予；未满则延后到满 5 分钟，不丢弃 |
| 完整唤醒后重新采样，指纹不同 | 按第一行处理 |
| 唤醒后指纹相同 | 保留现有的一次尝试，不授予预算；事故记为该次尝试失败，不再写一笔假的“耗尽” |
| 用户点击连接 / 重试 | 新的用户意图，授予新预算 |
| 同一 epoch 的重复通知、XDial 自己的事务开始 / 结束 | 不授予 |

### 3.4 防止循环

- 每次授予都对应一次宿主观察到并沉降的物理变化或用户动作；XDial 自己的重试不能产生 epoch。
  Transparent Proxy 不创建系统接口（架构 3.1），但宿主指纹直接取 NWPath 的可用接口，没有再做排除；
  Provider 启停会不会改变指纹或制造 unsatisfied 边沿，需要用测试和现场证据确认（6.6）。
- 同指纹 5 分钟间隔加全局上限（建议每小时最多 6 次授予，超出后延后到窗口允许）。最坏情况
  每小时约 30 次完整尝试，全部可在事故记录里看到；具体数字由用户决定。
- 休眠期间不授予、不尝试，沿用 `SystemSleepNetworkEpochGate`。
- 每次授予、延后和停泊写入事故记录（新事件类型），Debug `/state` 可见。

### 3.5 失败分类

授予前看停泊时的最后失败：

- **身份类终止**：凭据无效、Tailscale 需要登录、AnyConnect 认证失败、配置 / 引用错误。
  换网不会改变结果，不自动授予，只提示用户处理。
- **网络相关**：超时、连接重置、Underlay 出口不可用、地址族不可用，以及证书校验失败。
  门户劫持 TLS 时证书失败是网络造成的，新 epoch 下应允许再试一轮。

顺带把 `.automaticConnection` 的重试也改为遵守这条分类（1.2 中“需要重新登录”被重试五次）。
具体失败码的归类要以 6.4 的现场结果为准，未知错误不靠文字匹配获得重试资格。

### 3.6 门户：不识别，也不偷偷放行

- 不探测 `captive.apple.com` 判断门户，不读私有 CaptiveNetwork 状态，不按进程或域名扩大
  NE 排除集合。架构已经规定排除集合不按应用或产品扩展，就绪证明不依赖固定外部服务。
- 如果 6.2 / 6.3 证明门户检测或登录页被 Scenario 送进代理线路，给出用户可见的处理方式：
  一条手动 RuleSet 配方，包含进程路径前缀 `/usr/libexec/captiveagent`、
  `/System/Library/CoreServices/Captive Network Assistant.app` 和现场确认的检测域名，
  由用户在 Scenario 中绑定到 Direct。规则编辑器可以提供这份模板，但不自动注入。
- 已连接的旧 generation 若默认接口已不在当前 Underlay 中（例如从以太网换到 Wi-Fi），它无法
  被证明健康。按架构“无法证明旧 generation 健康时才进入全局回滚”，可以在 Switch 重试耗尽后
  主动完整回滚并进入停泊，让系统自己处理门户。这会把“已连接但不通（fail-closed）”变成
  “已断开、直连系统网络”，是否这样做由用户决定，并且只有 6.3 证明旧 generation 挡住了登录才值得做。

### 3.7 取证决定的扩展：停泊慢尾

只有 6.5 证明门户登录后没有任何宿主可观察的事实变化时才需要：停泊后在同一 epoch 内追加
有上限的单次尝试（建议 +2、+5、+10、+20、+30 分钟，最多五次），任何新 epoch 立即以完整预算
取代它；身份类终止错误不进入慢尾。断开状态下的尝试在 Commit 前失败会回滚，不打断现有流量，
但仍会产生连接事务与线路登录请求。这改变架构里“共享五次预算”的表述，需要用户明确同意。

### 3.8 边界核对

| 边界 | 本方案 |
|---|---|
| Underlay 不透明、不按产品识别网络 | 只使用已有指纹和连通性边沿；不识别门户、VPN 或 SSID 的含义 |
| sing-box 独占 DNS 与路由 | 只改宿主的恢复调度；Provider、Go 配置生成不变 |
| Provider 不做第二次 DNS 裁决 | 不涉及 Provider；门户相关流量仍由 Scenario 裁决 |
| 失败不静默回落 Direct | 停泊态是已报告的断开；门户放行只能由用户在 Scenario 中显式绑定 |
| 自动恢复有界 | 每个 epoch 五次；授予受物理事件、间隔和每小时上限约束 |
| 显式断开优先 | 显式断开立即结束停泊并撤销所有授予 |

## 4. 改动清单

| 文件 | 改动 |
|---|---|
| [AutomaticReconnectRetryPolicy.swift](../../macos/Shared/AutomaticReconnectRetryPolicy.swift) | 预算改为按 epoch 的账本（授予 / 延后 / 拒绝、间隔、每小时上限）；失败分类；删除或改造死分支 `.underlayChange` |
| [NetworkEpochSwitchCoordinator.swift](../../macos/Shared/NetworkEpochSwitchCoordinator.swift) | `NetworkEpochTransitionPolicy` 增加停泊输入与 `.resumeParkedRecovery` |
| [AutomaticConnectionPolicy.swift](../../macos/Shared/AutomaticConnectionPolicy.swift) | 唤醒重连在指纹相同时只尝试一次、不授予预算 |
| [ReconnectIncidentHistory.swift](../../macos/Shared/ReconnectIncidentHistory.swift) | 新事件：停泊、授予（原因）、延后；唤醒单次尝试不记为耗尽 |
| [TransparentProxyManager.swift](../../macos/Sources/XDial/TransparentProxyManager.swift) | 耗尽后进入停泊并保留只读 Underlay 监视；`handleUnderlayChange` 允许停泊态；用户连接授予预算；运行状态投影 |
| [AppState.swift](../../macos/Sources/XDial/AppState.swift) | 消费 `.resumeParkedRecovery`；SSID 换场景时走自动恢复而非手动 `connect()` |
| MainPopover / 菜单栏错误呈现 | 停泊态文案“自动重连已暂停，网络变化时重试”与“立即重试” |
| [DebugServer.swift](../../macos/Sources/XDial/DebugServer.swift) | `/state.automaticReconnect` 输出停泊与授予信息 |
| [ARCHITECTURE.md](../../ARCHITECTURE.md) 5.4、[DESIGN.md](../../DESIGN.md) 4.x | 预算归属、停泊态与呈现 |
| `docs/verification/captive-portal.md`（新） | 第 6 节的现场证据 |

不改 Provider、Go 配置生成和 sing-box 补丁。

## 5. 测试

- 账本：同 epoch 不重复授予；新指纹立即授予；同指纹连通性边沿 5 分钟内延后、到点授予；
  每小时上限；身份类终止不授予；用户连接授予；稳定五分钟清零仍有效；等待 Underlay 不计次。
- 转移策略：只有“断开 + 停泊 + 意图未撤销”返回 `.resumeParkedRecovery`；已连接仍走 Switch；
  显式断开返回 `.none`。
- 回放 09-04：耗尽后五次相同指纹的唤醒各一次尝试、没有新的“耗尽”记录；默认接口
  `utun12 → en0` 后授予完整五次。
- 防循环：在指纹不变时模拟 Provider 启停与等价路径回调，不产生授予。
- 分类：`.automaticConnection` 遇到“需要重新登录”不重试；超时、证书失败在新 epoch 获得预算。
- 事故记录新事件的编解码与旧记录兼容。

## 6. 现场取证清单

在真实门户网络（酒店、机场或可控的测试门户）上，分别在 XDial 断开、系统接管且同一 `en0`
从普通 Wi-Fi 换到门户 Wi-Fi、从以太网换到门户 Wi-Fi、仅 SOCKS5 四种状态下记录：

1. **路径事实**：加入未登录、登录后两个时刻的 `scutil --nwi`、`scutil --dns`、
   `route -n get default`，以及 Debug 日志里的 `underlay changed … kinds=`。
2. **检测流量去向**：系统日志中 `captiveagent` 是否发出探测、对应 flow 是否进入 Transparent Proxy；
   CNA 弹窗是否出现；探测和登录页最终走了哪条 Line（需要先修好或替换 1.4 中失效的路由探针）。
3. **旧 generation 能否承载登录**：已连接且候选失败时，手动打开 `captive.apple.com` 能否看到并完成登录。
4. **候选失败码**：门户拦截下 Switch 候选和完整连接的结构化失败码（超时 / 证书 / 重置 / DNS）。
5. **登录后的事实**：登录成功后多长时间内是否出现指纹变化或连通性恢复边沿，还是什么都没有。
   这一项决定是否需要 3.7。
6. **防循环**：在任意稳定网络上，停泊态下触发一次恢复尝试，确认 Provider 启停不产生 epoch。

记录只保留状态、接口名、失败码和时间，不记录门户 URL 参数、账号或 SSID。

## 7. 需要用户决定

1. 是否接受“预算属于网络 epoch + 停泊态”这一核心改动（推荐）。
2. 同指纹授予间隔与每小时上限的数字（建议 5 分钟、每小时 6 次）。
3. 用户手动连接是否授予新预算（推荐是）。
4. 默认接口已消失时，是否在 Switch 重试耗尽后主动回滚到停泊（3.6 末段），取决于 6.3。
5. 门户登录后若无可观察事实，是否加入停泊慢尾（3.7），取决于 6.5。

## 8. 不在本方案内

- `.automaticConnection` 对终止错误的重试若不随本方案一起改，应单独修。
- Debug 路由探针对任意域名返回 `matchCount 0`，需要单独查清。
- iOS / tvOS 的 Packet Tunnel 恢复路径未调查。
