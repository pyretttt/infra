# What we do now
***

There is **no monitoring stack** on the cluster today: no Prometheus, Grafana, Loki, Alloy, or metrics-server in the live Flux tree. Platform pieces already in place that matter for this stage:

- Flux GitOps (`./flux/cluster` → `./manifests`)
- Dual ingress-nginx (public + internal), cert-manager, external-dns
- WireGuard VPN for private access (stage 01) — **not Teleport**
- Private DNS via in-cluster CoreDNS (stage 02)
- Public DNS + TLS on the OCI NLB path (stage 03)
- IAM policy `k8s_allow_oci_metrics` so workers can read OCI Monitoring (prep for Grafana’s `oci-metrics-datasource`; not wired yet)
- **Two node pools** + **pool-pinned static PVs** — storage affinity is ready for Prometheus persistence (see below)

## Storage already allocated

Terraform provisions **two node pools** (one worker each) and **two OCI block volumes**, materialized as **static 1:1 PV ↔ PVC** pairs (`manifests/provisioned/storage/storage-access.yaml`). Each pool’s node carries label `name=k8s-cluster-pool-<index>`; each PV’s `nodeAffinity` already requires that label **and** the AD zone.

| PV / PVC | Size | Node pool label | StorageClass | Access | Reclaim |
|----------|------|-----------------|--------------|--------|---------|
| `main-ad1` | 50 Gi | `name=k8s-cluster-pool-0` | `oci-bv` | ReadWriteOnce | Retain |
| `main-ad2` | 50 Gi | `name=k8s-cluster-pool-1` | `oci-bv` | ReadWriteOnce | Retain |

Verify labels:

```bash
kubectl get nodes -L name
```

### How to think about them

These are **whole disks**, not a shared pool you can carve into many independent PVCs.

- Each PVC is already bound to its PV via `volumeName` and claims the **full 50 Gi**. There is no leftover capacity for a second PVC on the same volume.
- Access mode is **RWO**: at most **one node** can attach a given volume at a time. All pods that mount that PVC must run on **that same node**.
- Pattern: **one durable disk per pool** — `main-ad1` ↔ pool-0, `main-ad2` ↔ pool-1. PV affinity is already set; **workloads** that mount a claim must mirror the same `name` label (see below) so the scheduler does not thrash on RWO attach.
- Sharing one PVC among several pods is fine **only on that one node** (same RWO volume). `subPath` can isolate directories on the same disk; it does **not** create separate PVCs or free “remaining” quota for Prometheus.

**Decision: Prometheus and Grafana must not be ephemeral.** Bind them to the **existing** static PVCs (`main-ad1` / `main-ad2`), with matching pool `nodeSelector` and `subPath` if sharing a disk. Grafana: `persistence.existingClaim`. Prometheus: PVC `volumes` + `containers` mount patch on `/prometheus` (Operator has no `existingClaim`; do not set `additionalArgs.storage.tsdb.path`). Do not use emptyDir for Prom/Grafana data.

That means:

1. **Mount one of the two existing PVCs** (or a `subPath` on it) from Prometheus and Grafana with `nodeSelector: name: k8s-cluster-pool-N` matching that PVC — accept sharing that 50 Gi disk with whatever else uses it.
2. Loki (if added later) follows the same rule, or stays out until headroom is clear.
3. Remote-write elsewhere remains an optional alternative to shrink the in-cluster footprint — not the default for Prom/Grafana.

Do **not** assume a free 15 Gi Longhorn volume exists — there is no Longhorn. You also cannot spin up a third independent “small” PVC from unused bytes on `main-ad1`/`main-ad2` without repartitioning outside this static PV model.

### PV ↔ pool pin (already done)

A PVC has **no** node-affinity field. Affinity lives on the **PersistentVolume** (generated from `tf/storage-access.yaml.tftpl`) and must be mirrored on every **pod** that mounts the claim.

**1. PV affinity** — already in `storage-access.yaml` (do not hand-edit; re-apply via Terraform):

```yaml
# PersistentVolume main-ad1 (excerpt)
spec:
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: name
              operator: In
              values:
                - k8s-cluster-pool-0
            - key: topology.kubernetes.io/zone
              operator: In
              values:
                - ME-DUBAI-1-AD-1
```

