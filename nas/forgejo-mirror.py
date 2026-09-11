#!/usr/bin/env python3
"""Add a Forgejo pull mirror for every GitHub repo this account owns that
Forgejo does not have yet, forks excluded. Runs daily from cron and once from
setup.sh, which fills in the @...@ values. Forgejo then keeps each mirror in
sync on its own schedule. Skips when the GitHub token is not on the host yet."""

import json
import sys
import urllib.error
import urllib.request
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

GITHUB = "https://api.github.com"
FORGEJO = "http://127.0.0.1:@PORT@/api/v1"
OWNER = "@USER@"
GH_TOKEN = Path("@GH_CREDENTIALS@")
FORGEJO_TOKEN = Path("@FORGEJO_TOKEN@")

# A repo as either API returns it, only name, fork, clone_url and
# description are read
Repo = dict[str, Any]


def call(url: str, token: str, data: dict[str, Any] | None = None) -> Any:
    req = urllib.request.Request(
        url, data=json.dumps(data).encode() if data else None,
        headers={"Authorization": f"token {token}",
                 "Content-Type": "application/json"},
    )
    # a migrate call clones the repo before answering
    with urllib.request.urlopen(req, timeout=900) as res:
        return json.load(res)


def pages(url: str, token: str) -> Iterator[Repo]:
    page = 1
    while items := call(f"{url}&page={page}", token):
        yield from items
        page += 1


def missing(github: Iterable[Repo], forgejo: set[str]) -> list[Repo]:
    return [r for r in github if not r["fork"] and r["name"] not in forgejo]


def migrate(repo: Repo, gh_token: str, fj_token: str) -> None:
    call(f"{FORGEJO}/repos/migrate", fj_token, {
        "service": "github",
        "clone_addr": repo["clone_url"],
        "auth_token": gh_token,
        "repo_owner": OWNER,
        "repo_name": repo["name"],
        "description": repo["description"] or "",
        # public even for private GitHub repos, only the tailnet can reach it
        "private": False,
        "mirror": True,
    })


def main() -> None:
    if not GH_TOKEN.exists():
        print("forgejo-mirror: no GitHub token, run 'make github-token' first, skipped")
        return
    gh_token = GH_TOKEN.read_text().strip()
    fj_token = FORGEJO_TOKEN.read_text().strip()
    have = {r["name"] for r in pages(f"{FORGEJO}/user/repos?limit=50", fj_token)}
    failed = False
    url = f"{GITHUB}/user/repos?affiliation=owner&per_page=100"
    for repo in missing(pages(url, gh_token), have):
        try:
            migrate(repo, gh_token, fj_token)
            print(f"forgejo-mirror: added {repo['name']}", flush=True)
        except urllib.error.HTTPError as err:
            # one bad repo must not stop the rest, cron mails stderr
            print(f"forgejo-mirror: {repo['name']} failed, "
                  f"{err.code} {err.read().decode()}", file=sys.stderr)
            failed = True
    sys.exit(failed)


if __name__ == "__main__":
    main()
