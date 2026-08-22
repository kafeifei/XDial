# XDial

XDial 是一款 macOS 菜单栏网络分流工具。SwiftUI 提供控制面，sing-box 作为唯一数据面，
通过线路、规则和场景组合不同网络出口。

## 核心模型

- **Line（线路）**：定义出口，包括 Direct、AnyConnect、Tailscale 及常见代理协议。
- **RuleSet（规则）**：定义域名、IP/CIDR 等匹配条件。
- **Scenario（场景）**：将规则绑定到线路，并指定默认线路；只有当前场景会影响流量。

macOS 通过 Transparent Proxy 接管 TCP、UDP 和 DNS，并自然叠加在系统现有网络之上。
当前不接管 ICMP，因此 `ping` 不参与 XDial 的规则裁决。

## 开发

需要 macOS 15+、Xcode、Go、XcodeGen，以及可签名 System Extension 的开发环境。
Go 版本和具体构建依赖以 [`go.mod`](go.mod) 与 [`Makefile`](Makefile) 为准。

```bash
make test       # 运行测试
make app        # 构建 Debug App
make restart    # 构建、安装并启动本地 Debug App
make test-release-contract
```

改动前请完整阅读 [`ARCHITECTURE.md`](ARCHITECTURE.md)；界面改动还需阅读
[`DESIGN.md`](DESIGN.md)。

## Release 与自动更新

正式版本使用当前仓库的公开 GitHub Releases 作为唯一更新通道。发布前先更新
`RELEASE_NOTES.md` 的版本标题和“更新了什么”，再创建同版本的稳定标签。

本地完整分发门禁需要 Developer ID 签名环境和 Apple 公证凭据：

```bash
make release \
  RELEASE_TAG=v0.7.0 \
  RELEASE_BUILD_NUMBER="$(date +%s)" \
  NOTARY_KEYCHAIN_PROFILE=xdial-notary
```

命令只有在签名、公证、staple、Gatekeeper、压缩包回解和校验和全部通过后，才会生成
`build/release/XDial-v0.7.0.zip` 与对应的 `.sha256`。`make release-app` 仅用于诊断签名
构建，产物尚未公证，不能分发。

向 `vMAJOR.MINOR.PATCH` 标签推送后，`.github/workflows/release.yml` 会执行同一门禁并创建
GitHub Release。仓库需要配置以下 Actions secrets：

- `MACOS_DEVELOPER_ID_P12_BASE64`、`MACOS_DEVELOPER_ID_P12_PASSWORD`
- `MACOS_RELEASE_HOST_PROFILE_BASE64`、`MACOS_RELEASE_EXTENSION_PROFILE_BASE64`
- `APPLE_NOTARY_KEY_BASE64`、`APPLE_NOTARY_KEY_ID`、`APPLE_NOTARY_ISSUER_ID`

应用启动时及之后每十分钟检查一次稳定 Release；只有用户明确点击安装后才会下载、验证
并替换 `/Applications/XDial.app`。检查、下载和验证不会改变当前网络事务。

## License

[MIT](LICENSE)
