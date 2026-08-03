# snmp-exporter

Scrapes the Cisco SG300-52 core switch (`192.168.1.56`) over SNMP and re-exposes
`if_mib` interface counters to Prometheus. See `docs/switch-sg300.md` for the
switch itself.

The exporter is a proxy, not a sidecar: Prometheus scrapes `/snmp?target=…` and
the exporter does the SNMP walk. Adding another SNMP device means adding another
endpoint to `servicemonitor.yaml`, not another deployment.

No ConfigMap is used — the image's bundled `snmp.yml` already defines the
`public_v2` auth and `if_mib` module.

## Prerequisite: enable SNMP on the switch

**The exporter returns nothing until this is done.** The switch ships with SNMP v3
groups defined but no community and no listener; port 161 is closed.

`ssh sg300`, then:

```
configure
snmp-server server
snmp-server community public ro 192.168.1.97
end
copy running-config startup-config
```

Note the syntax: this firmware takes a **single management-station IP and no
netmask**. The IOS-style `<network> <mask>` form is rejected with
`% Wrong number of parameters or invalid range, size or characters entered`.

```
snmp-server community <string> {ro|rw|su} [ip-address] [view <name>]
```

Verify from any LAN host:

```
snmpwalk -v2c -c public 192.168.1.56 sysDescr
```

### On the community string and the pinned node

`public` read-only, accepted from exactly one host: `192.168.1.97` (k3s-wrk-3).
SNMPv2c sends the community in cleartext, so this is only acceptable because the
LAN is trusted and the grant is read-only — interface counters, nothing writable.

Because the ACL is a single IP and pod egress is SNAT'd to its node, the
deployment carries a matching `nodeSelector` for `k3s-wrk-3`. **The two must stay
in sync** — moving the pod without updating the switch ACL silently breaks the
scrape. k3s-wrk-3 is `lifecycle=persistent`, so it is the stable choice.

If this switch ever carries untrusted traffic, move to SNMPv3 with auth+priv
(the v3 groups already exist) and put the credentials in Infisical.

## Deploy

```bash
kubectl apply -f k8s/observability/exporters/snmp-exporter/
```

## Verify

```bash
# Exporter reaches the switch (expect ifNumber, ifHCInOctets, … )
kubectl -n observability port-forward svc/snmp-exporter 9116:9116
curl 'localhost:9116/snmp?target=192.168.1.56&auth=public_v2&module=if_mib' | head

# Prometheus picked the target up
#   → Status ▸ Targets, job "snmp-exporter", instance 192.168.1.56
```

`snmp_scrape_duration_seconds` present with no `ifHCInOctets` samples means the
walk is timing out — usually SNMP not enabled on the switch, or the ACL rejecting
the exporter's source IP.
