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
    echo "Stop with: docker rm -f kc-image-test"
    exit 0
  fi
  sleep 3
done
echo "Not ready after 3 minutes – check: docker logs kc-image-test"; exit 1
