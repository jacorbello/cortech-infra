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
snmp-server community public ro 192.168.1.0 255.255.255.0
end
copy running-config startup-config
```

Verify from any LAN host:

```
snmpwalk -v2c -c public 192.168.1.56 sysDescr
```

### On the community string

`public` read-only, restricted to the LAN subnet. SNMPv2c sends the community in
cleartext, so this is only acceptable because the LAN is flat and trusted and the
access is read-only — it grants interface counters, nothing writable.

The subnet-wide ACL is deliberate: the exporter pod's traffic is SNAT'd to
whichever node it lands on, so a single-IP ACL would break on reschedule. Pin the
deployment with a `nodeSelector` first if you want to narrow it.

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
