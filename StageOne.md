# What is needed
***

Currently public cluster endpoints are exposed through NLB (L4) which targets NodePort.
NodePort chains to Ingress, which resolves to a specific service. This is fine for a small OCI cluster.

```text
Internet → NLB :80/:443 → worker NodePort 31600/31601 → ingress-nginx → Service
```

There is also a need for **private endpoints** that must not be part of the public API.
Omitting a host/path from `manifests/ingress.yaml` (and from public DNS) is enough to keep the
endpoint off the public edge. Reaching that private endpoint then needs an access path into the VCN.

# Access options for private endpoints
***

## Requirements

| # | Requirement | Notes |
|---|-------------|-------|
| R1 | Free / OCI Always Free | No paid SaaS tier; no extra Always Free shape beyond what the cluster already uses |
| R2 | Works with HTTPS | Full TLS to the app (or TLS at a trusted edge in front of it) |
| R3 | Browser-native | Open a URL in a normal browser; no local tunnel CLI as the primary UX |
| R4 | One person, several devices | Laptop + phone + maybe tablet; not a team IdP story |
| R5 | Low footprint | No heavy client/daemon; no extra Always Free VM if avoidable |
| R6 | Easy setup | Hours, not a weekend of PKI/routing |
| R7 | Resolve private domains | Hit names like `foo.internal` / in-cluster DNS, not only public hostnames |

## Comparison matrix

Legend: **Y** = meets, **P** = partial / with caveats, **N** = does not meet.

| Variant | R1 Free | R2 HTTPS | R3 Browser | R4 Multi-device | R5 Low footprint | R6 Easy | R7 Private DNS |
|---------|---------|----------|------------|----------------|------------------|---------|----------------|
| WireGuard VPN | Y | Y | N | Y | Y | P | Y |
| Tailscale / Headscale | Y¹ | Y | N | Y | Y | Y | Y |
| OCI Bastion (SSH forward) | Y | P | N | P | Y | P | N |
| Cloudflare Tunnel (+ Access) | Y | Y | Y | Y | Y | Y | N² |
| Public hostname + auth | Y | Y | Y | Y | Y | Y | N |
| SSH SOCKS / local forward | Y | Y | N | P | Y | Y | P |
| sshuttle | Y | Y | N | P³ | Y | Y | Y |
| Teleport (self-hosted) | Y⁴ | Y | Y⁵ | Y | N | N | P⁶ |

¹ Tailscale personal free tier; Headscale is self-hosted (needs a tiny coordinator).  
² Public CF hostnames only, unless you add WARP + private-net routing (then R3 becomes **N**).  
³ Great on laptops; phones are impractical.  
⁴ Community/self-hosted is free; Teleport Cloud is a paid product for real use.  
⁵ Browser app access via the Teleport proxy UI; `tsh` still needed for full CLI workflows.  
⁶ Apps are registered Teleport names, not arbitrary VCN/CoreDNS resolution (unless you also VPN/tunnel).

---

## 1. WireGuard VPN

**How it works.** Users run a WireGuard client; encrypted UDP tunnel into the VCN (peer on a worker node, or a small always-on pod/VM). Once up, the device is “on the private network”: route pod/NodePort CIDRs, talk HTTPS to private Services/Ingress.

**K8s fit.** Deploy `wg` as a DaemonSet/Deployment with `hostNetwork` or as a sidecar on one node; open UDP in the private subnet security list (`enable_wireguard` already exists in `tf/`). Point clients at private Ingress or ClusterIP via pushed routes. Optional: push a CoreDNS / VCN DNS IP for private names.

**Caveats.** Not browser-native (client app required). Peer keys and IP allocation are manual unless you add something like `wg-easy`. Phone on cellular + UDP blocking can be annoying. Must not accidentally expose the WG port broadly. DNS split-horizon needs explicit config or apps keep using public names.

