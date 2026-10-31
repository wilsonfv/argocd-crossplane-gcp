# GitOps Source of Truth: GKE & Istio Ambient Service Mesh

This directory is the declarative GitOps source of truth for the Google Kubernetes Engine (GKE) cluster and the Istio Service Mesh (Ambient Mode).

---

## Directory Structure

```text
gitops/
├── gke/                          # GKE Cluster & Platform Declarations
│   ├── cluster-spec.yaml         # Declarative cluster definition & node specifications
│   ├── namespaces.yaml           # Core cluster namespaces & ambient enablement labels
│   ├── network-policies.yaml     # Baseline cluster network policies
│   └── resource-quotas.yaml      # Critical resource quotas for GKE
└── argocd-apps/                  # Argo CD Root Application Manifests
    └── istio-ambient-root.yaml   # Syncs all Istio Ambient configurations from private repo
```

> **Note**: All Istio Ambient Mode configurations (Helm charts, values, mesh policies, waypoint proxies, and ambient workloads) have been migrated to the dedicated private repository:
> 👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config)

---

## Istio Ambient Mode Architecture on GKE

Unlike sidecar-based service meshes, Istio Ambient Mode operates in two lightweight layers:
1. **Zero-Trust Tunnel (ztunnel)**: A node-level DaemonSet that handles mutual TLS (mTLS), L4 telemetry, and zero-trust authentication across pods without injecting sidecar containers.
2. **Istio CNI**: Configured specifically for GKE paths (`/home/kubernetes/bin` and `/etc/cni/net.d`) to redirect traffic transparently to `ztunnel`.
3. **Istiod**: The ambient-enabled control plane providing xDS configuration and mTLS certificates.

### Enabling Ambient Mode for Workloads

To enroll a namespace or pod into the Ambient Mesh, add the label:
```yaml
metadata:
  labels:
    istio.io/dataplane-mode: ambient
```

Pods will immediately enjoy encrypted mTLS and L4 telemetry **without requiring any container restart or sidecar injection**.
