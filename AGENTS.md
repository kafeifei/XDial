# XDial

XDial 是 macOS 菜单栏网络工具：SwiftUI 提供控制面，sing-box 提供数据面，AnyConnect
协议由 vendored sslcon 适配。

本文件是 Agent 的唯一常驻入口和阅读路由，不是仓库索引、架构全文或操作手册。先按任务
选择必要资料，再读涉及的实现与测试；不要默认把所有规范装入上下文。目录、类型、命令和
构建事实先用 `rg`、源码、测试和 `Makefile` 获取，以当前 checkout 与运行态为准。

## 先定任务和现场

- 答疑、审查、诊断只检查和报告；变更、构建、修复才编辑。扩大范围前先和用户对齐。
- 开始前检查 branch、HEAD、工作树和相关运行态。发现本地分支落后、存在无关改动或运行的
  App 与当前构建不一致时先报告，不自动 pull、reset、stash、覆盖或清理。
- 先比对正常路径，追事实源、所有权、状态流和不变量；历史文档与日志只作线索。
- 如果实现与规范冲突，先判断是实现越界还是规范需要改变。未经用户明确同意，不得改写
  架构或设计约束来迁就实现。

## 保护正在运行的系统

- 默认保留用户当前的 XDial 连接、网络配置、Line / Scenario、System Extension、账号状态
  和前台输入。
- 未经当前任务明确授权，不执行 `make restart`，不退出或替换运行中的 XDial，不调用
  connect / disconnect / reconnect / select-scenario / prepare-system-extension / 故障注入，
  不改变 DNS、路由、Network Extension、Tailscale 登录或远端节点状态。
- Debug Server 的 `/health`、`/state` 和 `/ax` 可用于只读检查。任何 POST 或 AX 操作都先
  判断实际副作用；授权只覆盖用户本次指定的目标，不自动扩展到断连、重装或故障注入。
- 获准做运行态验证前，先读取当前状态并说明预期影响与恢复边界；完成后用结构化事务、真实
  流量和当前进程证明结果。不得用重启后暂时恢复代替根因修复。
- 禁止重启、关机或注销电脑。需要具体 Debug 动作时才读
  [Debug Server 操作手册](docs/agent/debug-server.md)。

## 按任务阅读

所有任务先读本文件，再读改动涉及的源码、测试和 `Makefile`。其余资料按下表选择：

| 任务 | 必读资料 |
|---|---|
| 文案、局部测试、无行为变化的构建或文档维护 | 相关实现与测试；只有触及产品契约时再读规范 |
| Line / RuleSet / Scenario、配置生成、DNS、路由、连接事务或平台数据面 | `ARCHITECTURE.md` 的第 1、2、5、7–9 节，以及相关主题章节和 ADR |
| macOS Underlay、Transparent Proxy、Packet Tunnel | `ARCHITECTURE.md` 的 D31–D40 中相关决策，不默认加载全部事故记录 |
| Tailscale Line 或其验收 | D33–D35，以及 [Tailscale 验收边界](docs/verification/tailscale.md) |
| 安装、System Extension、更新或发布 | D37、相关事务实现、`Makefile` 与发布脚本 |
| UI、交互或视觉 | `DESIGN.md` 的第 1–2 节、受影响表面及第 3–11 节中的相关规则 |
| Debug Server、真实 UI 或网络现场诊断 | [Debug Server 操作手册](docs/agent/debug-server.md)；网络诊断再读相关 ADR |

只有修改架构/设计规范本身、改动跨越多个所有权边界，或无法判定相关决策时，才完整阅读
`ARCHITECTURE.md` 或 `DESIGN.md`。规范是权威约束，但不是每个任务的默认上下文。

## 不变量摘要

- **控制面与数据面分离**：XDial 表达、编译和托管；sing-box 接管、解析、裁决和转发。
- **外部密封律**：XDial 对系统只增加一个网络叠加层，DNS、路由和分流不散落到盒外。
- **内部正交律**：Ingress / Line / RuleSet / Scenario 相互正交，Scenario 是唯一连接点。
  声明不等于生效；未被 active Scenario 引用的对象不得影响本机流量。
- **自然叠加**：启动前的网线、Wi-Fi、企业 VPN、Tailscale 等共同组成不透明 Underlay。
  XDial 不识别产品、不重排接口，只把系统已有裁决交给 sing-box。

`core/config/invariants_test.go` 是架构约束的可执行门禁。测试变红时应修正实现；不得放宽、
跳过、删除或给断言加特例。确实要改变架构时，先与用户对齐并更新规范，再调整测试。

## 验证边界

- 从改动直接涉及的最小测试开始，再按风险扩展。具体 target 和构建细节以 `Makefile` 为准。
- UI 改动先完成编译、聚焦测试和静态检查。只有获得运行态授权后，才重启 App 并检查真实
  窗口、AX 树、键盘、VoiceOver 或输入设备行为。
- 网络改动必须核对当前 System Extension、Transparent Proxy、Provider、Underlay、DNS
  归因和真实流量出口。编译成功、配置可生成、NE 显示 connected 或 `sing-box check`
  通过，都不等于真实链路已工作；旧 helper、接口和路由只代表原生 TUN 历史路径。
- macOS Underlay 快照必须来自宿主 App 请求连接之前的 `NWPath`；Provider 内的 `NWPath`
  会隐藏既有全流量 VPN，只能用于诊断，不能作为 sing-box 的 Underlay。
- 分发产物只能使用 `make release` 生成的 `build/release/XDial.app`。Debug 构建包含本地调试
  接口，不得分发；不得为让 Release 通过而删除 entitlement 或把 Debug 标识带入 Release。
- Debug、FormalDevelopment 与 Release 始终使用同一套正式身份：Host
  `com.kafeifei.xdial.app`、Settings UI `com.kafeifei.xdial.app.settings-ui`、System Extension
  `com.kafeifei.xdial.app.transparent-proxy`、helper `com.kafeifei.xdial.app.helper`。配置之间只允许
  编译条件与签名方式不同，不得再用不同 bundle identity 隔离 Debug；正式 Release 必须保留
  host 与 extension 所需的 System Extension provisioning profile。
- 未完成真实运行验证时明确报告剩余边界，不把源码、测试或旧日志包装成现场结论。

## 仓库纪律

- 概念命名固定为线路 Line / 规则 RuleSet / 场景 Scenario。
- 不修改 `third_party/`；需要上游变更时使用本地补丁并留痕。Go 代码提交前执行 `gofmt`。
- 未经授权不 commit、push、merge、发布或清理 worktree / build 产物。
- 回复用户用中文，代码标识符保持英文。使用精确工程术语，不用含义不明的社区俗语。

## 文档职责

- `AGENTS.md` 只放常驻规则、阅读路由、保护项和最小验收边界。
- `ARCHITECTURE.md` 记录不能安全地从代码反推的架构契约与 ADR；专项事故证据不应成为
  所有任务的默认阅读内容。
- `DESIGN.md` 记录设计合同；按受影响的产品表面和横切规则读取。
- `docs/agent/` 放按需操作手册，`docs/verification/` 放专项验收边界。
- `docs/incidents/` 保存日期化证据、失败实验和历史取证；只在复盘同类事故或修改相关契约时读取。
- 局部原因写在代码旁。不在根指令维护目录树、完整命令清单或临时任务进度。
