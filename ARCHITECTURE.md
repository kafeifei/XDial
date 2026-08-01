# XDial 架构约束规范

## 0. 这份文档是什么

这是 XDial 的**架构约束规范**，不是代码导览。任何 AI 编码工具（Claude Code /
Codex / Cursor）和人类贡献者在改动本仓库前必须先读完本文，改完后必须能对照第 7 节
（禁止事项）和第 8 节（不变量测试）自证没有越界。

**为什么要有这份文档。** XDial 桌面版长期不稳定的根因不是某个函数写错，而是**模块越界**：某个维度的组件擅自替另一个维度做了决策，且这个决策对用户不可见。典型症状是"改一个看似无关的开关，全局路由/DNS 行为整个变了，且没人能在配置里指出是哪一行造成的"。这类 bug 无法靠 code review 逮住——每一处单看都"合理"，问题只在跨模块组合时出现。

因此约束由两部分构成，缺一不可：

- **本文档**——说明边界在哪、为什么在那里、越界长什么样。给人和 AI 读。
- **CI 不变量测试**（第 8 节）——把边界编码成可执行断言。给编译器读。

文档负责让你**理解**边界，测试负责在你**没理解**时把提交拦下来。如果你发现测试挡住了一个你认为正确的改动，**先停下来和用户讨论修改架构约束，不要绕过测试、不要放宽断言、不要给断言加特例分支**。

本文只记录**不能安全地从当前代码反推**的事实：职责边界、因果关系、失败语义、真实事故
证据、架构决策及被否决方案。目录树、类型/字段/函数清单和临时实现状态以源码与测试为
准，不在这里复制。必要的代码定位只使用文件路径和符号名，不使用容易漂移的行号。

---

## 1. 三条定律

### 定律零：控制面与数据面分离

> **XDial 负责表达、编译和托管；sing-box 负责接管、解析、裁决和转发。**

正面定义：

- XDial 的产品职责是 Line / RuleSet / Mode 的编辑、校验、编译，以及 sing-box 生命周期管理。XDial 不自行实现路由选择、DNS 分流、接口优先级或逐流转发。
- sing-box 是唯一的数据面：TUN 收包、DNS 应答、规则匹配、出口选择和逐流转发都由
  生成的 sing-box 配置完成。平台宿主只能向它提供操作系统事实，不能替它裁决。
- sing-box 尚不支持的线路协议可以有**窄适配器**。当前 AnyConnect 的 `sslcon` / `VPNBridge` 只把协议能力暴露成一个 sing-box 可用的 outbound；它不得读取 RuleSet、Mode 或自行裁决流量。
- 平台宿主可以执行 sing-box 无法脱离操作系统完成的接入动作。macOS 桌面由
  `NETransparentProxyProvider` 接收系统交付的 TCP/UDP flow，把启动前 `NWPath`
  的完整候选和同一时刻内核默认路由选中的接口原样交给同进程 sing-box；Apple 移动端仍由
  `NEPacketTunnelProvider` 提交 TUN/DNS/路由。旧原生 TUN helper 只保留为历史实现
  与诊断边界，不再是桌面 App 的主数据面。平台宿主不得包含域名、Line、RuleSet、
  Mode 或网络产品特例。

反面案例：

- XDial 根据当前存在的 VPN 产品、接口名称前缀或物理/虚拟分类，自行猜测
  `default_interface` / `bind_interface`。旧原生 TUN 唯一允许提供的
  `default_interface` 是启动 sing-box **之前**从系统默认路由读取的原值；
  Transparent Proxy 只允许提供同一时刻的内核默认路由结果和完整 `NWPath` 快照。二者转交的都是操作系统
  既有裁决，不是 XDial 的产品裁决。
- 在 Swift 或 daemon 里实现一套与 sing-box 并行的 DNS/路由规则。两套裁决一旦漂移，界面显示的 Mode 与真实数据面不再是同一件事。

### 定律一：外部密封律

> **XDial 自己只增加一个网络叠加层。DNS、路由、分流全部由这一层内的 sing-box 处理，不向系统散落策略。**

正面定义：

- 启动 XDial 前，系统可能已经由网线、Wi-Fi、官方 VPN 客户端等形成多层 Underlay。XDial 把这个整体视为不透明输入，不拆解、不重排、不接管其中任何产品。
- 系统层只能看到一个 XDial 接入层：macOS 是一份 Transparent Proxy 网络配置，
  iOS/tvOS 是 sing-box 使用的一个 TUN 和对应 DNS 设置。除此之外，XDial 不额外散落
  resolver 文件、代理设置、防火墙规则或产品级接口绑定。
- 所有分流决策发生在 sing-box 配置内部。系统不知道"哪些域名走哪条线"，也不需要知道。
- 盒子的边界是可枚举、可清理的：macOS 停止 Transparent Proxy 后不留下 XDial 路由
  或 DNS；旧原生 TUN helper 的 DNS 残留仍由 `core/engine/dns_takeover.go` 自愈，
  不能因为它不再是主入口就删除恢复能力。

反面案例（真实历史）：

- **桌面 DNS 出口曾硬编码 `direct`**。DNS 查询走 `direct` 出口 = 从物理网卡明文发 UDP 53 到系统 resolver。这意味着**解析这一步整个发生在盒外**：盒内的分域规则、经隧道解析、企业 DNS，全部没有机会生效。用户看到的是"配了规则但分流不准"，而配置文件里看不出任何问题——因为问题在于那条规则根本没被求值。修复后系统 DNS 包一律 `hijack-dns`（`core/config/generator.go` 的 `buildSystemRouteRules` / `buildNESystemRouteRules`），由 sing-box 自己应答，`buildDNS` 的分域链才成为唯一解析路径。
- 相关的次生灾难：启动前 Underlay 的系统 resolver 可能只在某个下层虚拟网络里可达。XDial 接管路由后若把 DNS 包强制从某个物理接口转发出去，就会形成解析黑洞，表现为**连接 XDial 后整机断网**。这正是"溢出到系统层"的代价：盒内正确性依赖盒外某个被错误选定的接口。

### 定律二：内部正交律

> **Ingress / Line / RuleSet / Mode 四个维度互不知道对方存在。Mode 是唯一的连接点。**

正面定义：

- 四个维度各自只掌握自己那一层的信息，不持有、不查询、不推断其他维度的对象。
- 只有 Mode 同时看得见 RuleSet 和 Line，并负责把它们绑定起来。
- **声明 ≠ 生效。** 一个对象存在于 Profile 里，只表示"用户配置过它"。它是否对本机
  流量产生任何影响，唯一取决于 active Mode 是否引用它。未被引用的对象不得进入数据
  面配置，也不得持有影响本机流量的活会话。

反面案例（真实历史）：

- **某线路 `enabled` 即全局注入自动路由**。线路携带的默认路由覆盖了 Mode 的 `final`，用户在 Mode 里配好的"默认直连"被一条谁也没写过的规则抢走。这是 Line 越权做路由裁决：Line 只该声明"我是一个出口"，却直接改写了全局默认。
- **同款问题的 DNS 版本**：某 Line 只因存在就注册全局 resolver，接管所有域名，而不是由 Mode binding 决定解析归属。默认 resolver 的变化因此可以静默改写整个 Profile。
- **订阅规则表隐式抢注在用户显式绑定之前**。订阅自带的规则表（Clash/Surge 的
  `RULE-SET` / `DOMAIN-SUFFIX` 列表）曾无条件排在 Mode 绑定之前，导致订阅里的大网段
  吞掉用户显式写的精确规则。用户看到的是“我明明绑定到了某条线路，流量却被订阅规则
  遮蔽”。因此用户显式绑定必须先于供给规则；改变这个优先级属于架构变更。
- **某线路的交互式认证流程反过来约束全局引擎状态机**。这是依赖方向倒流：一个协议的认证细节爬到全局生命周期上，让其他线路一起承担"必须断开"之类的代价。旧桌面 Tailscale 因此按 ADR **D29** 整体移除；后续只有在认证被隔离成显式、限时、无系统副作用的配置会话之后，才按 **D33** 重新引入。

---

## 2. 四个正交维度：职责边界

