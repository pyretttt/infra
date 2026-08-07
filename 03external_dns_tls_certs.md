# What we do now
***

Public access is already through the **OCI Network Load Balancer (L4)**. Clients hit the NLB public IP on :80/:443; the NLB forwards TCP to worker NodePorts `31600`/`31601`; ingress-nginx terminates HTTP(S) and routes to Services:

```text
Internet → OCI NLB (public IP) :80/:443 → worker NodePort 31600/31601 → ingress-nginx → Service
```

So the public hostname’s **DNS A/AAAA record must point at that OCI NLB public IP** (from `terraform outputs`). Cloudflare (or any other DNS host) is only the place you store the record — it is not a substitute for the NLB. Prefer **DNS-only** (grey-cloud) so resolution returns the NLB address and traffic stays on the path above.

What is still missing for real public HTTPS:

1. That **one DNS name → NLB public IP** record (today the public Ingress is path-only / IP-based).
2. A **trusted certificate** on the single public Ingress (no `tls:` block, no cert issuer yet) — TLS terminates at ingress-nginx behind the NLB, not on the NLB itself.
3. Automatic **certificate renewal** so HTTPS does not expire silently.

Internal names (`polywhale.com` via the separate CoreDNS from stage 02) stay private / WireGuard-only. This stage is about the **public** edge only. One public Ingress hostname is enough — paths under that host cover the public apps.

# Public DNS + TLS options
***

## Requirements

