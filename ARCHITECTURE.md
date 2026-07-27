# XDial 架构约束规范

## 0. 这份文档是什么

这是 XDial 的**架构约束规范**，不是设计介绍。任何 AI 编码工具（Claude Code / Codex / Cursor）和人类贡献者在改动本仓库前必须先读完本文，改完后必须能对照第 7 节（禁止事项）和第 8 节（不变量测试）自证没有越界。

**为什么要有这份文档。** XDial 桌面版长期不稳定的根因不是某个函数写错，而是**模块越界**：某个维度的组件擅自替另一个维度做了决策，且这个决策对用户不可见。典型症状是"改一个看似无关的开关，全局路由/DNS 行为整个变了，且没人能在配置里指出是哪一行造成的"。这类 bug 无法靠 code review 逮住——每一处单看都"合理"，问题只在跨模块组合时出现。

因此约束由两部分构成，缺一不可：

- **本文档**——说明边界在哪、为什么在那里、越界长什么样。给人和 AI 读。
- **CI 不变量测试**（第 8 节）——把边界编码成可执行断言。给编译器读。

文档负责让你**理解**边界，测试负责在你**没理解**时把提交拦下来。如果你发现测试挡住了一个你认为正确的改动，**先停下来和用户讨论修改架构约束，不要绕过测试、不要放宽断言、不要给断言加特例分支**。

> **关于代码引用格式。** 本文用 `文件路径` + **符号名**（函数/常量）定位，不用行号。这些文件正在被多条并行工作流改动，行号漂移会让引用在几次提交内全部失效，而符号名可以直接 `grep` 到。看到 `core/config/generator.go` 的 `buildDNS` 就 `grep -n "func buildDNS" core/config/generator.go`。

---

## 1. 两条定律

### 定律一：外部密封律

> **XDial 对系统只呈现一个 VPN。DNS、路由、分流全部在盒内处理，不溢出到系统层。**

正面定义：

- 系统层能看到的 XDial 只有一个 tun 接口（`utunN`）+ 一个被接管的系统 DNS 地址。除此之外，XDial 不在系统里留任何路由表项、resolver 配置、代理设置、防火墙规则。
- 所有分流决策发生在 sing-box 配置内部。系统不知道"哪些域名走哪条线"，也不需要知道。
- 盒子的边界是可枚举、可清理的：知道边界在哪，才能在崩溃/异常退出后把系统恢复原状（见 `core/engine/dns_takeover.go` 的残留识别与清理逻辑）。

反面案例（真实历史）：

- **桌面 DNS 出口曾硬编码 `direct`**。DNS 查询走 `direct` 出口 = 从物理网卡明文发 UDP 53 到系统 resolver。这意味着**解析这一步整个发生在盒外**：盒内的分域规则、经隧道解析、企业 DNS，全部没有机会生效。用户看到的是"配了规则但分流不准"，而配置文件里看不出任何问题——因为问题在于那条规则根本没被求值。修复后系统 DNS 包一律 `hijack-dns`（`core/config/generator.go` 的 `buildSystemRouteRules` / `buildNESystemRouteRules`），由 sing-box 自己应答，`buildDNS` 的分域链才成为唯一解析路径。
- 相关的次生灾难：系统 DNS 若被官方 Tailscale 客户端改成 `100.100.100.100`，该地址只在它自己的 utun 上有意义。XDial 接管路由后把 DNS 包从物理口转发出去就是黑洞，**整机解析全灭**（2026-07-26 实测；理由写在 `core/config/generator.go` 的 `desktopPublicDNSTag` 常量注释里）。这正是"溢出到系统层"的代价：盒内的正确性取决于盒外某个你不控制的组件。

### 定律二：内部正交律

> **Ingress / Line / RuleSet / Mode 四个维度互不知道对方存在。Mode 是唯一的连接点。**

正面定义：

- 四个维度各自只掌握自己那一层的信息，不持有、不查询、不推断其他维度的对象。
- 只有 Mode 同时看得见 RuleSet 和 Line，并负责把它们绑定起来。
- **声明 ≠ 生效。** 一个对象存在于 Profile 里，只表示"用户配置过它"。它是否对本机流量产生任何影响，唯一取决于 active Mode 是否引用它。参见 `core/config/generator.go` 的 `effectiveActiveTargetIDs`：未被 active Mode 引用的 Line / Subscription 根本不进入生成的 sing-box 配置。

反面案例（真实历史）：

