#!/usr/bin/env python3
"""XDial 端到端测试：通过 Unix socket 直接驱动 helper，验证连接/分流。

用法:
    python3 test/e2e_test.py

需要 helper 已经通过 launchd 在运行（/tmp/xdial.sock 可达），
VPN 密码从 Keychain 读取。
"""
import json
import socket
import subprocess
import sys
import time
from typing import Optional

SOCKET_PATH = "/tmp/xdial.sock"


def get_vpn_password() -> str:
    for account in ["xdial-port-vpn-vpn", "xdial-exit-vpn-vpn", "xdial-vpn"]:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "com.kafeifei.xdial",
             "-a", account, "-w"],
            capture_output=True, text=True, timeout=5
        )
        if out.returncode == 0:
            return out.stdout.strip()
    return ""


def make_profile(password: str) -> dict:
    return {
        "ports": [
            {"id": "direct", "name": "直连", "type": "direct", "enabled": True},
            {"id": "vpn", "name": "VPN", "type": "vpn", "enabled": True,
             "vpn_server": "vpn.example.com:8443",
             "vpn_username": "kafeifei",
             "vpn_password": password},
        ],
        "cargoes": [
            {"id": "internal", "name": "内部域名", "type": "manual", "enabled": True,
             "domains": ["example.com", "example.net", "example.org"]},
        ],
        "cruises": [
            {"id": "test", "name": "测试",
             "bindings": [{"cargo_id": "internal", "port_id": "vpn"}],
             "default_port_id": "direct"},
        ],
        "active_cruise_id": "test",
    }


class HelperClient:
    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCKET_PATH)
        self.sock.settimeout(30)

    def send(self, cmd: dict):
        self.sock.sendall((json.dumps(cmd) + "\n").encode())

    def recv_until(self, predicate, timeout: int = 25) -> Optional[dict]:
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            self.sock.settimeout(max(0.1, deadline - time.time()))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                return None
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                msg = json.loads(line)
                print(f"  ← {line.decode()}")
                if predicate(msg):
                    return msg
        return None

    def close(self):
        self.sock.close()


def wait_status(client: HelperClient, target: str, timeout: int = 25) -> bool:
    def matches(msg):
        if msg.get("type") != "status":
            return False
        data = json.loads(msg.get("data", "{}"))
        return data.get("status") == target
    return client.recv_until(matches, timeout) is not None


def test_connect_disconnect(password: str):
    print("\n=== test_connect_disconnect ===")
    client = HelperClient()
    try:
        profile = make_profile(password)
        print("→ start")
        client.send({"cmd": "start", "profile": json.dumps(profile)})
        assert wait_status(client, "connected", 25), "did not reach connected"
        print("✓ connected")

        time.sleep(2)

        print("→ stop")
        client.send({"cmd": "stop"})
        assert wait_status(client, "disconnected", 10), "did not reach disconnected"
        print("✓ disconnected")
    finally:
        client.close()


def test_routing(password: str):
    print("\n=== test_routing ===")
    client = HelperClient()
    try:
        profile = make_profile(password)
        print("→ start")
        client.send({"cmd": "start", "profile": json.dumps(profile)})
        assert wait_status(client, "connected", 25), "did not reach connected"

        time.sleep(2)

        # 内部域名应该走 VPN（202 是 example.com 的常见返回，或 200/302）
        print("→ curl example.com (应走 VPN)")
        r = subprocess.run(
            ["curl", "-s", "--max-time", "10", "-o", "/dev/null", "-w", "%{http_code}",
             "https://www.example.com"],
            capture_output=True, text=True
        )
        print(f"  HTTP {r.stdout}")
        assert r.stdout in ("200", "301", "302"), f"example.com 不可达: {r.stdout}"

        # baidu 直连
        print("→ curl baidu.com (应直连)")
        r = subprocess.run(
            ["curl", "-s", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}",
             "https://www.baidu.com"],
            capture_output=True, text=True
        )
        print(f"  HTTP {r.stdout}")
        assert r.stdout == "200", f"baidu.com 不可达: {r.stdout}"

        print("✓ 分流正确")

        client.send({"cmd": "stop"})
        wait_status(client, "disconnected", 10)
    finally:
        client.close()


def main():
    password = get_vpn_password()
    if not password:
        print("找不到 VPN 密码，请先在 app 里设置")
        sys.exit(1)

    test_connect_disconnect(password)
    test_routing(password)
    print("\n所有测试通过")


if __name__ == "__main__":
    main()
