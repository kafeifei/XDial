# XDial

macOS 菜单栏网络分流工具。场景将规则绑定到线路，统一决定 DNS 与连接出口；支持 Direct、
AnyConnect、Tailscale 及 sing-box 代理协议。iOS / tvOS 共用 Go 核心。

macOS 使用 Transparent Proxy 接入 TCP、UDP 和 DNS，叠加在系统现有网络之上。
ICMP 不在其接管范围内，`ping` 不经过 XDial 的规则裁决。

## 项目

- [架构与边界](ARCHITECTURE.md)
- [产品设计](DESIGN.md)
- [构建、签名与安装](docs/agent/development-builds.md)
- [诊断接口](docs/agent/debug-server.md)
- [更新与发布](docs/agent/updates.md)

## 构建

macOS 构建需要 Xcode、XcodeGen、Go，以及 System Extension 签名环境。版本和依赖以
[go.mod](go.mod)、[Makefile](Makefile) 和 [macOS 工程](macos/project.yml) 为准。

| 入口 | 结果 |
|---|---|
| `make app` | 构建本地 Debug 候选，不安装或启动 |
| `make restart` | 构建、退出旧 Debug、安装并启动新 Debug，影响当前连接 |
| `make test` | Go 与补丁测试 |
| `make test-macos-transaction` | macOS 事务与构建身份测试 |
| `make release` | 正式签名、公证和归档；参数及发布关系见更新文档 |

## License

[MIT](LICENSE)
