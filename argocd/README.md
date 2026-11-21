# Phase 2 – Argo CD (GitOps base)

| Step | What | Status |
|---|---|---|
| **2a** | Install Argo CD, open the UI, log in | ✅ done (server v3.5.2) |
| **2b** | App-of-apps: one root Application → everything else from Git | ✅ done (root Synced/Healthy) |
| **2c** | Operators: CloudNativePG + Keycloak Operator (ring0) | ✅ done (both operators Running) |
| **2d** | `keycloak-ring` Helm chart: PostgreSQL + Keycloak (GHCR image) | ← this step |
| 2e | Verify: status, cluster view, admin login | |

## 2a – Install Argo CD

**Why a script and not Git?** Argo CD can't deploy itself before it exists. Installing it with Helm is the one
manual bootstrap step; from 2b on, every other component is created by Argo CD from this repo.

### Files
```
argocd/install/values.yaml      Helm values: HTTP inside the cluster, no SSO/notifications, small resources
scripts/20-install-argocd.sh    helm install argo/argo-cd (pinned chart version) + prints the admin password
```

### Steps
1. Cluster up (see "Stop and start" in the main README):
   ```
   kubectl config use-context kind-kc-lab && kubectl get nodes
   ```
2. Install:
   ```
   chmod +x scripts/*.sh
   ./scripts/20-install-argocd.sh
   ```
   Expect all pods `Running` in namespace `argocd` and the initial admin password printed.
3. **Terminal 1** – open a tunnel to the UI and **leave it running** (it prints `Forwarding from 127.0.0.1:8085`):
   ```
   kubectl -n argocd port-forward svc/argocd-server 8085:80
   ```
   Browse http://localhost:8085 → **admin** / the printed password. An empty Applications page is correct for now.
   (Ignore the Helm notes suggesting `8080:443` – our values serve plain HTTP on port 80.)
4. **CLI login** – let the CLI open its own tunnel (more reliable than going through the step-3 tunnel):
   ```
   echo 'export ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --plaintext"' >> ~/.zshrc
   source ~/.zshrc
   argocd login --username admin
   argocd version            # shows client AND server versions when logged in
   argocd cluster list       # in-cluster: https://kubernetes.default.svc
   ```
5. Change the admin password **first**, and only **then** delete the initial secret:
   ```
   argocd account update-password       # 8–32 characters
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```
   Deleting the secret doesn't change the password – it only removes the stored copy. Keep the new password in
   your password manager; it is not stored in Git.

### Daily use – browser vs CLI
| To use | You need | Every session? |
|---|---|---|
| **CLI** (`argocd ...`) | `ARGOCD_OPTS` in `~/.zshrc` (step 4) | No – once; the CLI tunnels by itself |
| **Browser UI** | `./scripts/21-argocd-ui.sh` (runs the port-forward) | Yes – keep that terminal open while using the UI |

