# XDial Next 独立分支

分支 `codex/profile-next`，从本地已提交基线 `2eab57f` 开始维护。用户要求这一版长期独立，
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

## 这一版可用

- 配置 / 通用互斥；Profile 下拉中切换、重命名、复制、删除、新建、文件导入、链接订阅、
  刷新和脱敏导出。线路 / 规则 / 场景共用同一个 Profile，分别保留编辑位置。
- Popover 只选择要使用的 Profile 与场景；编辑选择不会连接。跨 Profile 连接复用现有
  Prepare / Commit 切换事务，失败保留原运行配置。准备期间继续编辑会保留待应用状态。
- selector / urltest 作为共享线路组，由 sing-box 执行选择和测速。选择器默认成员的修改
  在下次应用配置时生效。Direct 选择使用系统 Underlay DNS。
- 订阅来源对象只读；可以增加本地资源及场景，或建立完全可编辑的本地副本。更新保持
  本地对象、显示顺序及用户选择器选择，失效引用使更新整体失败。失败后自动刷新至少等待 15 分钟。
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
| 订阅 | 复用严格解析器处理 Clash、Surge、节点 URI / Base64 列表；规则转换支持 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / FINAL |
| XDial 企业 VPN | 保留现有 AnyConnect / Tailscale 平台适配，使用 `xdial.adapter_lines`；本次未替换 sslcon |
| 仅导入线路 | 用户显式选择后舍弃来源规则/分组，生成共享线路、选择组和默认场景；不自动采用部分成功结果 |

尚未完成自定义 DNS 的编辑和完整往返、通用 endpoints、所有路由 action / 匹配条件、
REJECT / GEOIP 等完整订阅转换、旧嵌套 Subscription 的无损迁移、单场景标准运行配置导出。
这些语义遇到不支持时明确拒绝；不能把本版称为完整 sing-box 或全机场订阅兼容。
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
