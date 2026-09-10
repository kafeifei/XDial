# 0.7.3 下载启动与平台安装事务故障

## 现场与原因

2026-09-08，本机下载的 0.7.3（build 1788788347）直接运行后提示旧版仍在运行。
用户结束所有 XDial 进程后重试，仍能复现。下列时间均为 Asia/Shanghai。

- 16:49:47，旧版日志记录网络 drain 完成、批准最终退出。
- 16:50:00，LaunchServices 将下载目录的 XDial 重定位到 AppTranslocation。
- 16:50:06，安装器启动 `/Applications/XDial.app`；LaunchServices 再次将目标重定位。
- 16:50:10，目标进程开始请求前任退出；16:50:22 才出现 SignalReady 和前任退出。
- 16:50:40–16:51:02 的下一次尝试出现相同双重重定位与 12 秒等待。

`isRunningFromApplications` 比较运行中的 bundle 路径与安装目标；重定位后的最终
接棒进程误入第二次安装。前任等待后继的 LaunchServices 启动完成回调，后继等待前任
退出。12 秒超时后后继创建错误弹窗，才完成 AppKit 启动并释放前任等待。

本机独立 AppKit 实验中，已退出 PID 会及时从 `runningApplications` 消失；没有证据
将此故障归因于进程列表缓存。正常自动更新的 staged 启动也携带 predecessor PID，
因此不能仅凭该 PID 禁止安装或豁免前任。

## 后续现场：bundle 交接成功后 helper 未就绪

初次修复只处理了重定位。用户当时授权真实启动，17:34:41 执行正常安装入口后，
前任在约 3.925 秒退出，最终进程从 `/Applications/XDial.app` 运行，携带专用后继标记。
这证明了当时的 bundle 交接成功，不能证明整笔安装成功：后继随后在 helper 阶段失败。

现场 `SMAppService.status` 为 enabled，但没有 helper 进程。launchd 的注册记录仍指向
旧的 parent bundle build；每 10 秒尝试启动并报找不到/不能执行 bundle 内 daemon，
即使当时正式目标内的 helper 文件存在且验签通过。历史中同一 helper PID 多次 re-exec
能够掩盖冷启动注册失效，不能据此认定 launchd 已重新绑定当前 bundle。

macOS SDK 的 `SMAppService.h` 要求 daemon 宿主经过公证，且 plist 或 executable 更新后
重新注册。同步 `unregister()` 返回不能代替异步 completion 所表示的服务退出完成。
本次初始候选只完成本地签名、没有公证，这是独立的交付缺口，不能把它当成已证明的
唯一现场原因。

系统设置中出现多个 XDial 网络扩展条目。只读证据同时存在旧身份/旧 build 的系统记录、
等待系统清理的停用版本，以及旧安装器遗留的隐藏 app 注册；没有证据把每个 UI 条目
一一对应到原因，也不能声称三个条目代表三个正在接管流量的扩展。

用户随后明确禁止继续操作当前 App、系统设置和网络。9 月 8 日剩余验证只使用源码、
隔离文件系统测试、模拟状态测试和本地构建。9 月 9 日用户重新授权启动测试，见下文。

## 9 月 9 日重新授权后的真实启动

- 11:06，正常启动 build `1788864000`，由产品安装并交接到 `/Applications/XDial.app`。
  helper 阶段报告 `helper-processStateUnknown`。内核快照显示 304 个进程的 `proc_name`
  不可读，但可读取 executable path；原逻辑丢弃了这个已知事实，将无关系统进程判为未知。
  修复合并 name 与 path 的身份信息，只有两者均不可用才保留未知状态；六项聚焦测试通过。
- 11:11，正常启动包含该修复的 build `1788944000`。产品移除旧 helper 注册后，
  新注册返回 EPERM。BTM 存储记录仍为 enabled/allowed，但 effective enabled 为 false，
  smd 报 `Job is not allowed to bootstrap`。不能把开关显示开启等同于此次注册成功，
  也不能将这个错误直接归因于公证。
- 11:14:50，日志记录另一轮安装尝试；11:14:57 helper 注册和运行版本验证通过，
  当前 daemon PID 为 `55592`，运行 hash 与磁盘一致。BTM 在新一轮 register 前仍为
  effective disabled，register 后转为 enabled 并成功 bootstrap，排除了“只等待便自行恢复”
  的解释。主线未点击这次重试；触发来源尚未证实，不能算首次自动完成。
- 11:14:58，扩展激活失败。sysextd 明确记录 `Error checking with notarization daemon: 3`
  和 requirement 错误 `-67050`；扩展单独完整验签通过，但系统评估为
  `Unnotarized Developer ID`。此次扩展失败有直接公证门禁证据。
- 安装器已收尾旧的隐藏 staging/backup 和 transaction receipt；长期协调 lock 保留。
  这不等于 macOS 自有的旧 System Extension 历史记录已清除。

