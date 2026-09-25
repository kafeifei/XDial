# Next 发布

远程 `xdial-next` 保存独立产品源码；每次发布使用 `next-vMAJOR.MINOR.PATCH` 标签。
发布目标固定为 `kafeifei/XDial` 的 GitHub prerelease，不更新稳定版 Pages feed，也不标记 Latest。
发布工具不会删除分支、重写历史或改动 main。

## 固定身份与构建模式

| 入口 | 应用 | 签名 | 调试服务 | 用途 |
|---|---|---|---|---|
| `make app` / `make app-debug` | `XDail Debug.app` | Apple Development | 有 | 本机 Debug |
| `make app-next` | `XDial Next.app` | Apple Development | 有 | 本机 Next 调试 |
| `make release-next` | `XDial Next.app` | Developer ID + 公证 | 无 | GitHub Next 分发 |

Next 调试与分发使用同一组 `.next` 组件身份、socket 和运行目录；不能同时安装成两个 Next。
`macos/project.yml` 的共享 Next 身份控制名称、helper、后台服务及扩展。
分发使用独立的 `NextRelease` 配置和 `app-proxy-provider-systemextension` 授权。
Swift 的 `isDevelopment` 目前表示独立于正式版的安装通道；是否包含调试服务由 `DEBUG` 编译条件决定。
Debug 既有 `XDail` 文件名保留，避免在一次发布中额外引入安装路径迁移。

## 一次性签名配置

需要同一团队 `UVZM439VGU` 的 Developer ID Application 证书和两份 Developer ID profiles：

- `XDial Next Developer ID Host`：`com.kafeifei.xdial.next`，System Extension 安装权限与 Network Extension。
- `XDial Next Developer ID Transparent Proxy`：`com.kafeifei.xdial.next.transparent-proxy`，Network Extension。

两者使用 App Group `UVZM439VGU.com.kafeifei.xdial.next.network`，授权必须包含
`app-proxy-provider-systemextension`、`ProvisionsAllDevices=true`，并在有效期内。
下载到 Xcode 的 provisioning profiles 目录。证书、profiles、API 私钥不提交到 Git。
公证通过现有 Keychain profile 传入，不把凭据写进构建脚本。

## 每次发布

先更新 `NEXT_RELEASE_NOTES.md`，验证并提交源码，正常推送到 `origin/xdial-next`，再在该提交建立
`next-v…` 标签。构建时必须同时满足干净工作区、标签指向 HEAD、HEAD 等于最新 `origin/xdial-next`。
构建号使用递增整数，并大于已分发/已安装的同通道扩展版本。

```sh
make app-debug MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates

make release-next RELEASE_TAG=next-v0.9.0 RELEASE_BUILD_NUMBER="$(date +%s)" \
  NOTARY_KEYCHAIN_PROFILE=xdial-notary

git push origin next-v0.9.0
make publish-next RELEASE_TAG=next-v0.9.0
```

本机构建可用 `git push origin HEAD:refs/heads/xdial-next` 正常推进远程分支；不使用 force push。
脚本验证实际归档签名、嵌套组件版本、源码提交、helper 编译身份、App Group、后台服务 plist、
无 DebugServer、无调试 entitlement、无本地 RuleSet 预设，公证并 staple 后再压缩。
GitHub 先建立 draft prerelease，核对上传文件的服务端 SHA-256，最后公开。
重跑时只接受内容一致的既有发布；不会覆盖不同内容的同名资产或标签。

## 安装与验收

构建与发布命令不启动或重启已安装的应用、helper 或网络。
`--install-only` 会停止同通道旧进程，不是保留现有连接的覆盖安装方式。
保留旧进程时，磁盘新包不等于当前运行版本；旧宿主调用 SMAppService 仍可能注册旧包。
完整升级验收需要核对新宿主、daemon、扩展版本和安装报告，不能仅凭文件替换完成宣称升级成功。

发布逻辑测试：`make test-release-contract`；身份配置测试：`make macos-identity-contract`。
无签名 CI 同时编译 Debug、Next、Release、NextRelease，只证明编译，不生成可分发产物。
