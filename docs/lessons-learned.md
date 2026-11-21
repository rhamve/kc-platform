# Lessons learned

## Containers run as a non-root user – copied files must be readable by that user
**Phase 1b, Nov 2026.** The `kcplatform` theme was inside the image, but Keycloak didn't list it in
Realm settings → Themes, and the logs showed no error.

- **Cause:** the theme files on disk had owner-only permissions (`-rw-------`). Docker copied them into the
  image owned by `root`, but Keycloak runs as user **`keycloak`** (uid 1000), so it couldn't read them and
  **silently skipped the theme**.
- **Proof:** `docker exec kc-image-test ls -l /opt/keycloak/themes/kcplatform/login` → `Permission denied`
  (`docker exec` runs as the image's user, just like Keycloak).
- **Fix:** `COPY --chown=keycloak:root themes/ /opt/keycloak/themes/` in the Dockerfile, plus
  `chmod -R a+rX image/themes` on disk.
- **Why CI didn't hit it:** Git doesn't store read permissions, so GitHub Actions checks the files out as readable.

**Rule:** containers often run as a **non-root user**, so files copied into an image must be readable by
*that* user. `COPY --chown=<runtime user>` is the standard way to guarantee it. The same rule applies later to
Kubernetes `securityContext` settings (`runAsUser`, `fsGroup`) and to any files you mount into pods
(ConfigMaps, Secrets, volumes).

## `start-dev` rebuilds Keycloak with only the options given at start
**Phase 1.** The local test's health check never passed although Keycloak started.
`start-dev` re-runs the build, dropping build-time options baked into the image (health, metrics).
Fix for the local test: pass `--health-enabled=true --metrics-enabled=true`. `start --optimized` (Kubernetes) keeps them.
Check: the log line `Installed features: [...]` must list `smallrye-health`.

## A token only works on the Keycloak that signed it
**Phase 1b.** A `PUT` to the Admin API returned `401` after the test script recreated the container:
the new Keycloak has new signing keys, so the old container's token was invalid. Get a fresh token after every restart.

## PKCE-only clients reject an auth request without `code_challenge`
**Phase 1b.** A curl check against `account-console` matched nothing because Keycloak returned an error page.
Public clients like `account-console` require PKCE, so add `code_challenge` and `code_challenge_method=S256`.
