# XDial Next 测试通道

Next 的 Profile 配置库已合入 main，正式版、Debug 与 Next 使用同一份源码和共享配置库。
Next 保留独立身份作为测试通道，从远程分支 `xdial-next` 发布；Next 发布不会替换正式版或 Debug 的组件。
产品设计依据 [Profile v0.3](../plans/profile-subscriptions.md)，分发见 [Next 发布](next-releases.md)。

## 构建与隔离

`make app-next MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates` 生成 Apple Development
签名的 `build/XDial Next.app`。默认安装目的地为 `/Applications/XDial Next.app`。
这是开发构建，不能公开分发。`NextRelease` 使用同一 Next 身份构建无调试服务的分发包；
`make restart` 只作用于 Debug。

| 项目 | Next |
|---|---|
| Host / Settings / Helper / Extension / Daemon | `com.kafeifei.xdial.next` 及对应后缀 |
| App Group | `UVZM439VGU.com.kafeifei.xdial.next.network` |
| 共享配置 / 密钥 service | `~/.xdial/configuration/profiles.enc` / `com.kafeifei.xdial.configuration` |
| Next 偏好 / 运行状态目录 | `com.kafeifei.xdial.next` / `~/.xdial-next` |
| helper 状态与 socket | `/Library/Application Support/XDial Next` / `/tmp/xdial-next.sock` |
| 诊断 HTTP | 调试包 `127.0.0.1:19878`；分发包不包含 |
| 更新 | 手动更新同一 Next 身份，不消费正式更新 |

首次启动不自动连接，也不自动注册系统组件。用户可以先配置；通用里的安装入口或显式
连接才启动安装事务。已有同通道 helper 的安装验证仍在启动时执行。
候选包的 `--install-only` 会停止同通道旧进程；不允许把它当作保留现有进程的覆盖安装命令。
各版本共用新版配置库和密钥，组件、连接事务及协议运行目录仍独立。
启动时先读取共享库；仅当文件不存在时自动转换一次。已有旧 Next 加密库时完整复制其中
全部 Profile，保留已有编辑；否则将旧版单份配置转换为“默认配置”，保留场景、顺序和引用。
历史文件跨通道存在多份时按最近保存时间选取；不按正式版或 Debug 设优先级。
已知来源包含原桌面偏好与 vault，以及旧沙盒配置。所有来源只读，原文件和旧密码不删除、
不写回；转换成功后才原子写入新库，失败不会创建空库。文件损坏、格式不支持或密钥不可读
不等于文件不存在，不能触发重新导入。Tailscale 的旧在线身份不复制。

已有共享库时直接使用，不再次扫描历史文件。界面只保留新建、文件导入、链接订阅等普通
Profile 管理，不再提供“导入旧版配置”。尚不能完整转换的旧嵌套订阅明确报错，不丢弃部分内容。
旧版应用继续读取原快照；新版修改只保存在共享库，不反向转换。
共享库写入持有文件锁并校验读入时的密文摘要；另一版本已修改或删除数据时拒绝覆盖，提示
重新打开应用后再编辑。首次迁移期间另一版本率先创建共享库时，采用已经创建的库。

卸载默认保留数据。勾选“同时删除新旧版本的配置与密码”后，清理共享库、已知 XDial / Debug /
Next 历史配置目录与偏好域、对应钥匙串凭据；其他版本仍在运行时先提示退出，避免数据被写回。
系统组件和 root 运行目录仍只清理当前卸载的通道，不通过配置清理去关闭其他网络。

候选包的 `--check-xdial-debug-import` 仍可只读诊断单份旧 Debug 配置；不初始化网络。

## 这一版可用

- 配置窗口提供线路 / 线路组 / 规则 / 场景 / 通用五页，通用在同一窗口中。
  顶栏分成 `[Profile ▾ | 线路 规则] [线路组 场景]`，通用独立靠右；菜单栏直接选择全局场景。
- 线路组与场景跨 Profile 引用，通过来源名区分同名线路与规则；仅显式连接才进入现有
  Prepare / Commit 事务，保存、刷新或切页不会替换当前运行快照。
- 订阅首次导入可创建组与场景；刷新保留场景、组名称、固定选线和测速参数。
  组可显式跟随来源成员，额外手动成员保留；新增源组与场景通过管理页导入。
  重新生成是独立的确认操作。依赖失效使整笔更新失败，自动刷新失败后至少等 15 分钟。
- selector / urltest 仍由 sing-box 执行；空组可保存为草稿。组支持跨来源嵌套，禁止循环、
  平台 VPN 成员及包含 Direct 的 urltest。手动组固定所选成员，测速不更改选择。
- Clash、Surge 及普通 sing-box 导入先按原策略归类规则，再按结构消除重复业务选择器。
  只有重复共享节点池、直连及同类选择器的手动组才转成场景绑定；保留配置中的手动选择，
  未设置时沿用首个成员。不同业务规则即使指向同一个出口也不合并。节点池、测速组、
  特殊成员范围及其他组/下载/native 选项依赖的组保留；XDial 便携文档保留已有自定义结构。
