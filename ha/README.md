# Home Assistant dashboard

Generates and applies the **Home** dashboard at `/home-cortech/home`, set as the
default landing page.

```bash
python3 ha/overview-dashboard.py                      # regenerate the JSON
HA_TOKEN=$(ssh root@192.168.1.52 'cat /root/.ha-token') \
  python3 ha/apply-dashboard.py --set-default         # validate, back up, push
```

`apply-dashboard.py` needs the `websockets` package. Lovelace config is
WebSocket-only — the REST API can neither read nor write it.

## Why this does not edit the Overview page

HA 2026 replaced the old auto-generated Overview with a built-in **Home strategy
dashboard** at `/home/overview`. It is rendered client-side and is not a writable
config collection:

- `lovelace/config/save` with `url_path: "home"` → `Unknown config specified`
- writing to the legacy default (`url_path: None`) **succeeds, reads back
  correctly, and changes nothing visible** — nothing in the sidebar points at it
  any more

That second failure mode is the dangerous one: every check passes and the page is
unchanged. Do not "fix" this by repointing `DASHBOARD_URL_PATH` at `None` or
`"home"`. Both are dead ends that fail silently. A real storage dashboard set as
the default is the supported route.

## Why a generator instead of checked-in YAML

Entity IDs are hard-coded on purpose. A dashboard built from live discovery
reshuffles itself whenever a device drops off the network, which is exactly when
you want the layout to stay put.

## Safety

- Every entity reference is validated against live state before saving. A typo
  otherwise renders as a silent "Entity not available" card. `FORCE=1` overrides.
- The live config is written to `overview-dashboard.json.backup` (gitignored)
  before being replaced.
- `--set-default` merges into the user's frontend data rather than replacing it —
  that key also carries `showAdvanced`, and clobbering it silently turns off
  advanced mode.
- Rollback: Profile → General → Dashboard to change the landing page; delete the
  dashboard under Settings → Dashboards to drop it entirely.

## Layout

Eight sections: alerts, climate, lights & plugs, people, network, printer, media,
system.

Sections lay cards out on a 12-column grid and default every card to full width,
which makes a section like the printer into one tall stack. Widths are set
explicitly — `FULL`/`HALF`/`QUARTER` in the generator — so toner gauges sit four
across rather than stacked.

A conditional card is sized by its **own** `grid_options`, not by the card it
wraps; an unsized wrapper silently falls back to full width and breaks its row.
The generator lifts the inner card's width onto the wrapper automatically.

Cards that would sit dead are wrapped in conditionals rather than shown greyed
out — the TV when powered off, PSN "now playing" when idle, update entities when
nothing is pending. The alerts section renders nothing at all unless WAN is down,
black ink is under 20%, or a backup is mid-run.

## Not covered yet

Both ecobee thermostats need the `ecobee` cloud integration (API key from
`developer.ecobee.com`). Only "Upstairs" is present today, via
`homekit_controller`; the Downstairs unit at `.143` advertises no pairable
HomeKit service, most likely because it is already paired to Apple Home.

Adopting `ecobee` is account-wide and will duplicate Upstairs. Removing the
HomeKit entry then changes `climate.upstairs` to a new entity ID, which breaks
the thermostat card — so the integration and a dashboard regeneration have to
land together.