上述测试保持外部 Tailscale，由正常产品安装入口推进；没有重置 BTM、切换系统批准开关、
重启电脑或绕过签名/公证。现场日志保存在 `build/installation-runtime-20260909-*`、
`build/installation-helper-register-failure-fixed.log` 与
`build/installation-sysext-signature-gate.log`。

后续补充 register/unregister 调用前后 status、NSError domain/code 及有限 underlying
错误链日志，避免再次只能看到 EPERM 文案；AlreadyRegistered/JobNotFound 必须匹配
SMAppService 错误域和错误号，不能吞掉同号的 POSIX/文件错误。没有根据不完整证据添加
通用自动重试。此轮 90 项聚焦 Swift 测试及新增 3 项错误分类/日志测试通过。
后台注册首次拒绝的来源仍未查明，正式公证候选的完整首次运行验收仍未通过。
包含该轮修订的 build `1788945000` 已通过 `make release-app`、签名和 profile 门禁，
日志为 `build/installation-runtime-20260909-candidate-build.log`；该阶段待公证包为
`build/installation-notary-candidate-1788945000.zip`，尚不可分发。

用户随后要求继续解决。`make release` 使用正式凭据完成 Apple 公证（Accepted，
job `975da5f7-0095-46e3-98bf-60cbcd1d18a0`）、staple、Gatekeeper 和正式压缩包回解验签。
正式产物为 `build/release/XDial-v0.7.3.zip`；没有发布 GitHub Release。

11:34:34 正常入口更新到公证 build `1788945000` 后，首次 helper 注册仍以
`SMAppServiceErrorDomain / 1` 失败。系统日志证明旧 daemon 已退出、异步注销完成，
不能归因于“没有等旧进程结束”。BTM stored enabled 与 effective disabled 的差异仍存在；
没有足够证据确定其内部 parent 记录如何失配。

11:35:02 的第二轮安装在 status=0 时再次完成注销，11:35:09 注册被接受，11:35:10
记录 `installation ready transaction=e397ff77-00ad-4423-9a9e-fc4f8ce4379e`。
当前 helper PID `60583` 与磁盘 hash 一致，System Extension `0.7.3/1788945000`
为 activated enabled；自有 staging/backup/receipt 已收尾，仅保留协调锁。
此轮真实更新安装成功，但仍依赖第二轮尝试，不是首次自动恢复的验证。

该复现后补充一次有界自动恢复：只在本次异步注销成功、精确的
`SMAppServiceErrorDomain / 1`、服务仍 notRegistered、维护记录为 committed 且目标 hash
匹配、产品允许维护并确认 helper 不存在时，再完成一次注销屏障并登记。第二次错误原样
返回，成功仍须验证运行 hash 和维护收尾响应。它复现已观察到的第二轮恢复路径；不能将其
描述成已查明 BTM 内部原因，也不能将隔离测试当成真实首次自动恢复通过。
这项后续源码修订未替换用户当前已就绪的 `1788945000`，已公证产物保持原样。
新增 7 项受限恢复测试，helper 协调器共 29 项通过；主机 Release 编译通过。
日志为 `build/installation-helper-reconciliation-tests.log` 与
`build/installation-helper-reconciliation-host-build.log`。

原有自动连接随后运行，另出现 `line-address-family-unavailable`。安装成功不等于
线路连接完成，未修改用户线路或外部 Tailscale 来掩盖该边界。

## 最终代码边界

### Bundle 替换和自有文件恢复

- 对复制后完整验签通过的 staging bundle 清除 `com.apple.quarantine`，保留下载源和
  其他扩展属性，不跟随符号链接。替换后再检查隔离属性和签名，失败恢复旧 app。
- 最终目标启动携带 `--xdial-installed-successor`；若位置仍异常，停止递归替换。
  正常下载和自动更新 staged 入口仍能执行各自安装。
- 在复制之前写入包含事务 UUID、应用身份与 Team ID 的 receipt，用相邻排他锁保护
  复制、替换和恢复。锁在等待最终 App 启动之前释放。
- receipt 负责 staging/backup 的清理；先检查 App、CLI、helper 占用，再撤掉相应
  LaunchServices 注册并删除。唯一可用备份和未知归属内容保留；缺失目标时恢复已验证备份。
- 历史无 receipt 的副本必须符合精确临时命名、验签、产品身份和占用条件才回收。
  foreign/损坏 receipt 不会被重新解释为无主临时文件，下载原件始终保留。
- canonical 启动和成功交接后的清理失败留下 receipt 供重试，不反报启动失败。
  helper/extension 安装就绪后再收尾一次，覆盖旧 helper 在启动阶段仍占用备份的情况。
  一个零字节安装锁文件是长期协调状态，不在持锁进程之间删除重建。

### Helper 注册与使用分离