| 维度 | 负责什么 | 绝不负责什么 | 典型违规写法 |
|---|---|---|---|
| **Ingress**（入口）<br>tun / 系统代理 | 流量如何进盒；把包归因到源（进程、接口、地址族）；声明盒子占用的地址段 | **绝不参与路由裁决**。不决定任何流量走哪个出口，不携带任何域名/规则知识 | 在 `buildTUNInbound` 里按线路类型改 `route_exclude_address`（VPN 服务端地址例外是密封性要求——不排除就会自环——不是裁决）；在 inbound 上挂 `outbound` 字段；按"当前模式"改 tun 地址段 |
| **Line**（出口） | 声明"怎么到达一个出口"：协议参数、凭据、传输选项、**能力**（能解析哪些后缀、是否自带 resolver、是否自带路由供给） | **绝不自行生效**。未被 active Mode 引用时，不得对本机流量决策产生任何影响；不得注册全局路由；不得抢占默认出口；不得改写系统状态 | Line 未被 active Mode 引用或用户未打开可见能力开关，就往 `route.rules` / `dns.rules` 插入 `preferred_by`；线路自己改写 `final`；线路 enabled 就发起出网连接 / 持有活跃会话 |
| **RuleSet**（匹配） | 只管**匹配流量**：域名、后缀、CIDR、远程规则集资源 | **不知道任何 Line 存在**。`RuleSet` 结构体里绝不能出现 `line_id`、`outbound`、`server` 之类字段 | 在 `RuleSet` 上加 `DefaultLineID`；在 `buildRouteRule` 里根据规则集内容猜出口；订阅规则表直接携带出口名并绕过 Mode |
| **Mode**（裁决） | 唯一裁决者：绑定 RuleSet→Line、指定默认出口、裁决 DNS 分域归属。route 规则和 DNS 规则**必须从同一份 Mode binding 编译** | 不定义匹配内容（那是 RuleSet），不定义出口参数（那是 Line），不定义流量如何进盒（那是 Ingress） | Mode 里内联域名列表；Mode 里内联服务器地址；route 规则从 Mode 编译而 DNS 规则从别处编译（两者必然漂移） |

**依赖方向是单向的**：`Mode → {RuleSet, Line}`。RuleSet 不指向 Line，Line 不指向 RuleSet，二者都不指向 Mode。Ingress 谁也不指向。任何引入反向或横向依赖的改动都是越界。

数据模型必须直接体现这条依赖方向。**给 `Line` 或 `RuleSet` 增加一个指向对方或
Mode 的字段，就是越界的最短路径。**

---

## 3. 供给源模型（D28）

现实需求：订阅，以及未来可能加入的线路适配器，可能天然“自带规则”。

朴素做法是让它们自己往生成的配置里插规则——这正是定律二的两个反面案例。D28 给出的解法是：

> **供给出来的规则必须以一等公民身份进入 Mode 裁决——可见、可禁用、可排序、可不用。绝不隐式抢注。**

四个形容词是硬指标，逐条含义：

- **可见**：供给出来的每一条规则，用户必须能在 UI 里看到它的存在、来源、匹配内容和目标出口。生成的 `route.rules` 里不允许存在任何用户无从得知的条目（这正是不变量 INV4 守护的）。
- **可禁用**：用户必须能关掉任意一条供给规则，且关掉后它从生成配置中彻底消失，不留任何降级替身。
- **可排序**：供给规则相对于用户手写绑定的优先级必须可见。默认顺序不是不可变事实，
  但任何调整都必须是显式产品决策并同步更新本文档。
- **可不用**：完全不引用供给源时，配置里必须一个字节都看不出这个供给源存在过。

供给源与消费者之间的关系是**申报制**，不是注入制：Line / 订阅向 Mode **申报**"我这里有这些规则"，Mode 决定采用哪些、放在什么位置。申报动作本身不改变任何生成产物。

D33 只有一个窄例外：被 active Mode 引用的 Tailscale Line 可以由用户在该 Line 上显式
勾选 MagicDNS。此时 DNS 与 route 必须成对使用 sing-box endpoint 从当前 NetMap 动态
申报的 `preferred_by`，且排在 Mode 的显式绑定之后；未引用或未勾选时产物必须为零。
这不是一般 Line 供给规则的豁免，不允许扩展成硬编码域名、CIDR 或默认路由。

---

## 4. DNS

### 4.1 因果链：名字 → 线路 → 地址

这三步的顺序**不可交换**，理由是一条严格的因果链：

1. **分流只需要名字。** 判断 `google.com` 该走哪条线，不需要知道它的 IP。规则匹配的输入是域名。
2. **解析的正确答案取决于从哪出去。** `oa.corp.example` 在企业 DNS 有记录、在公共 DNS 是 NXDOMAIN；`google.com` 经本地 resolver 解析可能被中间层改写、经隧道那头解析则是权威结果。**同一个名字，从不同出口解析得到不同且都"正确"的答案。**
3. 所以：**先按名字选线路，再按线路选解析器，最后才拿到地址。** 反过来（先解析再分流）等于用一个任意选定的解析器的答案去做本该由线路决定的判断，结论必然错。

推论：**解析权随线路走。** Line 只声明解析能力（例如企业 DNS 或经隧道的 DoH），
Mode 决定是否使用。同一条线路上，内网域名与公网域名也可能需要不同的解析视角，因此
不能仅凭 Line 类型自动选择 resolver。

**DNS 规则与路由规则必须从同一份 Mode binding 编译。** 两者一旦分家，就会漂移：
某个域名的流量走 A 线路、解析走 B 线路，得到的地址在 A 线路那头根本不通。

**这条约束的作用域只能是「基于域名的绑定」，这一点是因果链的直接推论，不是妥协。** 路由裁决可以基于 IP（`ip_cidr` / GEOIP / `ip_is_private`），而 DNS 裁决发生在拿到 IP **之前**。要求"任意域名的 DNS 判定与路由判定一致"等于要求 DNS 阶段就已经知道解析结果——逻辑上自相矛盾。所以正确表述是：**基于域名的绑定必须双向一致（有路由分支就有 DNS 分支，反之亦然）；基于 IP 的绑定天然不参与 DNS 分域。** 不变量 INV7 就是按这个收窄版写的。

两个显式边界是：`direct` 线路不声明独立解析器（本就使用 Underlay 视角），因此不产生额外
DNS 分支；以及 D33 的 Tailscale MagicDNS 开关，它只在该 Line 被 active Mode 引用且
用户勾选时，将同一个 endpoint 的动态 DNS 归属与 peer 路由成对编译。MagicDNS 规则排在
Mode 的显式域名绑定之后，所以与 CDN / 企业域名重叠时仍由 Mode binding 获胜；不得把
Tailscale 默认 resolver、硬编码 Tailnet 地址段或默认路由带入这个例外。这里的 Underlay 视角是 macOS 在 XDial 启动前已经组合并最终选定的
DNS；官方 VPN 存在时可以就是该 VPN 的 DNS，绝不等于绕过所有叠加层去寻找物理网卡
或路由器的 resolver。

**Mode 的默认线路也拥有默认解析权。** 没有命中任何更具体域名 binding 的名字，与没有
命中任何更具体 route rule 的流量，必须落到同一条 Mode 默认线路。Transparent Proxy
在 IP 规则前仍可用 Underlay DNS 做一次保守解析，只用于判断该 IP 规则是否命中；如果
没有命中，进入默认线路之前必须再从默认线路的解析视角求值，不能把用于分类的 Underlay
答案直接带到另一个出口。默认线路是 `direct` 时，两次解析自然都是完整 Underlay 视角；
默认线路是代理、AnyConnect 或内置 Tailscale 时，最终解析经该线路完成。

### 4.2 fake IP 的定位

fake IP 常被误解成一种分流机制。它不是。

问题的本质是一条**失忆缝隙**：应用先 `resolve("google.com")` 拿到一个地址，然后 `connect(地址)`。到了 connect 这一刻，"这个连接是发给 google.com 的"这个信息已经丢了——内核只看得见一个 IP。sing-box 在 connect 侧只能靠 sniff（读 TLS SNI / HTTP Host）把名字找回来，而 sniff 对非 TLS/HTTP 协议无效。

fake IP 的作用是：在 resolve 时刻返回一个**唯一的假地址**作为凭证，并记住"这个假地址 ↔ 这个域名"。connect 到来时，凭假地址查回域名。

所以准确的描述是：

> **fake IP 不做任何决策。它只是在连接到来时，"回忆起"DNS 时刻已经做出的决策。它的作用域严格限于 resolve 与 connect 之间的失忆缝隙。**

这决定了它在架构约束里的位置：fake IP 是**实现细节**，不是维度。它不得改变任何裁决结果——同一份 Mode，开不开 fake IP，流量的出口归属必须完全一致。任何"开了 fake IP 之后分流行为变了"的实现都是错的。

v1 不启用 fake IP（ADR **D-FAKEIP**），但地址段必须预留且与 tun 段分开，理由见 ADR。

