#!/bin/bash
# First-boot initialization, then hand off to supervisord.
#
# The whole container — this script included — runs as the single non-root
# "authentik" user, so nothing here ever needs chown, su or any capability.
# That keeps the image working in restricted environments (Kubernetes with a
# tight securityContext, rootless podman).
set -euo pipefail

# ---------------------------------------------------------------------------
# Public URLs. Grist lives at PUBLIC_GRIST_URL, Authentik under the /auth
# path of the same host by default (PUBLIC_AUTH_URL may also be set to a
# separate domain; its path component becomes AUTHENTIK_WEB__PATH).
# ---------------------------------------------------------------------------
export PUBLIC_GRIST_URL="${PUBLIC_GRIST_URL:-http://localhost:8080}"
export PUBLIC_AUTH_URL="${PUBLIC_AUTH_URL:-$PUBLIC_GRIST_URL/auth}"

# Grist's backend talks to Authentik via the same public URL the browser
# uses, so the auth hostname must resolve to nginx inside this container.
# Appending to /etc/hosts requires root; when that fails the mapping must
# come from outside (Kubernetes: pod hostAliases).
AUTH_HOST=$(printf '%s' "$PUBLIC_AUTH_URL" | sed -E 's#^https?://([^/:]+).*#\1#')
if ! grep -qE "[[:space:]]$AUTH_HOST(\$|[[:space:]])" /etc/hosts; then
    if ! echo "127.0.0.1 $AUTH_HOST" >> /etc/hosts 2>/dev/null; then
        echo >&2 "WARNING: /etc/hosts is not writable; $AUTH_HOST must resolve to this"
        echo >&2 "         container some other way. In Kubernetes add to the pod spec:"
        echo >&2 "           hostAliases:"
        echo >&2 "             - ip: \"127.0.0.1\""
        echo >&2 "               hostnames: [\"$AUTH_HOST\"]"
    fi
fi

# Serve Authentik under the URL's path prefix (e.g. /auth/); "/" if none.
AUTH_PATH=$(printf '%s' "$PUBLIC_AUTH_URL" | sed -E 's#^https?://[^/]+##')
AUTH_PATH="${AUTH_PATH%/}/"
export AUTHENTIK_WEB__PATH="$AUTH_PATH"

# ---------------------------------------------------------------------------
# Persistent data layout (mount a volume at /data)
#
# The image ships /data owned by this uid, and a fresh named volume copies
# that ownership on first use. In Kubernetes, make the mounted volume
# writable for this uid via securityContext (fsGroup — see README).
# ---------------------------------------------------------------------------
if [ ! -w /data ]; then
    echo >&2 "ERROR: /data is not writable by uid $(id -u). Mount a volume this uid"
    echo >&2 "       can write to. In Kubernetes set on the pod:"
    echo >&2 "         securityContext: {runAsUser: $(id -u), fsGroup: $(id -g)}"
    exit 1
fi
mkdir -p /data/postgres /data/grist/docs /data/authentik/storage

# PostgreSQL insists on *owning* its data directory — mere writability is
# not enough — so a volume initialized under a different uid cannot be
# reused. (Volumes created by pre-single-uid versions of this image fall in
# that category.)
if [ "$(stat -c %u /data/postgres)" != "$(id -u)" ]; then
    echo >&2 "ERROR: /data/postgres is owned by uid $(stat -c %u /data/postgres), but this"
    echo >&2 "       container runs everything as uid $(id -u) and cannot chown. Recreate"
    echo >&2 "       the volume, or chown it to uid $(id -u) from outside the container."
    exit 1
fi
chmod 700 /data/postgres

# ---------------------------------------------------------------------------
# Secrets: generated once, persisted in the volume
# ---------------------------------------------------------------------------
if [ ! -f /data/secrets.env ]; then
    gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
    umask 077
    cat > /data/secrets.env <<EOF
AUTHENTIK_SECRET_KEY=$(gen 60)
AUTHENTIK_BOOTSTRAP_PASSWORD=$(gen 20)
GRIST_OIDC_CLIENT_SECRET=$(gen 48)
GRIST_SESSION_SECRET=$(gen 48)
EOF
    echo "Generated new secrets in /data/secrets.env"
fi
set -a
# shellcheck disable=SC1091
source /data/secrets.env
set +a

# ---------------------------------------------------------------------------
# Derived configuration for Grist and the Authentik blueprint
# ---------------------------------------------------------------------------
export APP_HOME_URL="$PUBLIC_GRIST_URL"
export GRIST_OIDC_SP_HOST="$PUBLIC_GRIST_URL"
export GRIST_OIDC_IDP_ISSUER="$PUBLIC_AUTH_URL/application/o/grist/"
export GRIST_OIDC_IDP_CLIENT_SECRET="$GRIST_OIDC_CLIENT_SECRET"
# Read by the Authentik blueprint (!Env) to register the redirect URI
export GRIST_REDIRECT_URI="$PUBLIC_GRIST_URL/oauth2/callback"

# ---------------------------------------------------------------------------
# PostgreSQL: init cluster and create the authentik database on first boot.
# The socket lives in /tmp (PGHOST below, -k in supervisord.conf) because
# /run is a root-owned tmpfs under podman and Kubernetes. initdb runs as the
# "authentik" OS user, so the cluster superuser is the "authentik" role and
# no separate role needs creating.
# ---------------------------------------------------------------------------
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin | head -1)
export PGHOST=/tmp

if [ ! -s /data/postgres/PG_VERSION ]; then
    "$PG_BIN/initdb" -D /data/postgres -E UTF8 --locale=C.UTF-8
fi
rm -f /data/postgres/postmaster.pid

"$PG_BIN/pg_ctl" -D /data/postgres -w -o "-k /tmp" start
psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='authentik'" | grep -q 1 \
    || createdb -O authentik authentik
"$PG_BIN/pg_ctl" -D /data/postgres -m fast -w stop

echo "Starting services (first boot takes a few minutes while Authentik migrates)..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
