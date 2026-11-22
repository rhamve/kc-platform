# Lessons learned – every problem and its fix

All errors from the Keycloak labs and the kc-platform, oldest first. Add new ones at the bottom (Part 4).
Times are Sydney time (AEDT, UTC+11).

Format for every entry:
```
### <number>. <short title>
**Problem faced:** what we saw (error message / symptom) and why it happened
**Date & time:** YYYY-MM-DD HH:MM AEDT
**Fix/solution:** what solved it (commands / config) – and the general lesson
```

---

## Part 1 – Keycloak Docker Compose lab (`learn/kc`)

### 1. ISVA on Apple Silicon: WebSEAL containers do nothing
**Problem faced:** `iamlab-iviawrprp1-1` (WebSEAL) and `iamlab-iviadc-1` showed `0B / 0B` memory and 0 PIDs. IBM ships ISVA/IVIA images for x86 only; under Rosetta the Java parts run but native parts like WebSEAL often don't.
**Date & time:** 2026-10-22 21:56 AEDT
**Fix/solution:** run ISVA on an x86 host (e.g. a small EC2 instance). Keycloak, PostgreSQL, oauth2-proxy and whoami are multi-arch and run natively on arm64 – Rosetta can stay on.

### 2. `docker compose ps` doesn't show the SP Keycloak
**Problem faced:** the SP server started with `-f docker-compose.sp.yml` wasn't listed by `docker compose ps`.
**Date & time:** 2026-10-23 21:25 AEDT
**Fix/solution:** `docker compose -f docker-compose.sp.yml ps` – each compose file is its own project.

### 3. Two Keycloak servers on one machine: cookies and admin consoles
**Problem faced (preventive):** mixing `localhost` and `127.0.0.1` makes the SAML POST cross-site, so cookies get dropped; two master admin consoles in one browser log each other out (same cookie path).
**Date & time:** 2026-10-23 21:10 AEDT
**Fix/solution:** use `localhost` everywhere, distinct realm names (`demo`, `app`), and open the second admin console in a private window.

### 4. SAML: "Invalid Request" from the IdP
**Problem faced:** `GET /realms/demo/protocol/saml` → 400 Invalid Request. The IdP's single sign-on URL was opened directly, with no `SAMLRequest`.
**Date & time:** 2026-10-24 18:05 AEDT
**Fix/solution:** start SP-initiated login at the **SP**: `http://localhost:8080/realms/sp/account` → click **demo-saml**. Lesson: in SP-initiated SAML the flow always starts at the SP.

### 5. SAML: "Required attribute missing: Name"
**Problem faced:** SP log `ParsingException PL00063: Parser: Required attribute missing: Name`, event `invalid_saml_document`. The IdP's User Property mappers had an empty **SAML Attribute Name**, so `<saml:Attribute>` had no `Name`.
**Date & time:** 2026-10-25 09:05 AEDT
**Fix/solution:** IdP (`demo`) → client → Client scopes → dedicated scope → each mapper → set **SAML Attribute Name** (`email`, `firstName`, `lastName`). Lesson: the side that logs the error isn't always the side to fix – fix whoever *produced* the bad message.

### 6. SAML: "Invalid signature in response from identity provider"
**Problem faced:** SP log `SAMLEndpoint validation failed`, `error="invalid_signature"`, no stack trace. The SP required a **signed assertion** (*Want Assertions signed*), but the IdP signed only the outer Response.
**Date & time:** 2026-10-25 20:45 AEDT
**Fix/solution:** IdP client → Signature and Encryption → **Sign assertions ON** (or SP: *Want Assertions signed* OFF). Use `logs --tail 200 | grep -A 20` to see stack traces under an ERROR line.

### 7. SAML: first name and last name show the email
**Problem faced:** after SSO, the SP user's first and last name were `alice@example.com`. The SP's Attribute Importer mappers had an empty **Attribute Name** (`attr: null` in the Admin API), so each took the first attribute in the Response (email).
**Date & time:** 2026-10-27 13:42 AEDT
**Fix/solution:** SP → Identity providers → demo-saml → Mappers → set **Attribute Name** on each; delete the user (or rely on Force sync) and log in again. Lesson: a SAML attribute must be *named by the sender* and *matched by the same name* on the receiver; the mapper's own name is only a label.

---

## Part 2 – kc-platform: image and theme (Phase 1 / 1b)

### 8. GitHub device login: "where is the code?"
**Problem faced:** github.com/login/device asked for a code that wasn't shown anywhere.
**Date & time:** 2026-11-04 19:19 AEDT
**Fix/solution:** the code is printed in the **Terminal** by `gh auth login` (`! First copy your one-time code: XXXX-XXXX`). Re-run if it expired (~15 min). Never enter a code someone else sends you.

