#!/usr/bin/env python3
"""Creates the Cortech Home dashboard and pushes a generated config to it.

Why this does not touch the Overview page
-----------------------------------------
HA 2026 replaced the old auto-generated Overview with a built-in "Home"
strategy dashboard at /home/overview. It is rendered client-side and is NOT a
writable config collection: `lovelace/config/save` with url_path "home" returns
`Unknown config specified`, and writing to the legacy default (url_path None)
succeeds, reads back correctly, and changes nothing visible -- the sidebar no
longer points at it. Do not "fix" this by pointing DASHBOARD_URL_PATH at None
or "home"; both are dead ends that fail silently.

So this creates a real storage dashboard and makes that the default instead.

    python3 ha/overview-dashboard.py
    HA_TOKEN=$(ssh root@192.168.1.52 'cat /root/.ha-token') python3 ha/apply-dashboard.py

Lovelace config is WebSocket-only; the REST API can neither read nor write it.

Flags:
    --set-default   also make this the calling user's landing dashboard
    FORCE=1         save even if entity references do not resolve
"""
import asyncio
import itertools
import json
import os
import re
import sys

import websockets

HA_WS = os.environ.get("HA_WS", "ws://192.168.1.61:8123/api/websocket")
CFG = os.environ.get("CFG", os.path.join(os.path.dirname(os.path.abspath(__file__)), "overview-dashboard.json"))

DASHBOARD_URL_PATH = "home-cortech"  # must contain a hyphen; HA rejects bare words
DASHBOARD_TITLE = "Home"
DASHBOARD_ICON = "mdi:home-heart"

# Domains that name real entities, so the reference check does not flag
# card-schema words that merely look like entity IDs.
DOMAINS = {
    "sensor", "binary_sensor", "switch", "light", "climate", "person",
    "weather", "media_player", "update", "device_tracker", "button", "select",
}

# HA rejects a WebSocket message whose id is not strictly greater than the last
# ("id_reuse"), so ids come from one shared counter.
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
            sys.exit("auth failed -- token rejected or expired")

        # Validate every entity reference first. A typo does not fail the save;
        # it renders as an "Entity not available" card, easy to miss on a page
        # this size.
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

        listed = await call(ws, {"type": "lovelace/dashboards/list"})
        if DASHBOARD_URL_PATH not in {d["url_path"] for d in listed["result"]}:
            created = await call(ws, {
                "type": "lovelace/dashboards/create",
                "url_path": DASHBOARD_URL_PATH,
                "title": DASHBOARD_TITLE,
                "icon": DASHBOARD_ICON,
                "show_in_sidebar": True,
                "require_admin": False,
            })
            if not created.get("success"):
                sys.exit(f"could not create dashboard: {created.get('error')}")
            print(f"created dashboard /{DASHBOARD_URL_PATH}")
        else:
            # Back up the live config before replacing it.
            old = await call(ws, {"type": "lovelace/config", "url_path": DASHBOARD_URL_PATH})
            if old.get("success"):
                path = CFG + ".backup"
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(old["result"], fh, indent=2)
                print(f"backed up existing config -> {path}")

        saved = await call(ws, {"type": "lovelace/config/save",
                                "url_path": DASHBOARD_URL_PATH, "config": config})
        if not saved.get("success"):
            sys.exit(f"save failed: {saved.get('error')}")

        back = await call(ws, {"type": "lovelace/config", "url_path": DASHBOARD_URL_PATH})
        if not back.get("success"):
            sys.exit("saved, but read-back failed -- check the UI before trusting it")
        print(f"saved and verified: {len(back['result']['views'][0]['sections'])} sections")
        print(f"   https://ha.corbello.io/{DASHBOARD_URL_PATH}/home")

        if "--set-default" in sys.argv:
            # Landing dashboard is per-user frontend data. Merge rather than
            # replace: this key also carries showAdvanced and clobbering it
            # silently turns off advanced mode.
            cur = await call(ws, {"type": "frontend/get_user_data", "key": "core"})
            value = (cur.get("result") or {}).get("value") or {}
            value["defaultPanel"] = DASHBOARD_URL_PATH
            r = await call(ws, {"type": "frontend/set_user_data", "key": "core", "value": value})
            print("set as default dashboard:", r.get("success"), r.get("error") or "")


asyncio.run(main())
