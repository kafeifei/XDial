# 后台服务注册成功，但系统不能定位 executable

## 现场及定位

Debug 构建 `1790142245` 的 SMAppService 状态为 enabled，安装报告却停在
`helper-serviceUnavailable`。daemon 没有 PID 或 socket，日志最后一次退出发生在
13:32:31；这不是已经运行的服务响应较慢。

系统日志给出两个相邻事实：backgroundtaskmanagementd 的服务条目
`container=(null)`、`fullPath is nil`；launchd 使用 `BundleProgram` 解析时报告
`The specified path is not a bundle`、`copy_bundle_path` 失败，退出码 78。
重新登记当前 App 和一次完整 helper 注销／注册仍复用同一条目，并继续失败。
因此延长 socket 等待、重复 register 或只检查 enabled 都不能修复这次故障。
没有直接证据确定最早使容器关联失效的文件操作，不能把原因限定为某一次替换。

## 改动

XDial 在注册之前已强制定位到每个通道自己的 `/Applications` 路径，因此 daemon
改用标准 `Program` 指向该确定路径，不再使用 `BundleProgram` 的 BTM 容器解析。
仍由 SMAppService 注册和 launchd 托管，保留原服务身份、用户批准及签名约束。
Apple SDK `SMAppService.h` 明确允许标准 launchd 键，`BundleProgram` 是为了支持
安装后的自由移动而提供的可选键。没有替换成 root shell 启动、重置系统数据库或改动兄弟通道。
构建、Debug 包和 Next 分发包门禁检查 Program 路径必须与通道一致。

另修复完整升级后的自动推进：旧服务在文件替换前必须注销，但新 App 原来只在
服务仍注册时启动安装检查，导致正常升级被当成首次未安装。现在同通道的既有安装
完成记录或未完成的维护事务也触发检查。首次安装仍不自动注册；显式卸载会清除该记录。

安装必须通过产品事务完成。临时脚本交换正在注册的 App 容器，无法证明服务记录的
交接成功；保留进程的要求不授权绕过这一边界，应先保存候选，在允许升级时继续事务。

## 已验证

- 构建 `1790143385` 通过产品 `--install-only` 入口替换，然后启动最终路径的 App。
- 同一个 BTM 服务 UUID 下，launchd 从 `resolve program` 模式变为确定的 `program`，
  首次成功启动 daemon PID 20504；实际 SHA-256 与 bundled SHA-256 相同。
- 安装报告在约一秒内完成 helper 和当前网络扩展检查，进入 ready。
- 真实设置窗口展开六条规则的场景后持续响应，六次状态请求约 74–104 ms；
  本次不再出现原来的主线程布局卡死。此观察不等同于 120 Hz 滚动帧率验证。
- 78 项安装事务、helper 注册和注销测试通过，包括新增的升级续接、首次安装、
  卸载后保持未安装及通道隔离场景。

初次运行仍需显式触发安装，自动推进修复是在该验证中发现并补上的。

最终构建 `1790143738`（源码 `9f873c3`）再次通过产品入口执行真实升级，Host PID
25120 启动后无需调用 setup-helper 或点击重试，约 1.07 秒完成全部安装阶段。
daemon PID 25129 的运行 SHA-256 与新包匹配，版本为 `v0.8.3-11-g9f873c3`；
原 Next Host、Next daemon 和正式 daemon 在这次升级前后的 PID 与启动时间不变。
展开原场景时五次主线程 health 请求约 1.6–5.9 ms。

完整 `make test-macos-transaction` 通过：679 项 Swift 测试、18 项发布器测试及
发布合同和通道身份门禁。门禁同时更新为覆盖 AXSecureTextField 和 AXTextArea 两种
已有的凭据读取保护，旧正则只接受第一种 guard，误报了新增保护。

安装 ready 与线路连接是两个状态。初次自动连接曾报告内置 Tailscale 需要重新登录；
最终运行之后观察到 connected，不把安装验收当作所有线路或目标流量的验收。
