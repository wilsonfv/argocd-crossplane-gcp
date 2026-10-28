# GKE GitOps Platform: Argo CD, Crossplane & Istio Ambient Service Mesh

Automated scripts and declarative GitOps source-of-truth configurations following the **Google Shell Style Guide** for Google Kubernetes Engine (GKE) in GCP.

---

## Repository Structure

```text
.
├── install-argocd.sh          # Installs/configures latest Argo CD on GKE
├── install-crossplane.sh      # Installs latest Crossplane on GKE via Helm
├── deploy-istio-ambient.sh    # Deploys Istio Ambient Mode via Argo CD Applications
├── gitops/                    # GitOps Source of Truth
│   ├── gke/                   # Declarative GKE infrastructure & platform configs
│   │   ├── cluster-spec.yaml      # GKE Cluster definition & node configuration
│   │   ├── namespaces.yaml        # Core namespaces & Ambient enablement
│   │   ├── resource-quotas.yaml   # Critical pod resource quotas for GKE
│   │   └── network-policies.yaml  # Internal cluster traffic security policies
│   ├── istio/                 # Source of truth for Istio Ambient Mode Helm values
│   │   ├── base/values.yaml       # Istio Base CRDs configuration
│   │   ├── cni/values.yaml        # Istio CNI DaemonSet with GKE paths
│   │   ├── istiod/values.yaml     # Istiod Control Plane with Ambient profile
│   │   ├── ztunnel/values.yaml    # Istio Ztunnel node proxy DaemonSet
│   │   └── samples/               # Ambient validation workloads (apps-ambient)
│   └── argocd-apps/           # Argo CD Application Manifests
│       ├── istio-base.yaml        # Wave 0: Istio Base CRDs
│       ├── istio-cni.yaml         # Wave 1: Istio CNI Plugin
│       ├── istiod.yaml            # Wave 1: Istiod Control Plane
│       └── istio-ztunnel.yaml     # Wave 2: Istio Ztunnel L4 Proxy
└── README.md
```

---

## 1. Deploy Argo CD

```bash
./install-argocd.sh
```
- Access UI: `kubectl port-forward svc/argocd-server -n argocd 8080:443` -> [https://localhost:8080](https://localhost:8080)
- Username: `admin`
- Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo`

---

## 2. Deploy Crossplane

```bash
./install-crossplane.sh
```
- Verifies Crossplane `v2.4.3` deployment in `crossplane-system`.

---

## 3. Deploy Istio Service Mesh (Ambient Mode) via Argo CD

Istio Ambient Mode provides a transparent, sidecarless service mesh architecture:
- **Ztunnel (Zero-Trust Tunnel)**: Node-level DaemonSet handling mTLS and L4 authorization without injecting sidecars into application pods.
- **Istio CNI**: Redirects application traffic to node-local `ztunnel` instances (configured for GKE paths `/home/kubernetes/bin` and `/etc/cni/net.d`).
- **Istiod**: Central control plane operating with `profile: ambient`.

To deploy via Argo CD:
```bash
./deploy-istio-ambient.sh
```

### Check Argo CD Applications Status
```bash
kubectl get applications.argoproj.io -n argocd
```
Output:
```text
NAME            SYNC STATUS   HEALTH STATUS
istio-base      Synced        Healthy
istio-cni       Synced        Healthy
istio-ztunnel   Synced        Healthy
istiod          Synced        Healthy
```

### Validate Ambient Mode Traffic
Workloads in the `apps-ambient` namespace have the label `istio.io/dataplane-mode: ambient`.
Send a test HTTP request from the sleep client to the echo server:
```bash
kubectl exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server:80
```
Inspect `ztunnel` logs to verify transparent mTLS proxying:
```bash
kubectl logs -n istio-system daemonset/ztunnel -c istio-proxy --tail=20
```
