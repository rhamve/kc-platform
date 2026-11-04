# Phase 1 – Custom Keycloak image

Goal: one versioned, optimized Keycloak image with our login theme, built by GitHub Actions for
arm64 (your Mac / kind) and amd64 (EC2), pushed to GHCR. This image is the **software** change
type – everything in it rolls out pod by pod (patch) or blue/green (minor/major).

## Files
```
image/
  Dockerfile                                   # KC_VERSION lives here (single source of truth)
  themes/kcplatform/login/theme.properties     # parent=keycloak.v2
  themes/kcplatform/login/messages/messages_en.properties   # "Sign in to KC Platform"
.github/workflows/keycloak-image.yml           # build + push (see step 1)
scripts/10-test-image-local.sh                 # local smoke test on http://localhost:8090
```

What the Dockerfile does:
- **builder stage:** sets build-time options (`KC_DB=postgres`, health, metrics), copies the theme, runs `kc.sh build`
- **final stage:** copies the built Keycloak – so pods can start with `start --optimized` (faster, no rebuild at startup)

## Step 1 – put the workflow in place (once)
Remote tools can't write into `.github`, so the workflow is delivered in `.github-staging`:
```
cd ~/Documents/arutperumjothi/learn/kc-platform
mkdir -p .github/workflows
mv .github-staging/workflows/keycloak-image.yml .github/workflows/
rm -rf .github-staging
chmod +x scripts/*.sh
```

## Step 2 – test the image locally (and log in to the admin console)
```
./scripts/10-test-image-local.sh
```
- Admin console: http://localhost:8090/admin → **admin / admin** (local test only)
- See the theme: **master realm → Realm settings → Themes → Login theme = kcplatform → Save**,
  then open http://localhost:8090/admin in a private window → the login page says **"Sign in to KC Platform"**
- Health (management port): `curl http://localhost:9091/health/ready`
- Stop: `docker rm -f kc-image-test`

`start-dev --db=dev-file` is only for this smoke test; on kind the operator runs `start --optimized` with PostgreSQL.

Why the script passes `--health-enabled=true --metrics-enabled=true`: `start-dev` re-runs the build
("Updating the configuration…" in the log) using only the options given at start, so the build-time
options baked into the image are replaced. `start --optimized` (Phase 2) skips that and keeps them.
Check: the log line `Installed features: [...]` should include `smallrye-health` and `micrometer`.

## Step 3 – push and let GitHub Actions build it
```
git add . && git commit -m "Phase 1: custom Keycloak image + CI" && git push
gh run watch            # or GitHub → Actions → keycloak-image
```
Result in GHCR: `ghcr.io/rhamve/kc-platform/keycloak` with tags `26.7.3-<run>`, `sha-<short>`, `latest`.

## Step 4 – pull access for the image (repo is private)
The package is **private** (it follows the private repo), so anything pulling it needs credentials.

1. GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** →
   new token, scope **`read:packages`** only, expiry e.g. 90 days. Keep it out of Git.
2. Mac:
   ```
   echo <token> | docker login ghcr.io -u rhamve --password-stdin
   docker pull ghcr.io/rhamve/kc-platform/keycloak:latest
   docker image inspect ghcr.io/rhamve/kc-platform/keycloak:latest --format '{{.Architecture}}'   # arm64
   ```
3. kind (used from Phase 2) – an image pull secret per namespace that runs Keycloak:
   ```
   kubectl create namespace ring0
   kubectl -n ring0 create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io --docker-username=rhamve --docker-password=<token>
   ```
   (Later: Vault + External Secrets instead of a hand-made secret.)

Alternative: keep the repo private but set only the **package** to Public
(Packages → keycloak → Package settings → Change visibility). The image contains no secrets – only Keycloak + theme.

Argo CD will also need read access to the private repo (Phase 2): a fine-grained token with
**Contents: read** on `kc-platform`, added as an Argo CD repository credential.

## Step 5 – try a change (the "software" pipeline)
Edit `messages_en.properties` (e.g. `loginAccountTitle=Welcome to KC Platform`), commit, push →
a new image tag appears. In Phase 2 Argo CD deploys new tags; in Phase 8 we roll them out pod by pod.

## Upgrading Keycloak later
Change `ARG KC_VERSION=` in the Dockerfile (check the newest 26.7.x on quay.io/keycloak/keycloak first).
Patch (26.7.x → 26.7.y): rolling update. Minor/major (26.7 → 26.8 / 27): blue/green (Phase 8).

## Phase 1b (next) – CSS and logo
Inspect the parent `keycloak.v2` login theme inside the image, then add `css/` and `img/` resources and
`styles=` in `theme.properties` without breaking the parent's styles.

## Troubleshooting
| Symptom | Check |
|---|---|
| `kcplatform` not in the Login theme list | Theme folder path must be `themes/kcplatform/login/`; rebuild the image |
| Container exits at start | `docker logs kc-image-test` |
| Workflow fails at push with 403 | Repo → Settings → Actions → General → Workflow permissions → **Read and write** |
| kind can't pull the image later (`ImagePullBackOff`) | `ghcr-pull` secret in the namespace, or make the package Public |
| Health check never ready, but log says "started" | Health not enabled – `Installed features` must list `smallrye-health` |
