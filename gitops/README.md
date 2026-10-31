# GitOps Source of Truth: GKE Infrastructure

This directory is the declarative GitOps source of truth for Google Kubernetes Engine (GKE) platform infrastructure.

---

## Directory Structure

```text
gitops/
└── gke/                      # GKE Cluster & Platform Declarations
    ├── cluster-spec.yaml     # Declarative cluster definition & node specifications
    └── namespaces.yaml       # Platform namespaces (crossplane-system, argocd)
```

> **Important**: All Istio Ambient Mode configurations (Helm charts, values, mesh policies, namespaces, waypoint proxies, and ambient workloads) reside exclusively in the dedicated private repository:
> 👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config)
>
> Argo CD syncs all mesh configurations directly from `https://github.com/wilsonfv/istio-ambient-config`.