### 9. Local image test: health check never ready
**Problem faced:** `10-test-image-local.sh` timed out although the log said Keycloak started. `start-dev` re-runs the build with only the options given at start, dropping the health/metrics options baked into the image (`Installed features` lacked `smallrye-health`).
**Date & time:** 2026-11-04 20:44 AEDT
**Fix/solution:** pass `--health-enabled=true --metrics-enabled=true` to `start-dev`. `start --optimized` (Kubernetes) keeps the baked options.

### 10. GHCR image private
**Problem faced:** a private repo makes the GHCR package private, so kind/Argo CD would need credentials to pull it.
**Date & time:** 2026-11-04 20:44 AEDT
**Fix/solution:** repo made public. Alternatives: make only the package public, or an image pull secret with a `read:packages` token.

### 11. GitHub Actions warnings
**Problem faced:** "Node.js 20 is deprecated…" and "ubuntu-latest will migrate to Ubuntu 26".
**Date & time:** 2026-11-04 20:58 AEDT
**Fix/solution:** Dependabot (`.github/dependabot.yml`, ecosystem `github-actions`) bumps action versions weekly; pin `runs-on: ubuntu-24.04` for repeatable builds.

### 12. Login theme not applied – setting never saved
**Problem faced:** login page still showed "Sign in to your account"; the Admin API returned `"loginTheme": null` – the change in the admin UI never saved.
**Date & time:** 2026-11-06 19:40 AEDT
**Fix/solution:** set it through the Admin REST API: `PUT /admin/realms/master` with `{"loginTheme":"kcplatform"}` → `204`. The test script now does this automatically.

### 13. curl login-page check printed nothing
**Problem faced:** the grep for theme markers returned nothing, not even "Sign in to your account". `account-console` is a public client that **requires PKCE**; without `code_challenge` Keycloak returned an error page.
**Date & time:** 2026-11-06 20:34 AEDT
**Fix/solution:** add `&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256` to the auth URL.

### 14. Admin API 401 after re-running the test script
**Problem faced:** `{"error":"HTTP 401 Unauthorized"}` with a token fetched a minute earlier. The script had recreated the container → new Keycloak → **new signing keys**.
**Date & time:** 2026-11-06 21:11 AEDT
**Fix/solution:** get a fresh token after every restart. Lesson: a token only works on the Keycloak (keys) that signed it.