`main-ad2` uses `k8s-cluster-pool-1` the same way. Pool labels come from each node pool’s `initial_node_labels` in `tf/k8s-cluster.tf`.

**2. Pin the workload** that mounts the PVC — required so the scheduler picks the pool that owns the volume:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        name: k8s-cluster-pool-0
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: main-ad1
```

For kube-prometheus-stack, pin **Prometheus and Grafana** with `nodeSelector: name: k8s-cluster-pool-N` and mount the matching claim (`main-ad1` / `main-ad2`) with distinct `subPath`s. Grafana has native `persistence.existingClaim`; Prometheus Operator does **not** — add a PVC `volumes` entry and **patch** the prometheus container’s `/prometheus` mount via `containers` (do **not** use `additionalArgs.storage.tsdb.path`; the operator already owns that flag and will refuse to reconcile). **No emptyDir** for Prometheus TSDB or Grafana data.

(`affinity.nodeAffinity` on the same `name` key works if you prefer it over `nodeSelector`.)

| Approach | Role |
|----------|------|
| PVC alone | Cannot express a node pin |
| Zone affinity only | Both volumes could land on **either** pool in that AD — **not** our setup |
| RWO attach alone | Works after first mount, but the first pod can pick the “wrong” pool |
| PV `name` + zone affinity + workload `nodeSelector` (**current**) | Stable `main-ad1` → pool-0, `main-ad2` → pool-1 |

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
| R5 | Fits existing storage | **Non-ephemeral**: `existingClaim` on `main-ad1`/`main-ad2` + pool `nodeSelector` for Prometheus **and** Grafana; **no** Longhorn, **no** emptyDir for their data |
| R6 | Private Grafana by default | Reach via WireGuard + internal Ingress; public optional later |
| R7 | Flux / GitOps | HelmRelease + SOPS/age secrets |
| R8 | Useful signals | Cluster metrics incl. **remaining node CPU/RAM** (node-exporter); optional OCI cloud metrics; logs/OIDC optional |

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
| Persistence | No PVC in values (ephemeral) | **15 Gi Longhorn**, retentionSize 14GB | **Y** **existingClaim** on pool-pinned `main-adN` for Prom + Grafana; **N** ephemeral / Longhorn |
| Node exporter | Disabled | Enabled (DaemonSet) | **Enabled**, tight caps (~32–64 Mi × 2) — remaining CPU/RAM |
| Logs | Grafana Alloy → Loki (12h) | Loki TODO | Loki **under consideration** |
| Alerting | Alertmanager → Slack | Alertmanager → Slack | Same; SOPS webhook secret |
| Flux metrics | kube-state-metrics CR state (inline) | ConfigMapGenerator + valuesFrom | Both fine; nce split is cleaner |
| OCI cloud metrics | `oci-metrics-datasource` | Same plugin | IAM policy already present |
| Exposure | Gateway API HTTPRoute | HTTPRoute + SecurityPolicy (OIDC) | **N** — use Ingress + WireGuard |
| Extra deps | Cilium Gateway, Loki ns, privileged monitoring NS | Longhorn, Dex, Envoy, Teleport | **N** Cilium / Envoy / Longhorn / Teleport |
| Access story | (cluster-specific) | Teleport | **WireGuard** replaces Teleport |
| metrics-server | In monitoring module | Separate core module | Optional phase 2 (~50 Mi) for `kubectl top` |
| Est. monitoring RSS | ~1.8 GiB full (Prom+Grafana+Alloy+Loki) | ~2.3+ GiB + Longhorn overhead | Slim phase 1 ~1.0 GiB (incl. node-exporter ×2) |
| Storage pressure | Loki short retention; Prom ephemeral | 15 Gi Prom + Longhorn replicas | Prom + Grafana on existing `main-adN` PVCs; share carefully / use `subPath` |

### Resource estimates (working set, not just requests)

Cluster schedulable memory after OKE + Flux + dual ingress + cert-manager + DNS + WireGuard is roughly **~6–7 GiB** free across two nodes (estimate; verify with `kubectl top` / `describe nodes` before install).

| Stack | Est. RSS | Notes |
|-------|----------|-------|
| piontec full (Prom + Grafana + AM + operator/KSM + Alloy×2 + Loki + metrics-server) | ~1.8 GiB | Plausible but tight; Loki/Alloy optional |
| nce as written (+ Longhorn overhead) | ~2.3+ GiB | Needs Longhorn — **out of scope** |
| **Recommended phase 1** (slim Prom + Grafana + AM + operator/KSM + node-exporter ×2) | ~1.0 GiB | Best start for this repo |

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

**Prefer a piontec-shaped slim stack**, adapted to oci-infra. Storage pinning is in place — ready to implement:

1. **kube-prometheus-stack** with Grafana **in-chart**, Alertmanager on, **prometheus-node-exporter on** (tight limits — remaining CPU/RAM), control-plane ServiceMonitors off (etcd/scheduler/controller-manager/proxy).
2. Short retention (12–24h). **Persist** Prometheus and Grafana on `main-ad1` (or `main-ad2`) with `nodeSelector: name: k8s-cluster-pool-0` (or pool-1) — Grafana via `existingClaim`, Prometheus via volumes/volumeMounts; not ephemeral, not nce’s 15 Gi Longhorn PVC.
3. Expose Grafana on the **internal** Ingress (WireGuard path), not via Gateway HTTPRoute / Envoy / Teleport.
4. Wire **`oci-metrics-datasource`** using existing `k8s_allow_oci_metrics`.
5. Optionally borrow nce’s **external ConfigMap** for Flux kube-state-metrics CR metrics.
6. **Loki** and **Dex**: keep as follow-ups under consideration — metrics first; Alloy→Loki or remote logs only if headroom remains; Dex only if password + WireGuard is not enough.

### Remaining CPU / RAM (chosen approach)

| Option | What you get | Cost | Status |
|--------|--------------|------|--------|
| 1. metrics-server only | Live `kubectl top`; no history | ~50 Mi | Phase 2 optional |
| 2. **Tight node-exporter** | Grafana history: `node_memory_MemAvailable_bytes`, CPU idle | ~32–64 Mi × 2 nodes | **Chosen** |
| 3. kube-state-metrics only | Schedulable headroom (allocatable − requests), not real free RAM | already in stack | Useful extra, not sufficient alone |

kube-state-metrics ≠ node-exporter: KSM is API object state; node-exporter is host CPU/RAM. For “how much is left on the box?” over time, use option 2.

**Do not adopt as-is:** Cilium, Envoy Gateway, Longhorn, Teleport, or nce’s large persistent Prometheus volume.

---

## HelmRelease values (`manifests/kube-prom-stack/helmrelease.yaml`)

Paste / tune under `spec.values`. PVCs `main-ad1` / `main-ad2` are in **`default`**, so `spec.targetNamespace` must stay `default` (Kubernetes cannot mount a PVC from another namespace).

### Value options

| Knob | Options | Suggestion |
|------|---------|------------|
| Target PVC / pool | `main-ad1` + `k8s-cluster-pool-0` **or** `main-ad2` + `k8s-cluster-pool-1` | **`main-ad1` / pool-0** |
| Grafana persistence | (A) off / emptyDir · (B) new PVC via `storageClassName`+`size` · (C) `existingClaim` + `subPath` | **(C)** `existingClaim: main-ad1`, `subPath: grafana` |
| Prometheus persistence | (A) default emptyDir · (B) `storageSpec.volumeClaimTemplate` (new PVC) · (C) `volumes` + `containers[].volumeMounts` patch on `/prometheus` | **(C)** — never `additionalArgs.storage.tsdb.path` (operator rejects it → no StatefulSet → Ingress 503) |
| Alertmanager persistence | ephemeral · new PVC · existing claim + subPath | **ephemeral** for phase 1 |
| Retention | `12h`–`24h`; optional `retentionSize` | **`24h`** + `retentionSize: 20GB` |
| Node exporter | off · on (chart defaults) · on + tight caps | **on + tight** (`10m/32Mi` req, `50m/64Mi` lim) — remaining CPU/RAM |
| Control-plane scrapes | kubeEtcd / Scheduler / ControllerManager / Proxy on · off | **off** (OKE managed; scrapes fail/noise) |
| Grafana exposure | no Ingress · `nginx-internal` (WireGuard) · public `nginx` | **`nginx-internal`**, host e.g. `grafana.polywhale.com` |
| Grafana admin secret | chart-generated · `existingSecret` | **`grafana-admin`** (SOPS) with keys `admin-user` / `admin-password` |
| Resources | chart defaults · tight Always Free caps | caps in the file below (~1.0 GiB phase 1) |

### Suggested `spec.values` (in-repo)

The live draft is `manifests/kube-prom-stack/helmrelease.yaml`. Core of the suggestion:

```yaml
values:
  defaultRules:
    create: true
    rules:
      etcd: false
      kubeControllerManager: false
      kubeProxy: false
      kubeSchedulerAlerting: false
      kubeSchedulerRecording: false

  kubeEtcd:
    enabled: false
  kubeControllerManager:
    enabled: false
  kubeScheduler:
    enabled: false
  kubeProxy:
    enabled: false

  prometheus-node-exporter:
    enabled: true
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 50m, memory: 64Mi }

  alertmanager:
    enabled: true
    alertmanagerSpec:
      replicas: 1
      resources:
        requests: { cpu: 10m, memory: 64Mi }
        limits:   { cpu: 100m, memory: 128Mi }

  grafana:
    enabled: true
    admin:
      existingSecret: grafana-admin
      userKey: admin-user
      passwordKey: admin-password
    nodeSelector:
      name: k8s-cluster-pool-0
    persistence:
      enabled: true
      type: pvc
      existingClaim: main-ad1
      subPath: grafana
    ingress:
      enabled: true
      ingressClassName: nginx-internal
      hosts:
        - grafana.polywhale.com
      path: /
      pathType: Prefix
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }

  prometheus:
    prometheusSpec:
      replicas: 1
      retention: 24h
      retentionSize: 20GB
      scrapeInterval: 30s
      evaluationInterval: 30s
      nodeSelector:
        name: k8s-cluster-pool-0
      # No storageSpec.volumeClaimTemplate — that would create a *new* PVC.
      # No additionalArgs.storage.tsdb.path — operator-managed; causes reconcile failure.
      volumes:
        - name: prometheus-data
          persistentVolumeClaim:
            claimName: main-ad1
      containers:
        - name: prometheus
          volumeMounts:
            - name: prometheus-data
              mountPath: /prometheus
              subPath: prometheus
      resources:
        requests: { cpu: 100m, memory: 512Mi }
        limits:   { cpu: 500m, memory: 1536Mi }

  prometheusOperator:
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits:   { cpu: 200m, memory: 256Mi }

  kube-state-metrics:
    resources:
      requests: { cpu: 10m, memory: 64Mi }
      limits:   { cpu: 100m, memory: 128Mi }
