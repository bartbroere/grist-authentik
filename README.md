# Grist + Authentik — single-image stack

This repository contains the files to build one Docker image containing:

| Component  | Role                                            |
| ---------- | ----------------------------------------------- |
| Grist      | Spreadsheet/database app (port 8484, internal)  |
| Authentik  | OIDC identity provider (port 9000, internal)    |
| PostgreSQL | Authentik's database (also runs its task queue) |
| nginx      | Reverse proxy — the only exposed port (8080)    |
| supervisord| Process manager tying it all together           |

This is combined to provide an easy way to try out Grist with accounts,
without needing to set up and configure a separate OIDC provider.

Users can **sign up themselves**: the Authentik login page shows a
"Sign up" link (enrollment flow), and Grist is pre-wired to use
Authentik as its OIDC provider via an Authentik blueprint
(`blueprints/grist.yaml`).

Sign-up asks for **username, name, email and password**. The email
address is **not verified** (no SMTP is configured); Grist uses it as
the account identity and for document sharing.

## Build & run

```sh
docker build -t grist-authentik .
docker run -d --name grist-authentik \
    -p 8080:8080 \
    -v grist-authentik-data:/data \
    grist-authentik
```

(Works identically with `podman`.)

The **first boot takes a few minutes** while Authentik runs its database
migrations and applies blueprints. Watch progress with
`docker logs -f grist-authentik`.

## URLs

Everything is served from one hostname; Authentik lives under the
`/auth` path:

- **Grist**: <http://localhost:8080> — click *Sign in*, then *Sign up*
  on the Authentik page to create an account.
- **Authentik admin**: <http://localhost:8080/auth/> — username
  `akadmin`, password:

  ```sh
  docker exec grist-authentik grep BOOTSTRAP /data/secrets.env
  ```

## Configuration

All state lives in the `/data` volume (Postgres, Grist docs,
generated secrets).
Environment variables you can override at `docker run` time:

| Variable            | Default                      | Purpose                          |
| ------------------- | ---------------------------- | -------------------------------- |
| `PUBLIC_GRIST_URL`  | `http://localhost:8080`      | Public URL of Grist              |
| `PUBLIC_AUTH_URL`   | `$PUBLIC_GRIST_URL/auth`     | Public URL of Authentik          |
| `GRIST_DEFAULT_EMAIL` | `admin@example.com`        | Email that gets Grist admin      |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | `admin@example.com`  | Email of the `akadmin` user      |

If you serve this on a real domain, set `PUBLIC_GRIST_URL` (e.g.
`https://grist.example.com`), point DNS at the container, and terminate
TLS in front of it. Authentik follows automatically under `/auth`; a
separate domain also works by setting `PUBLIC_AUTH_URL` explicitly (its
path component becomes Authentik's serving prefix). The OIDC issuer,
redirect URI and Grist app URL are derived from these variables on
every boot.

With an https `PUBLIC_AUTH_URL`, Grist's backend reaches Authentik
through that same public URL — which resolves to the container itself —
so nginx also listens on **port 443 inside the container**, with a
self-signed certificate regenerated on every boot. Grist trusts it via
`NODE_EXTRA_CA_CERTS`. This port is loopback plumbing only; don't
publish it — external TLS still belongs in your reverse proxy or
ingress.

## Single UID / restricted Kubernetes

Every process in the container (PostgreSQL, Grist, Authentik, nginx,
supervisord) runs as the **same non-root user** — the base image's
`authentik` user, uid/gid **1000**. Nothing is chowned at runtime, no
capability is needed, and pid files, temp files and the Postgres socket
live in `/tmp` (`/run` is a root-owned tmpfs under podman and
Kubernetes). This avoids errors like
`chown: changing ownership of '/data/postgres': Operation not permitted`
in clusters with a restrictive security policy.

The only requirement is that the `/data` volume is writable by that uid:

- **docker / podman named volume**: works out of the box — a fresh
  volume inherits the ownership baked into the image.
- **Kubernetes**: set `fsGroup` so the kubelet makes the volume
  group-writable, e.g. on the pod:

  ```yaml
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
  ```

- **Bind mounts / hostPath**: chown the directory to uid 1000 on the
  host (the entrypoint prints the exact uid if it can't write).

Because the entrypoint can no longer edit `/etc/hosts`, in Kubernetes
the Authentik hostname must be mapped to the pod itself when
`PUBLIC_AUTH_URL` is a separate domain:

```yaml
hostAliases:
  - ip: "127.0.0.1"
    hostnames: ["auth.example.com"]
```

Kubernetes also blocks non-root processes from binding ports below 1024
by default (Docker and podman don't), which the internal TLS listener
on 443 needs. The entrypoint probes this and simply skips the listener
if it can't bind — fine for plain-http setups, but with an https
`PUBLIC_AUTH_URL` you must allow it on the pod:

```yaml
securityContext:
  sysctls:
    - name: net.ipv4.ip_unprivileged_port_start
      value: "0"
```

**Note:** volumes initialized by older (multi-user) versions of this
image have a Postgres directory owned by a different uid and cannot be
reused; recreate the volume or chown it from outside the container.

## Notes & caveats

- Running many services in one container is convenient but unusual;
  for production, upstream recommends separate containers
  (docker-compose). This image trades that isolation for simplicity.
- Grist runs with `GRIST_SANDBOX_FLAVOR=unsandboxed`: formulas run
  as an unprivileged user but without gVisor sandboxing. Fine for
  trusted users; don't expose it to hostile ones.
- Email addresses are taken at face value at sign-up (Authentik reports
  `email_verified: false`, which Grist is told to ignore via
  `GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED=true`). If you later want real
  verification, configure `AUTHENTIK_EMAIL__*` (SMTP) and add an email
  stage to the enrollment flow in the blueprint.
