# XDial Next 独立分支

分支 `xdial-next`，从本地已提交基线 `2eab57f` 开始维护。用户要求这一版长期独立，
不合入 main，不覆盖正式版或 XDail Debug。产品设计依据 [Profile v0.3](../plans/profile-subscriptions.md)。

## 构建与隔离

`make app MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates` 生成 Apple Development
签名的 `build/XDial Next.app`。默认安装目的地为 `/Applications/XDial Next.app`。
这是开发构建，不是已公证的企业分发包。正式发布入口和 `make restart` 在本分支禁用。

| 项目 | Next |
|---|---|
| Host / Settings / Helper / Extension / Daemon | `com.kafeifei.xdial.next` 及对应后缀 |
| App Group | `UVZM439VGU.com.kafeifei.xdial.next.network` |
| 配置与钥匙串 service | `~/.xdial-next` / `com.kafeifei.xdial.next` |
| helper 状态与 socket | `/Library/Application Support/XDial Next` / `/tmp/xdial-next.sock` |
| 诊断 HTTP | `127.0.0.1:19878` |
| 更新 | 手动更新同一 Next 身份，不消费正式更新 |

首次启动不自动连接，也不自动注册系统组件。用户可以先配置；通用里的安装入口或显式
连接才启动安装事务。已有同通道 helper 的安装验证仍在启动时执行。
候选包的 `--install-only` 会停止同通道旧进程；不允许把它当作保留现有进程的覆盖安装命令。
Next 不自动读取、迁移或删除正式版、Debug 的配置。各 Profile 的协议身份目录再按 ID 隔离。
显式使用配置下拉中的「从 XDail Debug 导入」可读取本机已保存的配置和凭据，先预览，
再保存为一个独立的本地 Profile。保留线路、规则、场景及其顺序和引用；导入不激活 Profile，
不连接、不复制启动项或自动连接设置。原配置文件只读；密码进入 Next 的加密库。
Tailscale 使用新的设备名和独立身份目录，需要在 Next 单独登录；不复制 Debug 的在线身份。
包含旧版嵌套订阅的配置仍整体拒绝，不静默丢弃内部路由。

候选包的 `Contents/MacOS/XDial --check-xdial-debug-import` 可在两端运行时只读验证迁移。
`--import-xdial-debug` 将其保存为「XDail Debug 导入」，仅允许 Next 未运行时执行，
否则拒绝写入以保护正在编辑的配置库；Debug 无需退出。这两个命令均在 App、安装和网络
初始化之前退出，输出只有资源和凭据数量。导入后的编辑选择与运行选择保持独立。

## 这一版可用

- 配置窗口按线路 / 线路组 / 规则 / 场景分类；通用打开独立应用设置窗口，按启动与连接、
  外观与语言、系统与权限、关于与更新分类。Profile 下拉只负责选择与管理配置，
  不兼任页面切换；保留重命名、复制、删除、新建、文件导入、链接订阅、刷新和脱敏导出。
  线路 / 规则 / 场景共用同一个 Profile，分别保留编辑位置；打开通用不替换编辑器。
- Popover 只选择要使用的 Profile 与场景；编辑选择不会连接。跨 Profile 连接复用现有
  Prepare / Commit 切换事务，失败保留原运行配置。准备期间继续编辑会保留待应用状态。
- selector / urltest 作为共享线路组，由 sing-box 执行选择和测速。新建组为空，展开只显示已有
  成员，通过可搜索的「添加线路或组」入口逐项加入共享引用；移除成员不删除线路。成员区
  限高滚动，添加嵌套组时检查自身、循环、深度以及祖先测速组的 Direct 限制。空组可保存
  为编辑草稿，完整导出和连接仍由 Go 校验。测速组不提供手动选用；当前尚未回传核心
  实时选中成员，因此只说明自动选择行为。手动选择组保留选用成员，下次应用配置生效。
  订阅成员只读，手动选择保留本地覆盖。Direct 选择使用系统 Underlay DNS。
- 订阅来源对象只读；可以增加本地资源及场景，或建立完全可编辑的本地副本。更新保持
  本地对象、显示顺序、用户选择器选择及场景中单独修改的出口，失效引用使更新整体失败。
  失败后自动刷新至少等待 15 分钟。
- Clash、Surge 及普通 sing-box 导入先按原策略归类规则，再按结构消除重复业务选择器。
  只有重复共享节点池、直连及同类选择器的手动组才转成场景绑定；保留配置中的手动选择，
  未设置时沿用首个成员。不同业务规则即使指向同一个出口也不合并。节点池、测速组、
  特殊成员范围及其他组/下载/native 选项依赖的组保留；XDial 便携文档保留已有自定义结构。
- 本地整个 Profile 库（含来源 URL、密码和订阅基线）使用 AES-256-GCM 加密，随机密钥
  存在 Keychain。文件 0600、目录 0700；损坏或钥匙串不可访问时停止保存，不回退成空库。
- 脱敏导出将需要补填的配置标记为 `xdial.requires_input`；可重新导入编辑，缺少凭据时
  连接准备失败。协议实现自己的身份状态不等同于 Profile 库，仍由对应协议的存储机制管理。

## 格式与当前兼容边界

便携文档采用 sing-box JSON 的 `outbounds`、`route.rule_set`，外加 `xdial.schema_version = 1`、
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
运行指纹相等。新版加密配置库 schema 升为 2，接受旧 schema 1，旧 Next 因不理解新顺序
而拒绝读取新版库；不能直接降级使用新版库，可使用迁移前的加密备份回退。
四个配置页及内部匹配内容按需加载，不增加匹配引擎。

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

向 main 回流单项修复或建立 Next 发布渠道时，需要单独检查身份、数据升级和更新目标；
不得直接恢复本分支的稳定发布入口。
