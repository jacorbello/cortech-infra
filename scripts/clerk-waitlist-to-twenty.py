#!/usr/bin/env python3
"""Mirror Clerk waitlist entries into Twenty CRM as People.

Idempotent: matches on the custom `clerkWaitlistId` field, so re-running only
creates what is missing and patches what changed. Safe to cron.

Credentials come from Infisical (PlotLens project), never from argv:
  TWENTY_API_KEY     <- /twenty/API_KEY        (env dev)
  CLERK_SECRET_KEY   <- /CLERK_SECRET_KEY      (env prod)

  ./clerk-waitlist-to-twenty.py --dry-run
  ./clerk-waitlist-to-twenty.py
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

TWENTY = os.environ.get("TWENTY_URL", "https://crm.plotlens.ai")
PROJECT = "db72a923-3cd8-4636-b1ff-80845dc070ca"
INFISICAL_API = os.environ.get(
    "INFISICAL_API_URL", "https://infisical.corbello.io/api"
)

STATUS_MAP = {
    "pending": "PENDING",
    "invited": "INVITED",
    "completed": "COMPLETED",
    "rejected": "REJECTED",
}


def secret(name, env, path="/"):
    """Read one secret via the Infisical CLI."""
    got = os.environ.get(name)
    if got:
        return got
    out = subprocess.run(
        ["infisical", "secrets", "get", name, "--projectId", PROJECT,
         "--env", env, "--path", path, "--plain"],
        capture_output=True, text=True,
        env={**os.environ, "INFISICAL_API_URL": INFISICAL_API},
    )
    val = out.stdout.strip()
    if not val:
        sys.exit(f"FATAL: could not read {name} from Infisical {env}:{path}")
    return val


def api(url, token, method="GET", body=None):
    req = urllib.request.Request(
        url, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json",
                 # Clerk sits behind Cloudflare, which 403s (error 1010) the
                 # default urllib User-Agent.
                 "User-Agent": "cortech-infra/clerk-waitlist-to-twenty"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"FATAL: {method} {url} -> {e.code}\n{e.read().decode()[:500]}")


def clerk_waitlist(token):
    """All waitlist entries, paged."""
    out, offset = [], 0
    while True:
        page = api(
            f"https://api.clerk.com/v1/waitlist_entries?limit=100&offset={offset}",
            token,
        )
        rows = page["data"]
        out.extend(rows)
        offset += len(rows)
        if len(rows) < 100 or offset >= page.get("total_count", 0):
            return out


def twenty_people(token):
    """Existing People that carry a clerkWaitlistId, keyed by that id."""
    out, cursor = {}, None
    while True:
        url = f"{TWENTY}/rest/people?limit=60"
        if cursor:
            url += f"&starting_after={cursor}"
        page = api(url, token)
        rows = page["data"]["people"]
        for p in rows:
            if p.get("clerkWaitlistId"):
                out[p["clerkWaitlistId"]] = p
        if len(rows) < 60:
            return out
        cursor = rows[-1]["id"]


def desired(entry):
    inv = (entry.get("invitation") or {}).get("status")
    status = STATUS_MAP.get(entry["status"], "PENDING")
    # Clerk keeps status 'pending' once invited; the invitation tells the truth.
    if status == "PENDING" and inv in ("pending", "accepted"):
        status = "INVITED"

    email = entry["email_address"]
    local = email.split("@")[0]
    return {
        "emails": {"primaryEmail": email, "additionalEmails": []},
        # Clerk's waitlist collects no name, so seed something readable and
        # let a human correct it later.
        "name": {"firstName": local, "lastName": ""},
        "clerkWaitlistId": entry["id"],
        "waitlistJoinedAt": datetime.fromtimestamp(
            entry["created_at"] / 1000, timezone.utc
        ).isoformat(),
        "waitlistStatus": status,
        "signupSource": "UNKNOWN",
    }


def same(field, stored, wanted):
    """Compare what Twenty returns against what we'd send.

    Twenty normalises datetimes to '...423Z' while isoformat() produces
    '...423000+00:00', so a string compare would report every record as changed
    and re-PATCH all of them on every run.
    """
    if field == "waitlistJoinedAt":
        if not stored:
            return False
        try:
            return datetime.fromisoformat(
                stored.replace("Z", "+00:00")
            ) == datetime.fromisoformat(wanted)
        except ValueError:
            return False
    return stored == wanted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    tw = secret("API_KEY", "dev", "/twenty")
    ck = secret("CLERK_SECRET_KEY", "prod", "/")

    entries = clerk_waitlist(ck)
    existing = twenty_people(tw)
    print(f"clerk: {len(entries)} waitlist entries | twenty: {len(existing)} already mirrored")

    created = updated = unchanged = 0
    for e in entries:
        want = desired(e)
        have = existing.get(e["id"])

        if not have:
            print(f"  + {want['emails']['primaryEmail']} ({want['waitlistStatus']})")
            if not args.dry_run:
                api(f"{TWENTY}/rest/people", tw, "POST", want)
            created += 1
            continue

        # Only push fields that actually differ — keeps human edits to names intact.
        diff = {
            k: v for k, v in want.items()
            if k in ("waitlistStatus", "waitlistJoinedAt")
            and not same(k, have.get(k), v)
        }
        if diff:
            print(f"  ~ {want['emails']['primaryEmail']} {list(diff)}")
            if not args.dry_run:
                api(f"{TWENTY}/rest/people/{have['id']}", tw, "PATCH", diff)
            updated += 1
        else:
            unchanged += 1

    verb = "would create" if args.dry_run else "created"
    print(f"{verb}={created} updated={updated} unchanged={unchanged}")

    typos = [e["email_address"] for e in entries
             if e["email_address"].split("@")[1] in ("gmail.cm", "gmial.com", "gmail.co")]
    if typos:
        print(f"WARNING: undeliverable-looking addresses: {typos}")


if __name__ == "__main__":
    main()
