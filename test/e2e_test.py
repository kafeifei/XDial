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
      同源性：对活动模式里每条基于域名的绑定，断言「同一域名的路由出口与
              DNS 应答来源一致」（ARCHITECTURE.md §4.1 因果链 / INV7 的运行时版）：
              - DNS 侧：向名义公网解析器发查询必须被盒内应答（hijack-dns），
                且名义服务器换成接管地址答案不变；VPN 绑定的内网名，应答
                必须落在同一绑定的 CIDR 内——只有经该线路的企业 DNS 能给出
                这样的答案，这就是「应答来源」的行为学归属
              - 路由侧：真连该域名并保持连接，从 Clash API /connections 按
                本端源端口找到这条连接（结构化接口，非日志抓取），其出口链
                末端必须是同一线路；探针目标优先取 CIDR 外应答（域名归属）
              直连默认出口只验路由侧（direct 不声明解析器，INV7 显式豁免），
              判据是 rule=="final" 的探针域名出口链末端等于默认出口 tag
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
import http.client
import ipaddress
import json
import plistlib
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Callable, Optional

DEFAULT_SOCKET = "/tmp/xdial.sock"
DEFAULTS_DOMAIN = "com.kafeifei.xdial"
PROFILE_KEY = "xdial.profile"
VAULT_PATH = Path.home() / ".xdial" / "vault.json"
# 与 core/engine/dns_takeover.go 的 dnsTakeoverAddress 一致
DNS_TAKEOVER_ADDR = "198.18.0.2"
# 与 core/config/generator.go 的 clashAPIController 一致（仅桌面数据面开启）
CLASH_API = "http://127.0.0.1:9090"
# 与 core/config/generator.go 的 testDomains 一致（桌面诊断规则的探测域名，
# 会被前置系统规则导向 test-out selector，不能用作归属探针；改那边须同步）
TEST_DOMAINS = ["ip.sb", "ipinfo.io", "ip-api.com"]

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
                d = domain.strip()
                # 带前导点的条目只匹配子域名（sing-box domain_suffix 语义），
                # 剥点探测裸域名会假失败，跳过
                if d and not d.startswith(".") and re.fullmatch(r"[A-Za-z0-9.-]+", d):
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


# ---------------------------------------------------------------------------
# 同源性断言：同一域名的路由出口与 DNS 应答来源必须一致。
#
# 这是 ARCHITECTURE.md §4.1 因果链（名字→线路→地址）/ INV7 的运行时版：
# INV7 在生成阶段保证 route 规则与 dns 规则从同一份 mode.Bindings 编译，
# 这里在真实数据面上验证编译产物确实按同一归属生效——流量走 A 线路而解析
# 走 B 线路（漂移）时，得到的地址在 A 那头根本不通，且配置里看不出问题。
#
# 观测手段都是结构化接口，不抓日志（架构约束禁止事项 6 的同款纪律）：
#   路由侧   Clash API /connections 的 chains 字段（连接的出口链归属）
#   DNS 侧   真实 DNS 查询的行为学差分——密封盒下 hijack-dns 把发往任意名义
#            服务器的查询都拦在盒内，由 DNS 规则链选应答者。内网名的应答落在
#            绑定 CIDR 内 ⟺ 应答出自经该线路的企业 DNS（公网解析器既无记录
#            也不可能给出内网地址）。
# DNS 应答来源的归属证据分三级（依可观测性递进，测试输出里注明达到了哪级）：
#   E1 盒内应答不变性（硬断言）——@8.8.8.8 与 @198.18.0.2 两个名义服务器的答案
#      必须一致且非空。198.18.0.2 上没有任何真实服务器，能应答者只有盒内规则链；
#      答案一致证明 @8.8.8.8 的查询同样被拦在盒内（hijack 失效时两者必然不相交）。
#   E2 上游查询的出口链归属（可观测则硬断言）——若 Clash API 连接表里能看到
#      53 端口（企业 DNS）/ DoH 上游连接，其 chains 必须含绑定线路的 tag。
#   E3 应答落在绑定 CIDR 内（机会性强证据）——命中即为最强归属（公网解析器
#      不可能给出内网地址）；真实规则集里的域名多为「经 VPN 访问的公网站点」，
#      企业 DNS 对它们也返回公网 IP，故 E3 缺席不判失败，只降级提示。
# ---------------------------------------------------------------------------

