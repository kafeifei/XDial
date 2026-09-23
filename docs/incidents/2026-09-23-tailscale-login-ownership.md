# Tailscale 登录被整个连接状态锁住、跨通道设备同名

## 已确认的实现问题

- 线路编辑器和 helper 都用整个 XDial 是否 disconnected 阻止配置登录，包括不参与当前场景的身份。
- 已连接行把登录和出口配置整体替换为“断开后再配置”的文字，没有通向现有 Provider 实例的管理入口。
- 每次刷新会停止、重建 setup；跨全局 Profile 配置时，setup 状态目录还可能按 active Scenario 而非所选线路确定。
- 共享配置携带同一个 hostname，Debug 可以沿用带 Next 前缀的设备名。状态目录原本按安装通道隔离；本次不迁移、复制或删除 node key。

## 修复契约

1. 运行快照按本地通道生成稳定的设备名，保留 Profile ID、目录和密钥。连续投影不重命名，不在设备名中追加构建号。
2. 当前 Provider 按事务 ID 和原始 Profile 身份确认所有权，返回自身状态或继续浏览器登录。其他身份才交给 helper 的独立 setup；退出当前使用中的身份明确拒绝。
3. setup 刷新复用实例；按所选线路确定状态目录，保留独占文件锁。Auth Key 只进入本次请求，后续刷新缓存不含 key。
4. 连接、切换场景等待已接受的配置操作并确认 setup 退出；等待期间不停止旧 Provider。异步取消、超时和旧事务响应不授权打开第二份身份。
5. UI 登录入口不再依赖全局 disconnected。设备名来自实际 LocalAPI 状态；订阅身份也可登录，订阅内容仍只读。

## 参考流程

- [sing-box Tailscale endpoint](https://sing-box.sagernet.org/configuration/endpoint/tailscale/) 将交互认证放在端点管理入口；持久 state 和 hostname 分离。
- [Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli) 区分连接、登录和退出登录。退出会影响身份对应的连接，不能作为无副作用刷新。
- 本仓库固定依赖的 tsnet 启动时设置 prefs.Hostname；重命名不需要删除 state。浏览器按钮交给 StartLoginInteractive 校验、恢复授权 URL。

## 验证边界

离线测试覆盖三通道名称区分、命名幂等、长名称/DNS 合法性、目录稳定、选中身份与场景身份不同、刷新复用、事务所有权、退出保护以及连接交接等待。
完整构建检查 Host、helper、Provider 的通道身份和签名。实际 Tailnet 新名字和真实浏览器登录必须在新版本运行后观察；不能用构建或静态测试代替。

2026-09-23 离线验证：`make test-macos-transaction` 通过 686 项 Swift 测试及发布/身份门禁；
`go test -tags with_gvisor ./core/config ./core/libbox ./core/tailscalesetup ./cmd/xdial`
使用仓库 patched workfile 与 sing-box 校验器，四包全部通过。Debug 候选包构建与签名检查通过。
当前运行的 Debug 尚未被替换或重启；真实登录与 Tailnet 名称未做在线变更验证。