```

**Why Prometheus looks different from Grafana:** Grafana’s subchart accepts `persistence.existingClaim`. Prometheus Operator only knows `storageSpec.volumeClaimTemplate` (always a **new** PVC) or emptyDir. Reuse `main-ad1` by adding a volume and strategically merging a `/prometheus` mount onto the prometheus container — do not override `--storage.tsdb.path` via `additionalArgs`.

Swap to pool-1 by changing every `main-ad1` → `main-ad2` and every `k8s-cluster-pool-0` → `k8s-cluster-pool-1`.

Before reconcile: create SOPS Secret `grafana-admin` in `default` with keys `admin-user` / `admin-password`.

### Phase 1 checklist

- Flux HelmRelease: `kube-prometheus-stack` (values above)
- Grafana on, Alertmanager on, **node-exporter on** (tight limits) for remaining CPU/RAM
- Retention 24h; Prom + Grafana on `main-ad1` with `subPath` + pool-0 `nodeSelector`
- Grafana via internal Ingress + WireGuard
- Grafana admin (and later Slack webhook) via SOPS/age

Useful PromQL once scraped:

```promql
# Remaining memory (bytes) per node
node_memory_MemAvailable_bytes

# CPU idle ratio (1 = fully idle); adjust job label if needed
avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

### Phase 2 — OCI + Flux visibility

- Enable `oci-metrics-datasource` in Grafana
- Add Flux CR metrics via kube-state-metrics (nce ConfigMap style or piontec inline)
- Optional: metrics-server (~50 Mi) for `kubectl top` (live snapshot; node-exporter already covers history)

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