### 4.3 旧 macOS 原生 TUN 的 DNS 接入边界

本节记录旧原生 TUN 实现留下的事故证据与恢复约束；D35 之后它不再是桌面 App 的主
数据面。该形态能够声明应由系统使用的 DNS 地址，但
不能像 Network Extension 一样直接提交 `NEDNSSettings`，所以由
`core/engine/dns_takeover.go` 执行窄平台接入。它不是第二套 DNS 数据面：地址来自
sing-box TUN 约定，所有查询仍进入 sing-box 的 `hijack-dns`；适配器只负责应用、
就绪等待、恢复和崩溃自愈，不读取任何产品或策略对象。

以下要点提炼自该文件顶部三个常量的注释块（`dnsTakeoverAddress` /
`dnsTakeoverGateway` / `dnsTakeoverPrefix`）。那里写得比本节详细，**改这块前请完整
读原文**。

- **接管地址是 tun 接口地址 +1（`198.18.0.2`），不是 tun 地址本身（`198.18.0.1`）。** tun 自己的地址在内核路由表里是 `RTF_LOCAL` 项，发往它的包被环回投递给本机协议栈，**根本不会写进 tun 设备**，`hijack-dns` 永远接不住 → 系统 DNS 查询原地超时 → 整机解析全灭。`198.18.0.2` 不是接口地址，走的是 `auto_route` 装的 sub-range 路由，包会真正进 tun。sing-box 官方 libbox 的 `GetDNSServerAddress` 用的也是 `Addr().Next()`，同款约定。
- **为什么非接管系统 DNS 不可**：启动前 Underlay 的 resolver 可能通过 on-link 路由或下层虚拟接口可达，天然绕过 XDial 的 tun。不接管的话应用拿到的解析结果不受当前 Mode 的分域链约束，按域名分流随之失准。这是定律一的直接推论——解析不能留在盒外。
- **就绪判据**：`route -n get 198.18.0.2` 打印的 gateway 行等于 `198.18.0.1`。darwin 上 `auto_route` 装的是覆盖 IPv4 的多条 sub-range 路由，每条都是 `RTF_GATEWAY` 且 gateway 就是 tun 地址。其他下层虚拟接口的 link route 不满足该判据，因此不会被误认成 XDial 数据面已经就绪。该判据失败时，完整连接必须失败并回收数据面；不能只警告后显示 Connected，因为那意味着 DNS 仍在盒外、域名规则没有可靠生效。
- **残留识别是双判据**：先比对显式记录过的地址列表，再兜底判断"是否落在 `198.18.0.0/15` 段内"。RFC 2544 的这段地址不会出现在任何真实 DNS 配置里，误判率为零；而漏认一个的代价不可逆——一个死地址永久留在系统 DNS 里，没有任何路径会去救它。
- **地址同源约束**：`dnsTakeoverAddress` 与 `buildTUNInbound` 生成的 tun 地址必须保持 +1 关系，防漂移断言是 `TestDNSTakeoverAddressIsTunAddressPlusOne`。
- **适配器不做产品裁决**：它不得枚举、识别或针对某个 VPN 产品选择 resolver/interface。启动前的网络整体是 Underlay；XDial 只确认自己的 sing-box 路径已经就绪。

---

## 5. 铁律

1. **失败 fail-closed，且用户可感知。** 任何一步失败，宁可让流量断掉并弹出可见
   错误，也不能“看起来连上了，但流量实际绕过 XDial 从 Underlay 直接发送”。
2. **绝不静默降级到 direct 或公共 DNS。** 降级本身可以存在，但必须是用户显式配置的，且必须有可见提示。代码里出现 `if err != nil { use direct }` 一律视为越界。桌面宿主无法取得启动前默认接口时必须拒绝启动；DNS 接入失败必须终止本次连接并通过 `callback.OnError` 暴露，不能假装密封盒已经完整生效。
3. **Line 不可用窗口期（重连中）语义固定**：绑定到该 Line 的流量 **REJECT**，
   对应域名的 DNS **SERVFAIL**。不是超时、不是回落到其他线路、不是放行到 direct。
   理由：超时会让应用重试几十秒后才失败，用户以为是网络慢；回落会让流量从错误的
   Underlay 出口发送。
4. **配置变更只有唯一生效通道**：修改 Profile → 重新生成完整 sing-box 配置 → 重启数据面。不允许存在"运行时热改某条规则"的旁路。桌面通过 Clash API 切换 `testSelectorTag` 的逐线路地址探测只是诊断能力，不影响用户流量归属。
5. **启动期失败必须被捕获。** `sing-box check` 只做构造校验，抓不到数据面真正 `Start` 时的错误。桌面子进程由 `Engine.handleSingBoxExit` 把异常退出转成用户可见错误；移动端 Network Extension 必须在 libbox 启动且系统网络设置提交成功后才完成 `startTunnel`。
6. **生成阶段 fail-fast。** 悬空引用（`inspectModeReferences`）、重复 outbound tag、多条 active AnyConnect 线路，以及多条 active Tailscale 线路，一律在生成阶段返回 error。宁可拒绝生成，也不要让系统显示 VPN 已连接而数据面尚未可用。

---

## 6. 决策记录（ADR）

### D28 — 供给源模型

- **决策**：Line 和订阅可以"自带规则"，但供给出的规则必须以一等公民身份进入 Mode 裁决：可见、可禁用、可排序、可不用。供给是申报制，不是注入制。
- **理由**：现实中的订阅和未来适配器可能携带路由知识，硬堵会让功能不可用；但直接注入会摧毁定律二，且产生的 bug 无法在配置里定位。申报制在保留能力的同时把裁决权留在 Mode。
- **被否决的替代方案**：(a) 完全禁止自带规则——订阅会失去核心能力；(b) 自带规则直接注入生成配置——已实证会摧毁 Mode 默认出口；(c) 给供给规则一个固定的低优先级——用户无法表达"我就是要订阅规则优先"，且顺序仍不可见。

### D29 — 桌面端移除旧内置 Tailscale（历史决策，已被 D33 取代）

- **决策**：当时的桌面 XDial 移除 Tailscale Line、认证、状态目录、DNS 和路由特例。官方 Tailscale 客户端如果已在运行，仍只是启动前 Underlay 的组成部分，与网线、Wi-Fi 或其他 VPN 在 XDial 看来没有区别。
- **理由**：Tailscale 同时带来了控制面认证、endpoint 生命周期、MagicDNS 和路由供给，迫使 XDial 为一个外部网络产品理解并重建系统已有的叠加关系，违反定律零。它也是本轮桌面不稳定的主要新增变量；先移除能恢复最小、可验证的闭环。
- **被否决的替代方案**：(a) 保留内部 endpoint 再逐条修产品特例——依旧让 XDial 知道 Underlay 产品；(b) 识别官方 Tailscale 的 utun 并固定绑定——把系统已经决定的组合关系降级成脆弱的接口名称规则。
- **后续**：D29 证明了旧实现不能保留；它没有永久否定 sing-box 盒内 endpoint。D33
  只重新引入符合三条定律的新实现，不恢复上述产品特例。

### D30 — 每 profile 至多一条 active AnyConnect Line

- **决策**：v1 硬校验：一个 profile 里 active（被 active Mode 引用且 enabled）的 AnyConnect 线路不得超过一条，超过则生成阶段直接报错。
- **理由**：vendored sslcon 是**包级单例**（全局状态、单一会话），两条线路会互相踩掉对方的隧道。
- **被否决的替代方案**：(a) 改造 sslcon 成多实例——违反"`third_party/` 不改"纪律，上游合并无望，维护成本无限；(b) 运行时择一启用——用户配了两条却只有一条生效，且"哪条生效"不可预测，正是架构约束要消灭的那类 bug。
- **失败语义**：用户启用第二条线路时应尽早收到可见提示；生成阶段必须作为最后防线
  拒绝多条 active AnyConnect，不能运行时静默择一。

### D31 — macOS 全流量 Packet Tunnel 方案已实机否决

- **决策**：macOS 桌面不使用 `NEPacketTunnelProvider` 作为全流量入口。该方案保留给
  iOS/tvOS，不属于桌面运行边界。
- **实机证据**：同时运行官方 Tailscale exit node 时，macOS 把 Tailscale 与 XDial
  都登记成 `Primary Tunnel`、`Enterprise - Exclusive`。XDial 提交默认路由后系统先
  停止 Tailscale；Tailscale 自动恢复后又以 stop reason 11
  (`Configuration was superceded by another configuration`) 停止 XDial。扩展在停止前
  已完成 libbox 启动和 DNS 设置，因此不是 sing-box、DNS 或签名故障。
