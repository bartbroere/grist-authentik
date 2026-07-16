# Grist + Authentik (incl. PostgreSQL) in a single image,
# behind an nginx reverse proxy, orchestrated by supervisord.
#
#   build:  docker build -t grist-authentik .
#   run:    docker run -d --name grist-authentik -p 8080:8080 \
#               -v grist-authentik-data:/data grist-authentik
#
# Grist:              http://localhost:8080
# Authentik (admin):  http://localhost:8080/auth/
#
# Note: Authentik >= 2025.8 no longer needs Redis; tasks and cache run
# on PostgreSQL, so Postgres is the only extra dependency.

FROM docker.io/gristlabs/grist:latest AS grist

FROM ghcr.io/goauthentik/server:2026.2.5

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql \
        nginx \
        supervisor \
        libstdc++6 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Node runtime + the Grist application, taken from the official Grist image.
# Grist's npm dependencies live at /node_modules (root level) in that image.
COPY --from=grist /usr/local/bin/node /usr/local/bin/node
COPY --from=grist /node_modules /node_modules
COPY --from=grist /grist /grist

# Grist's data engine runs on the Python that ships in the Grist image
# (its dependencies live in /usr/local/lib/python3.11/site-packages)
COPY --from=grist /usr/bin/python3.11 /usr/bin/python3.11
COPY --from=grist /usr/local/lib/libpython3.11.so.1.0 /usr/local/lib/libpython3.11.so.1.0
COPY --from=grist /usr/local/lib/python3.11 /usr/local/lib/python3.11
RUN ldconfig

RUN useradd --system --shell /usr/sbin/nologin --home-dir /data/grist grist

# Bake the /data layout and its ownership into the image: a fresh named
# volume copies the image content *including owners*, so no chown is needed
# at runtime. Restricted environments (dropped CAP_CHOWN, rootless engines,
# root-squashed storage) forbid runtime chown, so the entrypoint only treats
# it as best-effort. This must precede the VOLUME declaration below —
# changes to a path after VOLUME are discarded from the image.
RUN mkdir -p /data/postgres /data/grist/docs /data/authentik/storage /var/run/postgresql \
    && chown postgres:postgres /data/postgres /var/run/postgresql \
    && chown -R grist:grist /data/grist \
    && chown -R authentik:authentik /data/authentik \
    && chmod 700 /data/postgres

# The ak script logs to /dev/stderr, which cannot be re-opened when stderr
# is a root-owned supervisord pipe and the process runs as "authentik".
# Point it at the already-open fd instead.
RUN sed -i 's#>/dev/stderr#>\&2#' /lifecycle/ak

COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY blueprints/grist.yaml /blueprints/grist.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh && chmod 644 /blueprints/grist.yaml

# --- Authentik ---------------------------------------------------------
ENV AUTHENTIK_POSTGRESQL__HOST=127.0.0.1 \
    AUTHENTIK_POSTGRESQL__USER=authentik \
    AUTHENTIK_POSTGRESQL__NAME=authentik \
    AUTHENTIK_STORAGE__FILE__PATH=/data/authentik/storage \
    AUTHENTIK_BOOTSTRAP_EMAIL=admin@example.com \
    AUTHENTIK_DISABLE_UPDATE_CHECK=true \
    AUTHENTIK_DISABLE_STARTUP_ANALYTICS=true \
    AUTHENTIK_ERROR_REPORTING__ENABLED=false \
    AUTHENTIK_AVATARS=initials

# --- Grist -------------------------------------------------------------
# OIDC client settings are derived in entrypoint.sh; the secret is
# generated on first boot and stored in /data/secrets.env.
ENV PORT=8484 \
    GRIST_HOST=127.0.0.1 \
    GRIST_SINGLE_PORT=true \
    GRIST_SERVE_SAME_ORIGIN=true \
    GRIST_ORG_IN_PATH=true \
    GRIST_SESSION_COOKIE=grist_core \
    GRIST_ALLOW_AUTOMATIC_VERSION_CHECKING=false \
    GRIST_SANDBOX_FLAVOR=unsandboxed \
    GRIST_SANDBOX=/usr/bin/python3.11 \
    GRIST_DATA_DIR=/data/grist/docs \
    GRIST_INST_DIR=/data/grist \
    TYPEORM_DATABASE=/data/grist/home.sqlite3 \
    GRIST_FORCE_LOGIN=true \
    GRIST_IN_SERVICE=true \
    GRIST_DEFAULT_EMAIL=admin@example.com \
    GRIST_OIDC_IDP_CLIENT_ID=grist \
    GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED=true \
    NODE_OPTIONS=--no-deprecation \
    NODE_ENV=production

EXPOSE 8080
VOLUME /data

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s \
    CMD curl -fsS http://127.0.0.1:8080/ -o /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
