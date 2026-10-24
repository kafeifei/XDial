"""跨版本、跨进程共享的版本常量契约（D22）。

正式版和 beta 用同一个身份：共用配置库、UserDefaults、钥匙串、App Group、root helper
和网络扩展；Debug 也共用配置库。持久格式和跨进程协议的版本号只能经 main 演进：任何
一侧单方面改值，另一侧就会拒绝加载配置库、交接失败、重跑迁移，或把对方写的数据读错。
这个检查直接读两侧源码，把每个版本号固定为当前值，并核对写入方和读取方一致。

纳入标准（同时满足）：
1. 显式版本：版本字段的取值、缺字段时的缺省值、版本判断的阈值，或文件名、UserDefaults
   键、钥匙串账户、认证附加数据、持久值前缀里的 v1 之类后缀；
2. 跨越构建边界：写入方和读取方不保证是同一个构建。包括持久化到磁盘、UserDefaults、
   钥匙串或 App Group 后由之后的版本（或共用身份的另一通道、共用配置库的 Debug）读取；
   经 IPC 在分别安装和替换的进程之间传递（宿主 App、root helper、网络扩展）；经更新
   清单或便携 Profile 文档交给其他已安装的版本；由仓库脚本读取已安装 App 写下的文件。

不纳入：
- 只在同一进程、同一构建内产生和消费的：ConnectionPlan 的 schema_version 由宿主进程内
  的 Libbox 生成、宿主自己校验；线路运行身份的 line-runtime-v1: 前缀由网络扩展进程内的
  Libbox 生成，摘要用进程内随机密钥，只在同一个扩展进程里比较；
- 写入后没有任何读取方的：NE providerConfiguration 里的 schema_version；Tailscale 迁移
  标记文件的内容 "v1"（读取方只看文件是否存在，文件名已固定）；
- 随同一构建打包的输入：RuleSetPresetCatalog 的 schema_version；
- 上游依赖补丁里的字段：sslcon 诊断快照的 SchemaVersion 已由
  scripts/prepare-patched-go-mod.sh 校验，且属于 D22 的依赖版本门禁；
- iOS / tvOS：仍是草稿平台。

新增属于同一类的版本号时，把它加进 PINS。
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

POLICY = (
    "这些版本号由正式版、beta 与 Debug 共享（D22）。改动必须先在 main 上演进，并让新旧"
    "版本都能处理对方写下的数据；不能只在 beta 或其他分支单方面修改。确实要演进时，在同"
    "一个合入 main 的 PR 里同时改写入方和读取方、兼容旧值，再更新 "
    "test/version_constants_test.py 里的固定值。"
)


def site(side, path, pattern, minimum=1):
    """pattern 只有一个捕获组，捕获版本值。该文件里至少要找到 minimum 处，找到的每一处都必须等于固定值。"""
    return {"side": side, "path": path, "pattern": pattern, "minimum": minimum}


PINS = [
    {
        "name": "helper 注册维护意图 version",
        "value": "1",
        "shared": "App 写、App 与 root helper 都读的同一个文件；升级期间新旧 App 和新旧 helper 交叉读写",
        "sites": [
            site("Swift", "macos/Shared/HelperRegistrationMaintenanceIntent.swift",
                 r"Record\(version:\s*(\d+),"),
            site("Swift", "macos/Shared/HelperRegistrationMaintenanceIntent.swift",
                 r"record\.version\s*==\s*(\d+)"),
            site("Go", "cmd/xdial/registration_handoff.go",
                 r"intent\.Version\s*!=\s*(\d+)"),
        ],
    },
    {
        "name": "helper 注册交接回复 protocol_version",
        "value": "1",
        "shared": "root helper 写进 registration-handoff 回复，安装方要求恰好等于这个值才租用维护窗口，"
                  "否则按服务忙放弃；升级期间新旧 App 与新旧 helper 交叉组合",
        "sites": [
            site("Go", "cmd/xdial/daemon.go", r"\bProtocolVersion:\s*(\d+)"),
            site("Swift", "macos/Sources/XDial/PrivilegeManager.swift",
                 r"reply\.protocolVersion\s*==\s*(\d+)"),
        ],
    },
    {
        "name": "helper 声明的注册交接能力 registration_handoff_version",
        "value": "1",
        "shared": "root helper 在 daemon-info 里声明；安装方不要求相等，只拿它和最低协议版本比大小，"
                  "低于最低版本就当旧 helper 走旧维护窗口",
        "sites": [
            site("Go", "cmd/xdial/daemon.go", r"\bRegistrationHandoffVersion:\s*(\d+)"),
        ],
    },
    {
        "name": "helper 注册交接的最低协议版本（低于它按旧 helper 处理）",
        "value": "1",
        "shared": "安装方据此判断正在运行的 helper 能否租用维护窗口；helper 声明的能力版本不能低于它",
        "sites": [
            site("Swift", "macos/Sources/XDial/PrivilegeManager.swift",
                 r"handoffProtocolVersion\s*<\s*(\d+)"),
            site("Swift", "macos/Shared/HelperRegistrationCoordinator.swift",
                 r"handoffProtocolVersion\s*<\s*(\d+)"),
        ],
    },
    {
        "name": "旧 helper 缺省的注册交接版本（daemon-info 不带该字段时）",
        "value": "0",
        "shared": "早于交接协议的旧 helper 不带 registration_handoff_version，安装方按这个值处理；它必须小于"
                  "最低协议版本，旧 helper 才会走旧维护窗口，而不是收到它不认识的 registration-handoff",
        "sites": [
            site("Swift", "macos/Sources/XDial/PrivilegeManager.swift",
                 r"registrationHandoffVersion\s*\?\?\s*(\d+)"),
        ],
    },
    {
        "name": "helper 注册标记 UserDefaults 键",
        "value": "xdial.helper.registration.v1",
        "shared": "正式版与 beta 共用 UserDefaults；键名变了，另一方会认为 helper 未注册而重新注册",
        "sites": [
            site("Swift", "macos/Sources/XDial/PrivilegeManager.swift",
                 r'registrationMarkerKey\s*=\s*"([^"]+)"'),
        ],
    },
    {
        "name": "dns-takeover.json version",
        "value": "1",
        "shared": "root helper 写下，下一个 helper 进程（可能是另一个版本）启动时据此自愈系统 DNS",
        "sites": [
            site("Go", "core/engine/dns_takeover.go",
                 r"dnsTakeoverState\{\s*Version:\s*(\d+),", minimum=2),
            site("Go", "core/engine/dns_takeover.go",
                 r"state\.Version\s*==\s*0\s*\{\s*state\.Version\s*=\s*(\d+)"),
        ],
    },
    {
        "name": "Tailscale 状态迁移标记",
        "value": ".xdial-tailscale-state-v1",
        "shared": "共用 App Group 里的一次性迁移标记；改名会让另一版本把已迁移的身份再迁一次",
        "sites": [
            site("Go", "core/tailscalesetup/state.go", r'migrationMarker\s*=\s*"([^"]+)"'),
        ],
    },
    {
        "name": "共享配置库 profiles.enc schemaVersion",
        "value": "3",
        "shared": "正式版、beta、Debug 共用 ~/.xdial/configuration/profiles.enc；读取方拒绝更高版本",
        "sites": [
            site("Swift", "macos/Sources/XDial/ProfileLibrary.swift", r"var schemaVersion = (\d+)"),
            site("Swift", "macos/Sources/XDial/ProfileLibrary.swift",
                 r"\(1\.\.\.(\d+)\)\.contains\(schemaVersion\)"),
            site("Swift", "macos/Sources/XDial/ProfileLibrary.swift",
                 r"(?<![\w.])schemaVersion < (\d+)", minimum=2),
            site("Swift", "macos/Sources/XDial/ProfileLibrary.swift",
                 r"result\.schemaVersion = (\d+)"),
            site("Swift", "macos/Sources/XDial/GlobalConfiguration.swift",
                 r"^[ \t]*schemaVersion = (\d+)[ \t]*$"),
            site("Swift", "macos/Sources/XDial/ProfileLibraryStore.swift",
                 r"decoded\.schemaVersion < (\d+)"),
        ],
    },
    {
        "name": "共享配置库认证附加数据",
        "value": "XDial Profile Library v1",
        "shared": "profiles.enc 的 AES-GCM 附加数据；改了另一方就解不开整个配置库",
        "sites": [
            site("Swift", "macos/Sources/XDial/ProfileLibraryStore.swift",
                 r'authenticating:\s*Data\("([^"]+)"\.utf8\)', minimum=2),
        ],
    },
    {
        "name": "共享配置库密钥的钥匙串账户",
        "value": "profile-library-key-v1",
        "shared": "profiles.enc 的密钥；改了另一方就找不到密钥",
        "sites": [
            site("Swift", "macos/Sources/XDial/ProfileLibraryStore.swift",
                 r'kSecAttrAccount as String:\s*"([^"]+)"'),
            site("Swift", "macos/Sources/XDial/SettingsLayoutPreview.swift",
                 r'kSecAttrAccount as String:\s*"([^"]+)"'),
        ],
    },
    {
        "name": "沙盒凭据合并标记 UserDefaults 键",
        "value": "xdial.migratedFromSandboxVaultV1",
        "shared": "共用 UserDefaults 里的一次性迁移标记；改名会让另一版本用旧快照再合并一次凭据",
        "sites": [
            site("Swift", "macos/Sources/XDial/KeychainStore.swift", r'let marker = "([^"]+)"'),
        ],
    },
    {
        "name": "更新后重启意图 schemaVersion",
        "value": "2",
        "shared": "旧版本在更新前写入 UserDefaults，新版本重启后读取并决定是否恢复连接；读取方仍接受 v0.9.x 及更早写下的 1",
        "sites": [
            site("Swift", "macos/Sources/XDial/AppUpdateTransaction.swift",
                 r"struct AppUpdateRelaunchIntent: Codable, Equatable \{\s*(?:///[^\n]*\n\s*)*static let schemaVersion = (\d+)"),
        ],
    },
    {
        "name": "更新清单 schemaVersion",
        "value": "1",
        "shared": "所有已安装的客户端读同一份发布清单；发布脚本核对线上清单",
        "sites": [
            site("Swift", "macos/Sources/XDial/AppUpdateReleaseLookup.swift",
                 r"wire\.schemaVersion == (\d+)"),
            site("Python", "scripts/publish-release.py",
                 r'expected = render_feed\(\{\s*"schemaVersion":\s*(\d+),'),
        ],
    },
    {
        "name": "安装临时文件回执 schemaVersion",
        "value": "1",
        "shared": "安装方写在 /Applications 旁的回执，由之后启动的版本据此清理",
        "sites": [
            site("Swift", "macos/Shared/ApplicationInstallationArtifacts.swift",
                 r"Transaction\(\s*schemaVersion:\s*(\d+),"),
            site("Swift", "macos/Shared/ApplicationInstallationArtifacts.swift",
                 r"transaction\.schemaVersion == (\d+)"),
        ],
    },
    {
        "name": "安装报告 schemaVersion（含完成标记 installation-vN）",
        "value": "4",
        "shared": "写进 UserDefaults 的完成标记和日志目录里的 installation-report.json，下次启动读取",
        "sites": [
            site("Swift", "macos/Shared/InstallationTransaction.swift",
                 r"struct InstallationReport: Codable, Equatable \{\s*static let schemaVersion = (\d+)"),
        ],
    },
    {
        "name": "连接报告 connection-report.json schema_version",
        "value": "3",
        "shared": "网络扩展写进 App Group，宿主 App 与 root helper 读取；扩展和宿主可能版本不同",
        "sites": [
            site("Swift", "macos/Shared/ConnectionTransaction.swift",
                 r"let now = Date\(\)\s*schemaVersion = (\d+)"),
        ],
    },
    {
        "name": "自动重连记录 reconnect-incidents.json schema_version",
        "value": "1",
        "shared": "写在共用的 Application Support 目录，之后的版本继续追加",
        "sites": [
            site("Swift", "macos/Shared/ReconnectIncidentHistory.swift",
                 r"struct ReconnectIncidentHistory: Codable, Equatable \{\s*var schemaVersion = (\d+)"),
        ],
    },
    {
        "name": "底层网络捕获证据 schema_version",
        "value": "1",
        "shared": "嵌在连接报告和重连记录里随之持久化、跨进程传递",
        "sites": [
            site("Swift", "macos/Shared/HostUnderlayCaptureDiagnostics.swift",
                 r"HostUnderlayCaptureEvidence\(\s*schemaVersion:\s*(\d+),", minimum=2),
            site("Swift", "macos/Sources/XDial/TransparentProxyManager.swift",
                 r"HostUnderlayCaptureEvidence\(\s*schemaVersion:\s*(\d+),"),
        ],
    },
    {
        "name": "宿主与网络扩展的场景切换 IPC 版本",
        "value": "1",
        "shared": "宿主 App 与网络扩展分别替换，更新期间可能版本不同",
        "sites": [
            site("Swift", "macos/Shared/ScenarioSwitchIPC.swift",
                 r"enum ProviderScenarioSwitchCodec \{\s*static let version = (\d+)"),
        ],
    },
    {
        "name": "宿主与网络扩展的诊断 IPC 版本",
        "value": "1",
        "shared": "宿主 App 与网络扩展分别替换，更新期间可能版本不同",
        "sites": [
            site("Swift", "macos/Shared/ProviderDiagnosticsIPC.swift",
                 r"enum ProviderDiagnosticsCodec \{\s*static let version = (\d+)"),
        ],
    },
    {
        "name": "宿主与网络扩展的本地 SOCKS 共享 IPC 版本",
        "value": "1",
        "shared": "宿主 App 与网络扩展分别替换，更新期间可能版本不同",
        "sites": [
            site("Swift", "macos/Shared/LocalSOCKSShare.swift",
                 r'struct LocalSOCKSShareRequest: Codable, Equatable \{\s*static let kind = "local-socks-share"\s*static let version = (\d+)'),
        ],
    },
    {
        "name": "宿主与网络扩展的 Tailscale 控制 IPC 版本",
        "value": "1",
        "shared": "宿主 App 与网络扩展分别替换，更新期间可能版本不同；读取方版本不符就回 invalid-request",
        "sites": [
            site("Swift", "macos/Shared/TailscaleControlIPC.swift",
                 r'kind = "tailscale-control"\s*version = (\d+)$'),
            site("Swift", "macos/Shared/TailscaleControlIPC.swift",
                 r'kind == "tailscale-control" && version == (\d+)'),
        ],
    },
    {
        "name": "文本规则集转换出的 sing-box 源规则集 version",
        "value": "3",
        "shared": "转换结果缓存在共享 App Group 的 xdial-rule-sets，缓存路径不含版本，由共用 App Group 的其他版本"
                  "直接读取；读取方的 sing-box 拒绝它不认识的版本，缓存失效后离线或拉取失败时连接报 rule-set-unavailable",
        "sites": [
            site("Go", "core/libbox/configgen.go", r"sourceRuleSet\{\s*Version:\s*(\d+),"),
        ],
    },
    {
        "name": "运行配置指纹版本前缀",
        "value": "runtime-v1:",
        "shared": "宿主算出的指纹随连接报告写进 App Group；之后的构建（或共用身份的另一通道）接管运行中的连接、"
                  "判断配置是否已应用、判断同场景切换是否 no-op 时，都拿它和自己现算的指纹做相等比较。前缀是指纹"
                  "算法的版本：改了它，接管后的连接会被误判为有未应用的改动；改投影或摘要算法时同样要在 main 上处理"
                  "新旧指纹的比较",
        "sites": [
            site("Go", "core/config/runtime_fingerprint.go",
                 r'runtimeConfigurationFingerprintPrefix\s*=\s*"([^"]+)"'),
        ],
    },
    {
        "name": "便携 Profile 文档 xdial.schema_version（读取上限、仅资源文档）",
        "value": "2",
        "shared": "导出文件、订阅和预置配置包里的文档会被其他版本导入",
        "sites": [
            site("Go", "core/config/profile_document.go",
                 r"document\.XDial\.SchemaVersion > (\d+)"),
            site("Go", "core/config/profile_document.go",
                 r"document\.XDial\.ResourcesOnly && \(document\.XDial\.SchemaVersion != (\d+)"),
            site("Go", "core/config/profile_document.go",
                 r"document\.XDial\.SchemaVersion = (\d+)"),
        ],
    },
    {
        "name": "便携 Profile 文档 xdial.schema_version（含场景的完整文档）",
        "value": "1",
        "shared": "导出文件会被其他版本导入",
        "sites": [
            site("Go", "core/config/profile_document.go",
                 r"ImportWarnings: profile\.ImportWarnings, SchemaVersion: (\d+),"),
        ],
    },
]


def inspect(pin):
    """返回 (问题列表, [(语言, 位置, 当前值)])。"""
    problems = []
    observed = []
    for entry in pin["sites"]:
        path = ROOT / entry["path"]
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            problems.append(f"{entry['side']} {entry['path']}：文件不存在")
            continue
        matches = list(re.finditer(entry["pattern"], text, re.MULTILINE))
        if len(matches) < entry["minimum"]:
            problems.append(
                f"{entry['side']} {entry['path']}：应至少找到 {entry['minimum']} 处，实际 {len(matches)} 处"
                f"（/{entry['pattern']}/）。代码移动或改写后，要在 main 上同步更新本契约的位置")
        for match in matches:
            line = text.count("\n", 0, match.start(1)) + 1
            observed.append((entry["side"], f"{entry['path']}:{line}", match.group(1)))
    for side, location, value in observed:
        if value != pin["value"]:
            problems.append(f"{side} {location}：当前为 {value!r}，固定值为 {pin['value']!r}")
    by_side = {}
    for side, _, value in observed:
        by_side.setdefault(side, set()).add(value)
    values = set().union(*by_side.values()) if by_side else set()
    if len(by_side) > 1 and len(values) > 1:
        detail = "，".join(f"{side}={'/'.join(sorted(found))}" for side, found in sorted(by_side.items()))
        problems.append(f"两侧不一致：{detail}")
    return problems, observed


def pin_named(name):
    return next(pin for pin in PINS if pin["name"] == name)


def failure_message(pin, problems):
    lines = [f"版本常量「{pin['name']}」偏离契约："]
    lines += [f"  - {problem}" for problem in problems]
    lines.append(f"共享方式：{pin['shared']}")
    lines.append(POLICY)
    return "\n".join(lines)


class VersionConstantContractTests(unittest.TestCase):
    def test_pinned_versions_match_on_every_side(self):
        for pin in PINS:
            with self.subTest(constant=pin["name"]):
                problems, _ = inspect(pin)
                if problems:
                    self.fail(failure_message(pin, problems))

    def test_contract_table_is_well_formed(self):
        names = [pin["name"] for pin in PINS]
        self.assertEqual(len(names), len(set(names)), "PINS 里有重名的常量")
        for pin in PINS:
            with self.subTest(constant=pin["name"]):
                self.assertTrue(pin["value"])
                self.assertTrue(pin["shared"])
                self.assertTrue(pin["sites"])
                for entry in pin["sites"]:
                    self.assertIn(entry["side"], {"Go", "Swift", "Python"})
                    self.assertEqual(re.compile(entry["pattern"]).groups, 1, entry["pattern"])
                    self.assertGreaterEqual(entry["minimum"], 1)

    def test_required_cross_language_pairs_are_checked_on_both_sides(self):
        # 计划 H4 点名的两组跨 Go/Swift 常量必须两侧都在表里，不能只剩一侧。
        for name in ["helper 注册维护意图 version", "helper 注册交接回复 protocol_version"]:
            pin = pin_named(name)
            self.assertEqual({entry["side"] for entry in pin["sites"]}, {"Go", "Swift"}, name)

    def test_helper_handoff_versions_keep_their_order(self):
        # 安装方只拿 helper 声明的能力版本和最低协议版本比大小：缺省值必须低于最低版本，旧 helper
        # 才会走旧维护窗口；helper 声明的版本不能低于最低版本，否则新 helper 也会被当成旧 helper。
        legacy = int(pin_named("旧 helper 缺省的注册交接版本（daemon-info 不带该字段时）")["value"])
        minimum = int(pin_named("helper 注册交接的最低协议版本（低于它按旧 helper 处理）")["value"])
        declared = int(pin_named("helper 声明的注册交接能力 registration_handoff_version")["value"])
        self.assertLess(legacy, minimum, f"旧 helper 缺省值 {legacy} 必须小于最低协议版本 {minimum}。{POLICY}")
        self.assertGreaterEqual(
            declared, minimum, f"helper 声明的版本 {declared} 不能低于最低协议版本 {minimum}。{POLICY}")


if __name__ == "__main__":
    unittest.main()
