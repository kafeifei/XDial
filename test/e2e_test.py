#!/usr/bin/env python3
"""XDial 端到端验收测试（密封盒）。

通过 Unix socket 直接驱动 helper daemon，验证协议层与真实数据路径。

分层：
  Tier A（protocol）—— 协议与 fail-closed 校验。用的 profile 都保证在配置生成阶段
    就被拒绝，不会触碰特权面（不拨号、不建 TUN、不改系统 DNS），随时可跑。
  Tier B（live）—— 真实路径验收。读 app 保存的真实 profile（UserDefaults）和
    vault 密码（~/.xdial/vault.json），真连接后断言：
      连接态：系统 DNS 已被接管到 198.18.0.2、解析可用、默认线路可达、
              VPN 绑定的内网域名可达、sing-box 数据面进程存在
      断开后：系统 DNS 还原、解析仍可用、无残留 sing-box 进程
    会真实拨通 VPN 并短暂改变整机路由/DNS，只在开发机上跑。

用法:
    python3 test/e2e_test.py                 # Tier A + 条件满足时 Tier B
    python3 test/e2e_test.py --tier a        # 只跑协议层
    python3 test/e2e_test.py --tier b        # 只跑真实路径
    python3 test/e2e_test.py --socket PATH   # 指定 daemon socket（默认 /tmp/xdial.sock）
    python3 test/e2e_test.py --require-fresh # daemon 版本与本仓库不一致时判失败（默认仅警告）

需要 helper daemon 已在运行（launchd 托管，/tmp/xdial.sock 可达）。
"""
import argparse
import json
import plistlib
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

DEFAULT_SOCKET = "/tmp/xdial.sock"
DEFAULTS_DOMAIN = "com.kafeifei.xdial"
PROFILE_KEY = "xdial.profile"
VAULT_PATH = Path.home() / ".xdial" / "vault.json"
# 与 core/engine/dns_takeover.go 的 dnsTakeoverAddress 一致
DNS_TAKEOVER_ADDR = "198.18.0.2"

CONNECT_TIMEOUT = 60  # AnyConnect 拨号 + 数据面就绪
DISCONNECT_TIMEOUT = 20
RPC_TIMEOUT = 15


class Failure(Exception):
    pass


def run(cmd: list, timeout: int = 10) -> subprocess.CompletedProcess:
    """所有外部命令统一走这里：必须带超时，绝不无限等。"""
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ---------------------------------------------------------------------------
# daemon 客户端（协议见 cmd/xdial/protocol.go：换行分隔 JSON，
# Request{id,cmd,...} / Response{id,ok,message,data} / Event{event,data}）
# ---------------------------------------------------------------------------

