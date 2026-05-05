# SonarQube

Self-hosted code-quality scanner exposed at <https://sonarqube.corbello.io>.

Currently runs SonarQube **Community Build 26.4.0.121862** (`sonarqube:26.4.0.121862-community`)
in namespace `sonarqube`, on K3s worker `k3s-wrk-1` (PVCs are `local-path`, so the
deployment is pinned to that node by volume affinity).

## Layout

| File | Resource |
|------|----------|
| `namespace.yaml` | Namespace |
| `pvcs.yaml` | `sonarqube-data` (20Gi), `sonarqube-extensions` (5Gi), `sonarqube-logs` (5Gi) |
| `deployment.yaml` | Deployment (1 replica, `Recreate` strategy, `sysctl vm.max_map_count` init container) |
| `service.yaml` | ClusterIP `:80 → :9000` |
| `ingress.yaml` | Traefik ingress for `sonarqube.corbello.io` |
| `kustomization.yaml` | Bundles the above |

## Secret (not in git)

The deployment expects a secret `sonarqube-db` in the `sonarqube` namespace with:

```
SONAR_JDBC_URL       = jdbc:postgresql://<pg-host>:5432/sonarqube
SONAR_JDBC_USERNAME  = sonarqube
SONAR_JDBC_PASSWORD  = <password>
```

Backed by the shared Postgres LXC. Manage out-of-band (SOPS/Vault); never commit.

## Apply

```bash
kubectl apply -k k8s/sonarqube/
```

## Upgrades

1. Take a Postgres backup of the `sonarqube` DB:
   ```bash
   PGPASSWORD=... pg_dump -h <pg-host> -U sonarqube -d sonarqube \
     -F c -Z 6 -f sonarqube-pre-<version>.dump
   ```
2. Bump `image:` in `deployment.yaml` to the new pinned tag from
   <https://hub.docker.com/_/sonarqube/tags?name=community>.
3. `kubectl apply -k k8s/sonarqube/`
4. SonarQube returns `DB_MIGRATION_NEEDED` and serves only `/maintenance`.
   Trigger the migration:
   ```bash
   curl -X POST https://sonarqube.corbello.io/api/system/migrate_db
   ```
5. Poll `https://sonarqube.corbello.io/api/system/status` until
   `"status":"UP"` (usually a couple of minutes).

## Notes

- Both probes hit `/api/system/status` (anonymous-OK). `/api/system/liveness`
  requires auth on 26.x and is not suitable as a probe path.
- Only one replica — local-path PVCs are RWO and node-pinned. If the node dies,
  recovery requires restoring the PVCs (or the Postgres DB if you're rebuilding
  the SonarQube install from scratch).
