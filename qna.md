# Keycloak platform – Questions and answers

Key distinction used throughout:
- **Keycloak cluster** = a group of Keycloak instances (pods) sharing **one database** and working as one.
- **Kubernetes cluster** = the machines that run pods. One Kubernetes cluster can run several Keycloak clusters.

---

## 1. Ring means cluster?
Close. A **ring** is a group that receives a change *at the same time*; rings are updated in order (ring 0 → ring 1 → ring 2).
Here each ring is **one independent Keycloak cluster with its own database**, serving a subset of tenants.
**Cell** (from *cell-based architecture*) means a self-contained copy of the whole stack serving part of the users.
"Ring" stresses rollout order, "cell" stresses isolation – here they are the same thing.

## 2. Keycloak ×2 means 2 nodes in the cluster?
Yes – 2 Keycloak pods forming one Keycloak cluster, sharing that ring's database.

## 3. Why GitHub Actions / Argo CD?
They automate the rollout so nobody clicks through each step.
- **GitHub Actions** – pipeline runner: on merge it lints realm files, builds images, applies to ring 0, runs tests, promotes.
- **Argo CD** – GitOps tool inside Kubernetes: keeps the cluster matching Git (image versions, manifests, the Keycloak resource).
Often both: Actions for build/test/config, Argo CD for deploying. You get an audit trail (every change is a commit),
gates between rings, and rollback by reverting a commit.

