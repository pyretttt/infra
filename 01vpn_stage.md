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

Deploying WireGuard in oci k8s cluster requires only one deployment and one config. Configuration file actually provides wireguard configuration with keys and peers setup.

Wireguard Client (your laptop) goes through public NLB IP (It's L4 network balancer, so it simplifies configuration a little bit). NLB forwards traffic from port `51820` to NodePort `31602` which forwards traffic to Wireguard Service.

Wireguard client config allows traffic to any cluster private/public subnet IPs, cluster node and cluster's service IPs.

> With this config it's possible to directly access service by assigned IP (from service_cidr range). While `port` is in cluster, `nodePort` is handled only from external connections somehow. And since, wg service is in cluster - we use `port`.