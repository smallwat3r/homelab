#!/usr/bin/env python3
"""Load the Let's Encrypt wildcard into OMV's certificate store and serve the
web UI over HTTPS with it. Runs as certbot's deploy hook on renewal and once
from setup.sh, which fills in @DOMAIN@. Idempotent: the store entry is found
again by its comment and updated in place."""

import json
import os
import re
import subprocess
from pathlib import Path

LINEAGE = Path(os.environ.get("RENEWED_LINEAGE", "/etc/letsencrypt/live/@DOMAIN@"))
COMMENT = "letsencrypt *.@DOMAIN@"


def rpc(service, method, params):
    out = subprocess.run(
        ["omv-rpc", "-u", "admin", service, method, json.dumps(params)],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out) if out.strip() else None


def main():
    # OMV's marker uuid for "create a new object" in set calls
    new_uuid = re.search(
        r'^OMV_CONFIGOBJECT_NEW_UUID="([^"]+)"',
        Path("/etc/default/openmediavault").read_text(), re.M,
    ).group(1)

    certs = rpc("CertificateMgmt", "getList", {"start": 0, "limit": -1})["data"]
    uuid = next((c["uuid"] for c in certs if c["comment"] == COMMENT), new_uuid)
    uuid = rpc("CertificateMgmt", "set", {
        "uuid": uuid,
        "certificate": (LINEAGE / "fullchain.pem").read_text(),
        "privatekey": (LINEAGE / "privkey.pem").read_text(),
        "comment": COMMENT,
    })["uuid"]

    # keep http on too, the LAN IP has no name the certificate covers
    settings = rpc("WebGui", "getSettings", {})
    settings.update(enablessl=True, sslport=443, forcesslonly=False, sslcertificateref=uuid)
    rpc("WebGui", "setSettings", settings)
    rpc("Config", "applyChanges", {"modules": ["certificates", "webgui", "nginx"], "force": False})
    print(f"omv-cert: web UI serving {COMMENT} ({uuid})")


if __name__ == "__main__":
    main()