- **理由**：产品目标是把启动前整个网络作为 Underlay，而 Apple 的唯一主 Packet
  Tunnel 仲裁会拆掉这个 Underlay，和目标直接矛盾。关闭 Tailscale取得绿灯只会制造
  假验收。

### D32 — macOS 原生 TUN 的历史实现与已知边界

- **历史实现**：桌面 root helper 启动 sing-box 原生 TUN。启动数据面之前，平台适配器
  从操作系统默认路由读取当前接口，并作为运行时 `route.default_interface` 交给
  sing-box；不得从 Profile、产品名、接口前缀或物理/虚拟分类推断。D34 实机否决它在
  全流量 Network Extension Underlay 上作为主入口后，桌面 App 已按 D35 改用
  Transparent Proxy；本决策继续约束旧 helper、CLI 和回归测试，防止历史路径重新引入
  产品特例。
- **理由**：sing-box 1.13.12 / sing-tun 0.8.9 在 macOS 的
  `auto_detect_interface` 只接受带 `RTF_GATEWAY` 的默认路由，会跳过 Tailscale 等
  无网关 utun，实机错误选择 `en0`。本机验证中 `utun13` 可正常访问，而强制 `en0`
  超时。把系统已选接口原样转交给 sing-box，解决的是**盒内出站 socket 使用哪个
  Underlay**；这不是 XDial 重做接口优先级，也不等于 macOS 一定会把系统流量送进
  XDial TUN。
- **已知平台边界**：当启动前 Underlay 是一个安装 `RTF_GLOBAL` / 接口作用域默认路由
  的全流量 Network Extension VPN 时，普通 sing-tun `RTF_GATEWAY` sub-range 可能
  无法成为外层入口。此时 `default_interface` 仍能让 sing-box 出站走对 Underlay，
  但系统入站和 DNS 可能绕过 XDial；D34 记录了实机证据。D32 因而只在路由与 DNS
  真实验收通过时成立，不得从“配置生成成功”推断为自然叠加成功。
- **失败语义**：默认接口读取失败、接口在启动前消失、或 sing-box 无法绑定该接口时
  连接失败并回到 disconnected，不得回落到 `auto_detect_interface`。系统 DNS 的
  接管地址未由 XDial TUN 承载时同样连接失败；这是入口未密封，不是可忽略的 DNS
  精度警告。
- **生命周期**：helper 由 `launchd KeepAlive` 托管，负责异常退出后的 TUN 进程回收和
  DNS 残留自愈。单次连接只持有启动时快照；下层默认接口变化后需要重新连接。未来如果
  增加自动监视，它也只能触发一次完整数据面重连，不能在配置之外热改 outbound。

### D33 — Tailscale 作为 sing-box 盒内 Line 重新引入

- **数据面决策**：内置 Tailscale 是 sing-box 的普通 `endpoint`，与 Trojan 等 Line
  一样只在被 active Mode 引用时进入完整配置。它不得启用 `system_interface`，不得
  创建第二个系统 TUN、接管系统 DNS、接受系统级 peer 路由或发布路由。Tailscale Line
  提供一个默认关闭的可见 `MagicDNS` 勾选项；只有该 Line 被 active Mode 引用且勾选时，
  生成器才成对启用 endpoint 原生 DNS server 与动态 `preferred_by` peer 路由。归属范围
  只能来自当前 NetMap：域名侧读取 endpoint 收到的 `DNS Config` 中 `Hosts`、`Routes` 和
  `SearchDomains`，地址侧读取 peer `AllowedIPs`；不得硬编码 `100.64.0.0/10`、IPv6
  前缀、搜索域或默认路由。`AllowedIPs` 中由 Exit Node 带来的 `0.0.0.0/0` 与 `::/0`
  必须排除，不能把默认出口伪装成 peer / subnet 归属。
  Mode 的显式规则优先于这个能力规则；流量是否走 Tailscale、是否使用 exit node，仍由
  用户可见的 Line 参数和 Mode 决定。
- **与 Underlay 的边界**：官方 Tailscale、XDVPN、企业 VPN、Wi-Fi 和网线仍共同组成
  不透明 Underlay。内置 Tailscale Line 是 XDial 自己选择的出口，不能识别、关闭或
  重排任何已存在产品，也不能改变 D32 的系统默认接口快照规则。
- **身份与并发**：一个 Profile 只有一份持久 Tailscale 身份和 state 目录，所有
  Tailscale Line 共享登录态。不同 Line 可以选择不同 exit node，但一个 active Mode
  至多引用一条 Tailscale Line；超过即生成失败，不能静默择一。
- **认证控制面**：浏览器登录和 Auth Key 是同一份身份的两种显式配置动作。用户打开
  并操作 Tailscale 配置时，helper 才可启动一个限时 setup session；该 session 不含
  TUN、系统 DNS、系统路由或用户流量规则，关闭、超时、开始完整数据面连接或 daemon
  退出时必须停止。它不是未引用 Line 的自动副作用。
- **秘密边界**：Auth Key 只作为一次注册请求的瞬时输入进入 helper，不写入 Profile、
  订阅、Keychain、日志、Debug Server 或生成后的日常运行配置；请求返回后 UI 立即
  清空。Key 过期只影响新的注册，不影响已经持久化的 node key。
- **失败语义**：未登录、需要重新认证、所选 exit node 不存在或不可用时，启动必须
  fail-closed 并给出结构化错误；不得自动选择其他节点、改走 direct 或继续使用旧的
  隐式路由。勾选 MagicDNS 但当前 Tailnet 尚未发布可用 MagicDNS 配置时，同样必须在
  Commit 前失败。状态和 exit-node 列表必须来自 Tailscale LocalAPI，禁止解析日志。

### D34 — 全流量 Network Extension Underlay 不能靠普通路由表强行叠加

- **实机证据（2026-07-28）**：官方 Tailscale exit node 作为启动前 Underlay 时，
  `utun13` 持有 `default ... UCSg`（`RTF_GLOBAL`）和接口作用域 DNS
  `100.100.100.100`。XDial 原生 TUN 在 `utun14` 正常创建
  `1.0.0.0/8 ... 128.0.0.0/1 → 198.18.0.1` 后，
  `route -n get 198.18.0.2` 仍命中 `utun13` 的 link route，系统 DNS 也继续留在
  Tailscale。结果是公司域名无法进入企业 DNS，任何基于域名的 Mode binding 都没有
  可靠生效条件。
- **被否决的修补实验**：临时给 sing-tun 的 Darwin route message 增加公开的
  `RTF_GLOBAL`，并把内置 Tailscale 的底层 socket 固定到启动前 Underlay。内置
  Tailscale Exit Node 随后能通过真实 HTTPS 就绪探测，普通目标的 `route get` 也一度
  指向 `utun14`；但 `198.18.0.2` 仍被 `utun13` 的接口作用域路由接走，真实 TCP
  SYN 在 `utun14` 超时。说明失败层级不只是最长前缀匹配，还包含 Network Extension
  的连接/接口作用域；继续堆路由 flag 不是可靠方案。
- **决策**：当前原生 TUN 遇到上述边界必须 fail-closed，保持原 Underlay 可用并给出
  明确错误。`RTF_GLOBAL` 是数据面入口的连接前置条件：Engine 必须在建立 AnyConnect
  等 Line 会话、预取规则或启动 sing-box 之前读取并拒绝，不能先让 TUN 接管真实流量，
  再在 `Connecting` 状态里等待出口超时。TUN 启动前还要重新确认 Underlay 没有变化。
  不得识别 Tailscale 产品名后删除其路由、关闭其 DNS、为控制面地址维护例外表，也不得
  把第二个 `NEPacketTunnelProvider` 当成修复——D31 已证明两个 Enterprise Packet
  Tunnel 会互相取代。
- **后续边界**：若要支持这类自然叠加，必须选择一个能与既有 Enterprise Packet
  Tunnel 共存的 Apple 支持入口，并证明它能把 TCP、UDP、DNS 全部交给同一份 sing-box
  裁决。D35 选择 `NETransparentProxyProvider` 进入实机验证，但在完成真实三出口验收
  前仍不得宣称自然叠加成功。

### D35 — macOS Transparent Proxy 是主入口，已通过当前 Mode 的基础三出口验收