def clash_get(path: str) -> dict:
    """读桌面数据面的 Clash API（只在连接态存在，只绑回环）。

    异常覆盖注意：OSError 才能罩住全版本的 socket.timeout / URLError /
    ConnectionError（Python 3.9 的 socket.timeout 不是 TimeoutError 子类，
    且 getresponse/read 阶段的超时不会被 urllib 包成 URLError）；
    HTTPException 罩住 IncompleteRead / RemoteDisconnected。
    """
    try:
        with urllib.request.urlopen(CLASH_API + path, timeout=5) as resp:
            return json.loads(resp.read())
    except (OSError, http.client.HTTPException, json.JSONDecodeError) as e:
        raise Failure(f"Clash API {path} 不可达: {e}")


def dig_short(name: str, nominal_server: str) -> list:
    """向指定名义服务器发 A 查询，返回应答 IP 列表。

    连接态下这个查询必然被 hijack-dns 拦在盒内——nominal_server 只是包上写的
    地址，真正的应答者由 sing-box DNS 规则链（mode.Bindings 编译产物）决定。
    """
    try:
        out = run(["dig", "+short", "+time=3", "+tries=1",
                   f"@{nominal_server}", name, "A"], timeout=10)
    except subprocess.TimeoutExpired:
        return []
    ips = []
    for line in out.stdout.splitlines():
        line = line.strip()
        try:
            ipaddress.ip_address(line)
            ips.append(line)
        except ValueError:
            continue  # CNAME 等非地址行
    return ips


def hold_connection(host: str, ip: str, use_tls: bool) -> socket.socket:
    """连到 ip:443 并保持连接打开，让它出现在 /connections 里。

    TLS 模式发真实 ClientHello（带 SNI），sniff 拿到域名后路由按域名归属，
    /connections 的 host 字段也会是这个域名；证书不校验——要的是路由归属，
    不是对端身份。裸 TCP 模式不发数据，sniff 超时后按目的 IP 归属。
    """
    sock = socket.create_connection((ip, 443), timeout=8)
    if not use_tls:
        return sock
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx.wrap_socket(sock, server_hostname=host)
    except (ssl.SSLError, OSError):
        try:
            sock.close()
        except OSError:
            pass
        raise


def connection_entry(source_port: int) -> Optional[dict]:
    """在 /connections 快照里按本端源端口找到**我们自己的**那条连接。

    不按 host / 目的 IP 匹配：连接表里有全系统的连接，浏览器到同一 CDN IP
    的长连接会顶包（审查实证：裸 TCP 时 sniff 无 host，目的 IP 撞车必然取错）。
    tun 记录的是 NAT 前的原始源端口，与 getsockname() 一致。
    """
    snapshot = clash_get("/connections")
    for conn in snapshot.get("connections") or []:
        meta = conn.get("metadata") or {}
        if str(meta.get("sourcePort", "")) == str(source_port):
            return conn
    return None


def route_probe(host: str, ip: str, allow_plain_tcp: bool) -> tuple:
    """真连 host（ip:443）并读出这条连接的 (出口链, 命中规则)。

    路由裁决选中的 tag 是 chains 的**末元素**（tracker 构链后 Reverse，
    首元素是嵌套组展开的叶子）；rule 字段未命中任何规则时是字符串 "final"
    ——这是判定「该连接落在默认出口」的结构化依据。

    TLS 模式发真实 ClientHello（带 SNI），路由按域名归属；裸 TCP 不发数据，
    sniff 超时后只能按目的 IP 归属——所以仅当调用方明确说「按 IP 归属也
    成立」（目标 IP 落在同绑定 CIDR 内）时才允许退回裸 TCP。
    """
    last_error = "未尝试"
    modes = (True, False) if allow_plain_tcp else (True,)
    for use_tls in modes:
        try:
            held = hold_connection(host, ip, use_tls)
        except (OSError, ssl.SSLError) as e:
            last_error = f"{'TLS' if use_tls else 'TCP'} 连接失败: {e}"
            continue
        try:
            source_port = held.getsockname()[1]
            deadline = time.time() + 6
            while time.time() < deadline:
                conn = connection_entry(source_port)
                if conn and conn.get("chains"):
                    return conn["chains"], str(conn.get("rule", ""))
                time.sleep(0.4)
            last_error = f"{'TLS' if use_tls else 'TCP'} 连接建立但 /connections 里找不到"
        finally:
            try:
                held.close()
            except OSError:
                pass
    raise Failure(f"无法取得 {host}（{ip}:443）的路由出口链——{last_error}")


