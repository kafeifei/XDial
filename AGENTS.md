# XDial

macOS menu bar app（SwiftUI + Go），管理 VPN/代理分流。数据面 sing-box，VPN 走 AnyConnect 协议（vendored sslcon）。本文件是所有 AI 编码工具（Claude Code / Codex / Cursor）的共同事实源。

## 构建

```bash
make app        # debug 构建（含 DebugServer）→ build/XDial.app
make release    # release 构建（无 DebugServer、注入版本号）→ build/release/XDial.app，分发一律用它
make cli        # 仅 Go CLI → build/xdial
make restart    # 一键：杀旧实例 + make app + 启动 + 等 debug server 上线（改 UI 后验证用这个）
make inspector  # 独立 AX 检查器 → build/xdial-inspector
```

## 测试

```bash
make test                 # Go 全量（含 libbox gVisor 数据面集成测试，-tags with_gvisor）
make test-smoke           # sing-box 配置生成冒烟测试
python3 test/e2e_test.py  # 端到端（需 helper daemon 已在运行）
```

## UI 调试 (Debug Server)

debug build 自动在 `127.0.0.1:19876` 启动 HTTP 调试服务器（只绑回环，release 构建不包含）。**任何涉及 UI 的改动，必须用这个服务器验证，不要靠猜。**

### 读取状态

```bash
# 完整应用状态：engine/profile/network/windows（密码与订阅 URL 已脱敏为 ***）
curl 127.0.0.1:19876/state

# UI 元素树：每个元素的 role/title/value/enabled/坐标
curl "127.0.0.1:19876/ax?depth=8"
```

### 操作 UI

```bash
# 点击按钮（按 title/description/value 匹配）
curl -X POST 127.0.0.1:19876/action -d '{"action":"ax-press","title":"连接"}'

# 修改文本框
curl -X POST 127.0.0.1:19876/action -d '{"action":"ax-set-value","title":"字段当前值","value":"新值"}'

# 切换设置 tab（当前命名：📡 线路 / 📋 规则 / 🔀 模式 / 通用）
curl -X POST 127.0.0.1:19876/action -d '{"action":"ax-press","title":"📋 规则"}'

# 应用级操作
curl -X POST 127.0.0.1:19876/action -d '{"action":"connect"}'
curl -X POST 127.0.0.1:19876/action -d '{"action":"disconnect"}'
curl -X POST 127.0.0.1:19876/action -d '{"action":"select-mode","id":"mode-id"}'
```

### 调试流程

1. `make restart` —— 重编 + 重启 + 等 debug server 上线，一条命令完成
2. 用 `/state` 和 `/ax` 验证改动效果
3. 用 `ax-press` / `ax-set-value` 模拟用户操作，验证交互逻辑

### 注意

- 服务器只在 debug build 存在（`#if DEBUG`），release build 自动排除
- 用 `127.0.0.1:19876`（`localhost` 偶尔因 IPv6 解析失败；服务器只绑 IPv4 回环）
- 只接受 POST /action（无 GET 别名）；Host 头必须是本机回环
- popover 需要先点菜单栏图标才能在 AX 树中可见
- 设置窗口需要先点齿轮按钮（`ax-press` title `gearshape`）才能打开

## 项目结构

- `macos/Sources/XDial/` — Swift 源码（SwiftUI app）
- `cmd/xdial/` — Go CLI + daemon（特权进程以 `xdial daemon` 运行）
- `core/` — 共享 Go 逻辑（config 生成 / engine / libbox）
- `third_party/sslcon/` — vendored sslcon（MIT，AnyConnect 协议，含本地补丁；独立 go module）
- `appletv/` — tvOS app（xcodegen 工程，`make appletv`）
- `test/` — 端到端测试
- `tools/inspector.swift` — 独立 AX 检查器（后备，需 Accessibility 权限）

## 约定

- 概念命名：线路 Line / 规则 RuleSet / 模式 Mode（旧 JSON key 有兼容层，见 core/config/compat.go）
- Go 代码提交前必须 `gofmt`（CI 有门禁）；vendored `third_party/` 不改不动
- 回复用户用中文，代码标识符保持英文
