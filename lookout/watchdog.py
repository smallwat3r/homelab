#!/usr/bin/env python3
"""Check each service over the tailnet, post to Slack when one changes state
and render index.html for nginx. Runs from watchdog.timer, SLACK_WEBHOOK
comes from make slack-webhook and STATE_DIRECTORY from the unit, setup.sh
fills in @DOMAIN@. A service's state file is written only once Slack
accepted the message, so a failed post is retried next run rather than
lost."""

import html
import json
import os
import sys
import time
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from string import Template

DOMAIN = "@DOMAIN@"
# name and URL, the name is the state file and what Slack and the page show
CHECKS = [
    ("ha", f"https://ha.{DOMAIN}/"),
    ("nas", f"https://nas.{DOMAIN}/"),
    ("files", f"https://nas.{DOMAIN}/files/"),
    ("git", f"https://nas.{DOMAIN}/git/"),
    ("gardener", f"https://gardener.{DOMAIN}/health"),
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


def check(name: str, url: str) -> str:
    """Check one service, alert on a change, return its row for the page."""
    state = "up" if is_up(url) else "down"
    state_file = STATE / name
    was = state_file.read_text().strip() if state_file.exists() else "up"
    if state != was:
        print(f"{name} is {state}", flush=True)
        if notify(name, state, url):
            state_file.write_text(state)
    since = stamp(state_file.stat().st_mtime) if state_file.exists() else "never"
    return (f'<tr><td><a href="{html.escape(url)}">{html.escape(name)}</a>'
            f'<td class="{state}">{state}<td>{since}')


def main() -> None:
    rows = [check(name, url) for name, url in CHECKS]
    # written aside then moved, so nginx never serves a half page
    tmp = STATE / ".index.html"
    tmp.write_text(PAGE.substitute(rows="\n".join(rows), checked=stamp()))
    tmp.replace(STATE / "index.html")


if __name__ == "__main__":
    main()
