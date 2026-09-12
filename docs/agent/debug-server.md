# Debug Server 与运行态记录

独立 Debug 的 HTTP 地址是 `127.0.0.1:19877`；旧正式身份的 Debug 构建可能使用 `19876`。
当前 `FormalDevelopment` 与 `Release` 不包含 Debug Server。端口不是安装或 Provider 版本。
实现入口：[DebugServer.swift](../../macos/Sources/XDial/DebugServer.swift)。

## HTTP 接口

```sh
curl -sS 127.0.0.1:19877/health
curl -sS 127.0.0.1:19877/state
curl -sS '127.0.0.1:19877/ax?depth=8'
```

| 入口 | 内容与作用 |
|---|---|
| `GET /health` | 仅返回 `ok` 和 Host `pid`；可执行路径来自该 PID 的进程信息，bundle identity 来自对应 App 的 Info.plist |
| `GET /state` | 当前 Host 的安装、连接、Scenario、网络观察和窗口快照；凭据字段脱敏 |
| `GET /ax` | 当前 Host 的 AX 树；密码字段不读取；Popover 打开时才有对应元素 |
| `POST /action` | JSON `action` 分派到下列动作；HTTP 方法本身不表示是否只读 |

| action | 实际作用 |
|---|---|
| `check-helper`、`daemon-info` | 刷新 helper 状态，或读取 daemon 的版本、PID、实际与 bundled SHA-256 |
| `routing-probe-snapshot`、`application-attribution-snapshot` | 读取当前已提交事务的归因快照 |
| `begin-route-probe` | 对指定 ASCII 域名建立真实外部连接；端口固定 443，超时范围 500–15000 ms |
| `open-settings`、`open-update` | 打开窗口并激活 App，会改变前台焦点 |
| `ax-press`、`ax-set-value` | 按 `title` 操作 UI；副作用由目标控件决定，可能保存配置或触发连接 |
| `connect`、`disconnect`、`reconnect`、`quit` | 改变连接或 Host 生命周期 |
| `select-scenario` | 经 AppState 的 Scenario 切换入口执行；可能启动连接或切换已连接事务 |
| `prepare-system-extension` | 安装或替换 System Extension；不提交网络配置 |
| `setup-helper` | 进入完整安装事务，包含 helper 与 System Extension |
| `sm-register`、`sm-unregister` | 注册或注销持久 helper 服务 |
| `connect-with-failure` | 真实启动连接并在指定阶段注入失败，触发回滚 |
| `fake-update`、`clear-update` | 注入更新 UI 候选；清除时还会丢弃已暂存更新并复位更新状态 |

路由探针参数与响应关联：

```sh
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"begin-route-probe","host":"example.com","timeout_ms":10000}'
curl -sS -X POST 127.0.0.1:19877/action \
  -d '{"action":"routing-probe-snapshot","probe_id":"<probeID>"}'
```

## 状态的含义

- `installationReport` 表达平台安装事务；`ready` 只表示 App、helper、System Extension
  前置条件就绪。`connectionReport` 表达连接事务的计划、任务、事件、错误和回滚结果。
- `activeScenarioID` 是 Profile 的 active Scenario；`desiredConnectionScenarioID` 是连接
  意图。切换期间的来源、候选和实际提交身份在 `scenarioSwitchReport` 中。
- `configDirty` 表示已保存配置的有效运行依赖与当前事务不同。底层指纹可能受凭据影响，
  不对外暴露。
- `network.perLine` 是按 `transactionID` 绑定的易失出口地址观察，不是 Line 运行状态；
  断开、Scenario 或 transaction 变化时清空。
- 路由探针的 `lineIDCounts` 表达本次实际 Line 归因；`outboundTagCounts` 是内部出口
  计数，不能独自证明 Line 映射。公网 IP 和旧 Clash API selector 也不表达本次归因。

## Release 的安装记录

Release 与 Debug 都将安装报告写入当前用户日志目录的 `installation-report.json`：

- 正式身份：`~/Library/Logs/XDial/installation-report.json`
- 独立 Debug：`~/Library/Logs/XDial Debug/installation-report.json`

记录包含 `processIdentifier`、`bundleIdentifier`、`bundleVersion`、`recordedAt` 和 `report`。
它可能由旧进程留下，文件存在不表示当前进程已就绪，也不包含连接或流量验收结果。
写入和路径分别见 [InstallationCoordinator.swift](../../macos/Sources/XDial/InstallationCoordinator.swift)、
[GoEngine.swift](../../macos/Sources/XDial/GoEngine.swift) 与
[XDialBuildIdentity.swift](../../macos/Shared/XDialBuildIdentity.swift)。
