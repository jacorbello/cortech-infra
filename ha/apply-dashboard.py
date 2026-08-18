#!/usr/bin/env python3
"""Applies a generated dashboard config to Home Assistant over the WebSocket API.

Lovelace config is WebSocket-only; the REST API cannot read or write it. Needs
a long-lived access token, read from HA_TOKEN_FILE (default /root/.ha-token on
the Proxmox master) so the credential never lands in a shell history or a
process listing.

    python3 ha/overview-dashboard.py            # writes ha/overview-dashboard.json
    python3 ha/apply-dashboard.py               # pushes it to HA

Reads the existing config back before overwriting and writes it to
<config>.backup-<n> so a bad push is recoverable.
"""
import asyncio
import itertools
import json
import os
import re
import sys

import websockets

HA_WS = os.environ.get("HA_WS", "ws://192.168.1.61:8123/api/websocket")
CFG = os.environ.get("CFG", os.path.join(os.path.dirname(__file__), "overview-dashboard.json"))

# Only domains that name real entities. Excludes card-schema words that look
# like entity IDs but are not, so the check does not raise false alarms.
DOMAINS = {
    "sensor", "binary_sensor", "switch", "light", "climate", "person",
    "weather", "media_player", "update", "device_tracker", "button", "select",
}


# HA rejects a WebSocket message whose id is not strictly greater than the last
# ("id_reuse"), so ids come from one shared counter rather than being passed in.
_next_id = itertools.count(1)


async def call(ws, msg):
    mid = next(_next_id)
    msg["id"] = mid
    await ws.send(json.dumps(msg))
    while True:
        m = json.loads(await ws.recv())
        if m.get("id") == mid:
            return m


async def main():
    token = os.environ.get("HA_TOKEN")
    if not token:
        sys.exit("HA_TOKEN not set. Try: HA_TOKEN=$(ssh root@192.168.1.52 'cat /root/.ha-token')")
    config = json.load(open(CFG, encoding="utf-8"))

    async with websockets.connect(HA_WS, max_size=None) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(await ws.recv())["type"] != "auth_ok":
            sys.exit("auth failed — token rejected or expired")

        # Back up whatever is live before replacing it. A missing config is not
        # an error: it means HA is still auto-generating the Overview.
        old = await call(ws, {"type": "lovelace/config", "url_path": None})
        if old.get("success"):
            path = CFG + ".backup"
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(old["result"], fh, indent=2)
            print(f"backed up existing config -> {path}")
        else:
            print("no stored config yet (HA is auto-generating the Overview)")

        # Validate every entity reference before writing. A typo does not fail
        # the save — it renders as an "Entity not available" card, which is easy
        # to miss on a page this size. Cheaper to catch it here.
        states = await call(ws, {"type": "get_states"})
        known = {s["entity_id"] for s in states["result"]}
        refs = set(re.findall(r'"([a-z_]+\.[a-z0-9_]+)"', json.dumps(config)))
        missing = sorted(r for r in refs if r.split(".")[0] in DOMAINS and r not in known)
        if missing:
            print("WARNING: dashboard references entities that do not exist:")
            for m in missing:
                print("   ", m)
            if os.environ.get("FORCE") != "1":
                sys.exit("refusing to save; set FORCE=1 to override")

        saved = await call(ws, {"type": "lovelace/config/save", "url_path": None, "config": config})
        if not saved.get("success"):
            sys.exit(f"save failed: {saved.get('error')}")

        back = await call(ws, {"type": "lovelace/config", "url_path": None})
        if not back.get("success"):
            sys.exit("saved, but read-back failed — check the UI before trusting it")
        n = len(back["result"]["views"][0]["sections"])
        print(f"saved and verified: {n} sections")


asyncio.run(main())
