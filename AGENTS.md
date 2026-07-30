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
- 网络改动必须分别核对已激活的 System Extension、Transparent Proxy 配置、Provider
  状态、Underlay、DNS 归因和真实流量出口；旧 helper、接口和路由只代表原生 TUN
  历史路径。编译成功、配置可生成、Network Extension 显示 connected 或
  `sing-box check` 通过，都不等于真实链路已工作。
- macOS Underlay 快照必须来自宿主 App 请求连接之前的 `NWPath`；Provider 进程内的
  `NWPath` 会隐藏既有全流量 VPN，只能用于诊断，不能作为 sing-box 的 Underlay。
- 分发产物只能使用 `make release` 生成的 `build/release/XDial.app`；Debug 构建包含
  本地调试接口，不得分发。
- 本机 Debug 暂用已获签名授权的 `com.kafeifei.xdial.ne-probe{,.extension}` 标识；
  Release 保持正式标识。正式 Release 需要同时包含 System Extension 权限的 host 与
  extension provisioning profile；缺少签名账号时不得为“让构建通过”删除 entitlement
  或把 Debug 标识带进 Release。

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

# Debug-only 故障注入；会真实启动并回滚网络会话，必须先取得用户对本次断连的授权
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"connect-with-failure","stage":"commit"}'

# 只安装或替换 System Extension，不创建网络配置、不接管流量
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"prepare-system-extension"}'

# 打开设置、选择模式
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"open-settings"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"select-mode","id":"mode-id"}'

# 在当前已提交事务中建立一次固定 443 端口的路由归因探针，再读取结构化快照。
# host 只接受 ASCII DNS 名；Provider 会再次校验当前 transaction。
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"begin-route-probe","host":"example.com","timeout_ms":10000}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"routing-probe-snapshot","probe_id":"<上一步返回的 probeID>"}'

# 按 /ax 返回的 title 操作 UI
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"ax-press","title":"连接"}'
curl -sS -X POST 127.0.0.1:19876/action \
  -d '{"action":"ax-set-value","title":"字段当前值","value":"新值"}'
```

`/state.connectionReport` 是本次连接事务的事实来源：它包含动态计划、逐任务状态、错误、
事件顺序及回滚结果。诊断连接失败时先读这里，不得从文本日志反推控制流。
`/state.network.perLine` 只是由当前 Provider 事务产生、按 `transactionID` 绑定的易失
出口地址观察；它不表示 Line 运行状态，断开、Mode 或 transaction 改变时会清空。
逐域名归因使用 `begin-route-probe` 后读取 `routing-probe-snapshot`；不得用页面显示、
公网 IP 或旧的 Clash API selector 反推命中线路。实际 Line 归因只读响应中的
`lineIDCounts`；`outboundTagCounts` 是 Provider 内部证据，无法唯一映射时不得猜测。

Popover 只有在菜单栏图标被点开后才会出现在 AX 树中；设置窗口优先用
`open-settings` 打开。helper 的安装状态、版本和进程信息也通过 `/state` 或
`POST /action` 的 `check-helper`、`daemon-info` 检查，避免凭进程名猜测。

### Tailscale 验收边界

- 桌面 Tailscale 的登录与节点发现只能由设置页 Line 卡片显式启动。Debug Server
  可以用 AX 打开和检查这张卡片，但不得增加接收、回显或持久化 Auth Key 的接口。
- 浏览器登录会改变用户的 Tailscale 账号状态；Agent 未经用户明确授权，只验收到登录
  入口和结构化状态，不代替用户完成登录。Auth Key 同理不得从本机配置或日志中搜集。
- setup session 前后都要确认 XDial 数据面处于断开状态，系统没有新增 XDial TUN、
  默认路由与 DNS 未被 setup 改写。正式连接还必须确认 LocalAPI 登录态、所选 exit
  node 在线，以及连接后的真实出口；仅看到下拉框或配置生成成功不算完成。
- 官方 Tailscale exit node 等全流量 Network Extension 作为 Underlay 时，原生 TUN
  存在 D34 平台边界。不得只凭 `route.default_interface`、一条 `route get` 或出口
  自测宣告叠加成功；系统 DNS 必须进入 XDial，且普通 TCP/UDP 要分别证明命中真实
  Mode 出口。DNS 接管路由被下层 link route 抢走时应让连接失败，不得追加产品特例或
  再尝试第二个 Packet Tunnel。
- 旧原生 TUN 遇到 `RTF_GLOBAL` Underlay，必须在任何 Line 会话、规则预取和 sing-box
  启动之前拒绝。Transparent Proxy 不靠这条路由判据，但同样必须先完成 sing-box 与
  active Tailscale 出口就绪，再提交系统网络设置；`Connecting` 不是允许半接管用户
  流量的状态。
- 若结构化状态同时满足 exit node 在线且已选中、存在于 netmap / magicsock / engine、
  `tx > 0`、`rx = 0`、无握手，应报告 peer handshake 失败，不能改写成登录、GFW、
  Underlay 或普通出口探测结论。需要定位 DERP 状态漂移时必须做同时间双端取证，分别
  比较控制图与 magicsock 实时 Relay；旧日志和上一次成功不能替代本轮状态。远端
  `tailscaled` 重启只会清除既有内存状态，未经用户明确授权不得执行，也不得把重启后
  成功当作产品修复或验收。
- 本地 NetInfo 发布调用返回、lite map HTTP 接受、远端 peer map 消费、fresh handshake
  和真实出口是逐层独立的证据；只完成前一层不得宣称后一层。DERP client / ready 汇总
  只是点时快照，不能排除两次采样之间发生 reconnect；缺少结构化 lifecycle 证据时必须
  报告尚未确定。
- 不得在连接启动事务中自动触发 Home DERP 重选。出现上述 peer handshake failure 时
  必须在提交系统网络设置前失败并回滚；任何用户显式启动的重选也仍需 fresh handshake
  与真实出口验收，不能把本地提升或 control HTTP 接受当成恢复成功。

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
