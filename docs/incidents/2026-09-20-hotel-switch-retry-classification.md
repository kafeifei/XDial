# 网络变化后 Tailscale 超时丢失自动重试分类

## 现场与边界

2026-09-20（Asia/Shanghai），从公司 Wi-Fi 转入酒店 Wi-Fi。Host 日志在
18:13:18 记录 `Network epoch 26`、`reason=ssid-match`、`underlay-refresh=true`，
目标“中国”。Provider 在 18:13:23–18:13:51 连续记录 Tailscale 出口探测失败；
用户看到“切换失败，仍在使用公司场景”及 `context deadline exceeded`。
其后没有 Host 自动切换 retry 记录；18:19:51 出现另一笔成功提交。
成功事务本身不证明是自动恢复，也不证明最初失败的物理网络原因。

Host / Provider 构建号为 `1789194915`；两个二进制 SHA-256 与既有构建清单一致，
清单源码为 `2eab57f1d22f3d478adeff124c3dd11eb9522d20`，也是修复前 main。
系统扩展从 9 月 12 日运行至今不等于它落后于这次检查的 main。

失败窗口中 Home DERP 从 `transport_connected` 变成 `protocol_ready`，
回程 route 从 absent 变成 current，收发计数仍变化。这些状态不能证明实际 TLS
出口已恢复。屏幕唤醒记录也不能单独证明此次切换由系统休眠导致。

## 确定的缺口

`probeGenerationLineCapability` 将 Go `LineReadiness` 的结构化失败转换成
`ConnectionRuntimeFailure`。但 `waitForTailscale` 在等待窗口结束后把最后的错误
改成 `RuntimeError.tailscaleEgressUnavailable(localizedDescription)`，只留下文字。
该枚举分支没有专用 `reportCode`，落入 `scenario-switch-prepare-failed`。
Host 只对 `line-readiness-transient` 重试，因此暂态超时被当成终止错误。

修复保留原结构化 code / evidence，同时保留 Tailscale 中文提示并归因到对应 Line。
未知错误不通过文字匹配获得重试资格，终止、取消与过期网络分类也原样保留。
现有同一自动意图的 2 / 5 / 10 秒、最多三次重试预算不变；旧事务仍是提交权威。
另补 Provider 失败日志，记录来源、候选事务及结构化 code，避免只剩提示文字。

## 验证范围

回归覆盖错误包装 → Provider IPC 编解码 → Host 有界重试，以及终止、取消、
过期网络和包含 timeout 字样的未知错误。旧包装逻辑无法取得第一次重试，测试失败。
该回归验证自动切换不会因分类丢失提前停止，不保证任意酒店网络或远端出口必然可达。
