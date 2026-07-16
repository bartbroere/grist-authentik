#!/bin/bash
# First-boot initialization, then hand off to supervisord.
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
AUTH_HOST=$(printf '%s' "$PUBLIC_AUTH_URL" | sed -E 's#^https?://([^/:]+).*#\1#')
grep -qE "[[:space:]]$AUTH_HOST(\$|[[:space:]])" /etc/hosts \
    || echo "127.0.0.1 $AUTH_HOST" >> /etc/hosts

# Serve Authentik under the URL's path prefix (e.g. /auth/); "/" if none.
AUTH_PATH=$(printf '%s' "$PUBLIC_AUTH_URL" | sed -E 's#^https?://[^/]+##')
AUTH_PATH="${AUTH_PATH%/}/"
export AUTHENTIK_WEB__PATH="$AUTH_PATH"

# ---------------------------------------------------------------------------
# Persistent data layout (mount a volume at /data)
#
# Ownership is baked into the image, so a fresh named volume already has the
# right owners and no chown is needed. Restricted environments (dropped
# CAP_CHOWN, rootless engines, root-squashed storage) forbid chown at
# runtime, so it is only attempted when ownership is actually wrong, and a
# denied chown is fatal only if the service could not run anyway.
# ---------------------------------------------------------------------------
mkdir -p /data/postgres /data/grist/docs /data/authentik/storage

owner_uid() { stat -c %u "$1"; }
chown_hint() {
    echo >&2 "       Recreate the volume so it inherits the image's ownership," \
             "chown it to uid $(id -u "$1") on the host, or grant the container CAP_CHOWN."
}

# Grist and Authentik just need write access to their directories.
for spec in grist:/data/grist authentik:/data/authentik; do
    user=${spec%%:*} dir=${spec#*:}
    if [ "$(owner_uid "$dir")" != "$(id -u "$user")" ]; then
        chown -R "$user:$user" "$dir" 2>/dev/null \
            || su -s /bin/bash "$user" -c "test -w '$dir'" || {
            echo >&2 "ERROR: $dir is not writable by '$user' (uid $(id -u "$user"))," \
                     "and this environment does not permit chown."
            chown_hint "$user"
            exit 1
        }
    fi
done

# PostgreSQL refuses to start unless it *owns* its data directory, so mere
# writability is not enough here.
if [ "$(owner_uid /data/postgres)" != "$(id -u postgres)" ]; then
    chown postgres:postgres /data/postgres 2>/dev/null || {
        echo >&2 "ERROR: /data/postgres is owned by uid $(owner_uid /data/postgres)," \
                 "but PostgreSQL requires its data directory to be owned by" \
                 "'postgres' (uid $(id -u postgres)), and this environment does not permit chown."
        chown_hint postgres
        exit 1
    }
fi
# Run chmod as the directory's owner: that always works, even without
# CAP_FOWNER.
su -s /bin/bash postgres -c "chmod 700 /data/postgres"

# /var/run may be a fresh tmpfs, so the build-time copy of this directory is
# not guaranteed to survive. Postgres only creates its socket here and does
# not care about ownership, so a /tmp-style mode is an acceptable fallback
# (works when root just created the dir: owners may always chmod).
mkdir -p /var/run/postgresql
if [ "$(owner_uid /var/run/postgresql)" != "$(id -u postgres)" ]; then
    chown postgres:postgres /var/run/postgresql 2>/dev/null \
        || chmod 1777 /var/run/postgresql 2>/dev/null \
        || su -s /bin/bash postgres -c "test -w /var/run/postgresql" || {
        echo >&2 "ERROR: /var/run/postgresql is not writable by 'postgres'," \
                 "and this environment does not permit chown."
        exit 1
    }
fi

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
# PostgreSQL: init cluster and create the authentik database on first boot
# ---------------------------------------------------------------------------
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin | head -1)
pg_run() { su -s /bin/bash postgres -c "$1"; }

if [ ! -s /data/postgres/PG_VERSION ]; then
    pg_run "$PG_BIN/initdb -D /data/postgres -E UTF8 --locale=C.UTF-8"
fi
rm -f /data/postgres/postmaster.pid

pg_run "$PG_BIN/pg_ctl -D /data/postgres -w -o '-k /var/run/postgresql' start"
pg_run "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='authentik'\" | grep -q 1" \
    || pg_run "createuser authentik"
pg_run "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='authentik'\" | grep -q 1" \
    || pg_run "createdb -O authentik authentik"
pg_run "$PG_BIN/pg_ctl -D /data/postgres -m fast -w stop"

echo "Starting services (first boot takes a few minutes while Authentik migrates)..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
