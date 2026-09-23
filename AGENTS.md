# XDial

macOS 菜单栏网络分流工具；iOS / tvOS 共用 Go 核心。

远程 `xdial-next` 分支长期独立维护 XDial Next，基线为 `2eab57f`。
按用户要求不合入 main、不发布稳定版；Next 发布只进入 GitHub prerelease。
`make app` 构建 Next 调试包，`make app-debug` 构建既有 Debug 身份；只有明确要求时才覆盖对应安装。
分发流程见 [Next 发布](docs/agent/next-releases.md)。未经要求不重启应用或网络。

## 核心边界

- XDial 表达、编译和托管；sing-box 独占 DNS、路由和转发裁决。平台层只提供系统接入与网络事实。
- Ingress / Line / RuleSet / Scenario 正交；Scenario 是用户流量的唯一绑定点，声明不等于生效。
- 已知目标先确定 Line，再经该 Line 解析和连接；资源获取与 MagicDNS 的窄例外见架构。
- 启动前的系统网络是完整、不透明的 Underlay；XDial 不识别网络产品、不重排接口、不散落 DNS / 路由策略。
- 安装、连接、场景切换各有独立事务。候选切换准备期间，旧连接继续承载流量。
- 各版本共享用户 Profile 配置库；首次只读转换旧配置，旧文件不写回。勾选卸载删除数据时清理新旧配置及凭据。
- Debug、Next 与正式版的系统组件、运行状态和维护事务仍独立；不得因配置迁移重启或改变现有网络。

## 项目资料

| 内容 | 来源 |
|---|---|
| 所有权、DNS、Underlay、事务与协议边界 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 产品表面、状态和交互 | [DESIGN.md](DESIGN.md) |
| 构建产物、签名与安装副作用 | [本地开发](docs/agent/development-builds.md)、[Makefile](Makefile) |
| 更新协议与发布机制 | [更新与发布](docs/agent/updates.md) |
| 诊断接口与运行事实 | [Debug Server](docs/agent/debug-server.md)、[Tailscale 证据](docs/verification/tailscale.md) |
| 架构不变量 | [core/config/invariants_test.go](core/config/invariants_test.go) |
| 历史事故 | [docs/incidents/](docs/incidents/) |

上游依赖版本见 [go.mod](go.mod)；本地差异由 [补丁构建入口](scripts/prepare-patched-go-mod.sh) 组装，`third_party/` 保留上游源码。
