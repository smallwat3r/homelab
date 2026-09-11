#!/usr/bin/env python3
"""Check each service over the tailnet, post to Slack when one changes
state, render index.html for nginx, and hold the LAN route while ha is
down. Runs from watchdog.timer as root, SLACK_WEBHOOK comes from make
slack-webhook and STATE_DIRECTORY from the unit, setup.sh fills in
@DOMAIN@ and @LAN_SUBNET@. A service's state file is written only once
Slack accepted the message, so a failed post is retried next run rather
than lost."""

import html
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from string import Template

DOMAIN = "@DOMAIN@"
LAN_SUBNET = "@LAN_SUBNET@"
# Name, URL and the host it runs on if that is checked separately. The name
# is the state file and what Slack and the page show. A service on a down
# host is down without a fetch or a message of its own.
CHECKS = [
    ("ha", f"https://ha.{DOMAIN}/", None),
    ("nas", f"https://nas.{DOMAIN}/", None),
    ("files", f"https://nas.{DOMAIN}/files/", "nas"),
    ("git", f"https://nas.{DOMAIN}/git/", "nas"),
    ("gardener", f"https://gardener.{DOMAIN}/health", None),
]
STATE = Path(os.environ["STATE_DIRECTORY"])
WEBHOOK = os.environ["SLACK_WEBHOOK"]
PAGE = Template("""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<meta http-equiv="refresh" content="60">
<title>lookout</title>
<style>
  /* the Terminal theme's font and creamy palette, see ha's themes */
  @font-face { font-family: ocrab; src: url(ocrab.woff2) format("woff2"); }
  body { font: 15px/1.6 ocrab, monospace; margin: 2em; background: #f5e4c1; color: #000; }
  h1 { color: #a020f0; font-size: 1.4em; }
  th, td { padding: 0 2em 0 0; text-align: left; }
  th, p { color: #696969; }
  a { color: inherit; }
  .up { color: #008b00; }
  .down { color: #ee2c2c; font-weight: bold; }
</style>
<h1>lookout</h1>
<table>
<tr><th>service<th>state<th>last change
$rows
</table>
<p>checked $checked, every two minutes
""")


def stamp(when: float | None = None) -> str:
    # the Pi's local time, the page is read from the same house it sits in
    return datetime.fromtimestamp(when or time.time(), UTC).astimezone().strftime("%d %b %H:%M")


def is_up(url: str) -> bool:
    # three tries five seconds apart, a blip is not an outage
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=10):
                return True
        except OSError:
            if attempt < 2:
                time.sleep(5)
    return False


def notify(name: str, state: str, url: str) -> bool:
    req = urllib.request.Request(
        WEBHOOK, data=json.dumps({"text": f"{name} is {state}, {url}"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            return True
    except OSError as err:
        print(f"slack post failed, retrying next run: {err}", file=sys.stderr)
        return False


def check(name: str, url: str) -> tuple[str, bool]:
    """Check one service and alert on a change, returns the state and
    whether a message is still owed because Slack refused it."""
    state = "up" if is_up(url) else "down"
    state_file = STATE / name
    was = state_file.read_text().strip() if state_file.exists() else "up"
    owed = False
    if state != was:
        print(f"{name} is {state}", flush=True)
        if notify(name, state, url):
            state_file.write_text(state)
        else:
            owed = True
    return state, owed


def row(name: str, url: str, state: str) -> str:
    state_file = STATE / name
    since = stamp(state_file.stat().st_mtime) if state_file.exists() else "never"
    return (f'<tr><td><a href="{html.escape(url)}">{html.escape(name)}</a>'
            f'<td class="{state}">{state}<td>{since}')


def hold_route(hold: bool) -> None:
    """Advertise the LAN subnet only while ha is down. Tailscale picks any
    approved router as primary and never fails back, so lookout stays out
    of the running until needed and hands the route back when ha returns.
    The state file remembers what was last set, so tailscale's prefs on
    the card are only rewritten on a change. No file, as after
    provisioning, means unknown and the route is set either way."""
    state_file = STATE / "route"
    want = "on" if hold else "off"
    if state_file.exists() and state_file.read_text() == want:
        return
    routes = LAN_SUBNET if hold else ""
    if subprocess.run(["tailscale", "set", f"--advertise-routes={routes}"], check=False).returncode:
        print("tailscale set failed, retrying next run", file=sys.stderr)
        return
    print("holding the LAN route, ha is down" if hold else "released the LAN route to ha", flush=True)
    state_file.write_text(want)


def main() -> None:
    states: dict[str, str] = {}
    rows = []
    owed = False
    for name, url, host in CHECKS:
        if host and states[host] == "down":
            states[name] = "down"
        else:
            states[name], missed = check(name, url)
            owed = owed or missed
        rows.append(row(name, url, states[name]))
    # written aside then moved, so nginx never serves a half page
    tmp = STATE / ".index.html"
    tmp.write_text(PAGE.substitute(rows="\n".join(rows), checked=stamp()))
    tmp.replace(STATE / "index.html")
    hold_route(states["ha"] == "down")
    # a failed post fails the unit, so it shows in systemctl until it lands
    sys.exit(owed)


if __name__ == "__main__":
    main()
