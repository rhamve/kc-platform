# Phase 2 – Argo CD (GitOps base)

| Step | What | Status |
|---|---|---|
| **2a** | Install Argo CD, open the UI, log in | ✅ done (server v3.5.2) |
| **2b** | App-of-apps: one root Application → everything else from Git | ← this step |
| 2c | Operators: CloudNativePG + Keycloak Operator (ring0) | |
| 2d | `keycloak-ring` Helm chart: PostgreSQL + Keycloak (GHCR image) | |
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