- 本地整个 Profile 库（含来源 URL、密码和订阅基线）使用 AES-256-GCM 加密，随机密钥
  存在 Keychain。文件 0600、目录 0700；损坏或钥匙串不可访问时停止保存，不回退成空库。
- 脱敏导出将需要补填的配置标记为 `xdial.requires_input`；可重新导入编辑，缺少凭据时
  连接准备失败。协议实现自己的身份状态不等同于 Profile 库，仍由对应协议的存储机制管理。

## 格式与当前兼容边界

便携文档采用 sing-box JSON 的 `outbounds`、`route.rule_set`，外加完整策略文档的 `xdial.schema_version = 1`、
对象显示信息和 `xdial.scenarios[].route`。普通 sing-box 根级 `route.rules/final` 导入成默认场景。
运行配置由 XDial 注入场景、凭据和平台事实后生成，整个文档不能直接当作标准 sing-box 运行文件。

| 输入或资源 | 当前支持 |
|---|---|
| 原生线路 | Direct、Trojan、Shadowsocks、VMess、AnyTLS，保留核心支持的 TLS / transport 等附加选项 |
| 线路组 | selector、urltest，支持嵌套和循环引用检查；AnyConnect / Tailscale 直接绑定场景；含 Direct 的 urltest 暂不支持 |
| 原生规则 | domain、domain_suffix、domain_keyword、domain_regex、ip_cidr，以及这些字段组成的 logical / invert；remote / inline rule_set |
| 现有规则界面 | 域名/IP、应用/进程、URL 规则；另可编辑 sing-box 匹配表达 |
| 订阅 | 复用严格解析器处理 Clash、Surge、节点 URI / Base64 列表；规则转换支持 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / IP-CIDR6 / PROCESS-NAME / GEOIP 国家 / IP-ASN / FINAL，保留 IP 规则的 no-resolve |
| XDial 企业 VPN | 保留现有 AnyConnect / Tailscale 平台适配，使用 `xdial.adapter_lines`；本次未替换 sslcon |
| 仅导入线路 | 用户显式选择后舍弃来源规则/分组，生成共享线路、选择组和默认场景；不自动采用部分成功结果 |

尚未完成自定义 DNS 的编辑和完整往返、通用 endpoints、所有路由 action / 匹配条件、
REJECT 等完整订阅转换、旧嵌套 Subscription 的无损迁移、单场景标准运行配置导出。
未知规则或选项明确拒绝。USER-AGENT 没有 sing-box 等价匹配：原条目保存在
`import_warnings`，预览逐条列出，用户确认不生效后才能保存；当前配置下拉可再次查看，
复制和导出保留这些条目。刷新新增未支持条目时保留原配置，要求重新预览，不能静默采用。
不能把本版称为完整 sing-box 或全机场订阅兼容。

PROCESS-NAME 复用现有应用身份适配，保留进程名、通配符和路径语义；平台不匹配的
Windows/Android 进程名仍保留。GEOIP 国家转换为 SagerNet/sing-geoip 的显式远程 SRS，
IP-ASN 转为 MetaCubeX/meta-rules-dat 的 ASN SRS；预览说明来源，可在规则中查看或在本地
副本中修改，数据范围以所选来源为准。资源由现有连接准备事务下载，导入不启动线路。
Surge RULE-SET 严格展开保持原始位置，最多 64 个来源，仍受 30 秒总时限、1 MiB 内容、
20,000 条规则限制；未知条目或下载失败使整次导入失败。
`no_resolve` 属于规则元数据和运行指纹，编译时省略该 IP 规则匹配前的系统 DNS 解析。
Clash/Surge 的应用设置、监听端口、DNS/hosts、重写、脚本和 MITM 不作为订阅资源导入，
系统接入和 DNS 仍由 XDial 的当前场景及 Underlay 生成。
订阅按原出口身份聚合 RuleSet，名称沿用出口名；一个规则的 `conditions` 同时容纳
域名、IP、应用及远程资源。线路组继续保留成员、嵌套和选线方式，在独立页面管理。
规则页显示各类匹配数量并支持内容搜索，新建规则先命名，再添加多种匹配内容。
内部仍按连续来源、类别和 no-resolve 分块，避免为数千条域名创建视图。

默认 Scenario 的 `match_order` 保存归类前的交错顺序，场景绑定只出现一次完整规则；
没有 `match_order` 的场景按绑定顺序执行。原顺序模式下，新匹配项加入同规则最后一个
位置，新绑定追加；已有条件不重排。UI 明确标注原顺序模式，只有用户显式切换为列表
顺序才允许拖动。迁移中已有场景只使用部分条件时，绑定的 `condition_ids` 保留范围，
UI 标注「部分匹配」并允许用户改用完整规则。删除最后一个被选条件时移除该绑定，
不能把空选择解释为使用整个规则。订阅刷新遇到失效的范围或顺序引用整体失败。

