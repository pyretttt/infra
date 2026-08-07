# What we do now
***

There is **no monitoring stack** on the cluster today: no Prometheus, Grafana, Loki, Alloy, or metrics-server in the live Flux tree. Platform pieces already in place that matter for this stage:

- Flux GitOps (`./flux/cluster` → `./manifests`)
- Dual ingress-nginx (public + internal), cert-manager, external-dns
- WireGuard VPN for private access (stage 01) — **not Teleport**
- Private DNS via in-cluster CoreDNS (stage 02)
- Public DNS + TLS on the OCI NLB path (stage 03)
- IAM policy `k8s_allow_oci_metrics` so workers can read OCI Monitoring (prep for Grafana’s `oci-metrics-datasource`; not wired yet)

## Storage already allocated

Terraform provisions **two OCI block volumes** and materializes them as **static 1:1 PV ↔ PVC** pairs (`manifests/provisioned/storage/storage-access.yaml`):

| PV / PVC | Size | StorageClass | Access | Reclaim |
|----------|------|--------------|--------|---------|
| `main-ad1` | 50 Gi | `oci-bv` | ReadWriteOnce | Retain |
| `main-ad2` | 50 Gi | `oci-bv` | ReadWriteOnce | Retain |

### How to think about them

These are **whole disks**, not a shared pool you can carve into many independent PVCs.

- Each PVC is already bound to its PV via `volumeName` and claims the **full 50 Gi**. There is no leftover capacity for a second PVC on the same volume.
- Access mode is **RWO**: at most **one node** can attach a given volume at a time. All pods that mount that PVC must run on **that same node**.
- Intended pattern for this cluster: treat the two volumes as **one durable disk per worker** — e.g. apps on node A use `main-ad1`, apps on node B use `main-ad2`. Pin consumers with `nodeSelector` / affinity so scheduling matches the volume you chose (and so a restart does not fight RWO attach/detach).
- The generated PVs today only express **zone** `nodeAffinity` (availability domain), not a hostname pin. RWO attach still forces co-location once mounted; for a stable “this PVC ↔ this node” mapping, pin both the **PV** and the **workload** (see below).
- Sharing one PVC among several pods is fine **only on that one node** (same RWO volume). `subPath` can isolate directories on the same disk; it does **not** create separate PVCs or free “remaining” quota for Prometheus.

So for monitoring persistence, options are:

1. **Mount one of the two existing PVCs** (or a `subPath` on it) from a Prometheus/Loki pod that is affinity-pinned to the node that owns that volume — and accept that you are sharing that 50 Gi disk with whatever else uses it, or
2. Stay **ephemeral** (emptyDir / short retention), or
3. Avoid in-cluster TSDB and remote-write elsewhere.

Do **not** assume a free 15 Gi Longhorn volume exists — there is no Longhorn. You also cannot spin up a third independent “small” PVC from unused bytes on `main-ad1`/`main-ad2` without repartitioning outside this static PV model.

### How to pin a PVC to a specific node

A PVC has **no** node-affinity field. Pin at the **PersistentVolume**, and mirror the same pin on every **pod** that mounts the claim.

**1. Pin the PV** (source of truth) — hostname affinity instead of (or in addition to) zone only:

```yaml
# on PersistentVolume main-ad1
spec:
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <worker-node-1-name>   # kubectl get nodes
```

Same for `main-ad2` → the other worker. Node names:

```bash
kubectl get nodes -o wide
```

In Terraform, pass each worker hostname (or a stable node label) into `storage-access.yaml.tftpl` when generating the two PVs.