| # | Requirement | Notes |
|---|-------------|-------|
| R1 | Free / OCI Always Free | No extra nodes; stay within existing A1.Flex pool |
| R2 | Low OCPU / memory | Controllers must stay tiny; prefer one replica each |
| R3 | Trusted HTTPS in browsers | Public CA on ingress-nginx (Let's Encrypt); NLB stays L4 / no TLS there |
| R4 | DNS → existing OCI NLB → NodePort | Public A/AAAA = NLB public IP; do not require a cloud `LoadBalancer` Service or paid OCI LB |
| R5 | Auto-renew TLS for one public Ingress | Single public hostname; DNS may be one-shot manual (→ NLB IP); cert must renew without babysitting |
| R6 | Maintainable / debuggable | Clear status objects, logs, and failure modes (`Certificate`, DNS records) |
| R7 | Fits Flux / GitOps | HelmReleases + Secrets (SOPS); no imperative snowflake steps beyond token creation |

## Comparison matrix

Legend: **Y** = meets, **P** = partial / with caveats, **N** = does not meet.

| Variant | R1 Free | R2 Low footprint | R3 Trusted TLS | R4 DNS→NLB | R5 Auto-renew | R6 Debuggable | R7 GitOps |
|---------|---------|------------------|----------------|------------|---------------|---------------|-----------|
| Cert-Manager + ExternalDNS (Cloudflare DNS) | Y | P¹ | Y | Y² | Y | Y | Y |
| Cert-Manager + manual DNS (→ NLB IP) | Y | Y | Y | Y³ | Y | Y | Y |
| Cloudflare proxy + Origin CA | Y | Y⁴ | Y⁵ | N⁶ | Y⁷ | P | Y |
| Cloudflare Tunnel (+ optional Access) | Y | Y | Y | N⁸ | Y | P | Y |
| Traefik / Caddy built-in ACME | Y | P | Y | Y | Y | P | P⁹ |
| DIY certbot / acme.sh CronJob | Y | Y | Y | Y | P¹⁰ | N | P |
| Self-signed / mkcert only | Y | Y | N | Y | Y | Y | Y |

¹ Two small controllers (cert-manager suite + external-dns). Overkill for one hostname; fine if CPU/memory requests are capped.

² ExternalDNS must publish the **OCI NLB public IP** (`--default-targets` or `external-dns.alpha.kubernetes.io/target`) — there is no cloud LB Service to discover (`ingress-nginx` Service is disabled on purpose).

³ One manual A/AAAA whose **value is the OCI NLB public IP**; cert-manager renews via HTTP-01 through that same NLB :80 path.

⁴ No cert-manager / ExternalDNS required if you only use Origin CA + one DNS record.

⁵ Browser trusts Cloudflare's edge cert; origin sees Cloudflare Origin CA (Full Strict).

⁶ Orange-cloud proxy: public DNS resolves to **Cloudflare**, not the NLB. Clients no longer hit the OCI NLB directly (CF connects to the NLB as origin). Breaks the “DNS → NLB” invariant of this stage.

⁷ Origin CA certs last up to 15 years — renewal is rare; not LE-style automation, but fine for one host.

⁸ Tunnel replaces (or bypasses) the public HTTP(S) NLB path; architecture change, not an add-on to the current edge.

⁹ Would replace or duplicate ingress-nginx; large migration vs current Flux HelmRelease.

¹⁰ Works if the CronJob is solid; silent renewal failures are the usual failure mode.

---

## 1. Cert-Manager + ExternalDNS (Cloudflare as DNS host)

De-facto k8s setup. Two controllers, one Cloudflare API token (zone DNS edit), one ACME account. Cloudflare only hosts the zone; record **content** is still the OCI NLB public IP (DNS-only / grey-cloud).

**DNS:** ExternalDNS watches Ingress (and optionally Service) objects and upserts A/AAAA records → **NLB public IP**.

**TLS:** cert-manager issues Let's Encrypt certs via:

- **HTTP-01** — simplest; challenge traffic is `Internet → NLB :80 → NodePort → ingress`. Good for one hostname.
- **DNS-01** — same Cloudflare token; needed for **wildcards** (`*.example.com`) or if you ever close :80.

Flow:

```text
app.example.com  A/AAAA  →  OCI NLB public IP
Internet → NLB :80/:443 → NodePort → ingress-nginx
  Ingress (host + tls + cluster-issuer)
    → cert-manager → Let's Encrypt → TLS Secret → ingress :443
    → (optional) ExternalDNS keeps the A/AAAA in sync
```

**Pros:** Matches R5/R6/R7; same pattern as most public charts; wildcard-ready with DNS-01; debug via `Certificate` / `Order` / `Challenge` and ExternalDNS logs.

**Cons:** Highest in-cluster footprint of the serious options (cert-manager webhook + cainjector + controller, plus external-dns). Must teach ExternalDNS the static NLB IP. Buys almost nothing when there is only one public Ingress.

**Fit:** Preferred path for this stage when you want DNS + TLS both GitOps-managed (see Implementation steps).

---

## 2. Cert-Manager + manual DNS (→ OCI NLB IP)

Same TLS automation as (1), skip ExternalDNS.

In Cloudflare (or any DNS provider): create **one** A/AAAA for the public hostname, **value = OCI NLB public IP**, proxy **off** (DNS-only). Annotate that Ingress with `cert-manager.io/cluster-issuer` and a `tls:` secretName. HTTP-01 reaches the cluster through the same NLB :80 listener. Extra public apps stay as paths on that one host.

**Pros:** Fewest moving parts that still meet R4+R5; fewer pods/CRDs; NLB IP almost never changes, so the one DNS record is set-and-forget.

**Cons:** Adding a *second* public hostname later means another manual DNS edit (or then introducing ExternalDNS).

**Fit:** Lighter alternative when there is only one public hostname and you are fine creating the A/AAAA once by hand.


# Preferred: Variant
***

```text
app.example.com  A/AAAA  →  <nlb_public_ip>   # ExternalDNS upserts; DNS-only (grey-cloud)
Internet → OCI NLB :80/:443 → NodePort → ingress-nginx (LE cert) → Service
```

Same edge as today: Cloudflare only hosts DNS; record **content** is the OCI NLB public IP; TLS terminates on ingress-nginx behind the NLB.

- Prefer **HTTP-01** while NLB :80 stays open; DNS-01 only if you need wildcards or close :80.
- Let's Encrypt **staging** issuer first, then production (avoid rate limits).
- Cap requests/limits; single-replica cert-manager (and ExternalDNS if used).
- Put public apps as paths under **one** public host on `manifests/public-ingress.yaml`.
- Leave internal `polywhale.com` (stage 02 CoreDNS) alone — this stage is public edge only.

**Skip:** Cloudflare Tunnel and orange-cloud Origin CA (both pull clients off direct NLB access), Traefik/Caddy swap, DIY CronJobs.

# Implementation steps
***

## 0. Shared prerequisites

1. **Public hostname** — choose one FQDN (see [Free domains?](#free-domains) if you do not already own a name). Paths under that host cover public apps (`/one`, `/two`, …). For Variant 1 the zone should live on Cloudflare; for Variant 2 any DNS host where you can set an A record is enough.
2. **NLB public IP** — from Terraform:

   ```bash
   terraform -chdir=tf output -raw load_balancer_public_ip
   # or: terraform -chdir=tf output load_balancer_public_ip
   ```

   DNS A/AAAA **must** be this IP (not a worker, not a Cloudflare orange-cloud address).
3. **Confirm HTTP path still works** — `curl -I http://<nlb_public_ip>/one` (or an existing public path) returns from ingress-nginx. HTTP-01 needs NLB :80 → NodePort `31600` → public ingress-nginx.
4. **Flux + SOPS** — already set up (`mise run fluxcd-age-setup`). Cloudflare API tokens (Variant 1) go in SOPS-encrypted Secrets; encrypt with `mise run age-encrypt <file>`.
5. **Do not** enable `controller.service` on the public ingress-nginx HelmRelease — public exposure stays Terraform NLB → `nlb-public-nodeport`.

---

## Variant 1 — Cert-Manager + ExternalDNS (Cloudflare) + TLS at ingress

Goal: ExternalDNS keeps the public A/AAAA pointed at the NLB IP; cert-manager issues/renews a Let's Encrypt cert on the public Ingress; TLS terminates at ingress-nginx.

### 1. Cloudflare API token

1. Cloudflare dashboard → **My Profile** → **API Tokens** → Create Token.
2. Permissions (minimum):
   - **Zone → DNS → Edit**
   - **Zone → Zone → Read** (ExternalDNS zone discovery)
3. Zone Resources: include only the public zone you will use.
4. Save the token once; it will live in a SOPS Secret (next steps). Same token can later serve DNS-01 if you switch challenge type.

### 2. Install cert-manager (Flux)

1. Add a HelmRepository for Jetstack (alongside `ingress-nginx` under `manifests/` / flux sources), e.g. `https://charts.jetstack.io`.
2. Add a HelmRelease for `cert-manager` in its own namespace (typical: `cert-manager`):
   - `installCRDs: true`
   - single replica for controller / webhook / cainjector
   - tight `resources.requests` / `limits` (Always Free)
3. Wire the new manifests into `manifests/kustomization.yaml` (or a Flux Kustomization that already syncs `manifests/`).
4. Commit, push, wait for Flux. Check:

   ```bash
   kubectl -n cert-manager get pods
   kubectl get crd | grep cert-manager
   ```

### 3. ClusterIssuers (staging then production)

1. Create two `ClusterIssuer` objects (HTTP-01 via the **public** ingress class `nginx`):

   - `letsencrypt-staging` → `https://acme-staging-v02.api.letsencrypt.org/directory`
   - `letsencrypt-prod` → `https://acme-v02.api.letsencrypt.org/directory`

2. Solver sketch (same shape for both; only `server` and `email` differ):

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: letsencrypt-staging
   spec:
     acme:
       email: you@example.com
       server: https://acme-staging-v02.api.letsencrypt.org/directory
       privateKeySecretRef:
         name: letsencrypt-staging-account-key
       solvers:
         - http01:
             ingress:
               class: nginx
   ```

3. Apply via GitOps; confirm `kubectl get clusterissuer` shows `Ready=True`.

### 4. Install ExternalDNS (Flux) → Cloudflare

Use the **kubernetes-sigs** chart already wired in-repo (`manifests/external-dns/`, chart `1.21.1` → app `0.21.0`). Do not switch to Bitnami; value shapes differ.

1. Create a Secret (SOPS-encrypt before commit) in namespace `external-dns`. Key name must match the HelmRelease `env` below:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflare-api-token
     namespace: external-dns
   stringData:
     api-token: "<token from step 1>"
   ```

2. HelmRepository: `https://kubernetes-sigs.github.io/external-dns` (see `manifests/external-dns/helmrepository.yaml`).

3. HelmRelease (`manifests/external-dns/helmrealse.yaml`): set `spec.targetNamespace: external-dns` and `spec.releaseName: external-dns`. Chart Deployment is hardcoded to **1 replica** — fine for Always Free; do not try to scale it.

#### ExternalDNS values — what each key does here

| Chart value | Proposed | Why |
|-------------|----------|-----|
| `provider.name` | `cloudflare` | DNS host for the public zone (grey-cloud A records only). |
| `env[CF_API_TOKEN]` | Secret `cloudflare-api-token` / key `api-token` | Token auth; do **not** also set `CF_API_KEY`/`CF_API_EMAIL`. |
| `domainFilters` | `[example.com]` | Manage **only** the public zone. Keeps internal `*.polywhale.com` Ingresses out of Cloudflare. Replace with your real apex. |
| `txtOwnerId` | `oci-free-k8s` | Ownership TXT marker so another ExternalDNS (or a rebuild) does not fight this cluster’s records. |
| `registry` | `txt` (default) | Stores ownership next to each managed record. |
| `sources` | `[ingress]` | One public Ingress is enough. Drop `service` / `crd` / `gateway-httproute` — with `controller.service.enabled: false` there is no cloud LB IP to discover, and extra sources only invent bad targets. |
| `managedRecordTypes` | `[A]` | NLB is IPv4 today (`load_balancer_public_ip`). Add `AAAA` only if you later publish an IPv6 NLB address. |
| `policy` | `upsert-only` | Create/update records; do **not** delete stale ones until you trust the setup. Switch to `sync` later if you want deletions. |
| `extraArgs.default-targets` | `"<nlb_public_ip>"` | **Required.** Ingress has no `status.loadBalancer` IP (Service disabled). This forces every managed A record → OCI NLB public IP. Prefer this over per-Ingress `external-dns.alpha.kubernetes.io/target` so the IP lives in one GitOps place. |
| `extraArgs.cloudflare-proxied` | omit / `false` | Must stay **DNS-only** (R4). Enabling proxy would orange-cloud records and break “DNS → NLB”. |
| `extraArgs.exclude-target-net` | `10.0.0.0/8` | Belt-and-suspenders: ignore private ClusterIP/node nets if a source ever leaks them. Harmless with `default-targets` set. |
| `interval` | `1m` (default) | Fast enough for one hostname; Cloudflare rate limits are not a concern at this scale. |
| `resources` | requests/limits below | Cap Always Free footprint. |

**Chosen NLB targeting approach:** `--default-targets` in Helm values (not Ingress annotations). Do not also set `external-dns.alpha.kubernetes.io/target` unless you temporarily override.

#### Proposed `spec.values` (paste into the HelmRelease)

Replace `example.com` and `<nlb_public_ip>` before commit (`terraform -chdir=tf output -raw load_balancer_public_ip`):

```yaml
values:
  provider:
    name: cloudflare
  policy: upsert-only
  sources:
    - ingress
  domainFilters:
    - example.com
  txtOwnerId: oci-free-k8s
  managedRecordTypes:
    - A
  env:
    - name: CF_API_TOKEN
      valueFrom:
        secretKeyRef:
          name: cloudflare-api-token
          key: api-token
  extraArgs:
    default-targets: "<nlb_public_ip>"
    exclude-target-net: "10.0.0.0/8"
    # do NOT set cloudflare-proxied: true  — records must stay DNS-only
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 50m
      memory: 64Mi
```

Map-form `extraArgs` renders as `--default-targets=<ip>` / `--exclude-target-net=10.0.0.0/8` (chart 1.21.1). Array form (`- --default-targets=...`) is equivalent if you prefer it.

#### Align the in-repo draft

Current `manifests/external-dns/helmrealse.yaml` is a stub — update it to match the table above:

- Secret ref: `cloudflare-api-token` / `api-token` (not `external-dns-config` / `apiKey`).
- `sources: [ingress]` only (drop `service`, `crd`, `gateway-httproute`).
- Add `domainFilters`, `txtOwnerId`, `default-targets`, and `resources`.
- Change `policy: sync` → `upsert-only` until DNS behaviour looks right.
- Add `spec.targetNamespace: external-dns` so the pod and Secret share a namespace.

4. Commit, sync, check logs:

   ```bash
   kubectl -n external-dns logs deploy/external-dns -f
   ```

### 5. Wire the public Ingress (host + TLS + DNS)

Update `manifests/public-ingress.yaml`:

1. Set `spec.rules[].host` to the public FQDN (same host on every rule block you need).
2. Add `spec.tls` with that host and a `secretName` (e.g. `public-ingress-tls`) — cert-manager will create/fill the Secret.
3. Annotate:

   ```yaml
   annotations:
     cert-manager.io/cluster-issuer: letsencrypt-staging   # switch to -prod after success
     # NLB IP comes from HelmRelease extraArgs.default-targets — do not also set:
     # external-dns.alpha.kubernetes.io/target: "<nlb_public_ip>"
     # hostname is taken from spec.rules[].host; override only if needed:
     # external-dns.alpha.kubernetes.io/hostname: app.example.com
   ```

4. Keep existing paths (`/one`, `/two`, …) and `ingressClassName: nginx`.
5. Commit and sync.

### 6. Verify DNS then TLS

1. **DNS** — ExternalDNS should create/update A (and AAAA if applicable) for the hostname → NLB IP, **grey-cloud**.

   ```bash
   dig +short app.example.com
   # must equal terraform load_balancer_public_ip
   ```

2. **HTTP-01** — cert-manager creates `Certificate` / `Order` / `Challenge`; challenge path must be reachable via NLB :80:

   ```bash
   kubectl get certificate,order,challenge -A
   kubectl describe certificate -n default public-ingress-tls   # name matches secretName
   ```

3. **HTTPS** — after `Ready=True` on the Certificate:

   ```bash
   curl -vI https://app.example.com/one
   ```

   Staging issuer → browsers/curl will not fully trust the cert; that is expected. Switch annotation to `letsencrypt-prod`, delete the old Certificate/Secret if needed so it re-issues, re-verify.

4. Confirm TLS is on **ingress-nginx**, not the NLB (NLB remains L4 TCP passthrough on :443).

### 7. Harden / operate

- Cap CPU/memory on cert-manager and external-dns; avoid HA replicas on Always Free.
- Prefer leaving :80 open for renewals; if you close it later, migrate solvers to DNS-01 (reuse Cloudflare token).
- Do not orange-cloud the record — that breaks R4 (clients would hit Cloudflare, not the NLB).
- Internal Ingress (`nginx-internal`) and `polywhale.com` stay WireGuard-only; do not point ExternalDNS at them unless you intentionally want public records (you do not).

---

## Variant 2 — Cert-Manager + manual DNS (→ OCI NLB IP)

Same TLS automation as Variant 1; **no** ExternalDNS and **no** Cloudflare API token (HTTP-01 only).

### 1. Install cert-manager + ClusterIssuers

Follow **Variant 1 steps 2–3** exactly (HelmRelease, CRDs, staging + prod `ClusterIssuer` with `http01.ingress.class: nginx`).

### 2. Create the DNS record by hand

1. Cloudflare → DNS → Add record:
   - **Type:** A (and AAAA if you have one)
   - **Name:** public hostname (`app` or FQDN per CF UI)
   - **Content / IPv4:** `terraform output load_balancer_public_ip`
   - **Proxy status:** DNS only (grey cloud)
   - TTL: Auto is fine
2. Wait for propagation:

   ```bash
   dig +short app.example.com
   # must equal NLB public IP
   ```

### 3. Wire the public Ingress (host + TLS only)

Update `manifests/public-ingress.yaml` like Variant 1 step 5, **without** ExternalDNS annotations:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.example.com
      secretName: public-ingress-tls
  rules:
    - host: app.example.com
      http:
        paths:
          # existing /one, /two, …
```

Commit, sync.

### 4. Verify TLS

Same checks as Variant 1 step 6 (Certificate Ready → `curl -vI https://…` → switch to `letsencrypt-prod`).

If HTTP-01 fails: confirm DNS still points at the NLB, NLB :80 → NodePort 31600, and the Ingress host matches the ACME name exactly.

### 5. When to graduate to Variant 1

Introduce ExternalDNS (Variant 1 steps 1, 4, and ExternalDNS annotations / `--default-targets`) when:

- you add a **second** public hostname, or
- you want GitOps to own DNS upserts instead of a one-shot Cloudflare click.

ClusterIssuers and the Ingress `tls:` block do not need to change.

---

## Implementatation notes comparison (ops)

External-DNS configures Cloudflare DNS record for ingress resource. It updates domains by `spec.rules[*].host` the content of the record is taken from `metadata.external-dns.alpha.kubernetes.io/target`. It's crucial to set `-exclude-target-net=10.0.0.0/8` in the external-dns `HelmRelease` otherwise it have been also adding node's cluster IP as DNS record.

Configuration of `cert-manager` requires to create one stage _(for debugging)_ and one prod `Issuer/ClusterIssuer` specifying `spec.acme.privateKeySecretRef.name` _(name of the secret that cert-manager will automatically create)_ and solver `spec.acme.solvers[*]` http01 or dns01.

Using http01 solver only thing left is to choose `Issuer/ClusterIssuer` at the nginx ingress side `metadata.annotations.cert-manager.io/cluster-issuer` and specify `spec.tls` with host names. You can add subdomains of cloudflare dns domain.

```yaml
  tls:
    - hosts: [test.domain.cc, domain.cc]
  rules:
    - host: test.domain.cc
      ...
    - host: domain.cc
      ...
```

Let's Encrypt issues fixed ~90-day certs and ignores custom duration

```yaml
annotations:
  cert-manager.io/duration: 2160h   # 90d — requested lifetime
  cert-manager.io/renew-before: 360h # renew 15d before expiry
```

Also `Ingress` with `tls` by default redirect HTTP to HTTPS. Similar to

```yaml
annotations:
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
  # optional: also redirect if a proxy set X-Forwarded-Proto
  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```