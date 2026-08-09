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
make release    # 生成 Release App
```

改动前请完整阅读 [`ARCHITECTURE.md`](ARCHITECTURE.md)；界面改动还需阅读
[`DESIGN.md`](DESIGN.md)。

## License

[MIT](LICENSE)
