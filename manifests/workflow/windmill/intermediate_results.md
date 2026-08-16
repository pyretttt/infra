# Intermediate results — Postgres + Windmill (2026-08-16)

Context dump for a new session. Nothing was committed or pushed. Flux has not been told to reconcile unless the user did that separately.

## Goal

1. Add PostgreSQL to the cluster via Flux HelmRelease.
2. Finish Windmill against that Postgres: standalone mode, 1 CPU, 1536Mi RAM.

## Postgres

### Files

- `manifests/postgres/helmrepo.yaml` — OCI HelmRepository `postgresql` in `flux-system`
  - `type: oci`
  - `url: oci://registry-1.docker.io/bitnamicharts`
  - HTTP `https://charts.bitnami.com/bitnami` was dropped; charts are published as OCI (same pattern as n8n / cert-manager).
- `manifests/postgres/helmrelease.yaml` — HelmRelease `postgres` in `flux-system`, `targetNamespace: default`
  - Chart: `postgresql` **18.8.9** (app PostgreSQL 18.x)
  - `fullnameOverride: postgres` → service DNS `postgres.default.svc.cluster.local:5432`
  - Image: `docker.io/bitnami/postgresql:latest` (fully qualified for CRI-O). Public Bitnami catalog only publishes `latest` for current PG; `bitnamilegacy/postgresql` stops at 17.6.
  - Auth: custom user `user`, database `windmill`, passwords from secret `postgres-auth`
    - `adminPasswordKey: admin-password` (superuser `postgres`)
    - `userPasswordKey: postgres-password` (user `user`)
  - Architecture: standalone
  - PVC: `local-path`, 10Gi, `helm.sh/resource-policy: keep`, StatefulSet PVC retain on delete/scale
  - Resources: 50m–500m CPU, 768Mi memory
- `manifests/postgres/postgres-secret.yaml.tmpl` — plaintext template
- `manifests/postgres/postgres-secret.yaml` — SOPS/age encrypted Secret `postgres-auth` in `default` (already rendered; do not re-render)

### Why `auth.database: windmill`

Windmill does not `CREATE DATABASE`. It connects to the name in the URL path (`.../windmill`) and runs migrations there. Bitnami only creates extra DBs on **first init**, and only the name in `auth.database`. Without it you get `postgres` plus typically a DB named after the user (`user`). Connection to `/windmill` then fails.

If the Postgres PVC was already initialized without `windmill`, adding the Helm value will **not** create the DB. Create it by hand on the existing volume, or wipe/re-init (destructive).

### Mise

- `render:postgres-secret` — generates both passwords (`openssl rand -base64 16`) if the encrypted file is missing; included in `render:all`
- `get-postgres-creds` — prints user `user`, password from `postgres-auth` key `postgres-password`, host/port, database `windmill`

### Secret keys (current)

| Key | Used for |
| --- | --- |
| `postgres-password` | Bitnami custom user `user` (Windmill uses this) |
| `admin-password` | Bitnami superuser `postgres` |

## Windmill

### Files

- `manifests/workflow/windmill/helmrepo.yaml` — HTTP repo `https://windmill-labs.github.io/windmill-helm-charts/` (unchanged)
- `manifests/workflow/windmill/helmrelease.yaml` — finished values (see below)

### HelmRelease behavior

- Chart **4.0.240**, image `ghcr.io/windmill-labs/windmill:1.790.0`, `IfNotPresent`
- `dependsOn` HelmRelease `postgres` in `flux-system`
- Bundled chart Postgres **off** (`postgresql.enabled: false`). Old leftover `postgres:` values block removed (that was the previous chart schema).
- MinIO off, enterprise off
- **Standalone:** one app pod, `MODE=standalone` (API + worker in-process)
  - `appReplicas: 1`
  - `extraReplicas: 0` (no LSP/debugger)
  - `indexer.enabled: false` (default indexer wants 2Gi + 50Gi ephemeral)
  - `workerGroups`: only `default` with `replicas: 0` (replaces chart default of 3 workers + native worker)
- Chart templates hardcode `MODE=server` **after** `extraEnv`. A Flux `postRenderers` kustomize strategic-merge patch on Deployment `windmill-app` sets `MODE=standalone`.
- DB URL: `postgres://user:$(DATABASE_PASSWORD)@postgres.default.svc.cluster.local:5432/windmill?sslmode=disable`
  - `DATABASE_PASSWORD` from `postgres-auth` / `postgres-password` via `app.extraEnv` (list, not map)
  - kubelet expands `$(DATABASE_PASSWORD)` because that env var is defined first
  - **Caveat:** `openssl rand -base64 16` can include `+` `/` `=`. `+` and `/` break URI userinfo. If Windmill cannot connect, URL-encode the password in a dedicated secret or rotate to a hex password.
- Resources (app only): requests=limits `cpu: "1"`, `memory: 1536Mi`
- Ingress: `traefik-internal`, host `windmill.polywhale.com`, `baseProtocol: http`, no TLS (same pattern as n8n)

### Kustomization

`manifests/kustomization.yaml` now includes:

```
- postgres/helmrepo.yaml
- postgres/helmrelease.yaml
- postgres/postgres-secret.yaml
- workflow/windmill/helmrepo.yaml
- workflow/windmill/helmrelease.yaml
```

## Not done

- No git commit / push
- No cluster apply except whatever Flux already had
- No Windmill-specific SOPS secret (reuses `postgres-auth`)
- Default Windmill UI login is still the upstream default (typically `admin@windmill.dev` / `changeme`) unless changed in the UI after first boot
- Postgres `get-postgres-creds` originally said username `postgres`; it was updated to `user` after the HelmRelease auth was changed to a custom user