- **Tailscale 线路 `enabled` 即全局注入 `preferred_by` 路由**。exit node 广播的 `0.0.0.0/0` 被 `preferred_by` 整个捞给 Tailscale endpoint，结果是 **Mode 的默认出口永远失效**——用户在 Mode 里配好的"默认直连"被一条谁也没写过的规则抢走。这是 Line 越权做路由裁决的教科书案例：Line 只该声明"我是一个出口"，却直接改写了全局默认。2026-07 反复犯了两次。现状：Tailscale endpoint 只在线路 `enabled` 时生成（MagicDNS 解析需要它就绪），但路由上它是普通 outbound，只有 Mode 显式绑定的流量才走它——`grep -n "preferred_by" core/config/generator.go` 能读到这两处教训注释。想要"默认走 exit node"的正确做法是把 Mode 的默认线路设为该 Tailscale 线路（`final` 即 endpoint tag）。
- **同款问题的 DNS 版本**：Tailscale DNS server 的 `accept_default_resolvers` 若为 `true`，tailnet 的 resolver 会接管**所有**域名而不只是 tailnet 自家名字。这个字段现在在 `buildDNS` 和 `buildNEDNS` 里都被显式写死为 `false`，不依赖 sing-box 默认值——默认值翻转一次就等于全局 DNS 被静默劫持。
- **订阅规则表隐式抢注在用户显式绑定之前**。订阅自带的规则表（Clash/Surge 的 `RULE-SET` / `DOMAIN-SUFFIX` 列表）被无条件插在 Mode 绑定规则之前，导致订阅里的大网段（如 `1.0.0.0/8`）吞掉用户显式写的 `/32`。用户看到的是"我明明把 example.com 绑到了某条线路，流量却被订阅规则整个遮蔽掉"。现状是显式绑定的锁定验收规则先于订阅规则（见 `GenerateSingBoxFor` 里 `acceptanceModeRules` → 订阅规则 → `ordinaryModeRules` 的装配段）——但**这个顺序本身仍是架构约束约束的对象**，任何调整都必须在本文档留痕。
- **交互式 Tailscale 登录流程反过来约束引擎状态机**。为了给 Tailscale 走浏览器登录，引擎被迫加上"必须先断开 XDial 才能登录/刷新出口节点"的限制（历史上的 `Engine.StartTailscaleAuth` / `Engine.TailscaleStatus` 都以 `e.status != StatusDisconnected` 直接拒绝）。这是**依赖方向倒流**：Line 的一个实现细节（某个协议的认证方式是交互式的）爬到了引擎生命周期上，让所有其他线路一起承担这个代价。用户体验上就是"我只想换个出口节点，为什么要断网"。裁定见 ADR **D29**：Tailscale 配置形态必须与其他 Line 同构，`auth_key` 是纯参数，无登录流程。

---

## 2. 四个正交维度：职责边界

| 维度 | 负责什么 | 绝不负责什么 | 典型违规写法 |
|---|---|---|---|
| **Ingress**（入口）<br>tun / 系统代理 | 流量如何进盒；把包归因到源（进程、接口、地址族）；声明盒子占用的地址段 | **绝不参与路由裁决**。不决定任何流量走哪个出口，不携带任何域名/规则知识 | 在 `buildTUNInbound` 里按线路类型改 `route_exclude_address`（VPN 服务端地址例外是密封性要求——不排除就会自环——不是裁决）；在 inbound 上挂 `outbound` 字段；按"当前模式"改 tun 地址段 |
| **Line**（出口） | 声明"怎么到达一个出口"：协议参数、凭据、传输选项、**能力**（能解析哪些后缀、是否自带 resolver、是否自带路由供给） | **绝不自行生效**。未被 active Mode 引用时，不得对本机流量决策产生任何影响；不得注册全局路由；不得抢占默认出口；不得改写系统状态 | `preferred_by`；线路 enabled 就往 `route.rules` 插规则；线路自己往 `dns.rules` 插 `final`；线路 enabled 就发起出网连接 / 持有活跃会话 |
| **RuleSet**（匹配） | 只管**匹配流量**：域名、后缀、CIDR、远程规则集资源 | **不知道任何 Line 存在**。`RuleSet` 结构体里绝不能出现 `line_id`、`outbound`、`server` 之类字段 | 在 `RuleSet` 上加 `DefaultLineID`；在 `buildRouteRule` 里根据规则集内容猜出口；订阅规则表直接携带出口名并绕过 Mode |
| **Mode**（裁决） | 唯一裁决者：绑定 RuleSet→Line、指定默认出口、裁决 DNS 分域归属。route 规则和 DNS 规则**必须从同一份 Mode binding 编译** | 不定义匹配内容（那是 RuleSet），不定义出口参数（那是 Line），不定义流量如何进盒（那是 Ingress） | Mode 里内联域名列表；Mode 里内联服务器地址；route 规则从 Mode 编译而 DNS 规则从别处编译（两者必然漂移） |