**2. Pin the workload** that mounts the PVC — so the scheduler does not thrash before attach:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: <worker-node-1-name>
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: main-ad1
```

(`affinity.nodeAffinity` works the same way if you prefer it over `nodeSelector`.)

| Approach | Role |
|----------|------|
| PVC alone | Cannot express a node pin |
| Zone affinity only (current generated PVs) | Both volumes can land on **either** worker in that AD |
| RWO attach alone | Works after first mount, but the first pod can pick the “wrong” node |
| PV hostname affinity + workload `nodeSelector` | Stable `main-ad1` → node A, `main-ad2` → node B |

## Explicit non-goals (vs reference repos)

| Reference habit | This project |
|-----------------|--------------|
| Cilium CNI / Gateway API | **No** — OKE default networking + **ingress-nginx** |
| Envoy Gateway + HTTPRoute | **No** — Ingress resources only |
| Longhorn | **No** — OCI BV CSI (`oci-bv`) + the two static PVs above |
| Teleport for cluster access | **No** — **WireGuard** (stage 01) |
| Loki | **Under consideration** — not committed; defer until metrics fit |
| Dex / OIDC for Grafana | **Under consideration** — password or WireGuard-only Grafana first; Dex later if needed |

# Monitoring options for Always Free OKE
***

## Requirements

| # | Requirement | Notes |
|---|-------------|-------|
| R1 | Free / OCI Always Free | Stay on existing 2× A1.Flex (1 OCPU / 6 GiB each); no extra nodes |
| R2 | Low OCPU / memory | Single-replica controllers; hard requests/limits; Prefer ~≤1 GiB RSS for phase 1 |
| R3 | ARM (`linux/arm64`) | All images must run on A1 |
| R4 | Fits existing edge | ingress-nginx + NLB / WireGuard; **no** Cilium, Envoy, Gateway API |
| R5 | Fits existing storage | Prefer ephemeral or tiny PVC; respect the two 50 Gi `oci-bv` PVs; **no** Longhorn |
| R6 | Private Grafana by default | Reach via WireGuard + internal Ingress; public optional later |
| R7 | Flux / GitOps | HelmRelease + SOPS/age secrets |
| R8 | Useful signals | Cluster metrics + optional OCI cloud metrics; logs/OIDC optional |

## Reference setups compared

Two public Always Free OKE GitOps repos are useful baselines:

- [piontec/free-oci-kubernetes — `flux-modules/monitoring`](https://github.com/piontec/free-oci-kubernetes/tree/main/flux-modules/monitoring) (+ [loki](https://github.com/piontec/free-oci-kubernetes/tree/main/flux-modules/loki))
- [nce/oci-free-cloud-k8s — `gitops/core/kube-prometheus-stack`](https://github.com/nce/oci-free-cloud-k8s/tree/main/gitops/core/kube-prometheus-stack) (+ separate [grafana](https://github.com/nce/oci-free-cloud-k8s/tree/main/gitops/core/grafana))

### Comparison matrix

Legend: **Y** = good fit for oci-infra, **P** = partial / needs adaptation, **N** = poor fit / conflicts.

| Dimension | piontec | nce | oci-infra fit |
|-----------|---------|-----|---------------|
| Primary chart | kube-prometheus-stack 58.x | kube-prometheus-stack 80.14.4 | Either; pin a recent 70–80.x |
| Grafana | In-chart (password secret) | Separate HelmRelease + Dex OIDC | **Y** in-chart first; Dex under consideration |
| Prometheus requests | 200m / 200Mi (aggressive) | Chart defaults | Cap requests/limits; expect ~0.5–1 Gi RSS |
| Persistence | No PVC in values (ephemeral) | **15 Gi Longhorn**, retentionSize 14GB | **Y** piontec; **N** nce Longhorn |
| Node exporter | Disabled | Enabled (DaemonSet) | Keep **disabled** on Always Free |
| Logs | Grafana Alloy → Loki (12h) | Loki TODO | Loki **under consideration** |
| Alerting | Alertmanager → Slack | Alertmanager → Slack | Same; SOPS webhook secret |
| Flux metrics | kube-state-metrics CR state (inline) | ConfigMapGenerator + valuesFrom | Both fine; nce split is cleaner |
| OCI cloud metrics | `oci-metrics-datasource` | Same plugin | IAM policy already present |
| Exposure | Gateway API HTTPRoute | HTTPRoute + SecurityPolicy (OIDC) | **N** — use Ingress + WireGuard |
| Extra deps | Cilium Gateway, Loki ns, privileged monitoring NS | Longhorn, Dex, Envoy, Teleport | **N** Cilium / Envoy / Longhorn / Teleport |
| Access story | (cluster-specific) | Teleport | **WireGuard** replaces Teleport |
| metrics-server | In monitoring module | Separate core module | Add either way (~50 Mi) |
| Est. monitoring RSS | ~1.8 GiB full (Prom+Grafana+Alloy+Loki) | ~2.3+ GiB + Longhorn overhead | Slim phase 1 ~0.9 GiB |
| Storage pressure | Loki short retention; Prom ephemeral | 15 Gi Prom + Longhorn replicas | Must not fight the two 50 Gi BV PVCs blindly |

### Resource estimates (working set, not just requests)

Cluster schedulable memory after OKE + Flux + dual ingress + cert-manager + DNS + WireGuard is roughly **~6–7 GiB** free across two nodes (estimate; verify with `kubectl top` / `describe nodes` before install).

| Stack | Est. RSS | Notes |
|-------|----------|-------|
| piontec full (Prom + Grafana + AM + operator/KSM + Alloy×2 + Loki + metrics-server) | ~1.8 GiB | Plausible but tight; Loki/Alloy optional |
| nce as written (+ Longhorn overhead) | ~2.3+ GiB | Needs Longhorn — **out of scope** |
| **Recommended phase 1** (slim Prom + Grafana + AM + operator/KSM) | ~0.9 GiB | Best start for this repo |

Rough component breakdown:

**piontec full**

| Component | Est. RSS (Mi) | Notes |
|-----------|---------------|-------|
| Prometheus | 550 | Chart requests 200Mi; real higher |
| Grafana (in-chart) | 250 | |
| Alertmanager | 80 | |
| Operator + kube-state-metrics | 270 | |
| Alloy DaemonSet ×2 | 280 | pod + journal logs |
| Loki (12h) | 300 | promtail off |
| metrics-server | 50 | |

**nce as written**

| Component | Est. RSS (Mi) | Notes |
|-----------|---------------|-------|
| Prometheus | 1400 | 14 Gi retentionSize |
| Grafana (separate) | 280 | Dex OAuth |
| Alertmanager | 100 | |
| Operator + kube-state-metrics | 320 | |
| node-exporter ×2 | 120 | default enabled |
| metrics-server | 50 | |
| Longhorn overhead | ~600 | Required for their PVC — **we will not run this** |

---

## Verdict for this project

**Prefer a piontec-shaped slim stack**, adapted to oci-infra:

1. **kube-prometheus-stack** with Grafana **in-chart**, Alertmanager on, **prometheus-node-exporter off**, control-plane ServiceMonitors off (kubelet/etcd/scheduler/proxy as in piontec).
2. Short retention (12–24h) and **ephemeral storage**, or persist on one of the two node-local RWO volumes (`main-ad1` / `main-ad2`) with workload affinity to that node — do not copy nce’s 15 Gi Longhorn PVC.
3. Expose Grafana on the **internal** Ingress (WireGuard path), not via Gateway HTTPRoute / Envoy / Teleport.
4. Wire **`oci-metrics-datasource`** using existing `k8s_allow_oci_metrics`.
5. Optionally borrow nce’s **external ConfigMap** for Flux kube-state-metrics CR metrics.
6. **Loki** and **Dex**: keep as follow-ups under consideration — metrics first; Alloy→Loki or remote logs only if headroom remains; Dex only if password + WireGuard is not enough.

**Do not adopt as-is:** Cilium, Envoy Gateway, Longhorn, Teleport, or nce’s large persistent Prometheus volume.

---

## Recommended phased rollout

### Phase 1 — Metrics core (~0.9 GiB)

- Flux HelmRelease: `kube-prometheus-stack`
- Grafana on, Alertmanager on, node-exporter off
- Retention 12–24h; emptyDir or 2–5 Gi max if a free `oci-bv` slice exists
- Grafana via internal Ingress + WireGuard
- Slack (or similar) webhook secret via SOPS/age

### Phase 2 — OCI + Flux visibility

- Enable `oci-metrics-datasource` in Grafana
- Add Flux CR metrics via kube-state-metrics (nce ConfigMap style or piontec inline)
- Add metrics-server if not already present (for `kubectl top`)

### Phase 3 — Under consideration

| Item | Status | Notes |
|------|--------|-------|
| Loki (+ Alloy or Promtail) | Under consideration | Short retention only; competes for RAM and BV storage |
| Dex OIDC for Grafana | Under consideration | Useful if sharing access; overkill for single-admin + WireGuard |
| Remote write / Grafana Cloud | Optional alternative | Shrinks in-cluster footprint if free tier is acceptable |

---

## Sources

- [piontec monitoring module](https://github.com/piontec/free-oci-kubernetes/tree/main/flux-modules/monitoring)
- [piontec loki module](https://github.com/piontec/free-oci-kubernetes/tree/main/flux-modules/loki)
- [nce kube-prometheus-stack](https://github.com/nce/oci-free-cloud-k8s/tree/main/gitops/core/kube-prometheus-stack)
- [nce grafana](https://github.com/nce/oci-free-cloud-k8s/tree/main/gitops/core/grafana)
- nce README note: Always Free Ampere envelope commonly **2 OCPU / 12 GiB total** (post–Jun 2026); this cluster already matches that with 2×1 OCPU / 6 GiB
