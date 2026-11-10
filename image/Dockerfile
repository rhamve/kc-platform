# Custom Keycloak image for the kc-platform lab
# - optimized build (kc.sh build) so pods start faster and can use start --optimized
# - build-time options: PostgreSQL, health and metrics endpoints
# - custom login theme "kcplatform"
# Single source of truth for the version: the workflow reads this ARG.
ARG KC_VERSION=26.7.3

FROM quay.io/keycloak/keycloak:${KC_VERSION} AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true
WORKDIR /opt/keycloak
# --chown: Keycloak runs as user 'keycloak' (uid 1000); owning the files guarantees it can read the theme
# even if the files on disk were created with restrictive permissions (e.g. 600).
COPY --chown=keycloak:root themes/ /opt/keycloak/themes/
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KC_VERSION}
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