**依赖方向是单向的**：`Mode → {RuleSet, Line}`。RuleSet 不指向 Line，Line 不指向 RuleSet，二者都不指向 Mode。Ingress 谁也不指向。任何引入反向或横向依赖的改动都是越界。

数据模型上这一点是可验证的：`core/config/model.go` 里 `RuleSet` 只有匹配字段，`Line` 只有出口参数，绑定关系全部集中在 `Mode.Bindings`（`RuleBinding{RuleSetID, LineID, SubscriptionID}`）和 `Mode.DefaultLineID` / `Mode.DefaultSubscriptionID`。**给 `Line` 或 `RuleSet` 加一个指向对方的字段，就是越界的最短路径**。

---

## 3. 供给源模型（D28）

现实需求：有些对象天然"自带规则"。

- Tailscale 线路自带 tailnet 内部路由（`100.64.0.0/10`、`fd7a:115c:a1e0::/48`）和 MagicDNS 分域。
- 订阅自带整张规则表和策略组。

朴素做法是让它们自己往生成的配置里插规则——这正是定律二的两个反面案例。D28 给出的解法是：

> **供给出来的规则必须以一等公民身份进入 Mode 裁决——可见、可禁用、可排序、可不用。绝不隐式抢注。**

四个形容词是硬指标，逐条含义：

- **可见**：供给出来的每一条规则，用户必须能在 UI 里看到它的存在、来源、匹配内容和目标出口。生成的 `route.rules` 里不允许存在任何用户无从得知的条目（这正是不变量 INV4 守护的）。
- **可禁用**：用户必须能关掉任意一条供给规则，且关掉后它从生成配置中彻底消失，不留任何降级替身。
- **可排序**：供给规则相对于用户手写绑定的优先级，必须是用户可见且可调的。当前 `GenerateSingBoxFor` 里"锁定验收规则 → 订阅自带规则 → 普通模式规则"的顺序是一个**默认值**，不是不可变事实；改它要同步改本文档。
- **可不用**：完全不引用供给源时，配置里必须一个字节都看不出这个供给源存在过。

供给源与消费者之间的关系是**申报制**，不是注入制：Line / 订阅向 Mode **申报**"我这里有这些规则"，Mode 决定采用哪些、放在什么位置。申报动作本身不改变任何生成产物。

**Tailscale 内部网段是唯一的例外，且例外有明确边界**：`buildTailscaleInternalRouteRules` 在 Tailscale 线路存在时无条件加一条 tailnet 内网段规则。它被允许，是因为它的作用域严格等于"tailnet 私有地址空间"——这段地址在盒外没有任何意义，接管它不可能抢走任何用户流量。**这个例外不得扩大**：任何覆盖公网地址、`0.0.0.0/0` 或域名的自动规则都不适用此豁免。

---

## 4. DNS

### 4.1 因果链：名字 → 线路 → 地址

这三步的顺序**不可交换**，理由是一条严格的因果链：

1. **分流只需要名字。** 判断 `google.com` 该走哪条线，不需要知道它的 IP。规则匹配的输入是域名。
2. **解析的正确答案取决于从哪出去。** `oa.corp.example` 在企业 DNS 有记录、在公共 DNS 是 NXDOMAIN；`google.com` 经本地 resolver 解析可能被中间层改写、经隧道那头解析则是权威结果。**同一个名字，从不同出口解析得到不同且都"正确"的答案。**
3. 所以：**先按名字选线路，再按线路选解析器，最后才拿到地址。** 反过来（先解析再分流）等于用一个任意选定的解析器的答案去做本该由线路决定的判断，结论必然错。

推论：**解析权随线路走。** Line 声明它的解析器能力（企业 DNS、tailnet resolver、经隧道的 DoH），Mode 决定用不用。这在代码里就是 `collectVPNBoundDomains` + `collectProxyBoundDNSTargets`：两者都从 `mode.Bindings` 遍历，而**不是**从 Line 列表遍历。同一条线路上，手动规则集（内网名，归企业 DNS）和 URL 规则集（远程规则集里的公网名，归经隧道的公共 DoH）的正确解析器不同，这个二分逻辑就写在 `collectProxyBoundDNSTargets` 的注释里。

**DNS 规则与路由规则必须从同一份 Mode binding 编译。** 两者一旦分家，就会漂移：某个域名的流量走 A 线路、解析走 B 线路，得到的地址在 A 线路那头根本不通。当前实现里两者都以 `mode.Bindings` 为唯一输入源，这是硬约束不是巧合。

