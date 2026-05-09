# XDial

macOS menu bar app (SwiftUI + Go helper)，管理 VPN/代理分流。

## 构建

```bash
make app        # 构建 Go helper + Swift app → build/XDial.app
make inspector  # 构建独立 AX 检查器 → build/xdial-inspector
```

## UI 调试 (Debug Server)

debug build 自动在 `localhost:19876` 启动 HTTP 调试服务器。**任何涉及 UI 的改动，必须用这个服务器验证，不要靠猜。**

### 读取状态

```bash
# 完整应用状态：engine/profile/network/windows
curl localhost:19876/state

# UI 元素树：每个元素的 role/title/value/enabled/坐标
curl localhost:19876/ax?depth=8
```

### 操作 UI

```bash
# 点击按钮（按 title/description/value 匹配）
curl -X POST localhost:19876/action -d '{"action":"ax-press","title":"连接"}'

# 修改文本框
curl -X POST localhost:19876/action -d '{"action":"ax-set-value","title":"字段当前值","value":"新值"}'

# 切换 tab
curl -X POST localhost:19876/action -d '{"action":"ax-press","title":"📦 货品"}'

# 应用级操作
curl -X POST localhost:19876/action -d '{"action":"connect"}'
curl -X POST localhost:19876/action -d '{"action":"disconnect"}'
curl -X POST localhost:19876/action -d '{"action":"select-cruise","id":"cruise-id"}'
```

### 调试流程

1. `make app && open build/XDial.app` 启动 app
2. `curl localhost:19876/health` 确认调试服务器在线
3. 改代码 → 重新 `make app` → 重启 app → 用 `/state` 和 `/ax` 验证改动效果
4. 用 `ax-press` / `ax-set-value` 模拟用户操作，验证交互逻辑

### 注意

- 服务器只在 debug build 存在（`#if DEBUG`），release build 自动排除
- `localhost` 偶尔因 IPv6 解析失败，用 `127.0.0.1:19876` 更可靠
- popover 需要先点菜单栏图标（`ax-press` title `🚢`）才能在 AX 树中可见
- 设置窗口需要先点齿轮按钮（`ax-press` title `gearshape`）才能打开

## 项目结构

- `macos/Sources/XDial/` — Swift 源码（SwiftUI app）
- `cmd/xdial-helper/` — Go helper daemon（特权进程）
- `core/` — 共享 Go 逻辑
- `tools/inspector.swift` — 独立 AX 检查器（后备，需 Accessibility 权限）