def line_outbound_tag(line: dict) -> str:
    """线路 → outbound tag 的命名映射，与 core/config/generator.go 的
    resolveOutboundTag 逐分支镜像（Python 测试进不了 Go 包，只能对齐这份
    4 行映射；改那边必须同步这里）。else 分支与 Go 侧 default 同构：一切
    其余类型都是 proxy-<id>。订阅出口的组名要过 slugify，本函数不处理
    ——调用方对订阅绑定一律先行跳过。"""
    line_type = line.get("type")
    if line_type == "direct":
        return "direct"
    if line_type == "vpn":
        return "vpn"
    if line_type == "tailscale":
        return "tailscale-" + line["id"]
    return "proxy-" + line["id"]


def active_mode(profile: dict) -> Optional[dict]:
    return next((m for m in profile.get("modes", [])
                 if m["id"] == profile.get("active_mode_id")), None)


def build_consistency_probes(profile: dict) -> list:
    """把活动模式里「基于域名的绑定」编译成同源性探针清单。

    输入源刻意与生成器相同（mode.Bindings），覆盖范围与 INV7 的收窄语义一致：
    只看域名绑定；direct / tailscale 豁免（前者不声明解析器，后者的 tailnet
    名字在静态配置里没有域名列表）；URL 规则集的域名在远端 .srs 里，测试侧
    无法枚举，跳过（route 侧与 dns 侧引用的本就是同一份 rule_set 资源，
    静态一致性由 INV7 守护）。
    """
    mode = active_mode(profile)
    if mode is None:
        return []
    lines = {l["id"]: l for l in profile.get("lines", [])}
    rulesets = {r["id"]: r for r in profile.get("rule_sets", [])}
    probes = []
    for binding in mode.get("bindings", []):
        if binding.get("subscription_id"):
            continue  # 订阅出口的组 tag 经 slugify，测试侧不复刻命名规则
        line = lines.get(binding.get("line_id", ""))
        ruleset = rulesets.get(binding.get("rule_set_id", ""))
        if not line or not ruleset:
            continue
        if not (line.get("enabled") and ruleset.get("enabled")):
            continue
        if ruleset.get("type") != "manual":
            continue
        if line.get("type") in ("direct", "tailscale"):
            continue
        domains = []
        for raw in ruleset.get("domains", []):
            cleaned = raw.strip()
            if not cleaned:
                continue
            if cleaned.startswith("."):
                # 生成器原样写入 domain_suffix，sing-box 对带前导点的条目只
                # 匹配子域名、不匹配裸域名——剥点探测裸域名会得到假失败。跳过。
                print(f"  – 规则集 {ruleset.get('name')} 条目 {raw!r} 带前导点"
                      f"（仅匹配子域名），跳过该条探测")
                continue
            if not re.fullmatch(r"[A-Za-z0-9.-]+", cleaned):
                # 例如混入控制字符的条目：不修复、不沉默——这样的 domain_suffix
                # 在数据面永远匹配不中，用户以为绑定了实际没绑上
                print(f"  ⚠ 规则集 {ruleset.get('name')} 含非法域名条目 {raw!r}，"
                      f"该条绑定在数据面不会生效")
                continue
            if any(cleaned == t or cleaned.endswith("." + t) for t in TEST_DOMAINS):
                # 与桌面诊断规则（testDomains → test-out）撞车的域名会被前置
                # 系统规则截走，不适合做归属探针
                continue
            domains.append(cleaned)
        if not domains:
            continue
        probes.append({
            "ruleset": ruleset.get("name", ruleset.get("id", "?")),
            "domains": domains,
            "line_type": line.get("type"),
            "tag": line_outbound_tag(line),
            "cidrs": [c for c in ruleset.get("cidrs", []) if c],
        })
    return probes


def dns_upstream_chains(tag: str) -> list:
    """证据 E2：在连接表里找疑似 DNS 上游连接（企业 DNS 的 :53 / DoH 的
    1.1.1.1:443，见 generator.go buildDNS），返回它们的出口链列表。
    观测不到返回空（sing-box 是否把 DNS 上游计入连接表不属于我们的契约）。"""
    try:
        snapshot = clash_get("/connections")
    except Failure:
        return []
    chains = []
    for conn in snapshot.get("connections") or []:
        meta = conn.get("metadata") or {}
        port = str(meta.get("destinationPort", ""))
        is_plain_dns = port == "53"
        is_doh = port == "443" and meta.get("destinationIP") == "1.1.1.1"
        if not (is_plain_dns or is_doh):
            continue
        chain = conn.get("chains") or []
        if tag in chain:
            chains.append(chain)
    return chains


