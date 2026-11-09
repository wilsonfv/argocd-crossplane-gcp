# GKE GitOps Platform: Argo CD, Crossplane & Istio Ambient Service Mesh

Automated scripts and declarative GitOps source-of-truth configurations following the **Google Shell Style Guide** for Google Kubernetes Engine (GKE) in GCP.

---

## Repository Structure

```text
.
├── setup-multicluster.sh      # Provisions 3-cluster GKE & configures Argo CD via Workload Identity
├── install-crossplane.sh      # Installs latest Crossplane on GKE via Helm
├── deploy-istio-ambient.sh    # Deploys Istio Ambient Mode across all 3 clusters via Argo CD
├── access-argocd-ui.sh        # Port-forwards Argo CD Web UI & displays admin credentials
└── README.md
```

> **Note**: All Istio Ambient Mode configurations reside exclusively in the private GitOps repository:
> 👉 [**github.com/wilsonfv/istio-ambient-config**](https://github.com/wilsonfv/istio-ambient-config)
>
> This repository contains **no Istio configurations**; deployment syncs directly from the private repository.

---

## 1. Deploy or Delete Multi-Cluster GKE & Argo CD

```bash
# Provision both environments (all 6 clusters, default)
./setup-multicluster.sh --all

# Provision only Environment 1 (Full Control Plane + 2 Managed Clusters)
./setup-multicluster.sh --full

# Provision only Environment 2 (Headless Argo CD Core Control Plane + 2 Managed Clusters)
./setup-multicluster.sh --headless

# Delete clusters for the selected environment
./setup-multicluster.sh --delete
./setup-multicluster.sh --delete --yes
```

### Dual-Topology Architecture

#### Environment 1: Full Argo CD Control Plane (VPC1)
1. **Control Plane**: `argocd-control-plane` in GCP `mq-usecase-1`, VPC `mq-usecase-1-internal-vpc1`, subnet `internal-vpc1-europe-west1-gke` (`europe-west1`).
   - Mode: **Full Argo CD installation** (Web UI, API server, controller, repo-server, dex, redis).
2. **Managed Cluster 1**: `gke-managed-cluster` in GCP `mq-usecase-2`, VPC `mq-usecase-2-internal-vpc1`, subnet `internal-vpc1-europe-west1-gke` (`europe-west1-b`).
3. **Managed Cluster 2**: `gke-managed-cluster-2` in GCP `mq-usecase-2`, VPC `mq-usecase-2-internal-vpc1`, subnet `internal-vpc1-europe-west1-gke2` (`europe-west1-b`).
   - Both managed clusters registered into `argocd-control-plane` using GCP Workload Identity with `execProviderConfig` (`argocd-k8s-auth gcp`).

#### Environment 2: Headless Argo CD Core Control Plane (VPC2)
1. **Headless Control Plane**: `argocd-control-plane-headless` in GCP `mq-usecase-1`, VPC `mq-usecase-1-internal-vpc2`, subnet `internal-vpc2-europe-west1-gke` (`europe-west1`).
   - Mode: **Argo CD Core (headless mode) only** (`core-install.yaml` — controller, repo-server, redis, applicationset-controller, no UI/API server).
2. **New Managed Cluster 1**: `gke-managed-cluster-3` in GCP `mq-usecase-2`, VPC `mq-usecase-2-internal-vpc2`, subnet `internal-vpc2-europe-west1-gke` (`europe-west1-b`).
3. **New Managed Cluster 2**: `gke-managed-cluster-4` in GCP `mq-usecase-2`, VPC `mq-usecase-2-internal-vpc2`, subnet `internal-vpc2-europe-west1-gke2` (`europe-west1-b`).
   - Both new managed clusters registered into `argocd-control-plane-headless` using GCP Workload Identity with `execProviderConfig` (`argocd-k8s-auth gcp`).

### Options
| Option | Env Var | Default | Description |
|---|---|---|---|
| `--all` | `SETUP_TARGET=all` | `all` | Provision both environments (all 6 clusters) |
| `--full` | `SETUP_TARGET=full` | | Provision only Environment 1 (Full Control Plane + 2 Managed Clusters) |
| `--headless`, `--core` | `SETUP_TARGET=headless` | | Provision only Environment 2 (Headless Core Control Plane + 2 Managed Clusters) |
| `-m`, `--machine-type` | `MACHINE_TYPE` | `e2-standard-4` | Node machine type |
| `-n`, `--num-nodes` | `NUM_NODES` | `1` | Nodes per zone |
| `-d`, `--delete` | `DELETE_CLUSTERS` | `false` | Delete clusters for the selected target |
| `-y`, `--yes` | `AUTO_APPROVE` | `false` | Auto-approve deletion prompt |

### GCP Workload Identity for Managed Cluster Access
Both managed clusters are registered into Argo CD using **GCP Workload Identity** with `execProviderConfig` cluster secrets:
- All 3 GKE clusters are provisioned with Workload Identity pools (`--workload-pool="${PROJECT_ID}.svc.id.goog"`).
- **GSA in Control Plane Project**: A Google Cloud Service Account (`argocd-cluster-manager@<CP_PROJECT_ID>.iam.gserviceaccount.com`) is created in the control plane cluster's GCP project and bound to Argo CD's Kubernetes ServiceAccounts (`argocd-application-controller` and `argocd-server`) via `roles/iam.workloadIdentityUser`.
- **IAM Roles in Managed Projects**: The GSA is granted `roles/container.developer` and `roles/container.clusterViewer` across the managed cluster projects.
- **Cluster Secret with `execProviderConfig`**: The managed cluster secrets in Argo CD use `execProviderConfig` with `argocd-k8s-auth gcp` to mint short-lived tokens on the fly, eliminating the need to store static bearer tokens or credentials.

### Access Argo CD Web UI & 1-Click Direct Login
Use the automated access helper to print credentials, establish a local port-forward, and provide 1-click direct login URLs:
```bash
# Print credentials, 1-click direct login URL, and start port-forward
./access-argocd-ui.sh
```

When you click the **1-Click Direct Login URL**:
- `https://localhost:8080/?username=admin&password=<PASSWORD>`
- Or `https://admin:<PASSWORD>@localhost:8080/`

The local bridge securely exchanges credentials for a session token, sets the `argocd.token` cookie, and opens the UI directly into `/applications` without requiring any manual entry.

Manual access commands:
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
  - `05-argocd.yaml` (control plane only): Self-managing Argo CD Application on the control plane cluster.

### Self-Managing Argo CD on Control Plane
Argo CD on the control plane cluster is managed declaratively by Argo CD itself (`argocd-cp`):
- Declarative manifests reside in `manifests/argocd/` with Kustomize patches that enforce GCP Workload Identity annotations on `argocd-application-controller` and `argocd-server`.
- Reconciles and self-heals all Argo CD controllers, server deployments, CRDs, and RBAC policies.
- Protects runtime cluster secrets and initial credentials via `ignoreDifferences` and non-destructive sync policies.

To deploy Istio Ambient mesh across all 6 clusters (2 control planes + 4 managed clusters):
```bash
# Deploy to all 6 clusters across both environments (default)
./deploy-istio-ambient.sh --all

# Or deploy to Environment 1 only (Full Control Plane + 2 Managed Clusters)
./deploy-istio-ambient.sh --full

# Or deploy to Environment 2 only (Headless Control Plane + 2 Managed Clusters)
./deploy-istio-ambient.sh --headless
```

Or pass your GitHub PAT explicitly if not detected:
```bash
./deploy-istio-ambient.sh --token <GITHUB_PAT>
```

### Validate Ambient Mode Traffic Across All 6 Clusters
Workloads in the `apps-ambient` namespace have the label `istio.io/dataplane-mode: ambient`.

Send a test HTTP request from the sleep client to the echo server on each cluster:
```bash
# Environment 1 — Control Plane (mq-usecase-1, VPC1):
kubectl --context gke_mq-usecase-1_europe-west1_argocd-control-plane exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Environment 1 — Managed 1 (mq-usecase-2, VPC1, subnet 1):
kubectl --context gke_mq-usecase-2_europe-west1-b_gke-managed-cluster exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Environment 1 — Managed 2 (mq-usecase-2, VPC1, subnet 2):
kubectl --context gke_mq-usecase-2_europe-west1-b_gke-managed-cluster-2 exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Environment 2 — Headless Control Plane (mq-usecase-1, VPC2):
kubectl --context gke_mq-usecase-1_europe-west1_argocd-control-plane-headless exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Environment 2 — Managed 3 (mq-usecase-2, VPC2, subnet 1):
kubectl --context gke_mq-usecase-2_europe-west1-b_gke-managed-cluster-3 exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/

# Environment 2 — Managed 4 (mq-usecase-2, VPC2, subnet 2):
kubectl --context gke_mq-usecase-2_europe-west1-b_gke-managed-cluster-4 exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/
```

Inspect `ztunnel` logs to verify transparent mTLS proxying:
```bash
kubectl logs -n istio-system -l app=ztunnel --tail=20
```