- 安装协调器核对当前 bundle build、plist hash、daemon hash 的注册指纹。
  enabled 或 socket 可连均不足以判定安装完成；当前注册成功且运行版本一致后才保存指纹。
- 已批准但无存活 helper 的失效注册，在同一次安装中自动注销、等待系统完成、重新注册并
  验证。未知/无响应进程不会被当成不存在而强行替换。
- 新协议 helper 通过连接作用域的维护租约，原子排除正在进行的请求、引擎连接和 Tailscale
  配置会话。准备与提交分开：已提交维护不会因安装器 socket 断开而恢复接单。
  持久维护意图覆盖 KeepAlive 冷启动；超时保留状态，后续启动重新确认系统注销与旧 PID
  退出，再注册和验证当前版本。当前 daemon 完成收尾并确认后才恢复接单。
- 维护意图包含事务 token、阶段、目标 hash 与旧 PID，按身份和权限验证；文件原子更新，
  条件更新与清理使用共享锁，避免中断留下半份记录或旧回调误删后继事务。
- 旧协议没有原子的完整活动查询。兼容迁移要求唯一产品宿主、没有受保护工作，并等待
  125 秒连续空闲窗口覆盖旧版配置会话的空闲回收，然后直接刷新注册，避免旧临时路径
  的 re-exec 永远执行旧二进制。此路径依赖受控产品工作流；不能据此声称已观测任意
  外部旧协议 IPC 客户端的所有活动。新协议才提供原子维护门禁。
- GoEngine 使用已验证安装版本；普通操作不再自行 re-exec helper 来掩盖失效注册。

### System Extension 与分发门禁

- 安装先查询当前扩展属性，已启用且 build 匹配就直接完成；确实需要安装时才提交激活。
  激活完成后再验证一次，失败不会递归重复激活。
- 连接路径只核对已安装扩展，不代替安装过程提交激活或打开系统设置。
- 分发检查增加宿主/扩展的签名 entitlement 与内嵌 provisioning profile 匹配验证，
  包括 Team、application identifier、有效期、Developer ID 和所需 capability。
  修正带点 entitlement key 的提取方式，禁止 get-task-allow，提取或格式错误阻断产物。

没有改写 D37、正式 bundle identity、签名或网络接管边界。安装就绪不代表真实网络验收通过。

## 验证与交付限制

修复基于 `v0.7.3` 的提交 `7eb9a4f5d2522ebeff3385b56a94c5b451e654d7`，
不包含原 checkout 快照中的其他未发布功能。

- bundle/receipt/启动策略/安装事务/更新策略，以及 helper 协调器和持久维护记录的
  聚焦测试 105 项通过，含发布和身份静态门禁。
- 文件系统测试覆盖嵌套隔离属性、保留源文件、符号链接、替换失败回滚、复制中断、
  唯一备份恢复、外来 receipt、清理失败后重试、并发安装锁及后台进程占用后收尾。
- 维护记录的并发回归实际发现：读方打开旧 inode 后，rename 使其 link count 归零，
  原有验真逻辑会误报权限错误。修复保留严格文件验证，读方持共享锁，修改与完成方持
  排他锁；没有放宽测试或将读取失败当作没有维护事务。
- 新协议 daemon 的请求/维护竞争、提交后断线、冷启动门禁和收尾校验通过 Go race
  测试；旧协议受控空闲、审批、错误归属与拒绝假 ready 由模拟 I/O 测试覆盖。
  等待期间旧 helper 的 PID 若被 KeepAlive 替换，会在同一次安装中重新判断协议和状态，
  不会继续操作旧 PID；长期忙碌等待不重复刷进度事件。
- `make release-app RELEASE_TAG=v0.7.3 RELEASE_BUILD_NUMBER=1788864000` 已构建通过，
  包含宿主/扩展签名与 provisioning profile 门禁；最终修订在同一构建号下重新验证。
  日志保留在 `build/installation-final-tests.log`、
  `build/installation-helper-go-tests.log` 和 `build/installation-final-release-build.log`。
- 在用户后续限制之前，对真实下载副本执行生产隔离属性清理后验签仍通过；原下载源属性
  保留。独立随机身份的 LaunchServices fixture 首装和替换均通过，但不替代正式产品验收。
- 初始候选 `1788850000` 曾在当时授权下安装，bundle 交接成功、helper 失败。
  9 月 8 日的后续代码仅离线验证；9 月 9 日重新授权后的安装结果单独记于上节。

最终真实验收仍需要经过正式公证的候选，在授权范围内发起首次运行或升级，检查整笔
InstallationReport、当前 helper/扩展版本、临时副本收尾及后续用户工作流。
未知占用、权限不足或 macOS 延迟清理时会保全状态；离线测试不能证明系统设置中的旧记录
已经消失，也不能把“代码和构建通过”称为“首次运行已验收”。
