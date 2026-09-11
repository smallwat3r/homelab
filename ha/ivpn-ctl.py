#!/usr/bin/env python3
"""Controls the IVPN tunnel. Forced command for Home Assistant's ssh key,
the only thing that key can run, and usable directly on ha:
  ivpn-ctl start|stop|status   on, the exit node goes through IVPN, off,
                               straight out through the router. status
                               exits non-zero when the tunnel is down,
                               which is how the HA switch reads it
  ivpn-ctl server              print the current server (gateway code
                               from IVPN's server list, fr, gb, ch...)
  ivpn-ctl server CODE         move the peer to that server's least
                               loaded host and restart the tunnel if up
The key pair in the config is account wide, only the peer changes."""

import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any

CONF = "/etc/wireguard/ivpn.conf"
CACHE = Path.home() / ".cache/ivpn-servers.json"
API = "https://api.ivpn.net/v5/servers.json"
UNIT = "wg-quick@ivpn"

Server = dict[str, Any]


# a failed command aborts with its error, like set -e would, unless the
# caller says otherwise
def sudo(*args: str, check: bool = True, **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["sudo", *args], text=True, check=check, **kwargs)


def read_conf() -> str:
    return sudo("cat", CONF, capture_output=True).stdout


def servers(refresh: bool = False) -> list[Server]:
    if refresh or not CACHE.is_file() or CACHE.stat().st_size == 0:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(API, timeout=30) as res:
            CACHE.write_bytes(res.read())
    wireguard: list[Server] = json.loads(CACHE.read_text())["wireguard"]
    return wireguard


def current_server() -> str:
    match = re.search(r"^Endpoint = (.*):", read_conf(), re.MULTILINE)
    ip = match.group(1) if match else ""
    for server in servers():
        if any(host["host"] == ip for host in server["hosts"]):
            return str(server["gateway"]).removesuffix(".wg.ivpn.net")
    return ""


def set_server(code: str) -> None:
    if not re.fullmatch(r"[a-z-]+", code):
        sys.exit("ivpn-ctl: bad server code")
    server = next((s for s in servers(refresh=True) if s["gateway"] == f"{code}.wg.ivpn.net"), None)
    if server is None:
        sys.exit(f"ivpn-ctl: unknown server {code}")
    host = min(server["hosts"], key=lambda h: int(h["load"]))
    conf = re.sub(r"^PublicKey = .*$", f"PublicKey = {host['public_key']}", read_conf(), flags=re.MULTILINE)
    conf = re.sub(r"^Endpoint = .*$", f"Endpoint = {host['host']}:2049", conf, flags=re.MULTILINE)
    # tee rewrites the file in place, so its root-only mode stays
    sudo("tee", CONF, input=conf, stdout=subprocess.DEVNULL)
    sudo("systemctl", "try-restart", UNIT)


def main(argv: list[str]) -> None:
    # as a forced command, ssh puts what HA asked for in SSH_ORIGINAL_COMMAND
    args = os.environ.get("SSH_ORIGINAL_COMMAND", "").split() or argv or ["status"]
    match args:
        case ["start"]:
            sudo("systemctl", "start", UNIT)
        case ["stop"]:
            sudo("systemctl", "stop", UNIT)
            # a deliberate stop drops the policy rule so exit traffic goes
            # direct, start puts it back through the unit's drop-in. A tunnel
            # that fails on its own keeps the rule and exit traffic is
            # blocked, not leaked.
            for ip in (["ip"], ["ip", "-6"]):
                sudo(*ip, "rule", "del", "pref", "5100", check=False, stderr=subprocess.DEVNULL)
        case ["status"]:
            sys.exit(subprocess.run(["systemctl", "is-active", "--quiet", UNIT], check=False).returncode)
        case ["server"]:
            print(current_server())
        case ["server", code]:
            set_server(code)
        case _:
            sys.exit("ivpn-ctl: start, stop, status or server [CODE]")


if __name__ == "__main__":
    main(sys.argv[1:])