**这条约束的作用域只能是「基于域名的绑定」，这一点是因果链的直接推论，不是妥协。** 路由裁决可以基于 IP（`ip_cidr` / GEOIP / `ip_is_private`），而 DNS 裁决发生在拿到 IP **之前**。要求"任意域名的 DNS 判定与路由判定一致"等于要求 DNS 阶段就已经知道解析结果——逻辑上自相矛盾。所以正确表述是：**基于域名的绑定必须双向一致（有路由分支就有 DNS 分支，反之亦然）；基于 IP 的绑定天然不参与 DNS 分域。** 不变量 INV7 就是按这个收窄版写的。

两个显式豁免：`direct` 线路不声明解析器（它本就要本地视角，不产生 dns 分支）；`tailscale-dns` 用 `ip_accept_any` 做全局分支而非按域名展开——tailnet 名字是运行期从控制面拿的，静态配置里根本没有域名列表，它没有域名匹配键，因此不算"域名分支"。

### 4.2 fake IP 的定位

fake IP 常被误解成一种分流机制。它不是。

问题的本质是一条**失忆缝隙**：应用先 `resolve("google.com")` 拿到一个地址，然后 `connect(地址)`。到了 connect 这一刻，"这个连接是发给 google.com 的"这个信息已经丢了——内核只看得见一个 IP。sing-box 在 connect 侧只能靠 sniff（读 TLS SNI / HTTP Host）把名字找回来，而 sniff 对非 TLS/HTTP 协议无效。

fake IP 的作用是：在 resolve 时刻返回一个**唯一的假地址**作为凭证，并记住"这个假地址 ↔ 这个域名"。connect 到来时，凭假地址查回域名。

所以准确的描述是：

> **fake IP 不做任何决策。它只是在连接到来时，"回忆起"DNS 时刻已经做出的决策。它的作用域严格限于 resolve 与 connect 之间的失忆缝隙。**

这决定了它在架构约束里的位置：fake IP 是**实现细节**，不是维度。它不得改变任何裁决结果——同一份 Mode，开不开 fake IP，流量的出口归属必须完全一致。任何"开了 fake IP 之后分流行为变了"的实现都是错的。

v1 不启用 fake IP（ADR **D-FAKEIP**），但地址段必须预留且与 tun 段分开，理由见 ADR。

### 4.3 桌面系统 DNS 接管：198.18.0.2

要点提炼自 `core/engine/dns_takeover.go` 顶部三个常量的注释块（`dnsTakeoverAddress` / `dnsTakeoverGateway` / `dnsTakeoverPrefix`）。那里写得比本节详细，**改这块前请完整读原文**。

- **接管地址是 tun 接口地址 +1（`198.18.0.2`），不是 tun 地址本身（`198.18.0.1`）。** tun 自己的地址在内核路由表里是 `RTF_LOCAL` 项，发往它的包被环回投递给本机协议栈，**根本不会写进 tun 设备**，`hijack-dns` 永远接不住 → 系统 DNS 查询原地超时 → 整机解析全灭。`198.18.0.2` 不是接口地址，走的是 `auto_route` 装的 sub-range 路由，包会真正进 tun。sing-box 官方 libbox 的 `GetDNSServerAddress` 用的也是 `Addr().Next()`，同款约定。
- **为什么非接管系统 DNS 不可**：LAN 网关是 on-link 直达、官方 Tailscale 的 `100.100.100.100` 有自己的 host route，两者都天然绕过 tun 路由。不接管的话应用拿到的解析结果不可信，按域名分流随之失准。这是定律一的直接推论——解析这一步不能留在盒外。
- **就绪判据**：`route -n get 198.18.0.2` 打印的 gateway 行等于 `198.18.0.1`。darwin 上 `auto_route` 装的不是 `198.18.0.0/15` 接口路由，而是 8 条覆盖全 IPv4 的 sub-range（`1.0.0.0/8`、`2.0.0.0/7` … `128.0.0.0/1`），每条都是 `RTF_GATEWAY` 且 gateway 就是 tun 地址。别的 utun（官方 Tailscale 装的 link 路由）在 `route get` 里根本不打印 gateway 行，天然被这条判据拒掉。
- **残留识别是双判据**：先比对显式记录过的地址列表，再兜底判断"是否落在 `198.18.0.0/15` 段内"。RFC 2544 的这段地址不会出现在任何真实 DNS 配置里，误判率为零；而漏认一个的代价不可逆——一个死地址永久留在系统 DNS 里，没有任何路径会去救它。
- **地址同源约束**：`dnsTakeoverAddress` 与 `buildTUNInbound` 生成的 tun 地址必须保持 +1 关系，防漂移断言是 `TestDNSTakeoverAddressIsTunAddressPlusOne`。
- **与官方 Tailscale 客户端共存**：官方客户端需要开启 "Override local DNS"，否则两者争抢系统 resolver。这是叠罗汉窄承诺的一部分（ADR **D-STACK**）。