**Recommend?** **Yes, as the primary private-access path** for this setup: free, tiny, HTTPS-native once connected, solves private DNS, already partially wired in Terraform. Accept the client install for a one-person / few-devices case.

---

## 2. Other VPN (Tailscale / Headscale; OpenVPN)

**How it works.** Same idea as WireGuard, with orchestration. Tailscale = WireGuard mesh + coordination SaaS + MagicDNS. Headscale = self-hosted Tailscale control plane. OpenVPN = TLS VPN, heavier and fussier.

**K8s fit.** Run a userspace/subnet-router pod (or install on one node) advertising the pod/Service CIDR or private subnet. Clients resolve MagicDNS / Headscale names or real private DNS via split DNS.

**Caveats.** Tailscale free is fine for personal use but is an external dependency; some prefer no third-party control plane → Headscale (extra process to run). Still not browser-native. OpenVPN: skip unless you already know it — worse footprint and setup than WireGuard/Tailscale.

**Recommend?** **Tailscale if you want the easiest VPN UX**; **plain WireGuard if you want zero SaaS**. Skip OpenVPN here.

---

## 3. OCI Bastion

**How it works.** Managed jump service already in `tf/bastion.tf`. You create a session (SSH), then local port-forward (`-L`) or proxy to a private IP:port (worker NodePort, pod IP via node, etc.). Free STANDARD bastion; IP allow-list via `bastion_allowed_ips`.

**K8s fit.** Good for **break-glass / kubectl / one-off TCP**: forward to API private endpoint, a NodePort, or `kubectl port-forward` over the bastion. Poor fit as the daily way to open private HTTPS apps in a browser (new session TTL, per-port forwards, no private DNS).

**Caveats.** Session TTL (currently 10800s). Not browser-native. Does not resolve private domains. Port-forward UX does not scale to “several apps on several devices.” Allow-list must track your public IPs (home/CGNAT pain).

**Recommend?** **Keep for admin/SSH/kubectl; do not use as the main private-app access path.**

---

## 4. Cloudflare Tunnel

**How it works.** `cloudflared` inside the cluster dials out to Cloudflare; you map `https://private.example.com` → an in-cluster Service. Optional Cloudflare Access (SSO / email OTP) in front. No inbound ports on the VCN for that app.

**K8s fit.** Deployment + Secret + Tunnel Ingress/config; target ClusterIP Services directly (can bypass public NLB). Fits Flux manifests cleanly. Free Zero Trust seat count is enough for one person.

**Caveats.** Names are **Cloudflare/public DNS names**, not VCN/cluster private DNS (R7 fails unless you add WARP client + private network routes — then you lose browser-native-only UX). You are trusting CF’s edge. Tunnel identity secrets must be sealed (SOPS). Free tier is enough for light personal use; fancy IdP features may not be.

**Recommend?** **Yes, when the goal is “open in browser with auth, no VPN client”** for a handful of specific private web apps. Not a substitute if you truly need `*.internal` / cluster DNS resolution.

---

## 5. Public hostname + auth

**How it works.** Put the “private” app on the existing public NLB → Ingress path, protect with oauth2-proxy / Authelia / BasicAuth / Cloudflare Access. Privacy = authentication, not network isolation.

**K8s fit.** Extra Ingress rules + auth middleware/sidecar; reuses current `ingress-nginx` and cert flow. Easiest incremental change to what you already run.

**Caveats.** Still on the **public attack surface** (scanners, CVEs in auth proxy, misconfigured bypass). Not real private networking; R7 is public DNS only. Easy to accidentally expose an unauthenticated location. “Omit from ingress” is safer than “public + hope auth is perfect” for sensitive admin UIs — unless auth is hardened and monitored.

**Recommend?** **OK for low-sensitivity personal dashboards** where VPN is overkill. **Avoid for anything that must stay off the public edge** (prefer VPN or Tunnel with Access).

---

## 6. SSH SOCKS / local forward (bastion-like, minimal)

