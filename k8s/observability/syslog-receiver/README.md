# syslog-receiver

Receives UDP syslog from the SG300 switch and re-emits it to stdout as JSON, where
the existing promtail DaemonSet picks it up and ships it to Loki.

## Why this exists rather than pointing the switch at promtail

Promtail's syslog target parses **RFC5424 only**. The SG300 — like most network
gear — emits **RFC3164** (BSD syslog). Pointed straight at promtail, every message
is dropped.

The alternatives were adding Fluent Bit or Grafana Alloy to the stack to handle
RFC3164. For a single device that is a lot of moving parts, so instead this prints
to stdout and reuses the log path that already works for every other pod.

If a second device shows up with different framing, or parsing needs to get
clever, replace this with Alloy rather than growing the script.

## Why hostPort 514

The switch sends syslog on the well-known port and to a fixed address. 514 is below
the K3s NodePort range (30000-32767), so `hostPort` is the way to expose it. The
pod is pinned to `k3s-wrk-3` (`lifecycle=persistent`) so the address stays put —
the same reasoning as `snmp-exporter`, and the same coupling: **moving the pod
means updating the switch's logging target.**

## Configure the switch

`ssh sg300`, then:

```
configure
logging host 192.168.1.97
end
copy running-config startup-config
```

Verify the syntax with `logging ?` first — this firmware's CLI resembles IOS but
is not IOS (see `docs/switch-sg300.md`). If `logging host` is rejected, try
`logging 192.168.1.97`.

## Security

Syslog is unauthenticated UDP and trivially spoofed. `ALLOWED_SENDERS` restricts
accepted packets to `192.168.1.56`; anything else is dropped without being logged.
That is a spoofing speed-bump, not authentication — a host on the LAN can forge the
source address. Acceptable here because the payload is switch logs on a trusted
LAN, and nothing acts on them automatically.

## Verify

```bash
kubectl -n observability logs -l app.kubernetes.io/name=syslog-receiver --tail=20
```

Then force an event on the switch (unplugging a spare port, or a failed SNMP
attempt from a non-ACL'd host) and watch it appear. In Grafana:

```
{namespace="observability", pod=~"syslog-receiver.*"}
```

## Test

```bash
python3 test_receiver.py
```

Asserts RFC3164 PRI decoding and that the sender allow-list rejects foreign
sources. Requires `pyyaml`; runs the real ConfigMap script, not a copy.
