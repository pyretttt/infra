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

**Fit:** Skip unless public hostnames multiply later.

---

## 2. Cert-Manager + manual DNS (→ OCI NLB IP)

Same TLS automation as (1), skip ExternalDNS.

In Cloudflare (or any DNS provider): create **one** A/AAAA for the public hostname, **value = OCI NLB public IP**, proxy **off** (DNS-only). Annotate that Ingress with `cert-manager.io/cluster-issuer` and a `tls:` secretName. HTTP-01 reaches the cluster through the same NLB :80 listener. Extra public apps stay as paths on that one host.

**Pros:** Fewest moving parts that still meet R4+R5; fewer pods/CRDs; NLB IP almost never changes, so the one DNS record is set-and-forget.

**Cons:** Adding a *second* public hostname later means another manual DNS edit (or then introducing ExternalDNS).

**Fit:** Best match for a single public Ingress on this free-tier cluster.

---

## 3. Cloudflare proxy + Origin CA

Orange-cloud the record so **public DNS resolves to Cloudflare**, not the NLB. Cloudflare terminates browser TLS; it then connects to the NLB as origin. Install a long-lived [Cloudflare Origin CA](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/) cert as a TLS Secret on ingress-nginx and set SSL mode to **Full (strict)**.

**Pros:** Tiny cluster footprint (no ACME renewals, no LE rate limits); DDoS/WAF in front of the free-tier NLB.

**Cons:** Violates R4 — clients no longer resolve/hit the OCI NLB directly. Origin CA is not a general public CA if you ever switch back to grey-cloud; less “k8s-native” status than cert-manager `Certificate` objects.

**Fit:** Only if you explicitly want Cloudflare in the data path; not the default for this NLB-based edge.

---

## 4. Cloudflare Tunnel

`cloudflared` in-cluster publishes apps to Cloudflare; DNS and edge TLS are handled there. No need for public :80/:443 on the NLB for HTTP(S) (WireGuard listener can remain).

**Pros:** Strong automation + optional Access auth; no Let's Encrypt on origin; no exposure of node ports for web.

**Cons:** Sidesteps the NLB edge you already built; private DNS / WireGuard story from stages 01–02 stays separate; another daemon and Cloudflare app dependency; harder to debug “is it tunnel, ingress, or app?”

**Fit:** Only if you deliberately want to retire public HTTP(S) on the NLB — not the incremental next step.

---

## 5. Traefik / Caddy with built-in ACME

Ingress controller does ACME itself (no cert-manager). ExternalDNS (or manual DNS) still needed for names.

**Pros:** One less operator if you were greenfield on Traefik/Caddy.

**Cons:** You already run **two** ingress-nginx controllers (public + internal) under Flux. Replacing them is a migration, not a cert add-on. Worse R7/R6 for this repo.

**Fit:** Reject unless you plan to drop nginx entirely.

---

## 6. DIY certbot / acme.sh CronJob

CronJob runs ACME, writes a TLS Secret, Ingress references it. DNS stays manual or scripted.

**Pros:** Minimal continuous footprint between renewals.

**Cons:** Custom scripting, weak status model, easy to break renewals silently — poor R5/R6 compared to cert-manager.

**Fit:** Avoid for a GitOps cluster.

---

## 7. Self-signed / mkcert only

Fine for in-cluster or WireGuard-only experiments; browsers will warn on the public NLB path.

**Fit:** Not for public HTTPS. Out of scope for this stage's goal.

---

# Recommendation
***

**Use Cert-Manager + HTTP-01 + one manual DNS record → OCI NLB public IP** (variant 2).

```text
app.example.com  A/AAAA  →  <nlb_public_ip>   # DNS-only, not Cloudflare-proxied
Internet → OCI NLB :80/:443 → NodePort → ingress-nginx (LE cert) → Service
```

That meets R4+R5 with a single public Ingress: create the A/AAAA once (value from Terraform NLB output); cert-manager renews the cert. Cap requests/limits; single-replica cert-manager. Issuer: Let's Encrypt staging first, then production. Put public apps on paths under that one host.

**Do not install ExternalDNS** unless a second public hostname appears. Prefer **HTTP-01** while :80 stays open through the NLB; DNS-01 / wildcards are unnecessary for one name.

**Skip:** Cloudflare Tunnel and orange-cloud Origin CA (both pull public clients off direct NLB access), Traefik/Caddy swap, DIY CronJobs.

**Manual steps:** set the DNS A/AAAA to the NLB public IP (proxy off). ACME registration is handled by cert-manager (no Cloudflare API token needed for HTTP-01).
