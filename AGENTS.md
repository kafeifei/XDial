# XDial

macOS 菜单栏网络分流工具；iOS / tvOS 共用 Go 核心。

修改完成后合入最新 main，验证后直接覆盖安装并重启 Debug；`make restart` 会拒绝回退已装 Debug 里尚未进 main 的提交。

## 分支

| 分支 | 用途 | 规则 |
|---|---|---|
| `main` | 正式版基线，`vX.Y.Z` 从这里发布 | 只经 PR 合入；新工作从这里拉出 |
| 工作分支：`claude/*`、`codex/*`、`cindy/*`、`feature/*` | 单个修复或功能 | 从 main 拉出，PR 只开向 main；修复直接进 main，实验功能另合进 `xdial-beta` |
| `xdial-beta` | beta 线：main 加上实验功能，与正式版同一身份、靠更新源区分 | 只接收 main 和工作分支的合并，不从它拉分支、不合回 main；打 `vX.Y.Z-beta.N` 标签由 CI 构建 prerelease，`make publish RELEASE_CHANNEL=beta` 写入 beta.json，见[更新与发布](docs/agent/updates.md#beta-发布机制) |

Debug 从正在验证的工作分支构建（已合入最新 main），没有 Debug 专用分支；确需回退已装 Debug 时设 `ALLOW_DEBUG_ROLLBACK=1`。
main 回滚过的功能要进 beta，先在 `xdial-beta` 上撤销那次回滚，再合入该功能分支。

## 提交与验收

CI 不跑真机网络测试，真机验收由开发者（PR 作者）负责，是合并门槛。

1. **开发者自测：** 改动涉及网络扩展、连接、场景、分流、DNS 或升级迁移时，PR 作者在自己的 Mac 上装 Debug 实测，不能省。
2. **证据写进 PR：** 按 [PR 模板](.github/pull_request_template.md)写测了哪几项、机器和系统版本、每项结果，附截图或 [Debug Server](docs/agent/debug-server.md) 诊断输出。没测的项写"没测"和原因。
3. **自测做不了时停手：** 签名团队不匹配、没有对应网络环境等情况，在 PR 里写明缺哪项、为什么，然后等用户，不合并。
4. **合并由用户决定：** agent 不合并 PR，不开自动合并，不加批准标签。证据写全后在 PR 里说明"等用户合并"，然后停手。
5. **三轮审查不过就停：** 同一个 PR 审了 3 轮还不通过，停止打补丁，在 PR 里写思路复盘，交给用户。
6. **不碰配置：** 不改 secrets、仓库设置、环境和分支保护；确实需要改时告诉用户。

## 核心边界

- XDial 表达、编译和托管；sing-box 独占 DNS、路由和转发裁决。平台层只提供系统接入与网络事实。
- Ingress / Line / RuleSet / Scenario 正交；Scenario 是用户流量的唯一绑定点，声明不等于生效。
- 已知目标先确定 Line，再经该 Line 解析和连接；资源获取与 MagicDNS 的窄例外见架构。
- 启动前的系统网络是完整、不透明的 Underlay；XDial 不识别网络产品、不重排接口、不散落 DNS / 路由策略。
- 安装、连接、场景切换各有独立事务。候选切换准备期间，旧连接继续承载流量。
- 各版本共享用户 Profile 配置库；首次只读转换旧配置，旧文件不写回。勾选卸载删除数据时清理新旧配置及凭据。
- Debug 与正式版的系统组件、运行状态和维护事务仍独立；不得因配置迁移重启或改变现有网络。

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