---

## 5. 铁律

1. **失败 fail-closed，且用户可感知。** 任何一步失败，宁可让流量断掉并弹出可见错误，也不能"看起来连上了但流量在盒外裸奔"。
2. **绝不静默降级到 direct 或公共 DNS。** 降级本身可以存在，但必须是用户显式配置的，且必须有可见提示。代码里出现 `if err != nil { use direct }` 一律视为越界。`Engine.takeoverDNSLocked` 是正确范例：接管失败了，但同时 `callback.OnError` 把"按域名分流可能不准"推给用户。
3. **Line 不可用窗口期（重连中）语义固定**：绑定到该 Line 的流量 **REJECT**，对应域名的 DNS **SERVFAIL**。不是超时、不是回落到其他线路、不是放行到 direct。理由：超时会让应用重试几十秒后才失败，用户以为是网络慢；回落会把本该走隧道的流量泄漏到明网。
4. **配置变更只有唯一生效通道**：修改 Profile → 重新生成完整 sing-box 配置 → 重启数据面。不允许存在"运行时热改某条规则"的旁路。唯一例外是桌面端通过 Clash API 切换 `testSelectorTag` 做逐线路地址探测，且它**仅用于诊断**，不影响用户流量归属（NE 端不启 Clash API，连这个例外都没有）。
5. **启动期失败必须被捕获。** `sing-box check` 只做 `box.New` 不做 `Start`，抓不到启动期错误（典型：规则集首次下载失败让 router 直接 FATAL）。子进程退出必须被 `Engine.handleSingBoxExit` 接住并转成用户可见错误，否则 engine 会停在"已连接"而用户整机没网。
6. **生成阶段 fail-fast。** 悬空引用（`inspectModeReferences`）、重复 outbound tag、多条 active AnyConnect 线路、多条 enabled Tailscale 线路，一律在生成阶段返回 error。宁可拒绝生成，也不要"起来了但连不通"的假连接——helper 只确认进程 spawn 成功，用户看到的会是"已连接但流量全断"。

---

## 6. 决策记录（ADR）

### D28 — 供给源模型

- **决策**：Line 和订阅可以"自带规则"，但供给出的规则必须以一等公民身份进入 Mode 裁决：可见、可禁用、可排序、可不用。供给是申报制，不是注入制。
- **理由**：现实中 Tailscale 和订阅确实携带路由知识，硬堵会让功能不可用；但直接注入会摧毁定律二，且产生的 bug 无法在配置里定位。申报制在保留能力的同时把裁决权留在 Mode。
- **被否决的替代方案**：(a) 完全禁止自带规则——tailnet 和订阅都变成半残功能；(b) 自带规则直接注入生成配置——已实证会摧毁 Mode 默认出口（`preferred_by` 事故，2026-07 两次）；(c) 给供给规则一个固定的低优先级——用户无法表达"我就是要订阅规则优先"，且顺序仍不可见。
- **影响面**：`core/config/generator.go` 的规则装配顺序；订阅规则的 UI 呈现；未来任何新增的"自带规则"型 Line 类型；不变量 INV4。

### D29 — Tailscale 无特权、配置形态与其他 Line 同构

- **决策**：Tailscale 线路不享有任何特殊地位。配置形态与其他 Line 完全同构，`auth_key` 是纯参数（和 trojan 的 password 一个性质），**不存在登录流程**。
- **理由**：交互式登录流程让 Line 的实现细节爬到引擎生命周期上，逼出"必须先断开 XDial 才能登录/刷新出口节点"这种全局约束，所有其他线路陪绑。同时交互式登录引入了一个"半登录"中间态，四态 UI 和状态机的复杂度全部由它产生。
- **被否决的替代方案**：(a) 保留浏览器 OAuth 登录 + 特权 helper——依赖方向倒流，且开源自建场景下用户拿不到 helper 签名；(b) 后台静默登录——Tailscale 控制面不支持无交互的用户级登录，只有 auth key 一条路。
- **影响面**：Tailscale 线路的配置 UI 退化为一个文本框；引擎状态机移除 Tailscale 专属的前置断开约束；`Engine.StartTailscaleAuth` / `Engine.TailscaleStatus` / `Engine.LogoutTailscale` 及其会话类型整体退场。tailnet 身份仍是 Profile 全局单份（state 目录共享，见 `core/config/tailscale.go` 的 `TailscaleStateDirectory`：早期按 lineID 哈希分目录导致每条线路各注册一台设备、退登也清不干净）。