class DaemonClient:
    def __init__(self, socket_path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(socket_path)
        self.buf = b""
        self.events = []  # 尚未被消费的事件
        self.seq = 0

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _read_message(self, deadline: float) -> Optional[dict]:
        """读一条消息（事件或响应）；到 deadline 还没读到返回 None。"""
        while True:
            if b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                return json.loads(line)
            remain = deadline - time.time()
            if remain <= 0:
                return None
            self.sock.settimeout(min(remain, 1.0))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise Failure("daemon 关闭了连接")
            self.buf += chunk

    def request(self, cmd: str, timeout: int = RPC_TIMEOUT, **fields) -> dict:
        """发请求并等待同 id 的响应；中途的事件缓存进 self.events。"""
        self.seq += 1
        req_id = f"e2e-{self.seq}"
        req = {"id": req_id, "cmd": cmd, **fields}
        self.sock.sendall((json.dumps(req) + "\n").encode())
        deadline = time.time() + timeout
        while True:
            msg = self._read_message(deadline)
            if msg is None:
                raise Failure(f"等待 {cmd} 响应超时（{timeout}s）")
            if msg.get("event"):
                self.events.append(msg)
                continue
            if msg.get("id") == req_id:
                return msg
            # 别的请求的响应（本客户端串行使用，正常不该出现）——丢弃

    def next_event(self, timeout: int) -> Optional[dict]:
        if self.events:
            return self.events.pop(0)
        deadline = time.time() + timeout
        while True:
            msg = self._read_message(deadline)
            if msg is None:
                return None
            if msg.get("event"):
                return msg
            # 无人认领的响应，丢弃

    def wait_status(self, target: str, timeout: int,
                    fail_on_error: bool = True) -> None:
        """等状态事件到达 target；期间收到 error 事件按失败处理（可关）。"""
        deadline = time.time() + timeout
        seen = []
        while time.time() < deadline:
            ev = self.next_event(min(5, max(1, int(deadline - time.time()))))
            if ev is None:
                continue
            if ev["event"] == "error" and fail_on_error:
                raise Failure(f"引擎报错: {ev.get('data', '')}")
            if ev["event"] == "status":
                st = json.loads(ev.get("data", "{}")).get("status", "")
                seen.append(st)
                if st == target:
                    return
        raise Failure(f"等待状态 {target} 超时（{timeout}s），期间状态: {seen or '无'}")

    def wait_error_then_disconnected(self, timeout: int) -> str:
        """fail-closed 路径：先等 error 事件，再确认回到 disconnected。返回错误文本。"""
        deadline = time.time() + timeout
        err_msg = None
        while time.time() < deadline:
            ev = self.next_event(min(5, max(1, int(deadline - time.time()))))
            if ev is None:
                continue
            if ev["event"] == "error":
                err_msg = ev.get("data", "")
            if ev["event"] == "status":
                st = json.loads(ev.get("data", "{}")).get("status", "")
                if st == "disconnected" and err_msg is not None:
                    return err_msg
        raise Failure(f"等待 error+disconnected 超时（{timeout}s），err={err_msg!r}")

    def status(self) -> str:
        resp = self.request("status")
        if not resp.get("ok"):
            raise Failure(f"status 查询失败: {resp.get('message')}")
        return json.loads(resp.get("data", "{}")).get("status", "unknown")


# ---------------------------------------------------------------------------
# Tier A：协议层。所有 start 用的 profile 都会在配置生成阶段被拒绝
# （悬空引用 INV6a），不含 VPN 线路所以也不会拨号 —— 对系统零副作用。
# ---------------------------------------------------------------------------

def dangling_profile(new_keys: bool) -> dict:
    """活动模式绑定了一个不存在的规则 —— 必须 fail-closed 拒绝启动。"""
    if new_keys:
        return {
            "lines": [
                {"id": "direct", "name": "直连", "type": "direct", "enabled": True},
            ],
            "rule_sets": [],
            "modes": [
                {"id": "m", "name": "测试",
                 "bindings": [{"rule_set_id": "ghost", "line_id": "direct"}],
                 "default_line_id": "direct"},
            ],
            "active_mode_id": "m",
        }
    # 旧比喻命名（ports/cargoes/cruises），验证 daemon 端兼容层解码后
    # 走的是同一套校验
    return {
        "ports": [
            {"id": "direct", "name": "直连", "type": "direct", "enabled": True},
        ],
        "cargoes": [],
        "cruises": [
            {"id": "m", "name": "测试",
             "bindings": [{"cargo_id": "ghost", "port_id": "direct"}],
             "default_port_id": "direct"},
        ],
        "active_cruise_id": "m",
    }


def test_initial_status_event(client: DaemonClient):
    ev = client.next_event(timeout=5)
    if ev is None or ev.get("event") != "status":
        raise Failure(f"连接后未收到初始状态事件，收到: {ev}")
    st = json.loads(ev.get("data", "{}")).get("status")
    if st not in ("disconnected", "connecting", "connected",
                  "disconnecting", "reconnecting"):
        raise Failure(f"初始状态非法: {st}")


def test_daemon_info(client: DaemonClient):
    resp = client.request("daemon-info")
    if not resp.get("ok"):
        raise Failure(f"daemon-info 失败: {resp.get('message')}")
    info = json.loads(resp["data"])
    for key in ("version", "exe_sha256", "pid"):
        if not info.get(key):
            raise Failure(f"daemon-info 缺少 {key}: {info}")


def test_status_query(client: DaemonClient):
    st = client.status()
    if st not in ("disconnected", "connecting", "connected",
                  "disconnecting", "reconnecting"):
        raise Failure(f"status 返回非法状态: {st}")


def test_unknown_command(client: DaemonClient):
    resp = client.request("no-such-command")
    if resp.get("ok"):
        raise Failure("未知命令居然返回 ok")
    if "unknown command" not in resp.get("message", ""):
        raise Failure(f"未知命令的报错不对: {resp.get('message')}")


def test_invalid_profile_rejected(client: DaemonClient):
    resp = client.request("start", profile="{not json")
    if resp.get("ok"):
        raise Failure("非法 JSON profile 居然被接受")
    if "invalid profile" not in resp.get("message", ""):
        raise Failure(f"非法 profile 的报错不对: {resp.get('message')}")


def test_dangling_ref_fail_closed(client: DaemonClient):
    resp = client.request("start", profile=json.dumps(dangling_profile(new_keys=True)))
    if not resp.get("ok"):
        raise Failure(f"start 同步拒绝（应异步 fail-closed）: {resp.get('message')}")
    err = client.wait_error_then_disconnected(timeout=RPC_TIMEOUT)
    if "ghost" not in err:
        raise Failure(f"fail-closed 报错未指出悬空引用: {err}")


def test_old_key_compat_fail_closed(client: DaemonClient):
    resp = client.request("start", profile=json.dumps(dangling_profile(new_keys=False)))
    if not resp.get("ok"):
        # 旧 key 若解码失败会在这里以 invalid profile 拒绝 —— 那是兼容层坏了
        raise Failure(f"旧 key profile 未通过兼容层解码: {resp.get('message')}")
    err = client.wait_error_then_disconnected(timeout=RPC_TIMEOUT)
    if "ghost" not in err:
        raise Failure(f"旧 key profile 的 fail-closed 报错不对: {err}")


def test_stop_idempotent(client: DaemonClient):
    resp = client.request("stop")
    if not resp.get("ok"):
        raise Failure(f"已断开时 stop 应幂等成功: {resp.get('message')}")


TIER_A_TESTS = [
    ("初始状态事件", test_initial_status_event, False),
    ("daemon-info", test_daemon_info, False),
    ("status 查询", test_status_query, False),
    ("未知命令拒绝", test_unknown_command, False),
    ("非法 profile 同步拒绝", test_invalid_profile_rejected, True),
    ("悬空引用 fail-closed", test_dangling_ref_fail_closed, True),
    ("旧 key 兼容层 + fail-closed", test_old_key_compat_fail_closed, True),
    ("stop 幂等", test_stop_idempotent, True),
]


def run_tier_a(socket_path: str) -> int:
    print("\n===== Tier A: 协议层 =====")
    failed = 0
    for name, fn, mutates in TIER_A_TESTS:
        client = DaemonClient(socket_path)
        try:
            if mutates:
                # 只有引擎空闲时才发 start/stop 类命令，绝不打扰进行中的会话
                first = client.next_event(timeout=5)
                st = json.loads((first or {}).get("data", "{}")).get("status")
                if st != "disconnected":
                    print(f"  跳过 [{name}]: 引擎状态 {st}，不打扰")
                    continue
            fn(client)
            print(f"  ✓ {name}")
        except Failure as e:
            print(f"  ✗ {name}: {e}")
            failed += 1
        except Exception as e:  # noqa: BLE001 —— 单测崩溃不拖垮整轮
            print(f"  ✗ {name}: 异常 {type(e).__name__}: {e}")
            failed += 1
        finally:
            client.close()
    return failed


# ---------------------------------------------------------------------------
# Tier B：真实路径。真实 profile + vault 密码，真连接、真断言、真还原。
# ---------------------------------------------------------------------------

def load_real_profile() -> dict:
    out = run(["defaults", "export", DEFAULTS_DOMAIN, "-"], timeout=10)
    if out.returncode != 0:
        raise Failure(f"读取 defaults 失败: {out.stderr.strip()}")
    plist = plistlib.loads(out.stdout.encode())
    raw = plist.get(PROFILE_KEY)
    if raw is None:
        raise Failure(f"defaults 里没有 {PROFILE_KEY}")
    if isinstance(raw, str):
        raw = raw.encode()
    return json.loads(raw)


def inject_vault_passwords(profile: dict) -> int:
    """按 AppState.loadSaved 的映射把 vault 密码注回 profile。返回注入条数。"""
    if not VAULT_PATH.exists():
        return 0
    vault = json.loads(VAULT_PATH.read_text())
    suffix_field = {
        "vpn": "vpn_password",
        "trojan": "trojan_password",
        "ss": "ss_password",
        "vmess": "vmess_uuid",
        "tsauth": "tailscale_auth_key",
    }
    injected = 0
    for line in profile.get("lines", []):
        for suffix, field in suffix_field.items():
            v = vault.get(f"{line['id']}-{suffix}")
            if v:
                line[field] = v
                injected += 1
    for sub in profile.get("subscriptions", []):
        for line in sub.get("lines", []):
            for suffix, field in suffix_field.items():
                v = vault.get(f"{sub['id']}-{line['id']}-{suffix}")
                if v:
                    line[field] = v
                    injected += 1
    return injected


def pick_vpn_probe_domain(profile: dict) -> Optional[str]:
    """从活动模式里找一个绑定到 VPN 线路的手动规则域名（内网可达性探针）。"""
    mode = next((m for m in profile.get("modes", [])
                 if m["id"] == profile.get("active_mode_id")), None)
    if mode is None:
        return None
    lines = {l["id"]: l for l in profile.get("lines", [])}
    rulesets = {r["id"]: r for r in profile.get("rule_sets", [])}
    for binding in mode.get("bindings", []):
        line = lines.get(binding.get("line_id", ""))
        rs = rulesets.get(binding.get("rule_set_id", ""))
        if not line or not rs:
            continue
        if (line.get("type") == "vpn" and line.get("enabled")
                and rs.get("type") == "manual" and rs.get("enabled")):
            for domain in rs.get("domains", []):
                d = domain.strip().lstrip(".")
                if d:
                    return d
    return None


def network_services() -> list:
    out = run(["/usr/sbin/networksetup", "-listallnetworkservices"], timeout=10)
    services = []
    for line in out.stdout.splitlines()[1:]:  # 首行是说明文字
        line = line.strip()
        if line and not line.startswith("*"):  # * 前缀 = 已禁用
            services.append(line)
    return services


def dns_servers(service: str) -> list:
    out = run(["/usr/sbin/networksetup", "-getdnsservers", service], timeout=10)
    servers = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if re.match(r"^[0-9a-fA-F.:]+$", line):
            servers.append(line)
    return servers  # 空 = 未设置（DHCP 下发）


def singbox_pids() -> set:
    out = run(["pgrep", "-f", "sing-box"], timeout=10)
    return {p for p in out.stdout.split() if p.isdigit()}


def curl_code(url: str, timeout: int = 15, insecure: bool = False) -> str:
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
           "--max-time", str(timeout)]
    if insecure:
        cmd.append("-k")
    cmd.append(url)
    out = run(cmd, timeout=timeout + 5)
    return out.stdout.strip() or "000"


