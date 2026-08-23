# Tailscale 验收边界

本文件只在实现或验收 Tailscale Line 时按需阅读。架构语义同时以 `ARCHITECTURE.md` 的
D33–D35 为准；这里不授予登录、断连、重启本地或远端服务的权限。

- 桌面 Tailscale 的登录与节点发现只能由设置页 Line 卡片显式启动。Debug Server 可以用
  AX 打开和检查这张卡片，但不得增加接收、回显或持久化 Auth Key 的接口。
- 浏览器登录会改变用户的 Tailscale 账号状态；Agent 未经用户明确授权，只验收到登录入口
  和结构化状态，不代替用户完成登录。Auth Key 同理不得从本机配置或日志中搜集。
- setup session 前后都要确认 XDial 数据面处于断开状态，系统没有新增 XDial TUN、默认路由
  与 DNS 未被 setup 改写。正式连接还必须确认 LocalAPI 登录态、所选 exit node 在线，
  以及连接后的真实出口；仅看到下拉框或配置生成成功不算完成。
- 官方 Tailscale exit node 等全流量 Network Extension 作为 Underlay 时，原生 TUN 存在
  D34 平台边界。不得只凭 `route.default_interface`、一条 `route get` 或出口自测宣告叠加
  成功；系统 DNS 必须进入 XDial，且普通 TCP/UDP 要分别证明命中真实 Scenario 出口。
  DNS 接管路由被下层 link route 抢走时应让连接失败，不得追加产品特例或再尝试第二个
  Packet Tunnel。
- 旧原生 TUN 遇到 `RTF_GLOBAL` Underlay，必须在任何 Line 会话、规则预取和 sing-box
  启动之前拒绝。Transparent Proxy 不靠这条路由判据，但同样必须先完成 sing-box 与 active
  Tailscale 出口就绪，再提交系统网络设置；`Connecting` 不是允许半接管用户流量的状态。
- 若结构化状态同时满足 exit node 在线且已选中、存在于 netmap / magicsock / engine、
  `tx > 0`、`rx = 0`、无握手，应报告 peer handshake 失败，不能改写成登录、外部网络限制、
  Underlay 或普通出口探测结论。需要定位 DERP 状态漂移时必须做同时间双端取证，分别比较
  控制图与 magicsock 实时 Relay；旧日志和上一次成功不能替代本轮状态。远端 `tailscaled`
  重启只会清除既有内存状态，未经用户明确授权不得执行，也不得把重启后成功当作产品修复
  或验收。
- 本地 NetInfo 发布调用返回、lite map HTTP 接受、远端 peer map 消费、fresh handshake
  和真实出口是逐层独立的证据；只完成前一层不得宣称后一层。DERP client / ready 汇总只是
  点时快照，不能排除两次采样之间发生 reconnect；缺少结构化 lifecycle 证据时必须报告
  尚未确定。
- 不得在连接启动事务中自动触发 Home DERP 重选。出现上述 peer handshake failure 时必须
  在提交系统网络设置前失败并回滚；任何用户显式启动的重选也仍需 fresh handshake 与真实
  出口验收，不能把本地提升或 control HTTP 接受当成恢复成功。