### D30 — 每 profile 至多一条 active AnyConnect Line

- **决策**：v1 硬校验：一个 profile 里 active（被 active Mode 引用且 enabled）的 AnyConnect 线路不得超过一条，超过则生成阶段直接报错。
- **理由**：vendored sslcon 是**包级单例**（全局状态、单一会话），两条线路会互相踩掉对方的隧道。
- **被否决的替代方案**：(a) 改造 sslcon 成多实例——违反"`third_party/` 不改"纪律，上游合并无望，维护成本无限；(b) 运行时择一启用——用户配了两条却只有一条生效，且"哪条生效"不可预测，正是架构约束要消灭的那类 bug。
- **影响面**：`GenerateSingBoxFor` 的前置守卫（`only one active AnyConnect line is supported`）；UI 需要在用户 enable 第二条时就给出提示，而不是等到连接时才报错。同款约束因同款理由（state 目录单例）也适用于 Tailscale（`only one enabled Tailscale line is supported`）。

### D-DNS — DNS 分域归属由 Mode 裁决

- **决策**：每个域名的解析器归属，由 active Mode 的 binding 唯一决定。DNS 规则与 route 规则从同一份 `mode.Bindings` 编译。**不存在无主的 DNS 规则。**
- **理由**：见第 4.1 节的因果链。DNS 与 route 分家编译必然漂移，且漂移后的症状（流量走 A、解析走 B）极难归因。
- **被否决的替代方案**：(a) DNS 用一套独立的用户配置——两套配置必然不一致，用户要维护两遍；(b) 按 Line 类型自动推断解析器——Line 不该做裁决，且同一条 Line 上手动规则集（内网名）与 URL 规则集（公网名）的正确解析器不同。
- **影响面**：`buildDNS` / `buildNEDNS`；`collectVPNBoundDomains`；`collectProxyBoundDNSTargets`；不变量 INV2。

### D-FAKEIP — v1 不启用 fake IP，但地址段预留且与 tun 段分开

- **决策**：v1 不启用 fake IP。同时在地址规划上预留一段专用于 fake IP，**必须与 tun 使用的 `198.18.0.0/15` 分开**。
- **理由**：不启用——sniff 在当前目标场景（TLS/HTTP 为主）已能覆盖绝大多数流量，fake IP 引入的额外状态（映射表生命周期、跨重启一致性、与系统 DNS 缓存的交互）在 v1 不值得。预留且分开——fake IP 地址会被返回给应用并出现在 connect 目标里；若与 tun 段重叠，就无法区分"这是一个 fake IP 凭证"和"这是发往盒子基础设施的包"，而 tun 段还兼任 DNS 接管地址的残留识别判据（`dnsTakeoverPrefix`），两个用途混在一段里会让那条判据失效——代价是永久性的整机 DNS 损坏。
- **被否决的替代方案**：(a) v1 就启用——见上；(b) 不预留、以后再说——地址段一旦发布就进入用户的路由表和残留清理逻辑，事后改段需要处理所有历史残留，代价不对称。
- **影响面**：`buildTUNInbound` 的地址规划；`dnsTakeoverPrefix` 的语义边界；未来启用 fake IP 时的 DNS 配置。

### D-CRASH — 崩溃后 fail-open + 强通知

- **决策**：XDial 进程异常终止后，系统恢复到无 XDial 的状态（fail-open，用户仍能上网），但必须给出**强通知**告知用户"分流已失效、流量正在裸奔"。
- **理由**：这是铁律 1（fail-closed）的唯一例外，理由是**进程已死就无人能执行 fail-closed**。留下一个把全网流量黑洞掉的 tun 接口，用户在完全不知情的情况下整机断网，且没有任何进程能修复它——这比裸奔更糟。选择 fail-open 的前提是通知必须足够强，让"不知情"不成立。
- **被否决的替代方案**：(a) 崩溃后保留 tun 黑洞（真 fail-closed）——无人可救，用户第一反应是重启电脑，恢复路径比 XDial 本身还脆；(b) fail-open 但静默——用户以为还在分流，最坏情况是内网流量走了明网。
- **影响面**：`Engine.RestoreLeftoverDNS` 与 `Engine.StartDNSSelfHeal` 的残留自愈；下次启动时的残留检测与通知；`Engine.handleSingBoxExit` 的错误上报。

### D-INGRESS — 系统代理 Ingress 列入后续