### 15. `kcplatform` missing from the Login theme list, no errors in the log
**Problem faced:** the theme files were in the image but Keycloak didn't list the theme; `docker exec kc-image-test ls -l /opt/keycloak/themes/kcplatform/login` → `Permission denied`. The files on disk were owner-only (`-rw-------`), copied into the image as `root`, unreadable by user `keycloak` (uid 1000), so Keycloak silently skipped the theme. CI wasn't affected (Git doesn't store read permissions).
**Date & time:** 2026-11-08 11:59 AEDT (confirmed 2026-11-10 21:06 AEDT)
**Fix/solution:** `COPY --chown=keycloak:root themes/ /opt/keycloak/themes/` in the Dockerfile + `chmod -R a+rX image/themes`. Lesson: containers often run as a **non-root user**, so files copied into an image must be readable by *that* user. `COPY --chown=<runtime user>` is the standard way to guarantee it. The same rule applies to Kubernetes `securityContext` (`runAsUser`, `fsGroup`) and to any files mounted into pods.

---

## Part 3 – kc-platform: Argo CD and GitOps (Phase 2)

### 16. Argo CD CLI: `dial tcp [::1]:8085: connect: connection refused`
**Problem faced:** `argocd login localhost:8085` failed right after install – the `kubectl port-forward` wasn't running.
**Date & time:** 2026-11-18 19:34 AEDT
**Fix/solution:** run the port-forward in its own terminal and keep it open – or better, entry 18.

### 17. Argo CD CLI: "Argo CD server address unspecified"
**Problem faced:** every `argocd` command failed with this – no successful `argocd login` yet, so the CLI had no server context.
**Date & time:** 2026-11-18 19:34 AEDT
**Fix/solution:** log in first (entry 18).

### 18. Argo CD: initial admin secret deleted before changing the password
**Problem faced:** `argocd-initial-admin-secret` was deleted while the CLI login was still failing – worry that the admin password was lost.
**Date & time:** 2026-11-18 19:34 AEDT
**Fix/solution:** deleting the secret only removes the stored copy; the printed password stays valid. Change it first, then delete the secret. If truly lost: `argocd account bcrypt` + patch `argocd-secret` + `kubectl -n argocd rollout restart deployment argocd-server`.

### 19. Argo CD CLI: login refused on 127.0.0.1 while the browser works
**Problem faced:** `error dial proxy: dial tcp 127.0.0.1:8085: connect: connection refused`, though http://localhost:8085 worked in the browser. gRPC through a separate port-forward is fragile (and the browser used `localhost`/IPv6).
**Date & time:** 2026-11-19 20:42 AEDT
**Fix/solution:** let the CLI tunnel by itself – in `~/.zshrc`:
`export ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --plaintext"`, then `argocd login --username admin`.

### 20. Argo CD: "new password does not match ^.{8,32}$"
**Problem faced:** `argocd account update-password` rejected the new password.
**Date & time:** 2026-11-19 20:51 AEDT
**Fix/solution:** Argo CD passwords must be 8–32 characters.

### 21. Bootstrap script asked for a token (private repo)
**Problem faced:** `22-bootstrap-gitops.sh` prompted for a token – Argo CD reads the repo from GitHub, and a private repo needs a read-only credential.
**Date & time:** 2026-11-21 15:03 AEDT
**Fix/solution:** repo made public. Alternative: fine-grained token (Contents: Read-only, this repo only), stored as a Secret in `argocd`, never in Git.

### 22. Argo CD CLI: "token is expired"
**Problem faced:** `Unauthenticated desc = invalid session: token has invalid claims: token is expired` – CLI sessions expire after 24 hours.
**Date & time:** 2026-11-21 15:03 AEDT
**Fix/solution:** `argocd login --username admin` again. Status without the CLI: `kubectl -n argocd get applications`.

### 23. Finalizer warning on `kubectl apply`
**Problem faced:** `prefer a domain-qualified finalizer name including a path (/)` when applying `root-app.yaml`.
**Date & time:** 2026-11-21 15:03 AEDT
**Fix/solution:** harmless. New Applications use `resources-finalizer.argocd.argoproj.io/background`.

### 24. Empty HEALTH for child Applications
**Problem faced:** `argocd app get root` listed `platform-namespaces` as Synced with an empty HEALTH column.
**Date & time:** 2026-11-21 15:32 AEDT
**Fix/solution:** expected – Argo CD doesn't compute health for Application objects inside another Application. Check the child itself: `argocd app get <child>`.

### 25. Child apps OutOfSync / Missing right after a push
**Problem faced:** `argocd app get root --refresh` showed the three new operator apps as OutOfSync / Missing.
**Date & time:** 2026-11-21 16:37 AEDT
**Fix/solution:** none needed – the snapshot was taken between "Argo CD noticed the commit" and "Argo CD created the apps". Wait a few seconds: `kubectl -n argocd get applications -w`.

### 26. `21-argocd-ui.sh`: port 8085 already in use
**Problem faced:** `Unable to listen on port 8085 … bind: address already in use` for `127.0.0.1:8085` and `[::1]:8085` – an earlier port-forward (another terminal, or an earlier run of the script) was still running.
**Date & time:** 2026-11-22 08:55 AEDT
**Fix/solution:** the UI probably already works at http://localhost:8085. To start fresh: `lsof -nP -iTCP:8085 -sTCP:LISTEN` (see who holds it) → `pkill -f 'port-forward svc/argocd-server'` → re-run the script. The script now checks the port first and exits with this hint instead of looping.

---

## Part 4 – New problems
Add new entries here, newest at the bottom, using the format at the top.

### 27. Argo CD UI: http://localhost:8085 doesn't open – a suspended port-forward
**Problem faced:** the browser couldn't open http://localhost:8085 and `curl -sI http://127.0.0.1:8085` returned nothing, while
cluster and Argo CD pods were fine. `lsof` showed an old `kubectl -n argocd port-forward svc/argocd-server 8085:80`
(PID 38085) holding the port, and **`kill 38085` didn't remove it**. The tunnel had been **suspended** (Ctrl+Z in a
terminal, state `T` in `ps`): a stopped process keeps its port open but answers nothing, and a normal `kill` (SIGTERM)
is only acted on once the process is resumed.
**Date & time:** 2026-11-22 09:11 AEDT (diagnosed 10:33 AEDT)
**Fix/solution:**
1. Check the state: `ps -o pid,stat,command -p <PID>` – `T` = stopped/suspended
2. Force it: `kill -9 <PID>` (SIGKILL also ends stopped processes) – or resume then stop: `kill -CONT <PID>; kill <PID>`
3. One-liner for whatever holds the port: `kill -9 $(lsof -t -iTCP:8085 -sTCP:LISTEN)`
4. Restart the tunnel: `./scripts/21-argocd-ui.sh`, test with `curl -sI http://127.0.0.1:8085 | head -1` → `200 OK`
Lesson: stop a port-forward with **Ctrl+C**, never Ctrl+Z (Ctrl+Z only pauses it). General troubleshooting order for a UI
behind a tunnel: cluster → pods → port owner (`lsof`) → tunnel → `curl` → browser; the first step that fails is the problem.