def assert_route_dns_agree(probe: dict) -> None:
    """同一批域名（一条绑定）：路由出口与 DNS 应答来源必须归属同一条线路。

    扫描绑定的域名列表（上限 8 个）而不是只看第一个：真实规则集里 apex 域名
    往往是公网可解析的（split-horizon），单点判定既会误红也会漏放。
    """
    tag = probe["tag"]
    networks = [ipaddress.ip_network(c, strict=False) for c in probe["cidrs"]]

    resolved = []       # (domain, answers)
    in_cidr_pick = None  # (domain, ip) —— E3 强归属候选
    for domain in probe["domains"][:8]:
        answer_public = dig_short(domain, "8.8.8.8")
        if not answer_public:
            continue  # 该域名在当前视角无 A 记录，换下一个
        answer_takeover = dig_short(domain, DNS_TAKEOVER_ADDR)
        # E1：两个名义服务器的答案必须相交。198.18.0.2 上没有真实服务器，
        # 应答只可能来自盒内；不相交 = @8.8.8.8 的查询漏出了盒（hijack 失效）
        # 或盒内应答者不唯一。这是硬断言，一个域名违反即失败。
        if not set(answer_public) & set(answer_takeover):
            # 附带路由侧参考再报错：漂移的本质是两侧不一致，
            # 两侧的观测都给出来才好归因（例如叠罗汉场景是路由被抢，不是 DNS 配错）
            try:
                chain, rule_str = route_probe(domain, answer_public[0], False)
                route_ref = f"路由侧参考：出口链 {chain}，命中规则 {rule_str!r}"
            except Failure as route_err:
                route_ref = f"路由侧参考：{route_err}"
            raise Failure(
                f"{domain} 换名义服务器答案不相交（hijack 失效或应答者漂移）："
                f"@8.8.8.8={answer_public} @{DNS_TAKEOVER_ADDR}={answer_takeover}；{route_ref}")
        resolved.append((domain, answer_public))
        if in_cidr_pick is None:
            for ip in answer_public:
                if any(ipaddress.ip_address(ip) in n for n in networks):
                    in_cidr_pick = (domain, ip)
                    break

    if not resolved:
        raise Failure(
            f"绑定 {probe['ruleset']} 的域名（前 8 个）无一可解析——"
            f"该绑定的 DNS 分支整体不可用（漂移到 NXDOMAIN 路径或 SERVFAIL）")

    # E2：上游 DNS 连接的出口链归属（刚触发过真实查询，若 sing-box 把 DNS
    # 上游计入连接表，此刻应能看到）。观测到即为结构化硬证据。
    upstream = dns_upstream_chains(tag)

    dns_evidence = "E1 盒内应答不变性"
    if upstream:
        dns_evidence += f" + E2 上游出口链 {upstream[0]}"
    if in_cidr_pick:
        dns_evidence += f" + E3 内网应答 {in_cidr_pick[0]}→{in_cidr_pick[1]}"
    if not in_cidr_pick and not upstream:
        print(f"    （{probe['ruleset']}：应答来源仅达弱归属 E1——"
              f"域名均解析为公网 IP 且未观测到上游 DNS 连接）")

    # --- 路由侧 ---
    # 探针目标刻意优先选 CIDR **外**的应答：绑定规则同时携带 domain_suffix
    # 与 ip_cidr，CIDR 内的目标无论域名分支死活都会命中 ip_cidr 半边——只有
    # 「CIDR 外目标 + 带 SNI 的 TLS」才真正行使按域名归属（审查实证：否则
    # domain_suffix 路由分支丢失检不出）。全部应答都在 CIDR 内时才退回
    # IP 归属，并在输出里降级注明。
    attempts = []  # (域名, 目标 IP, 归属级别, 允许裸 TCP 兜底)
    for domain, answers in resolved:
        out_of_cidr = [ip for ip in answers
                       if not any(ipaddress.ip_address(ip) in n for n in networks)]
        if out_of_cidr:
            attempts.append((domain, out_of_cidr[0], "域名归属", False))
            break
    if in_cidr_pick:
        # 裸 TCP 只在目标落在绑定 CIDR 内时才允许：无 SNI 时按 IP 归属成立
        attempts.append((in_cidr_pick[0], in_cidr_pick[1], "IP 归属", True))

    chain, rule_str, route_domain, route_grade = None, "", "", ""
    route_errors = []
    for domain, ip, grade, allow_tcp in attempts:
        try:
            chain, rule_str = route_probe(domain, ip, allow_tcp)
            route_domain, route_grade = domain, grade
            break
        except Failure as e:
            route_errors.append(str(e))
    if chain is None:
        raise Failure(f"路由探针全部失败: {' ; '.join(route_errors)}")
    if chain[-1] != tag:
        raise Failure(
            f"{route_domain} 的路由出口链 {chain}（命中规则 {rule_str!r}）"
            f"末端不是期望线路 {tag}——路由与 DNS 归属漂移（流量走 A、解析走 B）；"
            f"DNS 侧证据：{dns_evidence}")
    if route_grade != "域名归属":
        print(f"    （{probe['ruleset']}：路由侧仅达 IP 归属——全部应答都在绑定 CIDR 内）")
    print(f"    （{probe['ruleset']}：路由出口 {chain}（{route_grade}）↔ DNS {dns_evidence}）")