## 4. What does canary mean?
The **small first slice** that gets a change before everyone else (from the miners' canary). If ring 0 breaks, stop
before ring 1. (AWS CloudWatch Synthetics also calls its test scripts "canaries".)

## 5. K8s cluster/ns – ns means namespace?
Yes. A ring can be a **separate Kubernetes cluster** (strongest isolation) or a **namespace in a shared cluster**
(cheaper). Either way it needs its own database.

## 6. What is keycloak-config-cli? Is it API based?
Yes. Open-source tool (adorsys) that reads realm configuration files (JSON/YAML) and applies them to a running Keycloak
**through the Admin REST API**. Idempotent: it creates, updates and optionally deletes so Keycloak matches the files.
Runs as a container or Kubernetes Job:
```
docker run --rm \
  -e KEYCLOAK_URL=http://keycloak:8080 -e KEYCLOAK_USER=admin -e KEYCLOAK_PASSWORD=admin \
  -e IMPORT_FILES_LOCATIONS=/config/* -v $PWD/realms:/config \
  adorsys/keycloak-config-cli:<tag-matching-your-keycloak-version>
```
Terraform's Keycloak provider uses the same Admin REST API – a different way of writing the same configuration.
(See Q22 for references.)

## 7. What is a synthetic login?
A **script that pretends to be a user**: logs in with a test account after each deployment or on a schedule and
checks the login worked and the token has the right claims. The manual curl tests (password grant, PKCE, client
credentials) automated – curl for API flows, a headless browser (Playwright) for login pages. Becomes the gate
between rings. CloudWatch Synthetics is AWS's managed version.

## 8. What is the Keycloak Operator? Example
A **Kubernetes controller that knows how to run Keycloak**: you describe what you want, it builds and maintains it
(StatefulSet, services, ingress, upgrades).
```yaml
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata: { name: keycloak, namespace: ring0 }
spec:
  instances: 2
  db:
    vendor: postgres
    host: ring0-db.cluster-xxxx.ap-southeast-2.rds.amazonaws.com
    usernameSecret: { name: kc-db, key: username }
    passwordSecret: { name: kc-db, key: password }
  hostname: { hostname: login-ring0.example.com }
  http: { tlsSecret: kc-tls }
```
`kubectl apply` → two pods connected to that database. Upgrade: change `spec.image`. Scale: change `instances` or add
an HPA. `KeycloakRealmImport` only *creates* realms (no updates), so keycloak-config-cli or Terraform handles ongoing changes.

## 9. Pod by pod – how do we know one pod is fine? What about the shared DB?
- **Signals:** readiness probe (`/health/ready`) – Kubernetes waits for Ready before the next pod; plus your own checks
  (pause the rollout, run synthetic logins against the new pod, check its metrics and logs).
- **Shared DB:** a new Keycloak *version* **migrates the schema at startup**; the DB is then in the new format while old
  pods still run.
  - **Patch releases** don't change the schema → rolling pod by pod is safe.
  - **Minor/major releases** do → the operator stops old pods and starts new ones. Snapshot the DB first (rollback = restore).
- **Realm configuration** never rolls pod by pod – it lives in the shared DB, so it is staged **ring by ring**.
- Operator `spec.update.strategy`: `RecreateOnImageChange` (default, downtime), `Auto` (runs a compatibility-check Job,
  then rolling if safe), `Explicit` (you control via `revision`). Check: `kc.sh update-compatibility check` – exit 0 =
  rolling OK, 3 = recreate needed. Status: `kubectl get keycloak -o yaml` → conditions `Ready`, `HasErrors`, `RecreateUpdateUsed`.

## 10. Can PostgreSQL be multi-site HA instead of Aurora?
Yes, with caveats:
- Options: **RDS for PostgreSQL Multi-AZ** (synchronous standby), or **Patroni** / **CloudNativePG** with synchronous replication.
- Replication must be **synchronous** so no committed write is lost on failover. **Aurora is Keycloak's documented and
  tested blueprint**; plain PostgreSQL works on the same principle but you validate it yourself.
- PostgreSQL has **one writer**; on failover a standby is promoted and Keycloak reconnects.
- Keycloak 26 stores sessions in the DB (persistent sessions), so **DB HA = session HA**.

## 11. `partition: 2` on a 3-pod set – order pod 2, pod 1, pod 3?
Pods are numbered **0, 1, 2**; partition means *update every pod numbered ≥ partition*:
```
partition: 2 → only keycloak-2 updates   ← check it
partition: 1 → keycloak-1 updates too
partition: 0 → keycloak-0 updates        ← done
```
Order is **highest to lowest: 2 → 1 → 0**. Only for image/pod-spec changes, never realm configuration.

## 12. Consistent issuer – can a ring 0 token be validated in ring 1?
**No.** Each ring has its **own signing keys**; tokens belong to the ring that issued them.
"Stable hostname" means the tenant's **issuer URL stays the same** if the tenant moves from ring 0 to ring 1
(e.g. `https://acme.login.example.com/realms/acme`), so apps and SPs keep their URLs. Keys still change on a move unless
migrated, so SAML SPs need new metadata.

## 13. Multi-site inside a ring – does each pod get its own DB?
**No.** All pods in one Keycloak cluster **share one database**. Multi-site inside a ring = the ring spans two sites
(AZs) with **one logical DB** replicated synchronously:
```
Ring 1 (one Keycloak cluster)
  AZ-a: keycloak-0, keycloak-1 ─┐
                                ├─→ ONE Aurora/PostgreSQL cluster
  AZ-b: keycloak-2, keycloak-3 ─┘     writer in AZ-a ⇄ sync replica in AZ-b
```

## 14. So ring 0 has one DB shared by 2–5 pods?
**Exactly.** One database per ring, shared by all its pods however many the HPA runs. Isolation is *between* rings.

---

## 15. Lab design (kind + GitHub Actions + Argo CD + Helm)
- **15.1 Build the image with GitHub Actions?** Yes – multi-arch image (arm64 + amd64) → **GHCR**; Actions commits the
  new tag to Git. Actions can't reach kind on the Mac, so **Argo CD inside kind pulls from Git** (GitOps pull model).
- **15.2 Deploy with Argo CD?** Yes – operators, ring0 Helm chart, config Job and test Job, all from Git.
- **15.3 Admin pod + engine pods on one DB:** split by **traffic**, not by change type. All pods must run the same
  image/version; config changes land in the shared DB and every pod sees them. Admin hostname (internal) → admin
  console/API; login hostname (public) → login/token paths, `/admin` blocked. See Q20 for the full admin/engine design.
  - **Configuration** (realms, clients, flows) → Admin API via keycloak-config-cli, **ring by ring**.
  - **Software** (Keycloak version, themes, logos, providers – all in the image) → **pod by pod for patches**,
    **blue/green for minor/major**.
  - DB replica later via CloudNativePG (Phase 10).
- **15.4 BFF with Redis?** Spring Boot + Spring Security OAuth2 client (confidential, auth code + PKCE) +
  **Spring Session on Redis**. Browser only gets a session cookie – no tokens in the browser.
- **15.5 Technology plan:**

| Area | Choice |
|---|---|
| Local Kubernetes | kind (3 nodes, zone labels az-a / az-b) |
| CI | GitHub Actions → GHCR |
| CD | Argo CD (app-of-apps) |
| Packaging | Helm chart `keycloak-ring` (ring0/ring1/blue/green differ only in values) |
| Keycloak | Keycloak Operator + optimized custom image |
| Database | CloudNativePG (replicas, backups, cloning, sync replication) |
| Traffic | Envoy Gateway (Gateway API, weighted routes for blue/green) |
| Config | keycloak-config-cli as Argo CD sync Job |
| Tests | Synthetic-login Job (curl PKCE + client credentials) |
| Observability | Prometheus + Grafana, later Loki |
| Later | Vault + External Secrets Operator, SIEM export, PAM |

- **15.6 Cluster technology – Infinispan?** Use the **embedded Infinispan** inside Keycloak (pods discover each other
  automatically). No separate Infinispan for a single-site ring. External Infinispan only for multi-cluster v1 across
  sites; 26.7 multi-cluster v2 (preview) doesn't need it.

## 16. Blue/green for minor and major upgrades on Kubernetes
The new version migrates the schema, so blue/green = **two complete Keycloak clusters, each with its own DB**:
```
1. Freeze config changes
2. Clone DB-blue → DB-green (CloudNativePG bootstrap from blue's backup)
3. Deploy NEW Keycloak on DB-green → migrates its copy only
4. Test green on its own hostname
5. Switch Gateway HTTPRoute weights blue→green (or tenant by tenant)
6. Rollback = flip weights back (blue DB untouched)
7. After soak, delete blue
```
Win: instant rollback. Cost: writes to blue after the clone (registrations, password changes, sessions) aren't in green →
users may log in again. Bonus: same DB copy → same keys and issuer, existing tokens and SAML trust keep working.

## 17. What does HPA mean?
**Horizontal Pod Autoscaler** – adds/removes pods based on a metric (e.g. CPU). For Keycloak: target the `Keycloak`
resource, scale on CPU ~70%, min 2, scale up fast, scale down one pod at a time, cap max pods by DB connections.

## 18. The Docker Compose containers
They're **containers** (pods are the Kubernetes term).

| Container | What it is |
|---|---|
| `kc-keycloak-1` | Keycloak server (IdP), port 8080 |
| `kc-postgres-1` | Keycloak's **database**: realms, clients, users, password hashes, keys, events, and (Keycloak 26) **sessions** |
| `kc-oauth2-proxy-1` | **OIDC client** in front of the app: runs auth code + PKCE with Keycloak, holds login session in a cookie |
| `kc-whoami-1` | Tiny demo app that **echoes the request headers** – plays "the protected application" |

## 19. What is GHCR?
**GitHub Container Registry** (`ghcr.io`), part of GitHub Packages. Images live next to the repo
(e.g. `ghcr.io/<you>/kc-platform/keycloak:26.7.x-1`). Actions pushes with the built-in `GITHUB_TOKEN`; public images are
free and kind pulls them without credentials. AWS equivalent: ECR.

## 20. Separate admin pod and engine pods – how?
```
namespace ring0 (one Keycloak cluster = one DB + one Infinispan cache cluster)
  Keycloak CR keycloak-admin           instances: 1
  Keycloak CR keycloak-engine          instances: 2 (+ HPA)
  Keycloak CR keycloak-engine-client1  instances: 2
  → same image/version, same DB, same cache cluster
Routes: admin.ring0…   → keycloak-admin   (/admin, Admin API)  internal only (+ NetworkPolicy)
        login.ring0…   → keycloak-engine  (/realms/*, /resources/*), /admin blocked
        client1.login… → keycloak-engine-client1, /admin blocked
```
- Config changes go through the admin pod → written to DB → **cache invalidations broadcast** → engines reload.
- **Must be one Infinispan cluster** across all groups. Keycloak 26 default discovery `jdbc-ping` uses the shared DB, so
  groups join automatically; if the operator configures per-resource discovery, set `cache-stack=jdbc-ping` in
  `additionalOptions`. Verify: every pod's log shows `ISPN000094: Received new cluster view` listing all pods.

| You gain | You don't gain |
|---|---|
| Admin console/API off the public path | No configuration staging – admin changes are live for all engines immediately |
| Heavy admin work can't slow logins | No version split – all groups upgrade together for minor/major |
| Per-client compute: scaling, sizing, crash isolation | No data isolation – one DB, same realms |

- Worth it for large platforms; small ones can use a separate admin hostname + blocked `/admin`.
- **One operator per ring namespace** – lets you upgrade the operator itself ring by ring.

## 21. Can we avoid re-login in blue/green? Sync the two DBs?
**Live two-way sync isn't possible for an upgrade** – green runs a newer schema:
- **Physical replication** keeps green read-only and identical – new Keycloak can't start on it or migrate it.
- **Logical replication** breaks once green migrates; not supported by Keycloak.

**Replica, then promote** avoids re-login:
```
1. Green DB = streaming replica of blue DB (green Keycloak not started)
2. Freeze config changes
3. Cutover: stop blue Keycloak → replica catches up → promote green DB →
   start green Keycloak (migrates) → synthetic logins pass → switch traffic   (a few minutes' outage)
4. Users keep SSO sessions: same DB contents, keys, issuer
```
| | Clone, then switch (Q16) | Replica, then promote |
|---|---|---|
| Downtime | ~0 | A few minutes |
| Users log in again | Possibly | No |
| Data loss | Writes after the clone | None |
| Rollback | Instant (blue untouched) | Fast, but writes made on green are lost |

For schema-changing upgrades you get **two of three**: zero downtime, zero data loss (incl. sessions), instant rollback.
Apps with their own sessions (BFF + Redis) ride through a short Keycloak outage. Patch upgrades: rolling, no re-login.

---

## 22. keycloak-config-cli calls the Admin API – reference?
keycloak-config-cli is built on Keycloak's Java **admin client** library (`keycloak-admin-client`), which is a wrapper
around the **Admin REST API**. It logs in to the `master` realm (client `admin-cli` by default) and then calls endpoints
such as `GET/PUT /admin/realms/{realm}`, `/admin/realms/{realm}/clients`, … – the same API the admin console uses.
You can see it in action: run it while tailing the Keycloak log or watching the admin events.
- keycloak-config-cli: https://github.com/adorsys/keycloak-config-cli
- Docker image and options: https://hub.docker.com/r/adorsys/keycloak-config-cli
- Keycloak Admin REST API reference: https://www.keycloak.org/docs-api/latest/rest-api/index.html
- Admin REST API and admin client guide: https://www.keycloak.org/docs/latest/server_development/#admin-rest-api

## 23. Admin/engine split – is all client configuration in one realm "of the admin node"?
Not quite – **no configuration lives in the admin node**. All realms, clients, users and keys live in the **shared
database**. The admin pod is only the **door** you change them through; the engine pods read the same realms from the
same database (cached in memory, refreshed on invalidation).
- One realm or many is your choice: client1 and client2 can be clients in one realm, or each have their own realm –
  the engine groups don't own any of it.
- An engine group can be **restricted by route** (e.g. client1's hostname only forwards `/realms/client1/*`) – that is
  traffic control, not data isolation.
- Side benefit: if the admin pod is down, **logins keep working** – engines don't depend on it, only on the database.

## 24. What is the "clone method" (clone, then switch)?
Blue/green where green gets a **one-time copy** of blue's database, then both run side by side until traffic switches:
```
time ─────────────────────────────────────────────────────────────►
blue:  serving traffic ─────────────────────────────────┐ (kept for rollback)
                 │ clone (snapshot / backup restore)    │
green:           └─► copy of DB → new Keycloak starts → tests → receives traffic
                                                         ▲ switch (Gateway weights)
writes to blue between "clone" and "switch" are NOT in green
```
1. **Clone:** take a snapshot/backup of blue's DB and restore it as a new DB for green
   (CloudNativePG: new cluster bootstrapped from blue's backup; AWS: Aurora clone or snapshot restore).
2. Start the new Keycloak version on green's DB – it migrates **its copy** only.
3. Test green on its own hostname.
4. **Switch:** move traffic from blue to green at the Gateway.
5. Rollback = switch back; blue's DB was never touched.

Contrast with **replica, then promote** (Q21): green's DB follows blue continuously and is promoted at cutover – no lost
writes or sessions, but a short outage and a less clean rollback.
