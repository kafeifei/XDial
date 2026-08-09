# macOS Network Extension 共存探针

这个探针只验证 D34 的平台前提，不属于 XDial 正式数据面。依据
`NEAppProxyProvider.handleNewFlow` 的 Apple SDK 契约，
`NETransparentProxyProvider` 对命中的 flow 返回 `false` 时会把 flow 交回系统网络栈，
而不是由探针代理；探针不会读取 Profile，也不会选择 Line、RuleSet、Scenario、DNS 或出口。

`configure-scoped` 只匹配调用方显式提供的受控 IPv4 端点；仓库不保存企业域名或地址。
`configure-all` 用于观察系统实际交付的 flow 身份，可能影响整机网络，只能在用户在线且
恢复路径已经确认时运行。

构建不会安装或启用扩展：

```bash
cd test/macos_ne_probe
xcodegen
xcodebuild \
  -project XDialNEProbe.xcodeproj \
  -scheme XDialNEProbe \
  -configuration Debug \
  -derivedDataPath ../../build/ne-probe-signed \
  -allowProvisioningUpdates \
  build
```

激活系统扩展必须由用户在场确认。macOS 要求宿主位于 `/Applications`：

```bash
ditto build/ne-probe-signed/Build/Products/Debug/XDialNEProbe.app /Applications/XDialNEProbe.app
/Applications/XDialNEProbe.app/Contents/MacOS/XDialNEProbe activate
```

扩展激活后，调用方必须通过环境变量传入本次测试目标。下面只展示保留域名与 RFC 5737
文档地址；实际企业值应来自本地私有配置或企业仓库，不得提交到公共仓库：

```bash
XDIAL_NE_PROBE_HOST=corp.example \
XDIAL_NE_PROBE_ADDRESS=192.0.2.10 \
  ./run_scoped_trial.sh

XDIAL_NE_PROBE_HOST=corp.example ./run_dns_trial.sh
```

`run_scoped_trial.sh` 会短时启用 scoped 配置，并把探针已连接、本次试验实际收到 flow、
既有 Tailscale 会话与默认接口不变作为独立门禁；退出、失败或收到信号时都会停用配置。
宿主的配置、状态与清理命令自身有 15 秒超时，避免恢复流程无限等待。目标参数缺失时会在
启用配置前失败。

无论试验走到哪一步，都可以显式清理：

```bash
/Applications/XDialNEProbe.app/Contents/MacOS/XDialNEProbe stop
/Applications/XDialNEProbe.app/Contents/MacOS/XDialNEProbe remove
```
