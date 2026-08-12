# What we do now
***

We want to login to **n8n** and **Grafana** through **GitHub**, preferably via a small in-cluster broker (e.g. Dex).

Today both apps sit on the **internal** Ingress (`nginx-internal`) and are reached over **WireGuard** only:

```text
WG client → CoreDNS *.polywhale.com → ingress-nginx-internal → Grafana / n8n
```

Passwords (Grafana admin secret, n8n local users) + network isolation are the only gate. There is no shared IdP, no oauth2-proxy, and no GitHub OAuth App yet.

Important constraint for this stage:

| App | Native GitHub / OIDC on free tier? | Implication |
|-----|--------------------------------------|-------------|
| Grafana | **Yes** — `[auth.github]` or generic OIDC | Can talk to GitHub or Dex directly |
| n8n Community | **No** — OIDC/SAML is Business/Enterprise | Need a **proxy** (oauth2-proxy / ingress auth) or a community hook; do not plan on `N8N_SSO_OIDC_*` without a paid license |

OAuth callbacks are fine on WireGuard: GitHub redirects the **browser**, and the browser already reaches `*.polywhale.com` via WG. Dex’s issuer URL must also be browser-reachable on the internal Ingress (e.g. `https://dex.polywhale.com`).

# Requirements
***

| # | Requirement | Notes |
|---|-------------|-------|
| R1 | Free / OCI Always Free | No extra nodes; stay within existing A1.Flex pool |
| R2 | Low OCPU / memory | Controllers must stay tiny; prefer one replica each |
| R3 | Trusted HTTPS in browsers | Public CA on ingress-nginx (Let's Encrypt); NLB stays L4 / no TLS there — same edge as stage 03 for anything public; internal names may stay HTTP-on-WG for now |
| R4 | DNS → existing OCI NLB → NodePort | Public A/AAAA = NLB public IP when exposing auth/apps publicly; do not require a cloud `LoadBalancer` Service or paid OCI LB |
| R5 | GitHub login for Grafana **and** n8n | One GitHub allowlist (org/users); n8n Community cannot use native OIDC |
| R6 | Maintainable / debuggable | Clear status objects, logs, and failure modes |
| R7 | Fits Flux / GitOps | HelmReleases + Secrets (SOPS); no imperative snowflake steps beyond GitHub OAuth App creation |

# OIDC / SSO options
***

## Comparison matrix

Legend: **Y** = meets, **P** = partial / with caveats, **N** = does not meet.

| Variant | R1 Free | R2 Low footprint | R3 TLS edge | R4 NLB path | R5 GH→both apps | R6 Debuggable | R7 GitOps |
|---------|---------|------------------|-------------|-----------------|-----------------|---------------|-----------|
| Dex (GitHub) + Grafana OIDC + oauth2-proxy for n8n | Y | Y¹ | Y | Y | Y | Y | Y |
| No broker: Grafana `[auth.github]` + oauth2-proxy (GitHub) for n8n | Y | Y² | Y | Y | Y | Y | Y |
| oauth2-proxy only (GitHub) in front of both | Y | Y | Y | Y | Y³ | P | Y |
| Dex + Grafana OIDC; n8n stays password | Y | Y | Y | Y | P⁴ | Y | Y |
| WireGuard + passwords only (status quo) | Y | Y | Y | Y | N | Y | Y |
| Authentik (GitHub source) | Y | N⁵ | Y | Y | Y | Y | Y |
| Keycloak | Y | N⁶ | Y | Y | Y | P | P |
| Authelia (file/LDAP users) | Y | Y | Y | Y | N⁷ | Y | Y |
| Cloudflare Access (+ Tunnel/proxy) | Y | Y⁸ | Y | N⁹ | P¹⁰ | P | P |
| Community `n8n-oidc` hook + Dex/Grafana | Y | Y | Y | Y | Y¹¹ | P | P |

¹ Dex ~32–64 Mi + oauth2-proxy ~32–64 Mi; single replica each; pin ARM images.

² No Dex pod; two GitHub OAuth Apps (or one App with multiple callbacks) and duplicated allowlist config.

³ Both apps get the same GitHub gate; Grafana loses native org/team → Grafana org mapping unless you re-introduce Grafana OAuth later.

⁴ Grafana only; n8n still local password (acceptable interim).

⁵ Authentik wants Postgres + several hundred MiB RSS — tight on 2×6 GiB with Prom/Grafana/n8n already running.

⁶ Keycloak routinely ≥1 GiB; poor Always Free fit.

⁷ Authelia is a fine forward-auth portal for **local** users; it is not a drop-in “login with GitHub → OIDC for apps” broker the way Dex is.

⁸ Zero in-cluster IdP, but moves identity to Cloudflare.

⁹ Orange-cloud / Tunnel pulls clients off direct NLB (and does nothing useful for WireGuard-only `*.polywhale.com`).

¹⁰ Easy for **public** hostnames behind CF; awkward for private WG apps (callbacks/policies fight the internal DNS story).

¹¹ Works without n8n paid SSO, but is a third-party hook (`EXTERNAL_HOOKS` / assets); treat as optional, not the default GitOps path.

---

## 1. Dex (GitHub connector) + Grafana OIDC + oauth2-proxy for n8n

Canonical “small k8s IdP” pattern. Dex speaks GitHub OAuth upstream and OIDC downstream. Grafana uses generic OAuth/OIDC against Dex. n8n Community sits behind **oauth2-proxy** (nginx `auth-url` / `auth-signin` annotations) because native OIDC is paid.

```text
Browser (WG)
  → grafana.polywhale.com  → Grafana  → Dex (OIDC) → GitHub
  → n8n.polywhale.com      → oauth2-proxy → GitHub (or Dex as OIDC upstream)
  → dex.polywhale.com      → Dex (issuer + callback)
```

Prefer pointing **oauth2-proxy at Dex** (OIDC) rather than at GitHub directly so there is **one** GitHub OAuth App and one org/user allowlist in Dex.

**Pros:** One broker for future apps (Dagu UI, etc.); Grafana gets real OIDC claims; n8n protected without a paid license; tiny footprint; Helm/GitOps friendly; ARM images exist.

**Cons:** Two small controllers + Ingress annotations for n8n; Dex issuer must be on internal Ingress; oauth2-proxy session ≠ n8n user identity (proxy gate only — n8n may still show its own login unless you also solve app-level auth).

**Fit:** Preferred when you want a shared GitHub IdP and may add more apps later.

**oauth2-proxy vs n8n login:** Forward auth only proves “this browser may reach n8n.” n8n Community still has its own user DB. Options: (a) accept double login once (proxy then n8n owner), (b) disable/limit n8n user invite and keep a single local owner behind the proxy, (c) later evaluate `n8n-oidc` if you need true SSO into n8n sessions.

---

## 2. No broker — Grafana `[auth.github]` + oauth2-proxy (GitHub) for n8n

Skip Dex. Grafana’s built-in GitHub OAuth. Separate oauth2-proxy with GitHub provider for n8n (and any other non-OIDC app).

**Pros:** Fewest pods; Grafana GitHub org/team mapping is first-class; no issuer URL to maintain.

**Cons:** Two (or more) places to configure GitHub client id/secret and allowlists; no reusable OIDC issuer for future apps; duplicated SOPS secrets.

**Fit:** Lightest path if Grafana + n8n are the **only** GitHub-gated apps forever.

---

## 3. oauth2-proxy only (GitHub) in front of Grafana and n8n

One proxy (or one Deployment + two Ingress auth annotations) gates both UIs. Grafana admin password can stay as break-glass; disable Grafana’s form login if desired.

**Pros:** Uniform gate; one GitHub App; works for any HTTP app.

**Cons:** Grafana never sees GitHub identity (no per-user Grafana accounts / team sync); debugging is “proxy 401” vs app logs; slightly worse UX than native Grafana OAuth.

**Fit:** Acceptable if you only care about “must be in our GitHub org,” not per-user Grafana ACLs.

---

## 4. Dex + Grafana OIDC; n8n stays password (+ WireGuard)

Same as (1) but defer oauth2-proxy until n8n needs sharing.

**Pros:** Smallest useful OIDC cut; proves Dex + Grafana first.

**Cons:** Does not meet R5 fully until n8n is gated.

**Fit:** Good **phase-1** if you want to land Dex without touching n8n Ingress yet.

---

## 5. WireGuard + passwords only (status quo)

**Pros:** Zero extra RAM; already deployed; WG is the real perimeter.

**Cons:** Shared passwords; no GitHub offboarding; fails R5.

**Fit:** Fine until a second human needs access or you want GitHub-based revoke.

---

## 6. Authentik / Keycloak

Full IdPs (flows, apps UI, optional LDAP, etc.).

**Pros:** Feature-rich; native OIDC for anything that can speak it.

**Cons:** Postgres + large RSS; Keycloak especially hostile to Always Free next to kube-prometheus-stack + n8n. Overkill for “GitHub org may open Grafana/n8n.”

**Fit:** Skip for this cluster.

---

## 7. Authelia

Excellent forward-auth for file/LDAP users; pairs well with ingress-nginx `auth-url`.

**Pros:** Light; mature; GitOps-friendly.

**Cons:** Does not replace Dex for “GitHub as the source of truth” without extra glue; not the path implied by R5.

**Fit:** Skip unless you abandon GitHub login and want local 2FA users instead.

---

## 8. Cloudflare Access

Identity at the edge (GitHub IdP in CF Access policies).

**Pros:** No in-cluster IdP; strong policy UI.

**Cons:** Breaks R4 for public apps (clients hit Cloudflare, not NLB); does not protect WireGuard-only `*.polywhale.com` without putting those names on CF and changing the access path; architecture change, not an add-on.

**Fit:** Skip for this stage (same reason as Tunnel/Origin CA in stage 03).

---

## 9. Community `n8n-oidc` (+ Dex)

Third-party hooks inject OIDC into Community n8n so Dex can provision real n8n sessions.

**Pros:** True SSO into n8n without Business license.

**Cons:** Extra image/volume/env surface; not an official n8n feature; upgrade risk; weaker “debuggable standard chart” story (R6/R7 partial).

**Fit:** Optional later if double login (oauth2-proxy + n8n form) is unacceptable — not the first merge.

---

# Preferred
***

```text
                    GitHub OAuth App (one)
                           ↑
Browser (WG) → dex.polywhale.com → Dex
                 ↑                ↑
         Grafana OIDC      oauth2-proxy (OIDC to Dex)
                 ↑                ↑
         grafana.polywhale.com   n8n.polywhale.com
              (nginx-internal)   (nginx-internal + auth annotations)
```

**Primary: Variant 1** — Dex (GitHub connector) + Grafana → Dex + oauth2-proxy → Dex in front of n8n.

- One GitHub OAuth App; Dex holds org/user allowlist.
- Grafana: generic OAuth/OIDC client against Dex (role mapping from GitHub teams via Dex `staticClients` + connectors).
- n8n: ingress-nginx `auth-url` → oauth2-proxy; accept Community’s local owner login as a second factor or break-glass until/unless you adopt `n8n-oidc`.
- All of Dex, oauth2-proxy, Grafana, n8n on **internal** Ingress + WireGuard; do not publish Dex on the public NLB unless you deliberately want public login.
- Single replica, tight requests/limits, `linux/arm64` images only.
- Secrets (GitHub client secret, Dex client secrets, oauth2-proxy cookie secret) via SOPS.

**Phase-1 slice (optional):** Variant 4 — ship Dex + Grafana OIDC first; add oauth2-proxy for n8n in a follow-up commit.

**Lighter alternative:** Variant 2 if you are sure you will never need a shared OIDC issuer.

**Skip:** Authentik, Keycloak, Authelia-as-GitHub-broker, Cloudflare Access/Tunnel for this stage, Traefik/ForwardAuth rewrites that replace ingress-nginx.

# Useful information
***

## WireGuard + OAuth

- Authorization code flow needs the **browser** to reach `redirect_uri`. With WG + CoreDNS, `https://dex.polywhale.com/callback` (and Grafana/oauth2-proxy callbacks) work without a public DNS record.
- Dex pods must reach `https://github.com` (egress). Grafana/oauth2-proxy must reach Dex’s issuer (ClusterIP Service is enough for token exchange; browser still uses the external issuer URL).
- Set Grafana `root_url` / n8n `editor_base_url` to the same host the browser uses (already `*.polywhale.com`). Prefer HTTPS on the internal Ingress when you terminate TLS there; if you stay HTTP-on-WG, OAuth cookies may need `secure: false` (Grafana/oauth2-proxy cookie flags) — match reality or add internal TLS.

## GitHub OAuth App checklist

1. GitHub → Settings → Developer settings → **OAuth Apps** → New.
2. Homepage: `https://dex.polywhale.com` (or Grafana host if Variant 2).
3. Callback(s), depending on variant:
   - Dex: `https://dex.polywhale.com/callback`
   - Grafana native GitHub: `https://grafana.polywhale.com/login/github`
   - oauth2-proxy direct GitHub: `https://n8n.polywhale.com/oauth2/callback` (path depends on proxy config)
4. Copy Client ID / secret → SOPS Secret.
5. Restrict to your org via Dex `orgs:` / oauth2-proxy `github-org` / Grafana `allowed_organizations`.

## Grafana config sketch (OIDC → Dex)

```yaml
# kube-prometheus-stack values (grafana.ini / grafana.env)
grafana.ini:
  server:
    root_url: https://grafana.polywhale.com
  auth.generic_oauth:
    enabled: true
    name: GitHub
    allow_sign_up: true
    client_id: grafana
    client_secret: $__file{/etc/grafana/secrets/client_secret}  # or env
    scopes: openid profile email groups
    auth_url: https://dex.polywhale.com/auth
    token_url: https://dex.polywhale.com/token
    api_url: https://dex.polywhale.com/userinfo
    role_attribute_path: contains(groups[*], 'admins') && 'Admin' || 'Viewer'
```

Keep the admin basic auth secret as break-glass; optionally `disable_login_form` once Dex works.

## ingress-nginx + oauth2-proxy (n8n)

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.default.svc.cluster.local:4180/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://n8n.polywhale.com/oauth2/start?rd=$scheme://$host$escaped_request_uri"
```

oauth2-proxy needs its own Ingress path `/oauth2` on the same host (or a dedicated auth host). Cookie domains must match `polywhale.com` if you ever share sessions across apps.

## Footprint budget (order of magnitude)

| Component | RSS (approx.) | Notes |
|-----------|---------------|-------|
| Dex | 32–64 Mi | One replica; SQLite/in-memory fine for tiny static clients |
| oauth2-proxy | 32–64 Mi | One replica |
| Authentik stack | 500 Mi–1+ Gi | Avoid |
| Keycloak | ≥1 Gi | Avoid |

Stay well under leftover RAM after kube-prometheus-stack + n8n (~512 Mi–2 Gi already).

## n8n SSO reality check

| Approach | Community OK? | Real n8n user session from GitHub? |
|----------|---------------|-------------------------------------|
| Native `N8N_SSO_OIDC_*` | No (paid) | Yes |
| oauth2-proxy / Authelia forward auth | Yes | No (gate only) |
| `n8n-oidc` community hook | Yes (unofficial) | Yes |
| Password + WireGuard | Yes | N/A |

## Relation to stage 03 / 04

- Stage 03 TLS/DNS is about the **public** edge. This stage’s Dex/Grafana/n8n hosts are **internal** unless you explicitly publish them.
- Stage 04 already flagged Dex as follow-up after password + WG Grafana; this doc is that follow-up for identity, extended to n8n.

# Implementation steps
***

Deferred until Variant 1 (or 2 / phase-1 Variant 4) is confirmed. Likely order:

1. GitHub OAuth App + SOPS secrets  
2. Dex HelmRelease + internal Ingress `dex.polywhale.com` + CoreDNS already covers `*.polywhale.com`  
3. Grafana generic OAuth → Dex; verify login over WG  
4. oauth2-proxy HelmRelease + n8n Ingress auth annotations  
5. Harden: org allowlist, break-glass admin, resource caps, no public Dex Ingress  

---
