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

`open-settings` 可带 `scenarioID`，只展开当前编辑配置中的场景卡片；不修改运行选择、
不保存配置、不连接网络。用于在真实窗口中复核布局问题，不能用 `select-scenario` 替代。

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
- Next 的 `profile` 是运行选择的配置，`editingProfile` 是配置窗口正在编辑的配置；
  两者都经过凭据脱敏。`profileEditorPosition` 记录当前分类和展开对象，供窗口交互验收。
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

### Next 本地规则集合并

`{"action":"reimport-profile-scenario","profileID":"...","scenarioID":"...","newProfileID":"UUID","name":"Naixi 新导入","preview":true}`
从已保存内容的指定场景重新导入：收集原候选线路和匹配内容，转换冗余业务选择器，生成新身份。
默认预览，`preview:false` 才通过 App 自己的密钥插入一个本地 Profile；不覆盖来源、不复制其他
本地场景或无关资源、不切换运行 Profile。保存前再次核对源记录及连接状态，源变化则失败。
只允许 Next 已加载配置库且未连接；操作不联网，不通过临时程序读取钥匙串。

旧模型归类使用 `{"action":"group-rules-by-destination","profileID":"...","referenceScenarioID":"...","preview":true}`，
不可对已简化出口的新导入再次按最终出口归类，否则会丢失业务分类。
指定默认场景作为归类依据，同出口条件合成一条规则；每个已有场景的顺序和部分匹配
范围独立保留。返回规则名称、归类前后数量及每个场景的原顺序 / 部分引用计数。
`preview:false` 才通过 App 缓存密钥保存；要求本地 Profile、Next 未连接，且所有场景
的运行指纹相等。旧迁移入口只作兼容，不用于新导入。

Next 的 `POST /action` 接受 `{"action":"separate-imported-rule-resources","profileID":"...","preview":true}`。
默认只预览；显式 `preview:false` 才保存。仅限已加载配置库、无待切换事务、未连接的 Next
中的本地 Profile。去掉旧导入器按目标生成的规则包装组，逐个验证所有场景的运行指纹
保持一致，再通过 App 自己的缓存密钥原子保存加密库；失败保留原值。返回匹配块数量、
规则名称及每个场景的绑定数量，不返回凭据，也不切换编辑或运行中的 Profile。

兼容旧版本的 `{"action":"compact-profile-rule-sets","profileID":"..."}` 仍保留，新的导入不再使用。
仅允许 Next 未连接、无场景切换事务且目标为无订阅来源的本地 Profile；只支持单场景、
每个规则集使用一次且没有未绑定资源。合并连续的同出口段，保留每个条件的完整定义与顺序，
迁移前后运行指纹必须一致。由已运行的 Next 使用自己的配置库和缓存密钥原子保存；
不要运行临时外部程序读取 Next 钥匙串，避免产生额外授权弹窗。
操作保留其他 Profile、线路、默认出口与编辑/运行选择；失败不修改配置。