**How it works.** SSH to a reachable host (OCI Bastion session, or a tiny public jump if you had one) with `-D` (SOCKS) or `-L`. Browser uses SOCKS; HTTPS to private IPs/names works if DNS is handled (remote DNS via SOCKS5, or `/etc/hosts`).

**K8s fit.** Same as Bastion: operational access, not a platform feature. No in-cluster component beyond having an SSH target.

**Caveats.** Same browser/client friction as Bastion. Private DNS is awkward (hosts file or SOCKS-aware resolution). Fine for occasional use.

**Recommend?** **Handy escape hatch; not the daily driver.**

---

## 7. sshuttle

**How it works.** Transparent VPN-like TCP (and optional DNS) proxy over plain SSH. Client runs `sshuttle -r user@host 10.0.0.0/16` (plus `--dns` if you want remote resolution); no kernel WireGuard module, no server-side daemon beyond `sshd`. Traffic to the listed CIDRs is intercepted locally and sent through the SSH hop.

**K8s fit.** Point sshuttle at any SSH-able host that can reach the private subnet / pod network — typically via OCI Bastion → worker, or a node with SSH. Route the VCN CIDR (and Service CIDR if the hop can reach it). No in-cluster install required. HTTPS to private Ingress/Services works once routes + DNS are captured.

**Caveats.** Not browser-native (local process must stay up). Laptop-oriented (Python client; root/TUN or firewall redirection depending on mode); phones are effectively out. TCP-focused (UDP/ICMP apps are a poor fit). Performance and hairpinning depend on the SSH hop. Still need a path to SSH (Bastion session / public jump). Less “always on” than WireGuard.

**Recommend?** **Yes as a zero-infra alternative to WireGuard** when you already have Bastion/SSH and only need laptop access + private DNS. Prefer WireGuard if you want phones, always-on, or UDP.

---

## 8. Teleport

**How it works.** Identity-aware access proxy: users authenticate to Teleport, then get short-lived certs for SSH, Kubernetes API, and/or **Application Access** (HTTPS apps proxied through Teleport’s web UI — browser-native). Agents (`teleport` / `tbot`) run next to targets and dial back or listen for the proxy.

**K8s fit.** Strong: Teleport Kubernetes Access + app agents as Deployments; can expose private web UIs through the Teleport proxy without putting them on the public NLB. Fits a Flux/GitOps layout, but you must run and HA the auth/proxy stack (or use Teleport Cloud).

**Caveats.** Heavy for a one-person Always Free cluster: auth+proxy memory/CPU, certs, roles, upgrades. Setup is days, not hours. Self-hosted free; Cloud is not a free long-term path. Private DNS is **not** general VCN resolution — you register specific apps/kube clusters in Teleport (R7 only partial). Overkill if you do not need audit trails, SSO, or multi-protocol IAM.

**Recommend?** **No for this stage** — capability is excellent (browser HTTPS + kube + SSH in one place), but footprint and ops cost fight free-tier / easy-setup goals. Revisit if you later want audited identity-aware access for more than one person.

---

## Recommendation (for this repo)

| Goal | Pick |
|------|------|
| Daily private HTTPS + real private DNS, few devices | **WireGuard** (or Tailscale if you want less key wrangling) |
| Laptop-only, no VPN daemon in-cluster | **sshuttle** over Bastion/SSH |
| Browser-only access to a few named apps | **Cloudflare Tunnel + Access** |
| kubectl / node shell / break-glass | **OCI Bastion** (already provisioned) |
| Identity-aware SSH/Kube/App proxy (later) | **Teleport** (skip for now) |
| Convenience for non-sensitive UI | Public Ingress + auth |

Best combo for your constraints: **WireGuard for network-private endpoints** (meets R1–R2, R4–R7; R3 is the only miss) **plus Bastion for admin**, optionally **sshuttle** when you want private routes without deploying WG, and **Cloudflare Tunnel** for the one or two apps you want pure-browser access to without a VPN.
