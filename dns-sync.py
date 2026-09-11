#!/usr/bin/env python3
"""Upsert A records <host>.DOMAIN -> tailnet IP in Cloudflare for the hosts
given as arguments, taking the IPs from the local tailscale client, make dns
passes every host directory. DOMAIN and CF_PASS_ENTRY come from config.
Token: a Cloudflare API token with Zone:DNS:Edit on the zone, from
$CF_API_TOKEN or pass. DRY_RUN=1 prints the changes without applying them."""

import functools
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

CONFIG = dict(
    line.split("=", 1)
    for line in Path(__file__).with_name("config").read_text().splitlines()
    if line and not line.startswith("#")
)
DOMAIN = CONFIG["DOMAIN"]
ZONE = DOMAIN.split(".", 1)[1]
API = "https://api.cloudflare.com/client/v4"
DRY_RUN = bool(os.environ.get("DRY_RUN"))


def token() -> str:
    tok = os.environ.get("CF_API_TOKEN") or subprocess.run(
        ["pass", "show", CONFIG["CF_PASS_ENTRY"]], capture_output=True, text=True, check=False,
    ).stdout.partition("\n")[0].strip()
    if not tok:
        sys.exit(f"no Cloudflare token, set CF_API_TOKEN or 'pass insert {CONFIG['CF_PASS_ENTRY']}'")
    return tok


def cf(tok: str, method: str, path: str, data: dict[str, Any] | None = None) -> Any:
    req = urllib.request.Request(
        f"{API}{path}", method=method, data=json.dumps(data).encode() if data else None,
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.load(res)["result"]
    except urllib.error.HTTPError as err:
        # Cloudflare puts the reason in the body
        sys.exit(f"{method} {path} failed, {err.code}: {err.read().decode()}")


def tailnet_ips() -> dict[str, str]:
    status = json.loads(subprocess.check_output(["tailscale", "status", "--json"]))
    nodes = [status["Self"], *status.get("Peer", {}).values()]
    return {n["HostName"]: n["TailscaleIPs"][0] for n in nodes if n.get("TailscaleIPs")}


def main(hosts: list[str]) -> None:
    if not hosts:
        sys.exit("usage: dns-sync.py HOST...")
    api = functools.partial(cf, token())
    ips = tailnet_ips()
    zones = api("GET", f"/zones?name={ZONE}")
    if not zones:
        sys.exit(f"zone {ZONE} not found in Cloudflare")
    zone = zones[0]["id"]
    for host in hosts:
        name = f"{host}.{DOMAIN}"
        ip = ips.get(host)
        if not ip:
            print(f"{name}: {host} is not on the tailnet, skipped", file=sys.stderr)
            continue
        records = api("GET", f"/zones/{zone}/dns_records?type=A&name={name}")
        record = records[0] if records else None
        body = {"type": "A", "name": name, "content": ip, "ttl": 300, "proxied": False}
        if record is None:
            print(f"{name} -> {ip} (create)")
            if not DRY_RUN:
                api("POST", f"/zones/{zone}/dns_records", body)
        elif record["content"] != ip:
            print(f"{name} -> {ip} (was {record['content']})")
            if not DRY_RUN:
                api("PUT", f"/zones/{zone}/dns_records/{record['id']}", body)
        else:
            print(f"{name} -> {ip} (unchanged)")


if __name__ == "__main__":
    main(sys.argv[1:])