- **入口决策**：桌面 App 使用 `NETransparentProxyProvider` 作为唯一系统接入层。
  Provider 只接收 macOS 交付的 TCP/UDP flow，并通过同进程、随机凭据保护的回环
  SOCKS 会话送入 sing-box；DNS 包、规则匹配、出口选择和实际拨号仍由同一份 sing-box
  数据面完成。Provider 不读取 Line / RuleSet / Mode，不实现第二套路由或 DNS 裁决。
- **Underlay 转交**：宿主 App 必须在请求 Transparent Proxy 连接之前捕获
  `route -n get default` 已选中的接口和 `NWPath.availableInterfaces` 完整候选，并随本次
  `startVPNTunnel(options:)` 交给 Provider；Provider 必须拒绝缺失或不一致的快照。
  不能在 Provider 进程内重新捕获来替代它：实机已证明该视角会把现有全流量 VPN
  `utun14` 折叠成物理接口 `en0`；`NWPath.availableInterfaces.first` 也不是默认路由
  契约，实机切换期间曾错误返回 `en0`。全程不得按接口名或类型过滤。Go 侧只按系统接口名称
  补齐 MTU、状态标志和地址；这属于把操作系统事实补全给 sing-box，不是选择或重排
  Underlay。生成配置的 `route.default_interface` 必须等于这份内核结果，从而让
  Provider 内的 direct、DNS、代理和内置 Tailscale 底层 socket 延续启动前 Underlay；
  不得为单条 outbound 生成 `bind_interface`。只有当前 XDial 会话自己登记的接口可以排除。
- **Underlay 生命周期**：宿主 App 在会话成功后继续观察系统路径。路径曾不可用，或默认
  接口、候选接口集合、系统 DNS 快照发生变化时，等待路由 / `NWPath` / DNS 通知收敛后，
  用同一份用户 Profile 触发一次完整数据面重连。它不得热改某条 outbound，也不得按接口
  名、类型或 VPN 产品决定策略。重连只替换运行时 Underlay 快照，不修改 Line / RuleSet /
  Mode。系统路径收敛不等于下层数据面已经恢复真实出口；仅当本次失败被结构化归因为
  `underlay-egress-unavailable`，且 Rollback 已完成、系统接管已移除时，宿主才可按
  2 / 5 / 10 / 20 / 30 秒做至多五次有界重试。Line 登录、节点、握手或规则失败不得被
  **Underlay 切换**这条重试掩盖。
- **已提交会话的 Line 局部恢复**：一次已经进入 `committed` 并真实发布为 `connected`
  的会话，如果某条 Line 在用户没有执行断开的情况下掉线，且该 Line 的协议适配器支持
  在同一 sing-box 代际内替换会话，则只允许把这条 Line 置为 `reconnecting` 并有界
  重建它自己的会话。其他 Line、endpoint、sing-box、Transparent Proxy Ingress 和
  transaction ID 必须保持不变；不可用窗口严格执行铁律 3 的 REJECT / SERVFAIL，
  不得回落到其他出口。每次尝试和最终恢复必须写入当前 `ConnectionReport`。局部预算
  耗尽后才把该 Line 失败提升为本次数据面失败，进入完整 Rollback 和宿主恢复。
- **已提交会话的完整恢复**：如果 Provider 自身掉线、数据面共享组件失败，或 Line
  局部恢复预算耗尽，宿主保留同一份用户连接意图，在系统接管已移除后启动有界自动
  重连。这个恢复序列使用五次总预算；恢复事务中的 Line / 握手失败必须原样写入报告和
  断线历史，但可以继续消耗剩余预算，不能静默无限拉起。短暂“连上又掉”不重置预算；
  只有同一事务连续稳定运行满五分钟才清零。用户主动断开立即取消恢复，且不触发新的
  重连。
- **断线事实源**：每次意外断线都要在用户私有目录留下有界结构化记录，至少包含断线
  时间、原事务与 Mode、结构化原因、系统最后断线错误、每次重连的时间/事务 ID，以及
  最终恢复、失败或耗尽预算的结果。Debug Server 只读暴露这份记录；日志不能反过来
  推动重连状态机。
- **启动与失败语义**：完整 sing-box 实例及 active Tailscale Line 的真实出口探测必须
  先成功，之后才能提交 Transparent Proxy 网络设置。启动失败不得安装半成品网络配置；
  已接管 flow 的转发失败必须关闭该 flow，不得回落系统直连。冷启动或唤醒产生的自动
  连接意图如果启动失败，只能在完整 Rollback 且已证明系统接管移除后进入与完整恢复相同
  的 2 / 5 / 10 / 20 / 30 秒有界重试；等待必须在 UI 显示结构化倒计时并允许用户立即
  消费当前已排定的尝试。用户显式点击连接失败不得自动循环拉起；用户显式断开后，系统
  回到原 Underlay，并立即取消倒计时与恢复意图。
- **MagicDNS 系统接入事故证据（2026-08-01）**：已提交事务中，Tailscale endpoint 与
  `dns:mode` 都曾被标记为 ready，但系统解析器仍把启动前 Wi-Fi resolver 作为查询目的地，
  成员短名得到 NXDOMAIN；仅凭 ready 状态不能证明系统 DNS 已进入 XDial。Apple 为
  Transparent Proxy 提供的受支持 DNS 捕获入口是 destination-domain network rule，
  `NEDNSSettings` 则会被该 Provider 类型忽略。因此启用 MagicDNS 时，Provider 必须在
  Commit 前从同一 endpoint 的实时 `DNS Config` 取得当前域名后缀、完整主机名和可展开的
  单标签别名，为它们生成 port 53 的 destination-host rules，再追加普通全流量规则。
  捕获列表为空、畸形或超过有界上限时连接必须失败，不能把“控制面存在 MagicDNS 后缀”
  冒充系统查询已经能进入 XDial。该列表只是 Ingress 捕获事实，不参与 Mode 裁决；
  Tailscale 默认 resolver 仍不得成为 XDial 的全局 DNS final。实机曾从当前 endpoint
  导入 87 条捕获名；直发 DNS 得到成员地址，且未被旧 NXDOMAIN 缓存污染的新成员短名可由
  `dscacheutil` 解析。macOS 可能继续缓存修复前的 NXDOMAIN；验收应使用新名称或在用户授权
  下刷新 mDNSResponder，不能把旧负缓存误判为当前数据面失败。
- **入口演进证据（2026-07-29）**：build 21 正确签名、嵌入并激活 System Extension，
  但 Provider 内捕获的 `NWPath` 把已有全流量 VPN 折叠成物理接口；build 22 能收到宿主
  的虚拟默认接口快照，但生成配置还没有把它写入 `route.default_interface`。两次都只
  证明安装、激活和失败关闭，不能证明数据通路。build 23 起，Provider 日志中的接口
  快照与 sing-box `direct` 精确 outbound 的真实 HTTPS 探测同时成功，才证明盒内出站
  延续了启动前 Underlay。
- **Tailscale peer 事故证据（2026-07-29 至 2026-07-30）**：build 24 首次记录所选
  exit node 已进入 netmap、magicsock 和 engine，发送计数持续增加，但接收计数为零且
  没有握手。build 57/58 的同时间双端取证进一步确认：XDial 本机控制连接存在，当前
  control client 已接收 NetInfo 发布调用，Home DERP 协议在采样时刻就绪且节点已选中；
  远端 `tailscaled` 收到每次 WireGuard initiation 并生成 response，却仍把 response
  发往已经过期的 peer DERP，DERP 明确返回“不认识该 peer”。这不是 XDial Underlay、
  登录态或出口探测超时。
- **确定的状态一致性链**：远端 magicsock 的完整 peer 快照为 DERP 2，随后
  `NodeMutationDERPHome(3)` 只把实时 endpoint 改为 DERP 3，没有同步完整快照；下一张
  full map 又报告 DERP 2 时，输入恰好等于旧快照，`updateNodes` 的无变化 fast path
  提前返回，实时 endpoint 因而错误地永久留在 DERP 3。重启远端 `tailscaled` 会从当前
  full map 同时重建快照和 endpoint，所以曾让链路立即恢复；它只是清除已经污染的进程
  状态，不是修复，也不能作为 XDial 的验收步骤。
- **本地防护与失败语义**：vendored Tailscale 通过仓库补丁记录“实时 endpoint 已收到
  增量 mutation”。下一次 full map 即使与快照相等也必须执行完整 endpoint upsert，
  同时重算 relay candidate，完成后才能清除 dirty 状态。回归测试固定复刻
  `snapshot=2 / endpoint=2 → delta(3) → full(2)`，并要求最终 endpoint 回到 2、随后
  才恢复 fast path。build 58 在远端既有脏状态仍未清除时，必须准确报告
  `tailscale-peer-handshake-failed`，在 Transparent Proxy Commit 前完整回滚。
  XDial 不得自动重启远端、固定 DERP、遍历 DERP 或回落 direct 来掩盖该故障；远端一次性
  恢复属于显式运维动作，必须另行授权。