便携文档的匹配资源使用原生 `route.rule_set`，`xdial.rule_groups` 保存成员，场景的
`match_order` 与 `binding_conditions` 保存优先级及局部范围。复制与往返重映射这些引用。
Go 统一展开为现有的有序条件绑定，再交给原 sing-box 编译路径；迁移必须逐个场景验证
运行指纹相等。新版加密配置库 schema 为 3，迁移旧 schema 1 / 2 的组与场景到全局。旧应用继续使用未改动的原配置文件；
支持共享目录但不理解新 schema 的构建应拒绝读取，不能用空库覆盖。
五个配置页及内部匹配内容按需加载，不增加匹配引擎。

旧桌面订阅 UI 已删除，Go 的旧订阅路径仍供现有移动端和兼容调用使用，尚未整体删除。

[公司示例配置](../examples/profile-next-company.json) 使用保留的 `.example` 域名，无真实凭据。
导入后填写自己的 VPN 地址和登录信息即可继续配置；它不是实际公司线路。

## 验证与维护

- Go：`core/config`、`core/libbox`、`core/subscription`、`cmd/xdial` 全包测试；配置用同版本
  sing-box validator 检查；涵盖原生规则/组、脱敏往返、严格拒绝、稳定 ID、DNS 归属及身份隔离。
- Swift：XDialTests 的 Next 配置；覆盖加密、篡改、钥匙串不可用、刷新引用与选择器选择等。
- `make test-profile-document-bridge` 使用实际 Libbox framework 解析公司示例，再用实际
  Swift Profile 解码、复制和脱敏往返。覆盖 Go 省略空字段时 Swift 解码的兼容边界。
- `scripts/verify-macos-identity-contract.sh` 同时检查 Next、Debug、正式配置；
  `scripts/verify-macos-debug-app.py '<Next app>' next` 检查实际签名产物。
- 真正的跨 Profile 网络切换、企业 VPN 登录、在线订阅刷新仍需要运行验收。
  编译、单元测试或打开设置窗口不作为这些行为已验证的证据。

Next 发布检查身份、数据升级、源码提交和更新目标；Next 发布入口不得指向稳定版 feed 或正式身份。

订阅导入对 AnyTLS 的 `tfo=true` 做有界兼容：关闭 sing-box 不支持的 TCP Fast Open，
保留节点、TLS/认证选项和路由内容，并在预览及管理页展示合并后的兼容说明。
此调整记录在 `import_adjustments`，随配置保存、复制和导出；不属于被跳过的规则。
原解析结果不修改，直接运行 AnyTLS + TFO 的校验仍拒绝该组合，其他协议的 TFO 不受影响。

## 统一线路组与测速

线路组首项为自动选择，其余项直接固定成员；底层仍保存原生 selector/urltest。
切换保留成员、测速参数和稳定 ID；selector 的备用自动测速参数随便携文档存入 xdial 元数据，
不会把 url/interval 写入不支持它们的 native selector。订阅更新保留本地选线覆盖。

Provider 提供受事务约束的 line-latency-snapshot 与 probe-line-latency。Host 仅传 Line ID，
不接受任意 URL 或出口 tag。Go 读取 sing-box 原生历史和真实嵌套组选择；测试借用当前 Box
的运行租约，在网络请求期间不持有生命周期锁，结束后核验代际。手动测试为固定 HTTPS HEAD，
不调用 SelectOutbound。Host 每 5 秒读历史；自动 URLTest 的测试间隔仍由原生引擎执行。
当前场景可复用有效 Line 能力；未接入当前场景的普通代理及 Direct 可由用户显式发起
ProbeStandaloneLineLatency。该入口接收单条线路，在内存中使用既有 LineOutbound 编译器
创建无 ingress 的 Box，只执行固定 HTTPS HEAD，结果不写入运行中 Box 的原生历史。
每条 5 秒，最多并发 3 条，取消或配置变化后拒绝迟到结果；无浏览触发的后台探测。
VPN/Tailscale 不在此入口创建身份，需先连接对应场景。

## 全局库升级与资源导出

升级共享配置库前，在同目录写入 `profiles-before-global-<UUID>.enc`，保留原加密字节，
使用既有 Keychain 密钥恢复；升级和刷新均受文件锁及原文件摘要约束。旧应用不认识 schema 3
时拒绝读取，已经打开的旧版本也不能覆盖新库。SSID 冲突或失效引用会阻止迁移，原文件保留。

Profile 脱敏导出仅含来源线路和规则，使用便携文档 schema 2 + `resources_only` 标记，
重新导入不会凭空创建默认场景。若规则下载仍引用全局组或其他来源，单 Profile 导出与复制
明确失败；不能丢掉依赖后悄悄改成直连。完整本地库和迁移备份包含全局对象与来源关系；
这一版不新增便携式整库备份/恢复界面。

Debug/Next 候选包提供 `--render-settings-preview <目录>` 离线验收入口，使用合成的两份
来源及跨来源组、场景，依次渲染实际 SwiftUI 五页到 PNG；不执行应用定位安装、配置加载、
订阅刷新、连接或安装初始化。此结果只证明界面布局，不证明实际网络行为。
