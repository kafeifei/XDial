# 场景运行状态验收

PR #58 仅在现有圆球布局上增加运行状态说明；原纵向列表及其离屏截图已移除，
圆球、悬停操作、失败与仅 SOCKS5 标识、缺项提示沿用 main。

## 状态说明约束

运行状态由 GoEngine.status、GoEngine.lastError、连接报告与 AppState.wakeReconnectPhase 持有；顶部说明只投影这些事实，
不写入引擎或连接事务。连接准备、断开和重连不能从 isBusy 推断为同一种状态。
AppState.statusText 是所有生命周期标题、任务名和失败原因的唯一文案来源，顶部直接复用。
报告决定已连接时的线路类别，以及已断开时是否存在失败；不得用旧报告覆盖进行中的断开或恢复。
失败和普通未连接均不能作为原网络恢复成功的证据；回滚、系统接管和原网络恢复由各自事实表达。

| 宿主恢复阶段 | 引擎状态 | 缺失、旧成功或失败报告的处理 |
| --- | --- | --- |
| 任一唤醒恢复阶段 | 任意 | 与状态带共用 WakeReconnectPhase 文案，不宣称就绪 |
| 无 | connecting | 复用状态带“正在连接”或当前任务名，不引用旧成功报告 |
| 无 | disconnecting | 正在断开，不表述为启用 |
| 无 | reconnecting | 正在重连，不表述为首次启用 |
| 无 | disconnected，无错误 | 复用“未连接”，忽略过期成功报告；不宣称网络恢复 |
| 无 | disconnected，报告失败或有报告/回滚/引擎错误 | 独立失败状态，复用状态带错误文案，不宣称回滚或网络恢复 |
| 无 | connected | 只按完整的已提交报告分类；缺失或失败报告显示未确认 |
| 无 | 未知 | 未确认，不推断直连或 VPN |

场景切换准备期间，源连接仍为 connected 且报告仍属于已提交源事务，因此保留源线路说明。
完成、取消、断开、重新连接或延迟到达的报告均按上表重新投影，无独立缓存或清理状态。

## 已验证（2026-11-16）

Xcode 27.1 / macOS arm64，以下 14 项定向测试通过：

- ScenarioConnectionPresentationTests（12 项）：纯直连、已提交 VPN、未提交或失败事务、
  未启用的过期报告、切换期间旧场景、未知类型、订阅加直连与仅订阅、
  订阅未就绪、VPN 加订阅、报告缺失时的中英文状态文案（不引导查看不存在的详情）。订阅策略字符串不能冒充线路类型。
  生命周期矩阵同时覆盖连接、断开、重连、唤醒恢复、旧报告与缺失报告、失败及回滚错误；
  任务名与错误标题必须与状态带输入逐字相同。
- ScenarioConnectionViewsTests（1 项）：状态说明组件中英文、浅深色及长名称渲染。
- ScenarioGridLayoutTests（1 项）：保留圆球均衡布局。

运行命令（先用 xcodegen generate --spec macos/project.yml 生成项目）：

```sh
xcodebuild -project macos/XDial.xcodeproj -scheme XDialTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xdial-pr58-tests CODE_SIGNING_ALLOWED=NO \
  -only-testing:XDialTests/ScenarioConnectionPresentationTests \
  -only-testing:XDialTests/ScenarioConnectionViewsTests \
  -only-testing:XDialTests/ScenarioGridLayoutTests test
```

另通过 MainPopover.swift 语法检查及 git diff --check。

## 构建和运行验收边界

2026-11-16 已按 CI 安装 gomobile/gobind v0.1.13 到临时任务目录，
并将当前源码复制到无空格路径执行 make ci-macos-build，已通过：
Debug / Release 的 Host 与 Transparent Proxy Extension 均完成未签名构建，
包含 macOS Libbox.xcframework、Go helper、身份合同与产物名称/最低系统版本检查。
构建副本中的 MainPopover、状态说明与测试源码以及 go.mod/go.sum 已逐字核对一致。
同一副本继续执行 make test-macos-transaction MACOS_TEST_XCODEBUILD_FLAGS=CODE_SIGNING_ALLOWED=NO，
整条门禁通过，其中 922 项 XCTest 0 失败；包括当前 PR 的全部 14 项定向测试。
此副本为仓库身份门禁建立了本地 Git 跟踪索引，不向远端发布临时快照。
临时副本只用于构建，未替换工作树、用户配置或已安装 App。

Debug 安装与真实网络操作尚未进行。本机签名身份已在主机权限下核实存在，
但两个可用开发证书的 OU 团队为 SX9RG894L5 和 NTC4BJ542G，
项目要求 DEVELOPMENT_TEAM=UVZM439VGU，未发现匹配的开发签名身份。
不修改团队身份、不申请新授权、不覆盖当前网络或凭据来完成验收。

下列真实 Debug 验收仍待具有匹配签名与测试配置的维护者完成，需每项附浅色与深色截图或录屏：

| 运行步骤 | 顶部状态说明应核对的内容 | 本任务结果 |
| --- | --- | --- |
| 未连接 | 与状态带同为“未连接”，不宣称原网络恢复 | 未实测，无截图 |
| 连接中 | 直接显示状态带的“正在连接”或当前任务名 | 未实测，无截图 |
| 直连场景提交 | 明确没有通过 XDial 建立 VPN | 未实测，无截图 |
| AnyConnect 提交 | VPN 线路就绪，不宣称所有流量走 VPN | 未实测，无截图 |
| 订阅场景提交 | 分流运行，不误报纯直连 | 未实测，无截图 |
| 报告缺失或未完整 | 未确认，不指向不存在的详情 | 未实测，无截图 |
| 场景切换准备 | 保留旧场景已提交事实 | 未实测，无截图 |
| 候选失败 | 旧连接说明保留，候选错误单独表达 | 未实测，无截图 |
| 断开、重连 | 标题与状态带逐字一致 | 未实测，无截图 |
| 睡眠唤醒、网络切换恢复 | 与状态带共用恢复阶段及任务标题 | 未实测，无截图 |
| 连接失败、回滚失败 | 保留失败原因，不用“未连接”推断恢复成功 | 未实测，无截图 |

组件渲染测试仅验证排版，不能替代以上真实运行截图；本任务没有新增截图附件。

## 维护者提供的验证

维护者在 PR #58 的 [f3a9646 复审](https://github.com/kafeifei/XDial/pull/58#pullrequestreview-5909550210)
报告 make ci-macos-build（Debug / Release 未签名）与 make test-macos-transaction 通过，
918 项测试 0 失败。该结果属于上一版提交，不替代本轮修改后的完整构建或 Debug 实测。
当前任务仍未修改网络配置或凭据，直连、AnyConnect、订阅以及切换、断开、重连的 Debug
运行验收尚待具备构建环境和可用测试配置的维护者完成。
