# XDial v0.7.0

## 更新了什么

- 新增应用内自动检查更新、Release Notes、下载进度、签名校验与显式安装入口。
- 更新采用验证优先的原子替换；失败时保留或恢复旧版本，并在重启后恢复更新前的连接意图。
- Release 流程统一 host、helper、设置载体与 System Extension 的版本，加入 Developer ID 签名、公证、staple、Gatekeeper、压缩包与校验和门禁。
- 改进场景切换、系统睡眠与网络路径变化后的连接恢复，并保留结构化 Underlay 证据。
- 更新菜单栏、设置窗口、应用图标与交互细节。

## 系统要求

- macOS 15 或更高版本。
- 需要在系统提示时批准 XDial 的 System Extension。