- **控制发布的确认边界（build 64，2026-07-30）**：本地 NetInfo 发布调用返回，只证明
  调用开始时捕获的当前 control client 已接收该调用，且同步调用已经返回；携带对应
  NetInfo 修订的 lite map 请求获得成功 HTTP 应答，只证明该请求被 control 的 HTTP
  接口接受。二者都不能证明远端 peer 已消费更新后的 map。远端 peer map 消费、fresh
  WireGuard handshake 与真实出口分别是独立事实，必须由同时间的远端结构化状态、握手
  事实和真实出口探测分别证明；前一级不得替代后一级。
- **启动恢复边界**：build 64 证明，本地 Home DERP 提升、本地 NetInfo 发布调用返回和
  lite map HTTP 接受，可以与持续发送、没有接收且没有握手同时成立。因此 Home DERP
  重选不再是连接启动事务中的自动恢复动作；满足 peer handshake failure 条件时必须失败，
  并在 Commit 前回滚。若未来保留重选能力，它只能是用户显式启动的诊断或维护动作，
  不得成为 Prepare 的成功条件，也不得据此宣告链路已经恢复。
- **身份级 A/B 边界（build 70 至 72，2026-07-30）**：在相同代码、相同官方
  Tailscale Underlay、相同 Exit Node 和相同 Mode 下，旧持久身份持续发送但接收为零，
  独立临时身份则在数秒内完成握手并通过真实出口探测。这证明该轮失败绑定于旧身份对应的
  peer / DERP 会话状态，而不是首次控制面访问、RuleSet、DNS 或 XDVPN。换身份能够清除
  该轮状态，但不是协议修复：不得据此宣称旧身份已经自愈，也不得在连接事务中静默轮换
  身份。旧身份必须保留以供取证；建立新身份仍是用户显式登录或运维恢复动作。
- **DERP readiness 快照语义**：DERP client 数与 protocol-ready 数只是采样时刻的汇总；
  前后两个相同汇总不能证明中间没有发生 transport reconnect 或 client / session
  generation 变化。需要排除瞬时重连时，必须读取结构化的 lifecycle sequence 或
  generation；尚无这类证据时只能报告无法由当前快照判定，不得从汇总值或日志缺失推出
  “没有重连”。
- **Transparent Proxy 运行态事实源**：宿主、设置页、菜单栏和 Debug Server 对本次
  Transparent Proxy 是否正在运行的判断，只能来自当前 `ConnectionReport` 的事务 ID、
  状态和系统接管结果。设置页出现、消失、展开 Line 卡片或刷新视图都不是数据面生命周期，
  不得因此启动出口探测、刷新线路或产生网络请求；UI 只能读取并展示既有事务事实。
- **旧桌面诊断旁路不属于 Transparent Proxy**：`127.0.0.1:9090` / `test-out` 是旧
  desktop helper / Clash API 路径留下的逐线路测试旁路；Transparent Proxy Provider
  不开放该 listener，也不得把它作为运行态 capability。若残留旧进程仍监听该端口，
  请求命中的是另一个生命周期和配置代际，会产生看似可用、实则不属于当前事务的错误事实；
  因而必须先验证 capability 属于当前事务，不能以端口可连接推断 TP Line 可用。
- **Provider diagnostics capability**：Provider 诊断必须以当前 transaction ID 为
  作用域，由 capability 明确列出本次 active `Line ID`，且只允许诊断其中的 Line。
  读取诊断必须完全只读，不得切换 selector、启动或结束事务、重启 Provider、改写
  sing-box 配置或改变任何系统网络状态。公网 IP 只是某次、某时刻从一个 outbound
  观察到的易失出口结果；它既不是 RuleSet 命中，也不能替代 matched outbound / Line
  的结构化证据。
- **DEBUG route watch 的最小边界**：逐流裁决观察只存在于 DEBUG，必须由显式目标和短时
  窗口启动，只观察经过本次会话认证且 inbound 为 `transparent-proxy-in` 的 flow。
  快照只返回固定闭集的 RuleSet / outbound / active Line 关系和有界 sequence，不回传
  目标域名或 IP、原始规则内容、URL、凭据及普通浏览历史；超时或事务结束后自动失效。
  它是观察器，不得参与裁决。
- **build 66 可观测性事故证据（2026-07-30）**：同一已提交事务中，`youtube.com`、
  `git.xindong.com` 和 `ip.cn` 的 TCP flow 均被系统交给 Provider 且 accepted；公司
  域名通过三个 resolver 入口得到相同私网答案，随后真实 HTTP 返回 200。这些事实分别
  证明 Transparent Proxy 接管、盒内 DNS 归因和公司线路可达，却仍不能证明三个 flow
  各自命中了哪个 RuleSet / outbound。build 66 的运行版本没有逐 flow 的 matched
  RuleSet / outbound 结构化观察；active Mode 配置只能表达期望，禁止据此倒推出实际
  Line 并冒充运行时证据。
- **基础三出口验收（build 26 首次通过、build 29 重验，2026-07-29）**：官方
  Tailscale 全程保持 `Running`，
  默认接口仍是其虚拟接口。相同 active Mode 下，默认 `direct` 得到美国 Underlay
  出口；解析到中国移动地址的专用 IP 检测服务经内置 Tailscale 得到日本 exit node
  出口；公司域名经 AnyConnect 分域解析得到私网地址并返回有效 HTTP 重定向。对公司
  域名分别向公共 DNS、不可达的测试地址和 MagicDNS 名义地址发查询，三者返回相同私网
  应答，证明 DNS 包被盒内 `hijack-dns` 接管，而不是碰巧由 Underlay resolver 回答。
  TCP、DNS UDP、保持 flow 存活的普通 UDP nonce 及一条立即关闭发送端的短命 UDP
  nonce 均实际穿过 Provider。build 29 将 `flow.open` 提前到 UDP relay 准备之前，
  消除了短 flow 在接管确认前被系统 reset 的错误风暴；后续 SOCKS relay 失败仍关闭
  flow，不得回落直连。
- **仍未完成的门禁**：Underlay 自动重连的代码存在不等于实机验收完成；仍需分别验证
  下层默认接口切换、断网后恢复、Provider 异常退出。UI 和自动化不得把 Network
  Extension 的 `connected` 单独当成策略生效证据；至少还要分别核对 DNS 归因、规则
  归属和真实出口。

### D36 — 每次连接是一笔由 active Mode 编译出的动态事务

- **不是固定检查清单**：控制面必须先从 active Mode 编译一份 `ConnectionPlan`。
  计划只包含本次实际引用的 RuleSet、Line、Subscription，以及由同一份 Mode 推导出的
  DNS、sing-box 数据面和系统 Ingress；顺序和依赖关系也是计划的一部分。对象仅仅存在或
  `enabled` 不得进入计划，Swift 也不得另写一份“VPN → Tailscale → 规则”的固定流程。
- **状态机**：一笔连接事务只有
  `planning → preparing → readyToCommit → committing → committed` 这一条成功路径；
  任一步失败或被取消都必须进入
  `rollingBack → rolledBack → failed/cancelled`。不能从中间状态直接宣称
  `connected`，也不能把 Network Extension 的系统状态当成事务状态。
- **Prepare 不接管系统网络**：Planning 只校验引用和生成依赖图，不产生网络副作用；
  Prepare 可以读取或更新持久 RuleSet 缓存、建立本次会话需要的 Line、生成并启动完整
  sing-box、执行真实就绪探测，但不得提交 Transparent Proxy 网络设置。只有所有计划任务
  都进入 `ready` 后，Provider 才能执行唯一的 Commit：
  `setTunnelNetworkSettings`。这使“规则未下载完”“线路登录失效”“出口不可达”都发生在
  系统流量仍走原 Underlay 的阶段。
- **回滚契约**：Rollback 按已完成动作的逆序执行，必须幂等、有超时上限，并把每一项
  结果写入同一份事务报告。经校验的 RuleSet 缓存、用户 Profile、Tailscale 本机身份等
  持久资产不回滚；本次创建的 AnyConnect / Tailscale 会话、sing-box 实例、回环 relay、
  Underlay monitor 和已经提交的系统网络设置都属于会话副作用，必须撤销。Rollback
  完成后要明确报告“系统接管已移除”，不能只报告原始启动错误。