- **决策**：v1 只有 tun 一种 Ingress。系统代理（HTTP/SOCKS + PAC）作为第二种 Ingress **列入后续**，不在 v1 实现。
- **理由**：tun 覆盖面最全且对应用透明；系统代理的价值在于不需要 tun 权限、能按应用生效，但它引入的归因语义与 tun 不同（拿得到进程信息但拿不到非代理感知流量），需要 Ingress 维度真正做到与裁决解耦后才能安全加入。提前实现会让第一版的 Ingress 抽象被单一实现带偏。
- **被否决的替代方案**：(a) v1 同时做两种——抽象未经检验，大概率长成"tun 的特例 + if 分支"；(b) 永远不做——系统代理是无特权场景的唯一选项，砍掉会锁死一部分用户。
- **影响面**：Ingress 维度的接口设计必须从一开始就假设有第二种实现，不得把 tun 特有的概念（地址段、`auto_route`、DNS 接管地址）漏进 Ingress 的通用契约。

### D-STACK — 叠罗汉窄承诺

- **决策**：XDial 只承诺在两种"叠加"场景下工作：
  1. 叠在**带真 `0.0.0.0/0` 默认路由的底层 VPN** 之上；
  2. 与**官方 Tailscale 客户端**共存（要求对方开启 "Override local DNS"）。

  检测到**其他 `auto_route` 型分流工具**、或**地址段冲突**，一律**拒绝启动**并明确报错，不尝试兼容。
- **理由**：叠加场景的组合空间是无穷的，逐个兼容不可能。选这两种是因为它们的行为可判定：底层 VPN 有真默认路由时，XDial 的 tun 优先级明确；官方 Tailscale 的路由是 link 路由，`route get` 不打印 gateway 行，能被 `dnsTakeoverGateway` 的就绪判据天然区分。其他 `auto_route` 工具会和 XDial 抢同一批 sub-range 路由，谁赢取决于安装顺序——不可判定，就不承诺。
- **被否决的替代方案**：(a) 尽力兼容所有工具——不可判定的冲突只会变成"有时好有时坏"的用户投诉，且无法复现；(b) 完全不检测、任其冲突——用户看到的是随机的连不上，归因成本转嫁给用户。
- **影响面**：启动前置检查需要枚举本机 utun 及其路由类型；地址段冲突检测；错误文案必须说清"检测到 X，XDial 不支持与它同时运行"，而不是泛泛的启动失败。

---

## 7. 禁止事项

以下每一条都对应至少一次真实事故。不允许以"这次情况特殊"为由绕过。

1. **不许让任何 Line 在未被 active Mode 引用时影响本机流量决策。** 包括但不限于：注册路由、抢占默认出口、注入 DNS 规则、修改系统状态。
2. **不许在生成器里注入用户不可见的路由规则。** 生成的 `route.rules` 每一条都必须能追溯到某个 Mode binding 或一份**显式列举**的系统白名单（`sniff` / `hijack-dns` / tailnet 内网段 / 桌面诊断 selector）。白名单本身不得在未更新本文档的情况下扩充。
3. **不许让任何 Line 在未被引用时持有活会话或发起出网请求**（含探测、健康检查、订阅刷新、控制面登录）。"enabled 就去连一下试试"是副作用面泄漏——它产生用户不知道的网络指纹，也会在断网时产生莫名其妙的错误。
4. **不许让 Swift 复刻 Go 的 tag / slug / schema 规则。** `macos/Sources/XDial/NetworkInfo.swift` 的 `slugify` 是一份存量违规复刻——它的注释里自认"必须与 Go 端 `core/config/generator.go` 的 `slugify` 完全一致"，这句话本身就是 bug 的定义（两份实现，一份契约，无人守护）。正确做法是 Go 侧导出运行时目录、Swift 侧只消费，参考 `RuntimeSubscriptionCatalog`。新代码一律走导出，存量复刻应逐步迁移。
5. **不许静默回落 direct**，也不许静默回落到公共 DNS，不许静默跳过一条无法生成的规则而不告知用户。**引用悬空必须报错**（见 INV6a），不得 `continue` 了事。
6. **不许用日志抓取做控制流。** 解析 sing-box / sslcon 的日志文本来判断状态，然后据此决策——日志格式不是契约，上游改一个字就静默失效，且失效方式是"永远走 else 分支"，没有任何报错。状态判断必须走结构化接口（Clash API、进程退出码、显式回调）。
7. **不许把 DNS 规则和 route 规则从不同来源编译。** 两者的唯一输入源是 `mode.Bindings`。
8. **不许扩大 tailnet 内网段的自动规则豁免。** 那条豁免的合法性完全来自"作用域等于 tailnet 私有地址空间"。任何覆盖公网地址、`0.0.0.0/0` 或域名的自动规则都不在豁免范围内。
9. **不许依赖 sing-box 的默认值来维持架构约束性质。** 影响裁决归属的字段（`accept_default_resolvers`、`independent_cache`、`auto_detect_interface`、`default_domain_resolver`、tun 的 `stack`）必须显式写死。上游默认值翻转过一次就会静默摧毁密封性。
10. **不许改 `third_party/`。** 需要上游改动时走本地补丁，并在 `third_party/` 的补丁说明里留痕。

