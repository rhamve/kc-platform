# Keycloak platform lab (kind + GitHub Actions + Argo CD + Helm)

A local, production-shaped Keycloak platform, built step by step:
custom image → GitOps deployment → config as code → rings → rolling and blue/green upgrades.

Location: `~/Documents/arutperumjothi/learn/kc-platform`

Related labs (left untouched – use them for MFA / TOTP and other feature experiments):
- `~/Documents/arutperumjothi/learn/kc/` – Docker Compose Keycloak lab (`docker-compose.yml`, `docker-compose.sp.yml`),
  notes in `docker.md`, `oauth.md`, `saml/`
- ISVA `iamlab` Docker lab

## Target architecture

```
 GitHub repo ──push──> GitHub Actions ──build/push──> GHCR (Keycloak image, BFF image)
      │                       │
      │                       └── commits new image tag back to Git
      ▼
 Argo CD (inside kind) ── pulls Git, syncs ──┐
                                             ▼
 kind cluster "kc-lab"   (control-plane + 2 workers labelled az-a / az-b)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ Gateway (Envoy Gateway, Gateway API)                                  │
 │   login.ring0.localtest.me  → Keycloak (public paths only)            │
 │   admin.ring0.localtest.me  → Keycloak admin console (lab-only route) │
 │   app.localtest.me          → BFF                                     │
 │                                                                       │
 │ namespace ring0                                                       │
 │   Keycloak cluster: 2–3 pods (Keycloak Operator, embedded Infinispan) │
 │   PostgreSQL: CloudNativePG cluster (1 primary → later + replica)     │
 │   keycloak-config-cli Job (realm config from Git)                     │
 │   synthetic-login Job (PKCE / client-credentials smoke tests)         │
 │                                                                       │
 │ namespace bff:  Spring Boot BFF + Redis (session store)               │
 │ namespace monitoring: Prometheus + Grafana (later)                    │
 └───────────────────────────────────────────────────────────────────────┘
```
`*.localtest.me` resolves to 127.0.0.1, so no /etc/hosts edits are needed. Gateway is reached on host port 8880/8843.

## Two kinds of change (and how each is rolled out)

| Change type | Examples | Lives in | Delivered by | Rolled out |
|---|---|---|---|---|
| **Software** | Keycloak version, themes/logo, providers, build options | Container image | GitHub Actions → GHCR → Argo CD | Pod by pod (patch, `update.strategy: Auto`) or blue/green (minor/major) |
| **Configuration** | Realms, clients, mappers, IdPs, flows, orgs | Shared database | keycloak-config-cli (Admin REST API) via Argo CD | Ring by ring (all pods of a ring see it at once) |

## Phases (tick off as we go)
- [ ] **0. Repo + kind cluster** – this commit
- [ ] **1. Custom Keycloak image** – Dockerfile + theme + GitHub Actions (multi-arch → GHCR)
- [ ] **2. GitOps base** – Argo CD, app-of-apps, Keycloak Operator, CloudNativePG, ring0 Helm chart
- [ ] **3. Traffic** – Envoy Gateway, login/admin hostnames, TLS
- [ ] **4. Config as code** – realm in Git, keycloak-config-cli Job
- [ ] **5. Synthetic logins** – smoke-test Job as Argo CD PostSync gate
- [ ] **6. BFF** – Spring Boot OAuth2 client + Redis sessions
- [ ] **7. Observability** – Prometheus/Grafana, Keycloak metrics and events
- [ ] **8. Upgrades** – rolling patch update (`Auto`), then blue/green minor upgrade
- [ ] **9. Rings** – ring1 + promotion pipeline (ring0 → tests → ring1)
- [ ] **10. Later** – database replica/HA, Vault + External Secrets, SIEM (event export), PAM

## Prerequisites (Mac)
```
brew install kind kubectl helm argocd gh k9s
```
Docker Desktop: keep ≥ 8 GB memory for this lab (more if the ISVA lab runs at the same time).

## Phase 0 – create the cluster
```
cd ~/Documents/arutperumjothi/learn/kc-platform
chmod +x scripts/*.sh
mkdir -p .github/workflows          # create locally (placeholder for Phase 1)
./scripts/00-create-cluster.sh
git init && git add . && git commit -m "Phase 0: repo skeleton + kind cluster"
gh repo create kc-platform --public --source . --push
```
Expected: 3 nodes `Ready`; the two workers show zones `az-a` and `az-b`.

Delete everything: `./scripts/99-delete-cluster.sh`

## Repo layout
```
kind/                 kind cluster definition
scripts/              bootstrap helpers
image/                custom Keycloak image (Phase 1)
.github/workflows/    CI pipelines (Phase 1)
argocd/               Argo CD applications (Phase 2)
charts/keycloak-ring/ Helm chart for one ring (Phase 2)
config/realms/        realm configuration as code (Phase 4)
apps/bff/             Spring Boot BFF (Phase 6)
docs/                 decisions, runbooks
```

## References
Keycloak
- Scaling and tuning (HPA, sizing): https://www.keycloak.org/getting-started/getting-started-scaling-and-tuning
- Operator – rolling updates and update strategies: https://www.keycloak.org/operator/rolling-updates
- Checking if rolling updates are possible (`kc.sh update-compatibility`): https://www.keycloak.org/server/update-compatibility
- Multi-site deployments: https://www.keycloak.org/high-availability/introduction
- Multi-cluster v2 and stateless mode (26.7, preview): https://www.keycloak.org/2026/07/multi-cluster-v2-and-stateless-mode
- Multi-cluster v2 upgrades: https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/upgrades
- Operator guide: https://www.keycloak.org/guides#operator
- Server guides (hostname, reverse proxy, containers): https://www.keycloak.org/guides#server

Tooling
- kind: https://kind.sigs.k8s.io/
- Argo CD: https://argo-cd.readthedocs.io/
- GitHub Actions: https://docs.github.com/actions
- GitHub Container Registry (GHCR): https://docs.github.com/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- Helm: https://helm.sh/docs/
- CloudNativePG: https://cloudnative-pg.io/documentation/
- Envoy Gateway (Gateway API): https://gateway.envoyproxy.io/docs/
- keycloak-config-cli: https://github.com/adorsys/keycloak-config-cli

Multi-tenancy
- Keycloak Organizations: https://www.keycloak.org/docs/latest/server_admin/#_managing_organizations
- Phase Two – multi-tenancy options: https://phasetwo.io/blog/multi-tenancy-options-keycloak/
