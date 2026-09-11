# Debug Server 操作手册

本文件只在操作 Debug Server、检查真实 UI 或诊断当前运行态时按需阅读。它不是根指令，
也不授予任何改变用户网络或 App 状态的权限。

## 安全边界

- 独立开发版 `Xdial debug.app` 只在 `127.0.0.1:19877` 提供 HTTP 接口，Release 构建完全排除。统一使用
  `127.0.0.1`，不要依赖 `localhost` 的 IPv6 解析。旧的正式身份 Debug 包仍可能使用
  `19876`；操作前必须核对 `/health` 的 PID、可执行路径和 bundle identity，不能跨通道发送动作。
- `GET /health`、`GET /state` 和 `GET /ax` 是默认的只读入口。
- HTTP 方法不代表副作用边界；POST 和 AX 动作都必须先判断实际行为。connect、disconnect、
  reconnect、select-scenario、prepare-system-extension、故障注入，以及可能保存配置的
  AX 操作，必须获得用户对本次具体动作的明确授权。
- `begin-route-probe` 会产生一次真实外部连接，只在当前诊断需要时执行；`open-settings`、
  `check-helper`、`daemon-info` 和结构化快照不改变网络配置，但仍不得抢占用户输入。
- `prepare-system-extension` 虽不创建网络配置或接管流量，仍会安装或替换平台组件，不能作为
  普通只读诊断执行。
- 操作前先保存当前 `/state` 中的连接、场景和事务身份；操作后读取新的结构化报告并核对
  预期边界。不得用重启、断连或重新连接后的暂时恢复代替根因证明。

## 接口

```bash
# 存活与进程
curl -sS 127.0.0.1:19877/health

# engine/profile/network/windows；敏感字段已脱敏
curl -sS 127.0.0.1:19877/state

# 当前 UI 元素树
curl -sS "127.0.0.1:19877/ax?depth=8"

# 连接、断开、重连；需要本次明确授权
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"connect"}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"disconnect"}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"reconnect"}'

# Debug-only 故障注入；会真实启动并回滚网络会话，需要本次断连授权
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"connect-with-failure","stage":"commit"}'

# 安装或替换 System Extension；需要本次平台变更授权
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"prepare-system-extension"}'

# 打开设置、选择场景；选择场景需要本次状态变更授权
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"open-settings"}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"select-scenario","id":"scenario-id"}'

# 在当前已提交事务中建立固定 443 端口的路由归因探针，再读取结构化快照。
# host 只接受 ASCII DNS 名；Provider 会再次校验当前 transaction。
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"begin-route-probe","host":"example.com","timeout_ms":10000}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"routing-probe-snapshot","probe_id":"<上一步返回的 probeID>"}'

# 按 /ax 返回的 title 操作 UI；可能改变配置，先判断并取得相应授权
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"ax-press","title":"连接"}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"ax-set-value","title":"字段当前值","value":"新值"}'
```

## 事实来源

`/state.installationReport` 是当前平台安装事务的事实来源；
`/state.connectionReport` 是本次连接事务的事实来源：它包含动态计划、逐任务状态、错误、
事件顺序及回滚结果。诊断安装或连接失败时先读对应报告，不得从文本日志反推控制流。
安装报告就绪只证明 App、helper 和 System Extension 前置条件，不证明网络配置、Line、
RuleSet、DNS 或真实出口已经工作。

`/state` 中当前与期望场景分别读取 `activeScenarioID`、`desiredConnectionScenarioID`。
Debug 动作只使用 `select-scenario`；不保留旧领域名别名。

`/state.configDirty` 只表示已保存配置的有效运行依赖与当前事务不同；未引用对象、显示名、
SSID 和顶层视觉排序变化不得令它置位。底层指纹可能受凭据影响，因此不得通过 Debug、日志
或 UI 暴露。

`/state.network.perLine` 只是由当前 Provider 事务产生、按 `transactionID` 绑定的易失
出口地址观察；它不表示 Line 运行状态，断开、Scenario 或 transaction 改变时会清空。

逐域名归因使用 `begin-route-probe` 后读取 `routing-probe-snapshot`；不得用页面显示、
公网 IP 或旧的 Clash API selector 反推命中线路。实际 Line 归因只读响应中的
`lineIDCounts`；`outboundTagCounts` 是 Provider 内部证据，无法唯一映射时不得猜测。

Popover 只有在菜单栏图标被点开后才会出现在 AX 树中；设置窗口优先用 `open-settings`
打开。helper 的安装状态、版本和进程信息也通过 `/state` 或 POST 动作 `check-helper`、
`daemon-info` 检查，避免凭进程名猜测。