---

## 8. 不变量测试清单

CI 门禁包含以下不变量，实现在 `core/config/invariants_test.go`。每条注明它守护架构约束的哪一部分。**这些测试是架构约束的可执行形式，失败即越界，不得通过放宽断言来"修复"。**

| 编号 | 不变量 | 守护什么 |
|---|---|---|
| **INV1** | **正交性**：未被 active Mode 引用的对象（Line / Subscription / RuleSet），其存在与否、enabled 与否，都不改变生成的 sing-box 配置 | 定律二「声明 ≠ 生效」；禁止事项 1 |
| **INV1c** | **Tailscale 例外收窄**：未被引用的 Tailscale 线路**只允许**多出一个 endpoint 条目（MagicDNS 就绪所需），不得多出任何路由或 DNS 分支。这是 INV1 唯一登记在案的例外，本测试把它锁死在最小范围 | 定律二；第 3 节「例外不得扩大」 |
| **INV2** | **DNS 归属**：每个 `dns.server` 都必须有主，能追溯到一条 active Line。**无主的 DNS server 即失败** | D-DNS；第 4.1 节因果链；禁止事项 7 |
| **INV3** | **密封性**：生成配置必须包含 `{"protocol":"dns","action":"hijack-dns"}`；必须**不存在** `protocol:dns → direct` 的规则 | 定律一；铁律 2。直接编码了"桌面 DNS 曾硬编码 direct"那次事故 |
| **INV4** | **无隐藏规则**：`route.rules` 的每一条都可追溯到某个 Mode binding 或显式系统白名单（`sniff` / `hijack-dns` / tailnet 内网段 / 桌面诊断 selector） | D28「可见」；禁止事项 2 |
| **INV4b** | **显式绑定优先于供给规则**：用户在 Mode 里写的绑定规则必须排在订阅自带规则之前。变红条件＝把订阅规则重新提前 | D28「绝不隐式抢注」；定律二反面案例 3 |
| **INV6a** | **悬空引用报错**：Mode binding 指向不存在的 RuleSet / Line / Subscription ID → 生成阶段返回 error，不得静默跳过 | 铁律 6 fail-fast；禁止事项 5 |
| **INV6b** | **禁用走 warning**：Mode binding 指向存在但 `enabled=false` 的对象 → 产生 warning（用户可感知），不报错。前者是配置损坏，后者是用户的合法意图 | 铁律 1「用户可感知」 |
| **INV7** | **域名绑定与 DNS 分域同源**（收窄版）：**基于域名的**绑定必须双向一致——有路由分支就有 DNS 分支，反之亦然。基于 IP 的绑定不参与（见 4.1 节的不可满足性论证）。豁免：`direct`、`tailscale-dns` | D-DNS；禁止事项 7 |
| **INVD30** | **单 AnyConnect**：桌面端存在多条 active AnyConnect 线路时拒绝生成 | D30 |

**尚未实现、但同样是架构约束要求的**（新增代码不得违反，实现该测试是待办）：

| 编号 | 不变量 | 守护什么 |
|---|---|---|
| **副作用面** | 未被引用的 Line 不得持有影响流量的活会话，也不得发起出网请求（含探测、健康检查、订阅刷新、控制面登录） | 禁止事项 3；定律二 |

INV1/INV2/INV4/INV7 的测试都依赖一份**足够复杂的基准 profile**（`invBaseProfile`）：如果基准 profile 里某个分支根本不会出现（例如没有企业 DNS 就不会生成 `enterprise-dns` server），对应断言会因为"空配置"而**假绿**。给生成器加新分支时，必须同步扩充基准 profile，否则等于悄悄关掉了一条不变量。

---

## 9. 改动前的自检清单

提交任何改动前，逐条回答：

1. 我动的代码属于哪个维度？它有没有读取或写入另一个维度的对象？
2. 我新增的任何配置输出，用户能在 UI 里看到吗？能关掉吗？
3. 我有没有引入一条"某个开关打开就自动生效"的全局行为？
4. 失败路径上，我是让它可感知地断掉，还是悄悄回落了？
5. 我有没有在 Swift 里重新实现一份 Go 已经有的规则？
6. 我有没有靠解析日志文本来判断状态？
7. `go build ./...` 和相关包的 `go test` 过了吗？`gofmt` 过了吗？

任何一条答不上来，先停下来问，不要提交。