def assert_default_line_chain(default_tag: str) -> None:
    """默认出口（route.final）的路由归属。

    「未绑定域名」不能靠假设——热门域名常被模式 URL 规则集 / 订阅自带规则
    截走（此时断言的是那条规则而不是 final，若出口同名就恒绿假测）。判据用
    结构化的 rule 字段：未命中任何规则时它就是字符串 "final"。被截走则换
    备选域名，全部被截走时可见跳过，不产出假绿。出口比对用 chains 末元素
    （末元素才是路由裁决选中的 tag，`in` 会把嵌套组成员误判为命中）。
    （direct 不声明解析器，DNS 侧按 INV7 豁免，不做来源归属。）"""
    candidates = ["www.apple.com", "example.com", "www.bing.com"]
    intercepted, unresolvable = [], []
    for domain in candidates:
        answers = dig_short(domain, DNS_TAKEOVER_ADDR)
        if not answers:
            unresolvable.append(domain)
            continue
        chain, rule_str = route_probe(domain, answers[0], allow_plain_tcp=False)
        if rule_str != "final":
            intercepted.append(f"{domain}（被 {rule_str!r} 截走）")
            continue
        if chain[-1] != default_tag:
            raise Failure(
                f"{domain} 落在 route.final，但出口链 {chain} 末端不是默认出口 {default_tag}")
        print(f"    （默认出口探针 {domain}：rule=final，出口链 {chain}）")
        return
    if not intercepted:
        # 全部候选连 DNS 应答都拿不到：这不是“探针不适用”，是接管地址上的
        # DNS 面已不可用——本身就是缺陷，必须红
        raise Failure(f"默认出口探针候选 {candidates} 经 {DNS_TAKEOVER_ADDR} 均无应答"
                      f"——接管地址上的 DNS 面不可用")
    print(f"    – 默认出口探针域名全部被前置规则截走：{'；'.join(intercepted + unresolvable)}"
          f"——该 profile 下无法构造 final 探针，跳过（非通过）")


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

        # --- 同源性：同一域名的路由出口与 DNS 应答来源一致（INV7 运行时版）---
        def assert_clash_api_up():
            version = clash_get("/version")
            if not version.get("version"):
                raise Failure(f"Clash API /version 返回异常: {version}")

        check("Clash API 可达", assert_clash_api_up)
        probes = build_consistency_probes(profile)
        if not probes:
            print("  – 同源性：活动模式没有可探测的域名绑定（手动规则集），跳过")
        for consistency_probe in probes:
            check(f"同源性 {consistency_probe['ruleset']} → {consistency_probe['tag']}",
                  lambda p=consistency_probe: assert_route_dns_agree(p))
        # 默认出口的期望值复刻生成器口径（generator.go 默认出口段）：
        # DefaultSubscriptionID 优先于 DefaultLineID；线路须存在且 enabled，
        # 否则 final 回落 "direct"。残余口径差：enabled 但参数不全的代理线路
        # 也会回落 direct（lineHasUsableOutbound），测试侧不复刻——vault
        # 注入后现实中不出现。
        if mode.get("default_subscription_id"):
            print("  – 默认出口是订阅组（tag 经 slugify 生成，测试侧不复刻），跳过出口链断言")
        else:
            default_line = next((l for l in profile.get("lines", [])
                                 if l["id"] == mode.get("default_line_id")), None)
            if default_line is not None and default_line.get("enabled"):
                default_tag = line_outbound_tag(default_line)
            else:
                default_tag = "direct"
                print("  – 默认线路缺失或已禁用，按生成器口径断言 final 回落 direct")
            check(f"默认出口 route.final → {default_tag}",
                  lambda t=default_tag: assert_default_line_chain(t))

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