From Phase 3 the UI gets a permanent address through the Gateway (http://argocd.localtest.me:8880) – no port-forward.

### Reset the admin password (if it's lost)
```
NEWPW='choose-a-strong-password'
HASH=$(argocd account bcrypt --password "$NEWPW")
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
kubectl -n argocd rollout restart deployment argocd-server
```

## 2b – App of apps

**Idea:** you apply **one** Application by hand – `root`. It watches `argocd/apps/` in Git. Every file there is a
*child* Application, which in turn deploys a folder of manifests. To add a component later, you add a file to
`argocd/apps/` and push – nothing else is ever applied by hand.

```
GitHub repo
  argocd/root-app.yaml ──(kubectl apply, once)──► Application "root"  ──watches──► argocd/apps/
  argocd/apps/platform-namespaces.yaml ─────────► Application "platform-namespaces" ──► platform/namespaces/
  argocd/apps/...            (2c: operators, 2d: ring0, later: gateway, monitoring, ...)
```

### Files
```
argocd/root-app.yaml                   root Application (path argocd/apps, auto-sync, prune, self-heal)
argocd/apps/platform-namespaces.yaml   first child app (sync-wave -10: namespaces before everything else)
platform/namespaces/namespaces.yaml    namespace ring0 (labels kc-platform/ring=0)
scripts/22-bootstrap-gitops.sh         fills in the repo URL, checks it's pushed, applies root
```

### Steps
1. First run – fills your repo URL into the manifests:
   ```
   chmod +x scripts/*.sh
   ./scripts/22-bootstrap-gitops.sh
   ```
2. Commit and push (**Argo CD reads GitHub, not your Mac**):
   ```
   git add argocd platform scripts && git commit -m "Phase 2b: app of apps" && git push
   ```
3. Second run – applies the root Application (asks for a read-only token only if the repo is private):
   ```
   ./scripts/22-bootstrap-gitops.sh
   ```
4. Check:
   ```
   argocd app list                       # root + platform-namespaces: Synced / Healthy
   kubectl get ns ring0 --show-labels
   ```
   In the UI (`./scripts/21-argocd-ui.sh`): click **root** → you see the tree root → platform-namespaces → Namespace ring0.

### Try GitOps behaviour (5 minutes, worth it)
| Experiment | Command | What Argo CD does |
|---|---|---|
| **Self-heal** | `kubectl label ns ring0 kc-platform/ring=9 --overwrite` | Puts `0` back within seconds (Git wins) |
| **Self-heal** | `kubectl delete ns ring0` | Recreates it |
| **Change via Git** | Add a label in `namespaces.yaml`, push | Applies it at the next poll (≤ 60s) or `argocd app sync platform-namespaces` |
| **Prune** | Add a second Namespace `scratch` in Git, push; then remove it, push | Creates `scratch`, then deletes it |

### Private repo?
The script registers a **fine-grained token** (GitHub → Settings → Developer settings → Fine-grained tokens →
*Only select repositories: kc-platform* → *Contents: Read-only*). It is stored as a Secret in the `argocd`
namespace, never in Git. Public repo: no token needed.

### Troubleshooting (2b)
| Symptom | Check |
|---|---|
| `root` shows **Unknown / ComparisonError**, "repository not found" | Repo private and no token, or URL typo – `argocd repo list` |
| `platform-namespaces` missing | Was `argocd/apps/` pushed? `argocd app get root` → Conditions |
| **OutOfSync** that never syncs | `argocd app get <app>` → sync errors; `argocd app sync <app>` to force |
| Changes on GitHub not picked up | Polling every 60s – or `argocd app get root --refresh` |

## 2c – Operators

An **operator** is a controller that knows how to run one kind of software. You declare *what* you want
(a `Cluster` for PostgreSQL, a `Keycloak` for Keycloak) and the operator creates and maintains the pods,
services, secrets and upgrades.

| Child app | Source | Installs | Scope |
|---|---|---|---|
| `operator-cnpg` | CloudNativePG Helm chart **0.29.2** (operator 1.30.2) | PostgreSQL operator in `cnpg-system` | whole cluster, watches all namespaces |
| `operator-keycloak-cluster` | `platform/operators/keycloak/cluster` | Keycloak CRDs + ClusterRoles (26.7.3) | cluster-wide, **once** for all rings |
| `operator-keycloak-ring0` | `platform/operators/keycloak/ring0` | Keycloak Operator 26.7.3 in `ring0` | **ring0 only** (one operator per ring) |

Sync order (sync waves): namespaces `-10` → CRDs + CNPG `-5` → ring0 operator `-4`.

### Why the Keycloak Operator is split in two
Upstream ships one file (`kubernetes.yml`) meant for a single namespace called `keycloak`. For rings we need:
- **cluster-scoped** pieces (CRDs, ClusterRoles) exactly **once** – two rings owning the same CRD would fight
- **namespaced** pieces (ServiceAccount, RoleBindings, Deployment) **per ring**, via a Kustomize overlay that sets
  the namespace, and a per-ring **ClusterRoleBinding** (`...-binding-ring0`) – upstream's points at namespace `keycloak`

The files are **vendored** (copied into this repo, pinned to 26.7.3) – reviewable, and an upgrade is a visible Git diff.

### Files
```
argocd/apps/operator-cnpg.yaml                Helm chart app (ServerSideApply: CRDs are large)
argocd/apps/operator-keycloak-cluster.yaml    prune: false – never auto-delete CRDs (it would delete every Keycloak)
argocd/apps/operator-keycloak-ring0.yaml
platform/operators/keycloak/cluster/          4 CRDs + clusterroles.yaml + kustomization.yaml
platform/operators/keycloak/namespaced/       operator.yaml (SA, RoleBindings, Service, Deployment)
platform/operators/keycloak/ring0/            overlay: namespace ring0, RoleBinding subjects, ClusterRoleBinding
```

### Steps
1. Commit and push – that's the whole deployment:
   ```
   git add argocd/apps platform && git commit -m "Phase 2c: CloudNativePG + Keycloak operators" && git push
   ```
2. Watch Argo CD pick it up (≤ 60s, or force it):
   ```
   argocd app get root --refresh
   kubectl -n argocd get applications -w        # Ctrl+C when all Synced/Healthy
   ```
3. Check:
   ```
   kubectl get crd | grep -E "keycloak|cnpg"                 # 4 keycloak CRDs + cnpg CRDs (clusters, backups, ...)
   kubectl -n cnpg-system get pods                           # cnpg-cloudnative-pg-...  Running
   kubectl -n ring0 get pods                                 # keycloak-operator-...    Running
   kubectl -n ring0 logs deploy/keycloak-operator | tail -20 # operator started, watching ring0
   ```

### Try it
- In the UI, open `operator-keycloak-ring0` → you see the Deployment, ServiceAccount, RoleBindings as a tree.
- `kubectl api-resources | grep -E "keycloak|cnpg"` – the new resource types the operators added to Kubernetes.

### Troubleshooting (2c)
| Symptom | Check |
|---|---|
| `operator-keycloak-cluster` **SyncFailed**: "metadata.annotations: Too long" | `ServerSideApply=true` missing in the app |
| `operator-keycloak-ring0` **Degraded**, pod `CrashLoopBackOff` | `kubectl -n ring0 logs deploy/keycloak-operator` – usually RBAC (`forbidden`) → check the ClusterRoleBinding subject is `ring0` |
| `operator-cnpg` **Unknown**, "chart not found" | Chart version typo; list versions: `helm search repo cnpg/cloudnative-pg --versions` (after `helm repo add cnpg https://cloudnative-pg.github.io/charts`) |
| Pods `Pending` | Memory – stop other labs; `kubectl describe pod <name>` → Events |

### Upgrading the operators later
- **CloudNativePG:** change `targetRevision` in `operator-cnpg.yaml`, push.
- **Keycloak Operator:** re-vendor the files for the new version (same split), push the CRDs first, then each ring's
  operator one ring at a time. Keep the operator version equal to the Keycloak image version.

## 2d – ring0: PostgreSQL + Keycloak (Helm chart)

The chart `charts/keycloak-ring` describes **one ring**. It contains no pods itself – only two custom resources,
and the operators from 2c turn them into running software:

```
Argo CD app "ring0" ──helm template (values-ring0.yaml)──►
   Cluster  kc-db     (wave 0) ──CloudNativePG──► pod kc-db-1, services kc-db-rw/-ro, secret kc-db-app
   Keycloak keycloak  (wave 1) ──Keycloak Operator──► StatefulSet keycloak (2 pods), keycloak-service,
                                                     secret keycloak-initial-admin
   Keycloak reads its DB user/password from secret kc-db-app – no password is ever written in Git
```

### Files
```
charts/keycloak-ring/Chart.yaml
charts/keycloak-ring/values.yaml                  defaults for any ring
charts/keycloak-ring/values-ring0.yaml            ring0: image tag, instances
charts/keycloak-ring/templates/postgres-cluster.yaml
charts/keycloak-ring/templates/keycloak.yaml      your GHCR image, startOptimized, update.strategy Auto,
                                                  HTTP only (TLS at the Gateway in Phase 3), spread over az-a/az-b
argocd/apps/ring0.yaml                            Argo CD app: chart + values-ring0.yaml → namespace ring0
```

### Steps
1. **Pick the image tag.** GitHub → repo `kc-platform` → **Packages** → `kc-platform/keycloak` → newest tag like
   `26.7.3-7` (the build that contains the Phase 1b theme fix). Put it in `charts/keycloak-ring/values-ring0.yaml`:
   ```yaml
   keycloak:
     image:
       tag: 26.7.3-7     # your tag
   ```
   (`latest` works for a first try, but a pinned tag is what makes rollouts visible and repeatable.)
2. **Image must be pullable without login:** `docker logout ghcr.io && docker pull ghcr.io/rhamve/kc-platform/keycloak:<tag>`.
   If denied → Packages → keycloak → Package settings → **Change visibility → Public**.
3. Commit and push:
   ```
   git add charts argocd/apps && git commit -m "Phase 2d: ring0 PostgreSQL + Keycloak" && git push
   argocd app get root --refresh
   ```
4. Watch it come up (first start takes 1–3 minutes: image pull, DB init, Keycloak schema creation):
   ```
   kubectl -n ring0 get cluster,keycloak,pods -w
   ```
   Expected end state:
   ```
   kc-db-1                    1/1 Running      (PostgreSQL)
   keycloak-0, keycloak-1     1/1 Running      (Keycloak)
   keycloak-operator-...      1/1 Running
   ```

## 2e – Verify
```
# 1. Keycloak resource status (operator's view)
kubectl -n ring0 get keycloak keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
#    expect Ready=True, HasErrors=False

# 2. Both pods formed ONE cache cluster
kubectl -n ring0 logs keycloak-0 | grep -i "cluster view"
#    expect a view listing 2 members (keycloak-0 and keycloak-1)

# 3. Database
kubectl -n ring0 get cluster kc-db          # STATUS: Cluster in healthy state

# 4. Admin console through a port-forward (terminal 1, keep open)
kubectl -n ring0 port-forward svc/keycloak-service 8095:8080

# 5. Admin login (terminal 2): the operator generated the first admin
kubectl -n ring0 get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n ring0 get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo
```
Browse http://localhost:8095/admin → log in → **this is your image on Kubernetes**.
Set master → Realm settings → Themes → Login theme `kcplatform` and open http://localhost:8095/admin in a private
window: the KC Platform login page (Phase 4 will set the theme from Git instead).

### Troubleshooting (2d/2e)
| Symptom | Check |
|---|---|
| `ImagePullBackOff` on keycloak-0 | Tag typo, or package not public – step 2 |
| keycloak pods `CrashLoopBackOff` right after start | DB not ready yet – it retries; `kubectl -n ring0 logs keycloak-0` → `Connection refused` to kc-db-rw resolves itself in a minute |
| `kc-db-1` stays `Pending` | `kubectl -n ring0 describe pod kc-db-1` → storage (PVC) or memory |
| Keycloak resource `HasErrors=True` | `kubectl -n ring0 describe keycloak keycloak` and operator log: `kubectl -n ring0 logs deploy/keycloak-operator` |
| Log warns "build time options have values that differ" | An option in the Keycloak resource is a build option – bake it into the image instead |
| Pods `Pending` (Insufficient memory) | Docker Desktop memory; stop other labs; or `instances: 1` in values-ring0.yaml |

### What got installed
| Pod | Role |
|---|---|
| `argocd-server` | UI + API (what the CLI and browser talk to) |
| `argocd-repo-server` | Clones Git and renders Helm charts / manifests |
| `argocd-application-controller` | Compares Git (desired) with the cluster (live) and syncs |
| `argocd-applicationset-controller` | Generates many Applications from one template (used for rings later) |
| `argocd-redis` | Cache |

### Useful commands
```
kubectl -n argocd get pods
argocd app list
helm -n argocd list                       # installed chart version
helm search repo argo/argo-cd --versions | head   # newer chart versions
```

### Troubleshooting
| Symptom | Check |
|---|---|
| `helm --wait` times out | `kubectl -n argocd get pods` – a pod `Pending` = not enough memory in Docker Desktop; stop other labs |
| Port-forward drops | Re-run it; it stops when the terminal closes or the pod restarts |
| CLI: `transport: ... tls` error | Use `--plaintext` (server runs HTTP) |
| `dial tcp [::1]:8085: connection refused` | The port-forward (step 3) isn't running – start it in its own terminal |
| `Argo CD server address unspecified` | `argocd login` hasn't succeeded yet – log in first (step 4) |
| Lost the admin password | See "Reset the admin password" above, or reinstall Argo CD (nothing else is in it yet) |

### Clean up / reinstall
```
helm -n argocd uninstall argocd && kubectl delete namespace argocd
```