- **结构化事实源**：`ConnectionPlan`、任务状态、错误代码、时间和回滚结果组成一份
  不含凭据的结构化 `ConnectionReport`。Provider、宿主 App、UI、Debug Server 和测试
  消费同一份报告；日志只用于人工取证，禁止解析日志文本来推动状态机。UI 的连接跑马灯
  和详情页必须显示计划中的真实任务，最后停在实际失败项，而不是根据 Line 类型猜进度。
  原始失败与回滚失败必须分开保存，回滚异常不得覆盖最初故障。报告还必须保留证据所在
  层级：本地 control 调用、control HTTP 接受、远端 map 观察、peer handshake 与真实
  出口不得折叠成一个笼统的“就绪”，也不得由前一层推定后一层。
- **Provider 是运行期报告的权威写入者**：macOS 以 root 运行 System Extension，相同
  App Group 在宿主用户与 Provider 中会映射到不同容器，不能假装它们共享一个文件。
  宿主把无凭据的初始报告随本次 `startVPNTunnel` options 交给 Provider；Provider 在
  root App Group 中建立并更新权威 journal。既有 root helper 只读转发这份报告，宿主
  再镜像到用户 App Group 供 UI 和 Debug Server 消费。helper 不生成状态、不改写任务，
  也不得成为连接状态机。
- **崩溃恢复**：权威事务报告写入 Provider App Group 的原子 journal。宿主或 Provider
  启动时若发现上一次事务停在 `preparing`、`committing` 或 `rollingBack`，必须先协调
  系统当前 Network Extension 状态并完成清理，再允许新事务开始。journal 不等同于
  数据库跨进程 ACID，但 Provider 内的读改写必须经同一把文件锁串行化；它是检测半完成
  事务和证明恢复结果的最低边界。Provider 无法可靠写入报告时不得执行 Commit。
- **验收门禁**：除成功连接外，至少注入 RuleSet 准备失败、Line 准备失败、Commit
  失败、用户取消和 Provider 异常退出；每种场景都必须证明未引用对象没有副作用、Commit
  前系统网络未被接管、Rollback 逆序完成、原 Underlay 仍可用。还必须证明连接不依赖
  打开设置页或展开某张 Line 卡片。

### D37 — 平台安装是一笔独立、幂等且不接管流量的事务

- **与连接事务分离**：应用位置、包签名、特权 helper 和 System Extension 是持久的
  平台前置条件，不属于某个 Mode 编译出的 `ConnectionPlan`。它们由独立的
  `InstallationReport` 表达；安装成功不能推导任意 Line、RuleSet、DNS 或真实出口已经
  就绪，连接事务也不得通过打开设置页来补做安装。
- **自动定位与替换**：从 `/Applications` 之外启动时，XDial 复制自身到
  `/Applications/XDial.app`，核对主程序、helper 和 System Extension 的完整签名及
  bundle identity 后重新启动。已存在同一签名身份的旧版本可以自动替换，但必须先保留
  临时备份，新版本二次验签成功后才清除；签名或 bundle identity 不一致时禁止覆盖。
  下载目录里的原文件不删除。
- **唯一流程**：首次启动和升级都依次验证当前 bundle、注册并验证 helper、激活并验证
  System Extension。macOS 要求人工批准时，状态停在准确任务并自动打开对应系统设置；
  批准后继续原事务。Tailscale 配置和完整连接只消费“安装已就绪”这一事实，不得各自
  临时注册 helper 或扩展，也不得把 `helper socket`、`extension not found` 之类底层
  错误当成产品流程。
- **副作用边界**：安装事务可以写入 app bundle、注册持久 helper、激活
  System Extension，但绝不能创建或启用 `NETransparentProxyManager` 网络配置、启动
  sing-box、建立 Line 会话、下载 RuleSet、读取或改变 Underlay、提交 DNS/路由或接管
  用户流量。只有 D36 的连接事务可以执行唯一的系统网络 Commit。
- **事实与恢复**：UI、Debug Server 和连接门禁消费同一份无凭据
  `InstallationReport`，禁止解析日志推动流程。每个步骤必须幂等；进程中断后从当前
  macOS 结构化状态重新执行。安装包替换失败恢复旧 app，helper 或扩展失败则保留原
  Underlay，并停在失败项供重试。

### D-DNS — DNS 分域归属由 Mode 裁决

- **决策**：每个域名的解析器归属，由 active Mode 的 binding 或默认线路唯一决定。
  DNS 规则、route 规则与最终 resolver 从同一份 Mode 编译。**不存在无主的 DNS 规则。**
  D33 的 MagicDNS 是唯一窄例外：active Mode 先决定该 Tailscale Line 是否进入数据面，
  Line 上可见且可关闭的勾选项再决定是否采用 endpoint 当前 NetMap 同时申报的 DNS 与
  peer 路由；两者必须成对出现，并排在 Mode 显式规则之后。
- **理由**：见第 4.1 节的因果链。DNS 与 route 分家编译必然漂移，且漂移后的症状（流量走 A、解析走 B）极难归因。
- **被否决的替代方案**：(a) DNS 用一套独立的用户配置——两套配置必然不一致，用户要维护两遍；(b) 按 Line 类型自动推断解析器——Line 不该做裁决，且同一条 Line 上手动规则集（内网名）与 URL 规则集（公网名）的正确解析器不同。

### D-FAKEIP — v1 不启用 fake IP，但地址段预留且与 tun 段分开

- **决策**：v1 不启用 fake IP。同时在地址规划上预留一段专用于 fake IP，**必须与 tun 使用的 `198.18.0.0/15` 分开**。
- **理由**：不启用——sniff 在当前目标场景（TLS/HTTP 为主）已能覆盖绝大多数流量，fake IP 引入的额外状态（映射表生命周期、跨重启一致性、与系统 DNS 缓存的交互）在 v1 不值得。预留且分开——fake IP 地址会被返回给应用并出现在 connect 目标里；若与 tun 段重叠，就无法区分"这是一个 fake IP 凭证"和"这是发往盒子基础设施的包"，而 tun 段还兼任 DNS 接管地址的残留识别判据（`dnsTakeoverPrefix`），两个用途混在一段里会让那条判据失效——代价是永久性的整机 DNS 损坏。
- **被否决的替代方案**：(a) v1 就启用——见上；(b) 不预留、以后再说——地址段一旦发布就进入用户的路由表和残留清理逻辑，事后改段需要处理所有历史残留，代价不对称。

### D-CRASH — 崩溃后 fail-open + 强通知

- **决策**：XDial 进程异常终止后，系统恢复到无 XDial 的状态（fail-open，用户仍能
  上网），但必须给出**强通知**告知用户“XDial 策略已失效，流量正在直接使用
  Underlay”。
- **理由**：这是铁律 1（fail-closed）的唯一例外，理由是**进程已死就无人能执行
  fail-closed**。保留一个无法继续转发的 TUN 会导致整机断网，且没有存活进程能够恢复
  它。选择 fail-open 的前提是通知必须足够强，让用户明确知道策略已经失效。
- **被否决的替代方案**：(a) 崩溃后保留不可转发的 TUN——无人可恢复，用户只能从
  XDial 之外修复网络；(b) fail-open 但静默——用户会误以为策略仍然生效，受限流量
  可能从错误出口发送。
- **适用范围**：以上是旧原生 TUN 的既定语义。Transparent Proxy 的 Provider 异常
  退出、系统自动拉起及通知链仍是 D35 的未完成门禁；不得直接假定 Apple 托管进程会
  自动满足同样语义。

### D-INGRESS — 系统代理 Ingress 列入后续

- **决策**：这里的“系统代理”特指 HTTP/SOCKS + PAC 设置，不是 D35 的
  `NETransparentProxyProvider`。HTTP/SOCKS + PAC 仍列入后续；当前移动端使用 tun，
  macOS 使用 Transparent Proxy。
- **理由**：系统代理的价值在于不需要 Network Extension 权限、能按应用生效，但它
  拿不到非代理感知流量，引入的归因语义与 tun / Transparent Proxy 都不同，需要
  Ingress 维度真正与裁决解耦后才能安全加入。
- **被否决的替代方案**：(a) 当前同时做 PAC 与 Transparent Proxy——抽象未经检验，
  大概率长成入口特例；(b) 永远不做——系统代理是无扩展权限场景的重要选项，砍掉会
  锁死一部分用户。
- **约束**：Ingress 的通用契约不得泄漏 tun 特有概念（地址段、`auto_route`、DNS
  接管地址），否则未来第二种入口只能靠特例接入。

