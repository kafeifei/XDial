# macOS 本地开发与正式发布

日常开发使用 `make app`。它生成 `build/Xdial debug.app`，采用 Apple Development
签名，不提交公证。正式版仍由 `make release` 生成，使用原有 Developer ID 签名、
provisioning profiles 和公证流程。

| 所有权 | Debug | 正式版 |
|---|---|---|
| 安装路径 | `/Applications/Xdial debug.app` | `/Applications/XDial.app` |
| Host | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial.app` |
| Settings UI / Extension / Helper / Daemon | Debug Host 加对应子标识 | 正式 Host 加对应子标识 |
| 偏好与钥匙串 service | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial` |
| 用户配置 | `~/.xdial-debug` | `~/.xdial` |
| helper 状态目录 | `/Library/Application Support/XDial Debug` | `/Library/Application Support/XDial` |
| App Group | `UVZM439VGU.com.kafeifei.xdial.debug.network` | `UVZM439VGU.com.kafeifei.xdial.network` |
| helper socket | `/tmp/xdial-debug.sock` | `/tmp/xdial.sock` |
| 本地诊断 HTTP | `127.0.0.1:19877` | Release 不包含；旧正式身份 Debug 使用 `19876` |

Debug 首次使用空的独立配置，不自动迁移、导入或清理正式版及旧沙盒数据，也不安装正式
更新包。两套 App 可以独立安装，但这不代表两个数据面同时启用已经过验证。

## 首次签名准备

开发证书与 host、extension 的开发 provisioning profiles 必须匹配新 Debug identity。
不能借用正式 profile，也不能通过去掉 entitlement 或关闭系统安全检查完成构建。

如果本机 Xcode 已登录有权限的开发者账号，可以显式允许 Xcode 为 Debug targets 创建或
更新开发签名资源：

```sh
make app MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates
```

这一步会访问 Apple 开发者账号服务。配置文件准备好后，日常直接运行 `make app`。
`scripts/verify-macos-debug-app.py` 验证实际产物中的 host、Settings UI、extension、helper、
开发 profile、App Group、daemon plist 与 Go helper 编译通道，验证时不启动 App。

## 安装与运行

构建不会启动 App，也不会替换 `/Applications` 中的安装。`make restart` 只针对本次构建
的 Debug identity，执行前必须获得对应 App 与连接生命周期操作的授权。它不能用正式版
Debug Server 的存在代替目标身份验证。

只有更新并重新激活网络扩展后，系统才会运行新扩展代码；旧扩展仍在运行不能算新代码的
验证。激活、连接、切换和真实流量检查仍遵守仓库的运行态授权边界。

`FormalDevelopment` 保留现有正式身份配置，仅供正式身份专项验证，不作为日常开发入口。
