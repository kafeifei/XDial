# XDial 架构与边界

## 1. 所有权

**XDial 表达、编译和托管；sing-box 独占 DNS、规则匹配、出口选择与转发。**

| 层 | 所有权 | 边界 |
|---|---|---|
| Go 控制面 | Profile 校验、配置与计划编译、运行目录及配置身份 | 不在 sing-box 之外裁决逐流路由或 DNS |
| Swift 宿主与 UI | 用户意图、平台生命周期、结构化状态展示 | 不复制 Go 的 tag、schema、依赖闭包或指纹算法 |
| 平台 Ingress | 系统 flow / TUN 接入、系统网络事实 | 不理解 Line、RuleSet、Scenario，不选择 resolver 或出口 |
| sing-box | 同一份配置内的解析、裁决与转发 | 不向系统散落产品级 DNS、路由或接口策略 |
| 协议适配器 | 将 sslcon 等能力暴露为盒内出口 | 不反向控制其他线路或全局状态机 |

XDial 对系统增加一个网络叠加层。外部已有的 Wi-Fi、网线、VPN
共同组成不透明 Underlay，不能被 XDial 按产品名拆解、关闭或重排。

## 2. 领域与供给（D28）

| 维度 | 项目中的职责 |
|---|---|
| Ingress | 流量如何进入盒内；与出口裁决正交 |
| Line | 出口协议、凭据、传输与解析能力；声明本身不生效 |
| RuleSet | 匹配内容与远程资源；不携带用户流量出口 |
| Scenario | 绑定 RuleSet → Line、指定默认 Line；用户流量裁决的唯一连接点 |

用户流量依赖方向为 `Scenario → {RuleSet, Line}`。只有 active Scenario 的有效依赖进入
运行配置；未引用对象没有流量规则、活会话或网络请求。限时 Tailscale 配置会话与
`URL RuleSet → fetch Line` 是独立资源会话，均无系统 Ingress。

