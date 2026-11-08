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

## 1. Deploy or Delete 3-Cluster GKE & Argo CD

```bash
# Provision all 3 GKE clusters, deploy Argo CD, and register both managed clusters
./setup-multicluster.sh

# Delete all 3 GKE clusters (with confirmation prompt)
./setup-multicluster.sh --delete

# Delete all 3 GKE clusters non-interactively
./setup-multicluster.sh --delete --yes
```

### 3-Cluster Architecture
1. **Cluster 1 (Control Plane)**: `argocd-control-plane` in VPC `mq-usecase-1-internal-vpc1`, subnet `internal-vpc1-europe-west1-gke` (`europe-west1`).
2. **Cluster 2 (Managed 1)**: `gke-managed-cluster-1` in VPC `mq-usecase-1-internal-vpc1`, subnet `internal-vpc1-europe-west1-gke2` (`europe-west1-b`).
3. **Cluster 3 (Managed 2)**: `gke-managed-cluster-2` in VPC `mq-usecase-1-internal-vpc2`, subnet `internal-vpc2-europe-west1-gke` (`europe-west1-b`).

### Options
| Option | Env Var | Default | Description |
|---|---|---|---|
| `-p`, `--project` | `PROJECT_ID` | `gcloud config list` | Default GCP Project ID (dynamically detected) |
| `--cp-project` | `CP_PROJECT_ID` | `PROJECT_ID` | Control plane cluster GCP project ID |
| `--managed1-project` | `MANAGED1_PROJECT_ID` | `PROJECT_ID` | Managed cluster 1 GCP project ID |
| `--managed2-project` | `MANAGED2_PROJECT_ID` | `PROJECT_ID` | Managed cluster 2 GCP project ID |
| `--cp-cluster` | `CP_CLUSTER_NAME` | `argocd-control-plane` | Control plane GKE cluster name |
| `--cp-location` | `CP_LOCATION` | `europe-west1` | Control plane location |
| `--cp-network` | `CP_VPC_NETWORK` | `mq-usecase-1-internal-vpc1` | Control plane VPC network |
| `--cp-subnet` | `CP_SUBNET` | `internal-vpc1-europe-west1-gke` | Control plane subnet |
| `--managed1-cluster`| `MANAGED1_CLUSTER_NAME`| `gke-managed-cluster-1`| Managed GKE cluster 1 name |
| `--managed1-location`| `MANAGED1_LOCATION`| `europe-west1-b` | Managed GKE cluster 1 location |
| `--managed1-network` | `MANAGED1_VPC_NETWORK` | `mq-usecase-1-internal-vpc1` | Managed cluster 1 VPC network |
| `--managed1-subnet` | `MANAGED1_SUBNET` | `internal-vpc1-europe-west1-gke2`| Managed cluster 1 subnet |
| `--managed2-cluster`| `MANAGED2_CLUSTER_NAME`| `gke-managed-cluster-2`| Managed GKE cluster 2 name |
| `--managed2-location`| `MANAGED2_LOCATION`| `europe-west1-b` | Managed GKE cluster 2 location |
| `--managed2-network` | `MANAGED2_VPC_NETWORK` | `mq-usecase-1-internal-vpc2` | Managed cluster 2 VPC network |
| `--managed2-subnet` | `MANAGED2_SUBNET` | `internal-vpc2-europe-west1-gke` | Managed cluster 2 subnet |
| `--gsa-name` | `ARGOCD_GSA_NAME` | `argocd-cluster-manager` | GCP Service Account for Workload Identity |
| `-m`, `--machine-type` | `MACHINE_TYPE` | `e2-standard-4` | Node machine type |
| `-n`, `--num-nodes` | `NUM_NODES` | `1` | Nodes per zone |
| `-d`, `--delete` | `DELETE_CLUSTERS` | `false` | Delete all 3 GKE clusters |
| `-y`, `--yes` | `AUTO_APPROVE` | `false` | Auto-approve deletion prompt |

### GCP Workload Identity for Managed Cluster Access
Both managed clusters are registered into Argo CD using **GCP Workload Identity** with `execProviderConfig` cluster secrets:
- All 3 GKE clusters are provisioned with Workload Identity pools (`--workload-pool="${PROJECT_ID}.svc.id.goog"`).
- **GSA in Control Plane Project**: A Google Cloud Service Account (`argocd-cluster-manager@<CP_PROJECT_ID>.iam.gserviceaccount.com`) is created in the control plane cluster's GCP project and bound to Argo CD's Kubernetes ServiceAccounts (`argocd-application-controller` and `argocd-server`) via `roles/iam.workloadIdentityUser`.
- **IAM Roles in Managed Projects**: The GSA is granted `roles/container.developer` and `roles/container.clusterViewer` across the managed cluster projects.
- **Cluster Secret with `execProviderConfig`**: The managed cluster secrets in Argo CD use `execProviderConfig` with `argocd-k8s-auth gcp` to mint short-lived tokens on the fly, eliminating the need to store static bearer tokens or credentials.

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

## 3. Deploy Istio Service Mesh (Ambient Mode) to All 3 GKE Clusters via Argo CD

Istio Ambient Mode configurations are synchronized from the dedicated private GitOps repository:
👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config) (Private)

### Shared Argo CD Apps & Dedicated Cluster Configurations
The GitOps repository refactors Argo CD application manifests using Kustomize inheritance:
- **`argocd/base/`**: Shared base application definitions (`00-istio-base`, `01-istio-cni`, `01-istiod`, `02-istio-ztunnel`, `03-istio-policies`, `04-ambient-samples`) containing all common sync policies, sync waves, retry logic, and ignore differences.
- **`argocd/clusters/<cluster-name>/`**: Dedicated folder per cluster containing:
  - `kustomization.yaml`: Inherits from `../../base`, applies cluster name suffix (`-cp`, `-managed-1`, `-managed-2`), and patches the target cluster destination.
  - `cluster-config.yaml`: Cluster-specific configurations, networking metadata, and ConfigMaps.

To deploy Istio Ambient mesh to all 3 clusters:
```bash
./deploy-istio-ambient.sh
```

Or pass your GitHub PAT explicitly if not detected:
```bash
./deploy-istio-ambient.sh --token <GITHUB_PAT>
```

### Validate Ambient Mode Traffic Across All 3 Clusters
Workloads in the `apps-ambient` namespace have the label `istio.io/dataplane-mode: ambient`.

Send a test HTTP request from the sleep client to the echo server on each cluster:
```bash
# Control plane cluster:
kubectl --context gke_${PROJECT_ID}_europe-west1_argocd-control-plane exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Managed cluster 1:
kubectl --context gke_${PROJECT_ID}_europe-west1-b_gke-managed-cluster-1 exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Managed cluster 2:
kubectl --context gke_${PROJECT_ID}_europe-west1-b_gke-managed-cluster-2 exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/
```

Inspect `ztunnel` logs to verify transparent mTLS proxying:
```bash
kubectl logs -n istio-system -l app=ztunnel --tail=20
```
