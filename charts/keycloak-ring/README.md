# keycloak-ring (Helm chart)

One ring = one PostgreSQL cluster (CloudNativePG) + one Keycloak cluster (Keycloak Operator), in the ring's namespace.
Rings differ only in their values file: `values-ring0.yaml` now; `values-ring1.yaml`, blue/green later.

| Template | Creates | Operator that runs it |
|---|---|---|
| `postgres-cluster.yaml` | `Cluster` kc-db (sync-wave 0) | CloudNativePG → pods kc-db-N, services kc-db-rw/-ro, secret kc-db-app |
| `keycloak.yaml` | `Keycloak` keycloak (sync-wave 1) | ring's Keycloak Operator → StatefulSet keycloak, services, secret keycloak-initial-admin |

Deployed by the Argo CD app `argocd/apps/ring0.yaml`. Render locally:
```
helm template ring0 charts/keycloak-ring -f charts/keycloak-ring/values-ring0.yaml
```