供给规则是可见、可禁用、可排序、可不用的申报，不是隐式注入。Scenario 显式绑定优先于
订阅供给；MagicDNS 的 DNS 优先级是 [单独限定的例外](#32-tailscale-与-magicdnsd33)。
引用悬空、重复 outbound tag 或单例冲突在生成阶段失败；主动禁用产生可见 warning，
不静默跳过无法生成的规则。

生成的 route 只来自 Scenario、显式系统规则（`sniff`、`hijack-dns`、桌面诊断 selector）
或已启用的动态 MagicDNS 能力。裁决相关的 resolver、缓存隔离、接口与 TUN stack 配置
显式生成，不依赖上游默认值维持产品边界。

入口：[配置生成](core/config/generator.go)、[ConnectionPlan](core/config/connection_plan.go)、
[不变量](core/config/invariants_test.go)。

## 3. 平台接入与 Line

### 3.1 macOS 与 Underlay（D31–D35、D-UNDERLAY、D-INGRESS）

macOS 主入口为 `NETransparentProxyProvider`，以随机凭据保护的回环 SOCKS 将 TCP/UDP
flow 交给同进程 sing-box。iOS / tvOS 使用 Packet Tunnel；HTTP/SOCKS + PAC 不是当前入口。
Transparent Proxy 不接管 ICMP。link-local、multicast、limited broadcast 留在 Underlay；
RFC1918、IPv6 ULA、Tailnet 与企业单播地址仍由 Scenario 裁决，排除集合不按应用或产品扩展。

Underlay 来自宿主请求连接前同一时刻的内核默认接口、完整 `NWPath.availableInterfaces`
与系统 DNS。Provider 内的 `NWPath` 可能隐藏既有全流量 VPN，只用于诊断。
`route.default_interface` 原样采用内核结果；接口快照仅补齐系统 MTU、标志与地址，
只排除当前 XDial 会话自己登记的接口，不按名称前缀筛选、不取首候选、不生成 outbound
`bind_interface`。缺失或不一致的快照不能启动连接。

macOS 已绑定 flow 的接口是系统既有裁决，经认证且有长度上限的 metadata 传给 sing-box；
Scenario 先选 Line，仅最终属于 Direct 的 flow 恢复该绑定，其他 Line 不继承它。

入口：[宿主](macos/Sources/XDial/TransparentProxyManager.swift)、
[Provider](macos/TransparentProxyExtension/TransparentProxyProvider.swift)、
[flow metadata](macos/Shared/TransparentProxyFlowMetadata.swift)。

### 3.2 Tailscale 与 MagicDNS（D33）

内置 Tailscale 是盒内 endpoint，不创建系统接口、不接管系统 DNS、不接受或发布系统路由。
每个 Profile 共用一份持久身份；不同 Line 可选择不同 exit node，但 active Scenario 至多
使用一条 Tailscale Line。未登录、需要认证或指定节点不可用产生结构化失败，不自动换节点。

显式配置动作可启动限时 setup session；关闭配置、超时、完整连接开始或 daemon 退出即停止。
Auth Key 仅作为单次注册输入，请求返回后 UI 清空，不进入 Profile、Keychain、订阅、日志、
Debug 或运行配置；已持久化 node key 的有效性不取决于该 Auth Key 是否过期。

MagicDNS 默认关闭，仅在该 Line 被引用且用户开启时生效。macOS Transparent Proxy 的契约为：

- 同一 endpoint 就绪后、Commit 前读取一次 NetMap `DNS Config`，会话中不持续追踪。
  快照原子注入 sing-box 内存 hosts；缺少可用配置或注入失败阻止 Commit。
- `Hosts` 提供完整名与地址，`SearchDomains` 展开已知单标签别名；只有无 resolver 的
  `Routes` 是本地权威命名空间。带 resolver 的 split-DNS route 不冒充本地权威。
- DNS 与 peer route 成对启用：DNS 权威范围优先于 Scenario DNS，范围内未知名直接
  NXDOMAIN；peer / subnet route 晚于 Scenario 显式 route。归属来自实时 `AllowedIPs`，
  排除 Exit Node 的 `0.0.0.0/0`、`::/0`，不硬编码 Tailnet 网段、域名或默认路由。
- 成员记录只存在于本次 Provider 的 sing-box 内存，不进入 Profile、持久 Provider 配置、
  缓存、日志或 Debug。解析与 route resolve 均不缓存，不调用 Tailscale DNS transport
  或默认 resolver；会话结束清空。
- 平台 Ingress 只取得同一 Libbox 事务返回的有界捕获名称，用于优先的 port 53 host rules；
  不取得成员 IP 映射或自行派生 DNS 归属。捕获集合为空、畸形或超限时不 Commit。

该快照契约不自动扩展到 iOS / tvOS 的现有 DNS 路径。

Tailscale 的 endpoint 在 delta 后必须标记已变异；即使下一张 full map 等于旧快照，也要先
upsert endpoint 并重算 relay candidate，避免 `A → delta(B) → full(A)` 留下旧运行状态。
LocalAPI 状态、control 接受、远端 map、fresh handshake 和真实出口是独立事实。
握手失败归因到该 Line，不靠重启远端、固定 DERP、轮换身份或 Direct 回落解决。
Home DERP 重选是显式维护能力，不是连接准备条件。

入口：[Tailscale 运行能力](core/libbox/tailscale_runtime_gvisor.go)、
[认证](core/tailscalesetup/)、[结构化证据](docs/verification/tailscale.md)。

### 3.3 AnyConnect（D30）

sslcon 是进程级单例；active Scenario 的有效依赖中至多有一条 AnyConnect Line，多条直接生成失败。
同配置的运行能力可以被新旧 Box 共享，认证与恢复由 Line 自己持有，不因 Scenario 切换重做。
不同配置的单例不能并发准备，切换保留旧场景并明确需要重建线路。

入口：[AnyConnect 运行能力](core/libbox/anyconnect_runtime.go)。

## 4. DNS

### 4.1 名字、线路与地址（D-DNS）

**已知目标先确定 Line，再按该 Line 的解析视角取地址并连接。** 目标已由域名或字面 IP
明确命中绑定时，预解析、探测、失败回退都不能先经过无关 Line。解析能力由 Line 提供，
使用权由 Scenario 决定；同一 Line 的内网名与公网名也不一定使用同一 resolver。

域名 binding 的 DNS 与 route 从同一 Scenario 同源编译，保持彼此顺序。纯 IP 与不可安全
拆分的 mixed 分支不生成 DNS 规则，也不截断后续明确的域名分支。
需要地址才能分类的 IP 规则可先采用 Underlay 解析；未命中后，默认分支仍按 Scenario 默认
Line 重新解析，不把分类答案或其他解析视角的缓存带入最终出口。
Application binding 的 `auth_user` 归属同样贯穿 DNS 与 route resolve。

### 4.2 Direct 原生解析

Direct 使用完整 Underlay 的解析语义，不寻找绕过既有 VPN 的“物理 DNS”。盒内有两条不同路径：

| 输入 | 解析路径 |
|---|---|
| 已捕获的系统 / 应用 DNS flow | sing-box 裁决为 Direct 后，经 Direct dialer 转发原 UDP/TCP 查询字节到原 resolver endpoint；响应校验事务 ID、问题和目标 |
| 无原始 flow 的盒内主动解析 | 使用 Apple `DNSServiceGetAddrInfo`，保留系统 scoped resolver、搜索域与既有叠加 |

已被接管、等待 Provider 应答的查询不能再次交给 mDNSResponder。
缺少原始上下文或校验失败不回落到重建查询、首选 resolver 裸 UDP 或公共 DNS。
Provider 不读域名、不执行第二次 DNS 裁决。

入口：[DNS transport](core/libbox/mobile_dns_transport.go)、
[原查询与系统解析补丁](patches/sing-box/)。

### 4.3 就绪与地址族

Direct 的就绪证明是当前 Underlay 上下文与配置归属，**不依赖固定外部 DNS、TLS 或出口
展示服务**，也不声称由此证明整个 IPv4 / IPv6 可达。其他 Line 的实际服务依赖经该 Line
的精确出口验证；诊断和展示失败不升级为无关 Line 或整个 Scenario 的连接门槛。
固定 IP、公共 resolver、TLS 或单个目标失败均不足以判定整个网络或地址族不可用。

能力属于具体 Line、network epoch、运行 revision 与候选 Box；旧结果不能跨事务复用或
传播到其他 Line。已有有效地址族限制时，同一 Line 的 DNS、Application binding 与 route
resolve 使用一致策略；合法单栈不等于整条 Line 失败，双栈也不因单点失败全局降为 IPv4。

应用可能保留旧地址。仅当 flow 有经校验的原始域名、且 endpoint 地址族不符合所属 Line
的有效能力时，盒内才在选定 Line 后重新解析。字面 IP 不存在安全重解析路径。
connect-by-name UDP 在 SOCKS 边界保留域名；这不代表支持 unconnected 多目标 UDP 或 QUIC 迁移。

入口：[就绪证明](core/libbox/line_network_readiness.go)、
[Direct 无强制 TLS 测试](core/libbox/line_network_readiness_test.go)。

### 4.4 fake IP（D-FAKEIP）

当前不启用 fake IP。预留地址段与 TUN 的 `198.18.0.0/15` 分离，避免与基础设施地址及旧 DNS
残留识别混淆；未来启用也只保留域名关联，不改变同一 Scenario 的出口裁决。

## 5. 连接、切换与恢复（D35、D36、D40）

### 5.1 连接事务

`ConnectionPlan` 由 active Scenario 的有效依赖闭包编译，包含真实任务和依赖，不是按协议
排列的固定流程。跨语言合同使用 `schema_version: 3` 与 `scenario`，无旧领域名别名。

| 阶段 | 边界 |
|---|---|
| `planning` | 校验引用与依赖图，无网络副作用 |
| `preparing → readyToCommit` | 准备所需 Line、规则缓存和完整 sing-box，不提交系统网络设置 |
| `committing → committed` | 所有所需任务 ready 后，首次连接以 `setTunnelNetworkSettings` 接管系统流量 |
| `rollingBack → rolledBack → failed/cancelled` | 任一步失败或取消时逆序、幂等、有界撤销已完成的会话副作用 |

Profile、持久身份与有效 RuleSet 缓存不回滚；本次会话、Box、relay、monitor 和已提交网络
设置被回收。原始失败与回滚失败分别保留，报告明确记录系统接管是否移除。
接管中的转发失败关闭 flow；Line 暂时不可用时对应流量 REJECT、DNS SERVFAIL，不静默回落
Direct、公共 DNS 或其他 Line。启动阶段构造成功不代表数据面已启动或系统 Commit 成功。

### 5.2 状态所有权

运行事实来自带 transaction ID 的 `ConnectionReport`，宿主、UI、Debug 与测试消费同一份
任务、错误、时间和回滚结果。日志不驱动状态机，Network Extension 的 `connected` 也不是
事务或真实出口成功的替代。打开设置、展开 Line 或刷新 UI 不产生探测、刷新线路或网络请求。

Provider 诊断限定当前事务的 active Line。短时 route watch 只返回有界归属与 sequence，
不返回目标、规则、URL、凭据或浏览记录；超时或事务结束即失效，结果不参与流量裁决。

Provider 是运行报告的权威写入者。root 与用户 App Group 是不同容器：初始报告随启动
options 传入，Provider 原子 journal 由文件锁串行写入，helper 只读转发，宿主镜像给 UI。
残留半完成事务先与系统状态协调清理；journal 无法可靠写入时不能 Commit。

配置指纹由 Go 与计划同源生成：包含实际 binding 顺序、默认 Line、有效依赖及 fetch Line；
排除显示名称、图标、SSID 和顶层视觉排序。Swift 只比较指纹判断 `configDirty`。
指纹及其投影可能受凭据影响，不进入日志或 Debug，外部只看到比较结果。

入口：[配置指纹](core/config/runtime_fingerprint.go)、
[Provider 报告](macos/TransparentProxyExtension/ConnectionTransactionReporter.swift)。

### 5.3 Switch 与 Line 租约

已连接时的场景切换、重连和自动选择创建候选 Switch；旧 generation 在候选准备期间继续
承载流量。候选重新编译完整计划和 Box，不先停止旧 Line、移除系统接管或原地热改规则。

- 配置身份完全相同的 Line 取得同一能力的租约，变更身份另行准备。身份由 Go 同源生成，
  包含协议、endpoint 与凭据因素，排除展示字段；身份材料不对外暴露。
- 能力池仅供当前 committed 与唯一候选计划持有。恢复归 Line 的唯一 owner；候选取消
  或旧 Box 退役只释放自己的租约，最后一个租约释放才停止能力，不并发创建第二个握手任务。
- 当前 epoch、revision 与 generation 的就绪证明有效后才 Commit。迟到成功不能恢复旧
  ready；同一 Line 的新成功不能清除其他 Line 的失败或 Box 结构错误。
- 提交原子切换新 flow 的 relay generation 与完整 DNS / route 配置；旧 flow 有界排空。
  规则、DNS 和默认出口不能分成多个可见提交。
- 候选失败只清理候选，保留旧场景、网络设置和连接时长；提交中失败恢复旧 relay。
  无法证明旧 generation 健康时才进入全局回滚。报告同时保留 from、to、候选与仍承载流量的事务。
- 任意时刻最多一个候选，latest-wins；相同目标与配置指纹为 no-op。显式断开优先取消候选
  和恢复意图，再释放全部租约与系统接管。单例身份变化不能伪装成可复用的无中断切换。

入口：[Line 能力池](core/libbox/line_runtime_pool.go)、[Switch 测试](core/libbox/switch_test.go)。

### 5.4 网络变化与恢复

NWPath、默认路由、DNS 与 SSID 的同次物理变化合并为一个不含 SSID 的 network epoch；
稳定样本只形成最终 `(epoch, desired Scenario, Underlay fingerprint)` 的一笔 Switch。
旧 epoch 的候选和退避回调失效，网络稳定不等于 Line 登录、握手或真实出口已恢复。

休眠至完整 `didWake` 之间只积累变化，Dark Wake 不停止已提交事务或创建候选。
唤醒后等价 Underlay 保留旧 generation；真实指纹变化才换代。Provider 仍 connected 时，
Line 自己处理协议恢复，不能仅凭路径不可用 / 恢复边沿重复连接。

同代 Line 局部恢复保持其他 Line、Ingress、Box 与 transaction ID 不变；局部预算耗尽、
Provider 掉线或共享组件失败才提升为完整恢复。完整恢复在 Rollback 与系统接管移除后进行，
共享五次预算；短暂连上不重置，同一事务稳定五分钟后才清零。
自动场景意图的瞬态失败保留 desired Scenario，按 2 / 5 / 10 秒最多重试三次，同 epoch
重复事件不重置。显式连接 / 切换失败、凭据 / 证书 / 配置等终止错误不自动循环；显式断开
立即取消所有恢复。重试进度、原始失败与断线历史均为结构化事实。

入口：[epoch 协调](macos/Shared/NetworkEpochSwitchCoordinator.swift)。

## 6. 安装与更新（D37）

安装是持久平台前置条件，由 `InstallationReport` 表达，与 Scenario 的 `ConnectionPlan`
独立。首次启动和升级共用 bundle → helper → System Extension 流程；人工批准暂停在准确
步骤并在批准后继续。连接与 Tailscale 配置消费安装结果，不另行补注册组件。

安装可以替换 App、注册 helper、激活扩展，但不建立 Line、下载 RuleSet、启动 sing-box、
读取或改写 Underlay、创建 / 启用 Transparent Proxy 网络配置或提交 DNS / 路由。
安装成功不代表连接就绪；替换过程可能终止旧进程，[安装命令的实际副作用](docs/agent/development-builds.md)
与“安装不接管流量”是不同边界。

同通道替换要求身份与签名匹配，保留临时旧包，二次验签后清理；失败恢复旧包，下载原件保留。
helper / 扩展失败停在对应安装步骤，幂等重试以 macOS 结构化状态为依据。

Debug 与正式版的 App、嵌套组件、签名、数据、凭据、App Group、IPC 和维护标记全部独立；
不自动迁移或清理另一通道。FormalDevelopment 保留正式身份，仅用于正式身份验证。
签名 profile 与 entitlement 属于对应身份，不以移除能力或借用正式身份填补 Debug 签名缺口。
独立安装不代表两个数据面同时接管已被证明兼容。

更新候选来自固定 Pages 地址的一份完整、版本化清单，归档由 GitHub Releases 托管；
客户端不通过匿名 API 或 HTML 拼装候选。检查、下载和验证不改变当前连接，安装点击后才交接。
缓存不是安装许可：下载与安装前重新确认候选，撤回、变化或无法确认即停止；归档大小、摘要、
实际版本 / build 与嵌套签名共同绑定同一候选。验收包的固定 acceptance ID 与正式更新隔离。

入口：[安装状态机](macos/Shared/InstallationTransaction.swift)、
[构建与身份](docs/agent/development-builds.md)、[更新协议与发布](docs/agent/updates.md)。

## 7. RuleSet 资源（D28、D38）

URL RuleSet 的 `fetch_line_id` 默认 Direct，仅拥有资源的 DNS、HTTPS、重定向与下载路径；
解析和连接经过同一精确 Line。它不是 Scenario binding，不生成用户 route、普通 DNS 分域
或默认出口。只有 active Scenario 引用该 RuleSet 时才产生获取会话或请求。

有效缓存按 RuleSet 身份、URL 与格式寻址，连接直接使用；过期缓存在 Commit 后刷新，
当前运行保持启动快照，新副本下次连接生效，新鲜缓存无网络请求。
无有效缓存时，Commit 前建立限时、无系统 Ingress 或 Scenario binding 的获取会话，
完成所需出口、DNS、HTTPS / 重定向 / 全地址 SSRF、内容语义校验与原子落盘后停止。
失败归因对应 RuleSet，不静默换 Direct。

后台刷新可复用正式数据面已有的同一获取 Line，否则建立同类隔离会话；进程级单例冲突时
保留有效缓存、延后刷新，不破坏已提交连接。
GEOIP 资源仅来自显式 `geoip_rule_set_url_template`，含 `{code}` 且为 HTTPS 或规范化绝对
`file://` 路径；缺失或非法时生成失败，无内置公共源或回退源，凭据不烘入应用与仓库。

## 8. SSID 激活（D39）

`match_ssids` 精确、区分大小写且不跨 Scenario 重复，空列表仅手动选择。SSID 变化经与点击
相同的意图激活场景：已有连接意图则 Switch，已显式断开则只改变选择；无匹配保持当前场景。
手动选择持续到 SSID 下次变化。

SSID 只是触发条件，不证明网络可信，也不进入 Provider、计划、日志、Debug、DNS、route 或
Underlay 快照。宿主在位置权限允许时读取；拒绝、Wi-Fi 关闭或读取失败不触发自动动作，
UI 显示权限状态，手动切换仍可用。

## 9. 历史兼容边界（D29、D31、D32、D34、D-CRASH）

- macOS 全流量 Packet Tunnel 会与既有 Enterprise Tunnel 互相取代，因此不作桌面入口；
  此限制不适用于 iOS / tvOS 当前入口。
- 旧原生 TUN 保留在 helper / CLI 与恢复路径。默认接口只能来自启动前系统路由；
  `RTF_GLOBAL` Underlay 在建立 Line、获取规则或接管流量前被拒绝，避免入口绕过。
- 旧 DNS 接管地址为 TUN 地址 +1；原地址是本机 `RTF_LOCAL`，不能把查询送进 TUN。
  DNS 接管路径未就绪即连接失败。已记录地址与保留网段共同识别历史残留，清理能力仍保留。
- 旧 TUN 崩溃语义为清理接管、恢复 Underlay 并强通知；不能据此推断 Transparent Proxy
  的 Provider 崩溃与系统自动拉起已经具有相同保证。
- D29 移除的是旧内置 Tailscale 的越界实现；D33 重新引入盒内 Line，不恢复产品级 Underlay 特例。

历史路径入口：[DNS 接入与自愈](core/engine/dns_takeover.go)、
[Underlay](core/engine/underlay.go)、[Transparent Proxy 证据](docs/incidents/d35-transparent-proxy-evidence.md)。
