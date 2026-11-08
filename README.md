# GKE GitOps Platform: Argo CD, Crossplane & Istio Ambient Service Mesh

Automated scripts and declarative GitOps source-of-truth configurations following the **Google Shell Style Guide** for Google Kubernetes Engine (GKE) in GCP.

---

## Repository Structure

```text
.
├── setup-multicluster.sh      # Provisions multi-cluster GKE & configures Argo CD control plane
├── install-crossplane.sh      # Installs latest Crossplane on GKE via Helm
├── deploy-istio-ambient.sh    # Deploys Istio Ambient Mode via Argo CD from private repo
├── gitops/                    # GitOps Source of Truth
│   └── gke/                   # Declarative GKE infrastructure & platform configs
│       ├── cluster-spec.yaml  # GKE Cluster definition & node configuration
│       └── namespaces.yaml    # Platform namespaces (crossplane-system, argocd)
└── README.md
```

> **Note**: All Istio Ambient Mode configurations reside exclusively in the private GitOps repository:
> 👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config)
>
> This repository contains **no Istio configurations**; deployment syncs directly from the private repository.

---

## 1. Deploy or Delete Multi-Cluster GKE & Argo CD

```bash
# Provision both GKE clusters, deploy Argo CD, and register managed cluster
./setup-multicluster.sh

# Delete both GKE clusters (with confirmation prompt)
./setup-multicluster.sh --delete

# Delete both GKE clusters non-interactively
./setup-multicluster.sh --delete --yes
```

### Options
| Option | Env Var | Default | Description |
|---|---|---|---|
| `-p`, `--project` | `PROJECT_ID` | `gcloud config list` | Default GCP Project ID (dynamically detected) |
| `--cp-project` | `CP_PROJECT_ID` | `PROJECT_ID` | Control plane cluster GCP project ID |
| `--managed-project` | `MANAGED_PROJECT_ID` | `PROJECT_ID` | Managed cluster GCP project ID |
| `-r`, `--region` | `REGION` | `europe-west1` | GCP region for clusters |
| `--cp-cluster` | `CP_CLUSTER_NAME` | `argocd-control-plane` | Control plane GKE cluster name |
| `--cp-subnet` | `CP_SUBNET` | `internal-vpc1-europe-west1-gke` | Control plane subnet |
| `--managed-cluster`| `MANAGED_CLUSTER_NAME`| `gke-managed-cluster` | Managed GKE cluster name |
| `--managed-subnet` | `MANAGED_SUBNET` | `internal-vpc1-europe-west1-gke2`| Managed cluster subnet |
| `--gsa-name` | `ARGOCD_GSA_NAME` | `argocd-cluster-manager` | GCP Service Account for Workload Identity |
| `-m`, `--machine-type` | `MACHINE_TYPE` | `e2-standard-4` | Node machine type |
| `-n`, `--num-nodes` | `NUM_NODES` | `1` | Nodes per zone |
| `-d`, `--delete` | `DELETE_CLUSTERS` | `false` | Delete both GKE clusters |
| `-y`, `--yes` | `AUTO_APPROVE` | `false` | Auto-approve deletion prompt |

### GCP Workload Identity for Managed Cluster Access
The managed cluster is registered into Argo CD using **GCP Workload Identity** with an `execProviderConfig` cluster secret:
- GKE clusters are provisioned with Workload Identity pools (`--workload-pool="${CP_PROJECT_ID}.svc.id.goog"` and `--workload-pool="${MANAGED_PROJECT_ID}.svc.id.goog"`).
- **GSA in Control Plane Project**: A Google Cloud Service Account (`argocd-cluster-manager@<CP_PROJECT_ID>.iam.gserviceaccount.com`) is created in the control plane cluster's GCP project and bound to Argo CD's Kubernetes ServiceAccounts (`argocd-application-controller` and `argocd-server`) via `roles/iam.workloadIdentityUser`.
- **IAM Roles in Managed Project**: The GSA is granted `roles/container.developer` and `roles/container.clusterViewer` in the managed GKE cluster's GCP project (`MANAGED_PROJECT_ID`).
- **Cluster Secret with `execProviderConfig`**: The managed cluster secret in Argo CD uses `execProviderConfig` with `argocd-k8s-auth gcp` to mint short-lived tokens on the fly, eliminating the need to store static bearer tokens or credentials.

- Access UI: `kubectl config use-context gke_${PROJECT_ID}_europe-west1_argocd-control-plane && kubectl port-forward svc/argocd-server -n argocd 8080:443` -> [https://localhost:8080](https://localhost:8080)
- Username: `admin`
- Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo`

---

## 2. Deploy Crossplane

```bash
./install-crossplane.sh
```
- Verifies Crossplane `v2.4.3` deployment in `crossplane-system`.

---

## 3. Deploy Istio Service Mesh (Ambient Mode) to Multi-Cluster GKE via Argo CD

Istio Ambient Mode configurations are synchronized from the dedicated private GitOps repository:
👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config) (Private)

Istio Ambient Mode provides a transparent, sidecarless service mesh architecture:
- **Ztunnel (Zero-Trust Tunnel)**: Node-level DaemonSet handling mTLS and L4 authorization without injecting sidecars into application pods.
- **Istio CNI**: Redirects application traffic to node-local `ztunnel` instances (configured for GKE paths `/home/kubernetes/bin` and `/etc/cni/net.d`).
- **Istiod**: Central control plane operating with `profile: ambient`.
- **Waypoint Proxy**: Envoy L7 gateway dynamically instantiated for L7 routing and authorization policies.

To deploy Istio Ambient mesh to both the control plane cluster and the managed cluster:
```bash
./deploy-istio-ambient.sh
```

Or pass your GitHub PAT explicitly if not detected:
```bash
./deploy-istio-ambient.sh --token <GITHUB_PAT>
```

### Check Argo CD Applications Status
```bash
kubectl get applications.argoproj.io -n argocd
```
Output:
```text
NAME                         SYNC STATUS   HEALTH STATUS
ambient-samples              Synced        Healthy
ambient-samples-managed      Synced        Healthy
istio-ambient-root           Synced        Healthy
istio-ambient-root-managed   Synced        Healthy
istio-base                   Synced        Healthy
istio-base-managed           Synced        Healthy
istio-cni                    Synced        Healthy
istio-cni-managed            Synced        Healthy
istio-policies               Synced        Healthy
istio-policies-managed       Synced        Healthy
istio-ztunnel                Synced        Healthy
istio-ztunnel-managed        Synced        Healthy
istiod                       Synced        Healthy
istiod-managed               Synced        Healthy
```

### Validate Ambient Mode Traffic
Workloads in the `apps-ambient` namespace have the label `istio.io/dataplane-mode: ambient`.

Send a test HTTP request from the sleep client to the echo server on each cluster:
```bash
# Control plane cluster:
kubectl --context gke_${PROJECT_ID}_europe-west1_argocd-control-plane exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Managed cluster:
kubectl --context gke_${PROJECT_ID}_europe-west1-b_gke-managed-cluster exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/
```

Inspect `ztunnel` logs to verify transparent mTLS proxying:
```bash
kubectl logs -n istio-system -l app=ztunnel --tail=20
```
