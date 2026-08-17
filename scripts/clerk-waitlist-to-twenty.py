#!/usr/bin/env python3
"""Mirror Clerk waitlist entries into Twenty CRM as People.

Idempotent: matches on the custom `clerkWaitlistId` field, so re-running only
creates what is missing and patches what changed. Safe to cron.

Credentials come from Infisical (PlotLens project), never from argv:
  /twenty/API_KEY       (env dev)   — override with $TWENTY_API_KEY
  /CLERK_SECRET_KEY     (env prod)  — override with $CLERK_SECRET_KEY_PROD

The override names are deliberately NOT the bare secret names: a stray `API_KEY`
in the environment must not become the Twenty token, and a stray
`CLERK_SECRET_KEY` (very likely the sk_test_ dev key) must not silently replace
the prod lookup and mirror QA users into the real CRM.

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


def secret(name, env, path="/", override_env=None):
    """Read one secret via the Infisical CLI.

    `override_env` is a distinct, explicit variable name — never the bare secret
    name, so unrelated env vars can't hijack a credential.
    """
    got = os.environ.get(override_env) if override_env else None
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


class ApiError(Exception):
    pass


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
        # Raise rather than exit: one poison record (a 400 on an odd name, a 429)
        # must not block every entry after it from ever syncing.
        raise ApiError(f"{method} {url} -> {e.code}: {e.read().decode()[:300]}")


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
        # Page purely on the returned row count. Bringing total_count into the
        # stop condition means a missing/renamed field defaults to 0, makes
        # `offset >= 0` true after page one, and silently truncates the sync to
        # the first 100 entries while still reporting success.
        if len(rows) < 100:
            return out


def twenty_people(token):
    """Existing People that carry a clerkWaitlistId, keyed by that id."""
    # Overridable only so the multi-page path can be exercised below 60 records.
    page_size = int(os.environ.get("TWENTY_PAGE_SIZE", "60"))
    out, cursor = {}, None
    while True:
        url = f"{TWENTY}/rest/people?limit={page_size}"
        if cursor:
            url += f"&starting_after={cursor}"
        page = api(url, token)
        rows = page["data"]["people"]
        for p in rows:
            if p.get("clerkWaitlistId"):
                out[p["clerkWaitlistId"]] = p

        # starting_after wants the opaque base64 cursor from pageInfo, NOT a
        # record id — passing a bare UUID returns 400 'Invalid cursor'. Getting
        # this wrong only shows up past the first page, where a partial map makes
        # the sync re-create every unseen entry as a duplicate.
        info = page.get("pageInfo") or {}
        if not info.get("hasNextPage") or not info.get("endCursor"):
            return out
        cursor = info["endCursor"]


def desired(entry):
    inv = (entry.get("invitation") or {}).get("status")
    status = STATUS_MAP.get(entry["status"], "PENDING")
    # Clerk keeps status 'pending' once invited; the invitation tells the truth.
    if status == "PENDING" and inv in ("pending", "accepted"):
        status = "INVITED"

    email = entry["email_address"]
    local = email.rpartition("@")[0] or email
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

    tw = secret("API_KEY", "dev", "/twenty", override_env="TWENTY_API_KEY")
    ck = secret("CLERK_SECRET_KEY", "prod", "/", override_env="CLERK_SECRET_KEY_PROD")

    entries = clerk_waitlist(ck)
    existing = twenty_people(tw)
    print(f"clerk: {len(entries)} waitlist entries | twenty: {len(existing)} already mirrored")

    # Report undeliverable addresses BEFORE touching anything — reported after the
    # write loop they'd be easy to miss, and a crash there would mark a run that
    # actually succeeded as a hard failure.
    typos = [e["email_address"] for e in entries
             if e["email_address"].rpartition("@")[2].lower()
             in ("gmail.cm", "gmial.com", "gmail.co", "gmai.com", "hotmial.com")]
    if typos:
        print(f"WARNING: undeliverable-looking addresses: {typos}")

    created = updated = unchanged = errors = 0
    for e in entries:
        want = desired(e)
        have = existing.get(e["id"])

        if not have:
            print(f"  + {want['emails']['primaryEmail']} ({want['waitlistStatus']})")
            if not args.dry_run:
                try:
                    api(f"{TWENTY}/rest/people", tw, "POST", want)
                except ApiError as err:
                    print(f"    ERROR {err}")
                    errors += 1
                    continue
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
                try:
                    api(f"{TWENTY}/rest/people/{have['id']}", tw, "PATCH", diff)
                except ApiError as err:
                    print(f"    ERROR {err}")
                    errors += 1
                    continue
            updated += 1
        else:
            unchanged += 1

    verb = "would create" if args.dry_run else "created"
    print(f"{verb}={created} updated={updated} unchanged={unchanged} errors={errors}")
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
