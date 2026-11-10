#!/usr/bin/env bash
# Phase 1: build the image locally and run it in dev mode on http://localhost:8090
# (8090 avoids the Compose lab on 8080/8081). Admin: admin / admin – local only.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t kc-platform/keycloak:local image/
docker rm -f kc-image-test >/dev/null 2>&1 || true
docker run -d --name kc-image-test -p 8090:8080 -p 9091:9000 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  kc-platform/keycloak:local start-dev --db=dev-file --health-enabled=true --metrics-enabled=true

echo "Waiting for Keycloak to be ready..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:9091/health/ready >/dev/null; then
    echo "Ready: admin console http://localhost:8090/admin  (admin / admin)"
    echo "Themes in the container:"
    docker exec kc-image-test ls -l /opt/keycloak/themes/
    # Set the master realm's login theme through the Admin REST API (no clicking needed)
    TOKEN=$(curl -s -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
      http://localhost:8090/realms/master/protocol/openid-connect/token | jq -r .access_token)
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" -d '{"loginTheme":"kcplatform"}' http://localhost:8090/admin/realms/master)
    echo "Set master loginTheme=kcplatform -> HTTP $code (204 = OK)"
    echo "Login page check:"
    curl -sL "http://localhost:8090/realms/master/protocol/openid-connect/auth?client_id=account-console&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A8090%2Frealms%2Fmaster%2Faccount%2F&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256" \
      | grep -o -E "Welcome to KC Platform|Sign in to your account|kcplatform\.css|kc-logo-text" | sort -u || echo "  (no theme markers found – theme not active)"
    echo "Stop with: docker rm -f kc-image-test"
    exit 0
  fi
  sleep 3
done
echo "Not ready after 3 minutes – check: docker logs kc-image-test"; exit 1
