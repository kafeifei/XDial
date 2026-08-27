# XDial v0.7.1

## 更新了什么

- Debug、FormalDevelopment 与 Release 统一使用正式的 `com.kafeifei.xdial.app` 产品身份，避免不同构建被 macOS 当作不同应用并分别保存菜单栏和权限状态。
- 阻止旧 `ne-probe` 身份重新作为安装源；升级时仍可识别并清理旧版本及 LaunchServices 残留注册。
- 修复升级后菜单栏图标可能保持隐藏的问题，并为所有构建和发布流程加入包身份门禁。
- 场景配置了 Wi-Fi SSID 自动切换但缺少位置权限时，安装窗口和菜单弹窗会持续提醒；未授权时由用户明确触发系统授权，已拒绝时可直接打开定位服务设置。
- 位置权限恢复后立即重新读取当前 Wi-Fi 并恢复场景自动匹配，无需退出或重启 XDial；手动连接、断开和切换始终可用。

## 系统要求

- macOS 15 或更高版本。
- 需要在系统提示时批准 XDial 的 System Extension。
