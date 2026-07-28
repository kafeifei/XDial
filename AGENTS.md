# XDial

XDial 是 macOS 菜单栏网络工具：SwiftUI 提供控制面，sing-box 提供数据面，AnyConnect
协议由 vendored sslcon 适配。

本文件是 Agent 的**最短执行入口**，不是仓库索引。目录、类型、函数、构建实现等能从
源码、测试或 `Makefile` 直接得到的事实，不在这里重复维护；先用 `rg` 定位，以当前代码
为准。

## 开始工作前

1. 动代码前完整阅读 [ARCHITECTURE.md](ARCHITECTURE.md)，尤其是三条定律、相关 ADR、
   第 7 节禁止事项和第 9 节自检清单。
2. 再读改动涉及的实现和测试。不要仅凭文档猜测当前代码行为。
3. 如果实现与架构规范冲突，先判断是实现越界还是规范需要改变。未经用户明确同意，不得
   改写架构约束来迁就实现。

架构的最短摘要：

- **控制面与数据面分离**：XDial 表达、编译和托管；sing-box 接管、解析、裁决和转发。
- **外部密封律**：XDial 对系统只增加一个网络叠加层，DNS、路由和分流不散落到盒外。
- **内部正交律**：Ingress / Line / RuleSet / Mode 相互正交，Mode 是唯一连接点。
  声明不等于生效；未被 active Mode 引用的对象不得影响本机流量。
- **自然叠加**：启动前的网线、Wi-Fi、企业 VPN、Tailscale 等共同组成不透明 Underlay。
  XDial 不识别产品、不重排接口，只把系统已有裁决交给 sing-box。

`core/config/invariants_test.go` 是架构约束的可执行门禁。测试变红时应修正实现；不得放宽、
跳过、删除或给断言加特例。若确实要改变架构，先与用户对齐并更新
`ARCHITECTURE.md`，再调整测试。

## 验证边界

具体 target 及构建细节以 `Makefile` 为准。常用闭环：

```bash
make test
make test-smoke
make restart
python3 test/e2e_test.py
```

- UI 改动必须执行 `make restart`，再通过 Debug Server 操作和读取真实 UI 状态。
- 网络改动必须核对真实 helper、接口、路由、DNS 和流量出口。编译成功、配置可生成或
  `sing-box check` 通过，都不等于真实链路已工作。
- 分发产物只能使用 `make release` 生成的 `build/release/XDial.app`；Debug 构建包含
  本地调试接口，不得分发。

## Debug Server

Debug 构建只在 `127.0.0.1:19876` 提供 HTTP 接口，release 构建完全排除。统一使用
`127.0.0.1`，不要依赖 `localhost` 的 IPv6 解析。

```bash
# 存活与进程
curl -sS 127.0.0.1:19876/health

# engine/profile/network/windows；敏感字段已脱敏
curl -sS 127.0.0.1:19876/state

# 当前 UI 元素树
curl -sS "127.0.0.1:19876/ax?depth=8"

# 连接、断开、重连
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"connect"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"disconnect"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"reconnect"}'

# 打开设置、选择模式
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"open-settings"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"select-mode","id":"mode-id"}'

# 按 /ax 返回的 title 操作 UI
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"ax-press","title":"连接"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"ax-set-value","title":"字段当前值","value":"新值"}'
```

Popover 只有在菜单栏图标被点开后才会出现在 AX 树中；设置窗口优先用
`open-settings` 打开。helper 的安装状态、版本和进程信息也通过 `/state` 或
`POST /action` 的 `check-helper`、`daemon-info` 检查，避免凭进程名猜测。

## 仓库特有纪律

- 概念命名固定为线路 Line / 规则 RuleSet / 模式 Mode。
- 不修改 `third_party/`。需要上游变更时使用本地补丁并留痕。
- Go 代码提交前执行 `gofmt`。
- 回复用户用中文，代码标识符保持英文。
- 使用精确工程术语：分域解析、域名归因、解析视角与出口视角一致、非权威或被篡改的
  应答、受限解析环境。不要使用含义不明确的社区俗语。

## 文档放什么

- `ARCHITECTURE.md` 记录无法安全地从代码反推的内容：边界、理念、因果关系、失败语义、
  真实事故证据、架构决策及被否决方案。
- `AGENTS.md` 记录 Agent 必须提前知道的操作入口：阅读顺序、硬约束、验收边界和
  Debug 接口。
- 局部实现中容易误改的原因写在代码旁，注释解释“为什么”，不复述“做了什么”。
- 不在文档维护目录树、类型/字段/函数清单、完整命令清单或临时任务进度；这些内容会
  漂移，应从源码、测试、`Makefile` 和实时状态获取。