def resolve_ok(name: str) -> bool:
    """走系统解析路径（dscacheutil），验证当前 DNS 配置真的答得了查询。"""
    try:
        out = run(["dscacheutil", "-q", "host", "-a", "name", name], timeout=8)
    except subprocess.TimeoutExpired:
        return False
    return "ip_address" in out.stdout or "ipv6_address" in out.stdout


def check_repo_freshness(client: DaemonClient, require_fresh: bool) -> None:
    info = json.loads(client.request("daemon-info")["data"])
    describe = run(["git", "describe", "--tags", "--always", "--dirty"],
                   timeout=10).stdout.strip()
    print(f"  daemon 版本: {info['version']} (pid {info['pid']})")
    print(f"  仓库版本:   {describe or '未知'}")
    if describe and info["version"] != describe:
        msg = (f"daemon 版本 {info['version']} ≠ 仓库 {describe}，"
               "验收结果不代表当前代码（用 make restart 让 helper 自愈到新二进制）")
        if require_fresh:
            raise Failure(msg)
        print(f"  ⚠ {msg}")


def run_tier_b(socket_path: str, require_fresh: bool) -> int:
    print("\n===== Tier B: 真实路径 =====")
    profile = load_real_profile()
    injected = inject_vault_passwords(profile)
    probe_domain = pick_vpn_probe_domain(profile)
    mode = next((m for m in profile.get("modes", [])
                 if m["id"] == profile.get("active_mode_id")), None)
    if mode is None:
        raise Failure("真实 profile 没有活动模式")
    print(f"  活动模式: {mode.get('name')}，注入密码 {injected} 条，"
          f"内网探针: {probe_domain or '无（跳过该断言）'}")

    client = DaemonClient(socket_path)
    failed = 0
    started = False
    try:
        check_repo_freshness(client, require_fresh)

        first = client.next_event(timeout=5)
        st = json.loads((first or {}).get("data", "{}")).get("status")
        if st != "disconnected":
            raise Failure(f"引擎状态 {st}，不在断开态，拒绝开始真实验收")

        pre_pids = singbox_pids()
        services = network_services()
        pre_dns = {s: dns_servers(s) for s in services}
        if any(DNS_TAKEOVER_ADDR in v for v in pre_dns.values()):
            raise Failure(f"连接前系统 DNS 已有 {DNS_TAKEOVER_ADDR} 残留，先修复再验收")

        print("  → start（真实 profile）")
        resp = client.request("start", profile=json.dumps(profile))
        if not resp.get("ok"):
            raise Failure(f"start 被拒绝: {resp.get('message')}")
        started = True
        client.wait_status("connected", CONNECT_TIMEOUT)
        print("  ✓ 已连接")
        time.sleep(2)  # 数据面/DNS 接管落稳

        def check(name: str, fn: Callable[[], None]):
            nonlocal failed
            try:
                fn()
                print(f"  ✓ {name}")
            except Failure as e:
                print(f"  ✗ {name}: {e}")
                failed += 1

        def assert_dns_taken_over():
            now = {s: dns_servers(s) for s in services}
            taken = [s for s, v in now.items() if DNS_TAKEOVER_ADDR in v]
            if not taken:
                raise Failure(f"没有任何网络服务的 DNS 指向 {DNS_TAKEOVER_ADDR}: {now}")

        def assert_resolution():
            if not resolve_ok("www.apple.com"):
                raise Failure("连接态下系统解析不可用")

        def assert_default_line():
            code = curl_code("https://www.apple.com")
            if code not in ("200", "301", "302"):
                raise Failure(f"默认线路不可达，HTTP {code}")

        def assert_vpn_probe():
            code = curl_code(f"https://{probe_domain}", insecure=True)
            if code == "000":
                raise Failure(f"VPN 绑定域名 {probe_domain} 不可达（HTTP 000）")

        def assert_dataplane_process():
            if not (singbox_pids() - pre_pids):
                raise Failure("连接态下找不到新增的 sing-box 数据面进程")

        check("系统 DNS 已接管", assert_dns_taken_over)
        check("连接态解析可用", assert_resolution)
        check("默认线路可达", assert_default_line)
        if probe_domain:
            check(f"VPN 域名可达 ({probe_domain})", assert_vpn_probe)
        check("数据面进程存在", assert_dataplane_process)

        print("  → stop")
        resp = client.request("stop", timeout=DISCONNECT_TIMEOUT)
        if not resp.get("ok"):
            raise Failure(f"stop 失败: {resp.get('message')}")
        started = False
        client.wait_status("disconnected", DISCONNECT_TIMEOUT, fail_on_error=False)
        print("  ✓ 已断开")
        time.sleep(2)  # DNS 还原落稳

        def assert_dns_restored():
            now = {s: dns_servers(s) for s in services}
            leftover = [s for s, v in now.items() if DNS_TAKEOVER_ADDR in v]
            if leftover:
                raise Failure(f"断开后 DNS 未还原: {leftover}")

        def assert_resolution_after():
            if not resolve_ok("www.apple.com"):
                raise Failure("断开后系统解析不可用")

        def assert_no_orphans():
            orphans = singbox_pids() - pre_pids
            if orphans:
                raise Failure(f"断开后残留 sing-box 进程: {orphans}")

        def assert_reachable_after():
            code = curl_code("https://www.apple.com")
            if code not in ("200", "301", "302"):
                raise Failure(f"断开后网络不可达，HTTP {code}")

        check("系统 DNS 已还原", assert_dns_restored)
        check("断开后解析可用", assert_resolution_after)
        check("无残留数据面进程", assert_no_orphans)
        check("断开后网络可达", assert_reachable_after)
        return failed
    finally:
        if started:
            # 任何失败路径都不许把机器留在连接态
            try:
                client.request("stop", timeout=DISCONNECT_TIMEOUT)
                client.wait_status("disconnected", DISCONNECT_TIMEOUT,
                                   fail_on_error=False)
                print("  （清理：已断开）")
            except Exception as e:  # noqa: BLE001
                print(f"  ⚠ 清理失败，请手动断开: {e}")
        client.close()


def main():
    parser = argparse.ArgumentParser(description="XDial 端到端验收测试")
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--tier", choices=["a", "b", "all"], default="all")
    parser.add_argument("--require-fresh", action="store_true",
                        help="daemon 版本与仓库不一致时判失败")
    args = parser.parse_args()

    try:
        probe = DaemonClient(args.socket)
        probe.close()
    except OSError as e:
        print(f"daemon 不可达（{args.socket}）: {e}")
        print("请先启动 helper daemon（安装版由 launchd 托管；"
              "开发版可 build/xdial daemon -socket /tmp/xdial-test.sock）")
        sys.exit(2)

    failed = 0
    if args.tier in ("a", "all"):
        failed += run_tier_a(args.socket)
    if args.tier in ("b", "all"):
        try:
            failed += run_tier_b(args.socket, args.require_fresh)
        except Failure as e:
            if args.tier == "b":
                print(f"  ✗ Tier B 中止: {e}")
                failed += 1
            else:
                print(f"\nTier B 跳过: {e}")

    if failed:
        print(f"\n✗ {failed} 项失败")
        sys.exit(1)
    print("\n✓ 全部通过")


if __name__ == "__main__":
    main()
