# macOS 构建与安装

日常 Debug 由 `make app` 生成 `build/XDail Debug.app`，使用 Apple Development 签名，
不提交公证。`FormalDevelopment` 保留正式身份，仅用于该身份的专项验证。
正式归档由 `make release` 生成，签名、公证与发布机制见 [updates.md](updates.md)。

## 通道身份

| 所有权 | Debug | 正式身份 |
|---|---|---|
| 安装路径 | `/Applications/XDail Debug.app` | `/Applications/XDial.app` |
| Host | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial.app` |
| Settings UI / Extension / Helper / Daemon | Host 加 `.settings-ui` / `.transparent-proxy` / `.helper` / `.daemon` | 同左 |
| 偏好与钥匙串 service | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial` |
| 用户配置 | `~/.xdial-debug` | `~/.xdial` |
| helper 状态目录 | `/Library/Application Support/XDial Debug` | `/Library/Application Support/XDial` |
| App Group | `UVZM439VGU.com.kafeifei.xdial.debug.network` | `UVZM439VGU.com.kafeifei.xdial.network` |
| helper socket | `/tmp/xdial-debug.sock` | `/tmp/xdial.sock` |
| 诊断 HTTP | `127.0.0.1:19877` | 当前构建不包含；旧正式身份 Debug 可能使用 `19876` |

Debug 使用独立配置，不迁移、导入或清理正式数据，也不消费正式更新包。身份定义在
[XDialBuildIdentity.swift](../../macos/Shared/XDialBuildIdentity.swift)；通道隔离合同见
[ARCHITECTURE.md](../../ARCHITECTURE.md)。独立安装不表示两个数据面同时接管已经过验证。

## 签名与构建产物

Debug 的开发证书与 host、extension provisioning profiles 必须匹配 Debug identity。
已登录开发者账号的 Xcode 可通过下列构建参数创建或更新签名资源，该参数会访问 Apple
开发者账号服务：

```sh
make app MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates
```

`make app` 末尾的 [verify-macos-debug-app.py](../../scripts/verify-macos-debug-app.py)
校验嵌套组件身份、签名、开发 profile、App Group、daemon plist 与 helper 编译通道，
不启动 App。host、Settings UI 和 extension 使用同次构建的 `DEBUG_BUILD_VERSION`，
默认取 Unix 时间戳；构建号用于系统识别扩展升级，不等于源码提交。

## 安装命令的实际效果

| 入口 | 实际效果 |
|---|---|
| `make app` | 构建并校验候选包，不替换 `/Applications`，不启动 App |
| 候选包的 `Contents/MacOS/XDial --install-only` | 安装到该通道的 `/Applications` 路径；替换时终止同通道旧 App，并维护旧 helper；不启动后继 App |
| `make restart` | 完整构建 Debug 后退出旧 Debug、安装、启动最终 App，等待安装与连接意图收敛 |
| 从 `/Applications` 外正常启动 App | 自动定位、替换同通道安装并启动最终 App，不是隔离的源码运行 |

`--install-only` 不提供保留旧进程或连接的安装能力。实现见
[ApplicationRelocator.swift](../../macos/Sources/XDial/ApplicationRelocator.swift)；
`make restart` 的交接和验收见 [restart-macos-app.sh](../../scripts/restart-macos-app.sh)。
该脚本在新事务提交后执行一次 HTTPS 检查，目标由 `XDIAL_RESTART_PROBE_URL` 指定，
未设置时为 `https://www.apple.com/`；这次访问仅反映该目标的当前路径结果。

候选包校验、磁盘安装、Host 进程与实际运行的 Provider 是不同状态。新扩展代码只有在
系统激活对应扩展后才生效；安装报告与运行态字段见 [debug-server.md](debug-server.md)。