### D-UNDERLAY — 自然叠加，不识别产品

- **决策**：XDial 启动时把操作系统当前已经形成的网络整体视为一个不透明
  Underlay，并在其上增加 sing-box 这一层。旧桌面原生 TUN 的
  `route.default_interface` 必须等于启动前系统默认路由给出的接口；macOS
  Transparent Proxy 把同一份内核默认路由结果写入 `route.default_interface`，并通过
  `PlatformInterface` 交付完整 `NWPath` 候选；移动端则把 `NWPath` 的默认接口和全部
  可用接口原样交给 sing-box。所有形态都不得生成 outbound `bind_interface`，不得按
  `utun` / `ipsec` / `ppp` 前缀过滤，只排除 XDial 当前会话自己明确登记的接口。
- **理由**：网线、Wi-Fi、企业 VPN、官方 Tailscale 等先后组合属于操作系统和先启动
  组件已经形成的事实。桌面入口使用运行时 `default_interface` 加接口快照，都只是把
  系统既有事实送入数据面，不是 XDial 选择接口。该不变量表达产品语义，
  不保证任意入口技术都能实现它；入口能力不足时必须拒绝连接，而不是破坏 Underlay
  来迁就当前实现。
- **被否决的替代方案**：(a) 按产品维护兼容表——新产品或版本变化都会制造新特例；
  (b) 固定绑定物理接口或拒绝所有 `utun`——会绕开用户已经建立的下层 VPN；(c) 无条件
  使用 `auto_detect_interface`——已实机证明会跳过无网关 utun；(d) 把下层 VPN 导入
  XDial 作为 Line——混淆 Underlay 与 XDial 自己裁决的 Outbound。

---

## 7. 禁止事项

以下每一条都对应至少一次真实事故。不允许以"这次情况特殊"为由绕过。

1. **不许让任何 Line 在未被 active Mode 引用时影响本机流量决策。** 包括但不限于：注册路由、抢占默认出口、注入 DNS 规则、修改系统状态。
2. **不许在生成器里注入用户不可见的路由规则。** 生成的 `route.rules` 每一条都必须能追溯到某个 Mode binding、一份**显式列举**的系统白名单（`sniff` / `hijack-dns` / 桌面诊断 selector），或 D33 中“active Mode 引用 + Line 可见勾选项”共同启用的动态 MagicDNS 能力。白名单本身不得在未更新本文档的情况下扩充；MagicDNS 不得硬编码匹配范围。
3. **不许让任何 Line 在未被引用时自动持有活会话或发起出网请求**（含探测、健康检查、订阅刷新、控制面登录）。"enabled 就去连一下试试"是副作用面泄漏——它产生用户不知道的网络指纹，也会在断网时产生莫名其妙的错误。唯一例外是 D33 定义的用户显式、限时、无系统网络副作用的配置会话；它不得混入完整数据面生命周期。
4. **不许让 Swift 复刻 Go 的 tag / slug / schema 规则。** `macos/Sources/XDial/NetworkInfo.swift` 的 `slugify` 是一份存量违规复刻——它的注释里自认"必须与 Go 端 `core/config/generator.go` 的 `slugify` 完全一致"，这句话本身就是 bug 的定义（两份实现，一份契约，无人守护）。正确做法是 Go 侧导出运行时目录、Swift 侧只消费，参考 `RuntimeSubscriptionCatalog`。新代码一律走导出，存量复刻应逐步迁移。
5. **不许静默回落 direct**，也不许静默回落到公共 DNS，不许静默跳过一条无法生成的规则而不告知用户。**引用悬空必须报错**（见 INV6a），不得 `continue` 了事。
6. **不许用日志抓取做控制流。** 解析 sing-box / sslcon 的日志文本来判断状态，然后据此决策——日志格式不是契约，上游改一个字就静默失效，且失效方式是"永远走 else 分支"，没有任何报错。状态判断必须走结构化接口（Clash API、进程退出码、显式回调）。
7. **不许把 DNS 规则和 route 规则从不同来源编译。** 普通分域的唯一输入源是 `mode.Bindings`；D33 MagicDNS 的 DNS 与 route 必须共同来自同一条 active Tailscale Line 的同一个可见开关，并保持成对启停与相同优先级。
8. **不许在 XDial 里选择或重排 Underlay。** 不得按产品名、接口名称前缀或物理/虚拟
   分类删除候选，不得生成 outbound `bind_interface`，也不得为了"兼容某个 VPN"增加
   产品级 DNS/路由分支。旧原生 TUN 的 `route.default_interface` 唯一合法来源是
   数据面启动前的系统默认路由快照；Transparent Proxy 的合法来源是同一份默认路由
   结果加 `NWPath` 原始候选，移动端的合法来源是 `NWPath` 原始快照。硬编码、Profile
   字段或名称匹配一律违规。
9. **不许依赖 sing-box 的默认值来维持架构约束性质。** 影响裁决归属的字段
   （`independent_cache`、旧桌面的 `default_interface`、Network Extension 的
   `auto_detect_interface`、`default_domain_resolver`、tun 的 `stack`）必须显式写死。
   上游默认值翻转会静默摧毁密封性。
10. **平台宿主适配器不许成为第二套数据面。** 旧桌面 helper 只能提供权限、系统默认
    路由快照、DNS 接入和生命周期清理；Packet Tunnel 只能提交 sing-box 声明的
    TUN/DNS/路由参数；Transparent Proxy 只能交付 flow 和 Underlay 快照。它们都不得
    读取 Line / RuleSet / Mode，不得自行选择 resolver 或出口。
11. **不许改 `third_party/`。** 需要上游改动时走本地补丁，并在 `third_party/` 的补丁说明里留痕。

---

## 8. 不变量测试

`core/config/invariants_test.go` 是本规范的可执行边界，当前测试名称和覆盖细节直接从该文件
读取，不在本文维护一份容易漂移的镜像清单。它至少必须守住：

- 未被 active Mode 引用的对象产生零数据面副作用；
- DNS 与路由同源、无隐藏规则、无静默 direct 或公共 DNS 回落；
- 悬空引用报错，用户主动禁用产生可见 warning；
- 桌面只允许一条 active AnyConnect；
- 一个 active Mode 只允许一条 active Tailscale，且未引用的 Tailscale 不生成 endpoint；
- 桌面 Tailscale endpoint 不创建系统接口、不接受或注入系统隐藏路由、不携带 Auth Key；
  MagicDNS 未勾选或 Line 未被 active Mode 引用时无任何 DNS / peer 路由产物，勾选后只
  使用当前 NetMap 动态归属且不得覆盖 Mode 显式规则；
- 桌面逐字转交系统默认路由与完整接口快照，不启用自动探测，也不为单条 outbound
  绑定接口。

这些测试失败即表示实现越过了架构边界。不得通过放宽断言、增加特例、跳过或删除测试来
“修复”。如果需求确实改变了架构，顺序必须是：先与用户对齐 → 更新本文 → 再更新测试。

仍缺少一条完整的**副作用面门禁**：未被引用的 Line 不得持有活会话，也不得发起探测、
健康检查、订阅刷新或控制面登录。现有代码和新增代码都必须遵守，直到它被测试完整覆盖。

---

## 9. 改动前的自检清单

提交任何改动前，逐条回答：

1. 我动的代码属于哪个维度？它有没有读取或写入另一个维度的对象？
2. 我新增的任何配置输出，用户能在 UI 里看到吗？能关掉吗？
3. 我有没有引入一条"某个开关打开就自动生效"的全局行为？
4. 失败路径上，我是让它可感知地断掉，还是悄悄回落了？
5. 我有没有在 Swift 里重新实现一份 Go 已经有的规则？
6. 我有没有靠解析日志文本来判断状态？
7. 桌面 `default_interface` 是否只来自启动前系统默认路由快照，Transparent Proxy
   是否同时原样转交完整 `NWPath` 候选？我有没有按接口名称或某个 VPN 产品增加
   DNS/路由特例？
8. 我写的是控制面、窄协议适配器还是平台宿主适配器？helper / Network Extension 是否
   只提供权限、系统既有网络事实与生命周期，有没有越界成为第二套数据面？
9. 这次连接的真实依赖是否来自 active Mode 的 `ConnectionPlan`？任何失败是否都进入
   可观察、逆序、幂等且有界的 Rollback，并证明系统接管已经移除？
10. `go build ./...` 和相关包的 `go test` 过了吗？`gofmt` 过了吗？

任何一条答不上来，先停下来问，不要提交。
