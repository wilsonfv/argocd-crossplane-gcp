#!/usr/bin/env bash
#
# Multi-Cluster GKE Setup with Centralized Argo CD Control Plane (3 Clusters).
#
# Creates 3 GKE clusters:
# 1. Control Plane Cluster: 'argocd-control-plane' in VPC 'mq-usecase-1-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke'
# 2. Managed Cluster 1:     'gke-managed-cluster-1' in VPC 'mq-usecase-1-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke2'
# 3. Managed Cluster 2:     'gke-managed-cluster-2' in VPC 'mq-usecase-1-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke'
#
# Configures GCP Workload Identity and registers both managed clusters to Argo CD.
#
# Style Guide: Google Shell Style Guide
# https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Global Constants and Defaults
# -----------------------------------------------------------------------------
readonly DEFAULT_REGION="europe-west1"
readonly DEFAULT_ZONE=""
readonly DEFAULT_VPC=""

# Cluster 1 (Control Plane)
readonly DEFAULT_CP_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_CP_LOCATION="europe-west1"
readonly DEFAULT_CP_VPC="mq-usecase-1-internal-vpc1"
readonly DEFAULT_CP_SUBNET="internal-vpc1-europe-west1-gke"

# Cluster 2 (Managed 1)
readonly DEFAULT_MANAGED1_CLUSTER_NAME="gke-managed-cluster"
readonly DEFAULT_MANAGED1_LOCATION="europe-west1-b"
readonly DEFAULT_MANAGED1_VPC="mq-usecase-1-internal-vpc1"
readonly DEFAULT_MANAGED1_SUBNET="internal-vpc1-europe-west1-gke2"

# Cluster 3 (Managed 2)
readonly DEFAULT_MANAGED2_CLUSTER_NAME="gke-managed-cluster-2"
readonly DEFAULT_MANAGED2_LOCATION="europe-west1-b"
readonly DEFAULT_MANAGED2_VPC="mq-usecase-1-internal-vpc2"
readonly DEFAULT_MANAGED2_SUBNET="internal-vpc2-europe-west1-gke"

readonly DEFAULT_POD_RANGE="gke-pod"
readonly DEFAULT_SERVICE_RANGE="gke-service"
readonly DEFAULT_MACHINE_TYPE="e2-standard-4"
readonly DEFAULT_NUM_NODES="1"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ARGOCD_GSA_NAME="argocd-cluster-manager"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
CP_PROJECT_ID="${CP_PROJECT_ID:-}"
MANAGED1_PROJECT_ID="${MANAGED1_PROJECT_ID:-}"
MANAGED2_PROJECT_ID="${MANAGED2_PROJECT_ID:-}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"

# Cluster 1
CP_CLUSTER_NAME="${CP_CLUSTER_NAME:-${DEFAULT_CP_CLUSTER_NAME}}"
CP_LOCATION="${CP_LOCATION:-${DEFAULT_CP_LOCATION}}"
CP_VPC_NETWORK="${CP_VPC_NETWORK:-${DEFAULT_CP_VPC}}"
CP_SUBNET="${CP_SUBNET:-${DEFAULT_CP_SUBNET}}"

# Cluster 2 (Managed 1)
MANAGED1_CLUSTER_NAME="${MANAGED1_CLUSTER_NAME:-${MANAGED_CLUSTER_NAME:-${DEFAULT_MANAGED1_CLUSTER_NAME}}}"
MANAGED1_LOCATION="${MANAGED1_LOCATION:-${MANAGED_LOCATION:-${DEFAULT_MANAGED1_LOCATION}}}"
MANAGED1_VPC_NETWORK="${MANAGED1_VPC_NETWORK:-${DEFAULT_MANAGED1_VPC}}"
MANAGED1_SUBNET="${MANAGED1_SUBNET:-${MANAGED_SUBNET:-${DEFAULT_MANAGED1_SUBNET}}}"

# Cluster 3 (Managed 2)
MANAGED2_CLUSTER_NAME="${MANAGED2_CLUSTER_NAME:-${DEFAULT_MANAGED2_CLUSTER_NAME}}"
MANAGED2_LOCATION="${MANAGED2_LOCATION:-${DEFAULT_MANAGED2_LOCATION}}"
MANAGED2_VPC_NETWORK="${MANAGED2_VPC_NETWORK:-${DEFAULT_MANAGED2_VPC}}"
MANAGED2_SUBNET="${MANAGED2_SUBNET:-${DEFAULT_MANAGED2_SUBNET}}"

POD_RANGE="${POD_RANGE:-${DEFAULT_POD_RANGE}}"
SERVICE_RANGE="${SERVICE_RANGE:-${DEFAULT_SERVICE_RANGE}}"
MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
NUM_NODES="${NUM_NODES:-${DEFAULT_NUM_NODES}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ARGOCD_GSA_NAME="${ARGOCD_GSA_NAME:-${DEFAULT_ARGOCD_GSA_NAME}}"
DELETE_CLUSTERS="${DELETE_CLUSTERS:-false}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

#######################################
# Print current timestamp in ISO format.
#######################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

#######################################
# Log informational message.
#######################################
log_info() {
  echo -e "[$(timestamp)] ${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

#######################################
# Log success message.
#######################################
log_success() {
  echo -e "[$(timestamp)] ${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

#######################################
# Log warning message.
#######################################
log_warn() {
  echo -e "[$(timestamp)] ${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

#######################################
# Log error message.
#######################################
log_error() {
  echo -e "[$(timestamp)] ${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
}

#######################################
# Retrieve active GCP project ID.
#######################################
get_gcloud_config_project() {
  gcloud config list --format='value(core.project)' 2>/dev/null || true
}

#######################################
# Display usage instructions.
#######################################
usage() {
  local active_project
  active_project="$(get_gcloud_config_project)"
  local display_project="${PROJECT_ID:-${active_project:-[not set in gcloud config]}}"

  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sets up a Multi-Cluster GKE environment with Argo CD control plane (3 Clusters):
  - Cluster 1 (Control Plane): '${CP_CLUSTER_NAME}' in VPC '${CP_VPC_NETWORK}', subnet '${CP_SUBNET}'
  - Cluster 2 (Managed 1):     '${MANAGED1_CLUSTER_NAME}' in VPC '${MANAGED1_VPC_NETWORK}', subnet '${MANAGED1_SUBNET}'
  - Cluster 3 (Managed 2):     '${MANAGED2_CLUSTER_NAME}' in VPC '${MANAGED2_VPC_NETWORK}', subnet '${MANAGED2_SUBNET}'

Options:
  -p, --project PROJECT_ID          Default GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  --cp-project PROJECT_ID           Control plane cluster GCP project ID (default: ${CP_PROJECT_ID:-${display_project}})
  --managed1-project PROJECT_ID     Managed cluster 1 GCP project ID (default: ${MANAGED1_PROJECT_ID:-${display_project}})
  --managed2-project PROJECT_ID     Managed cluster 2 GCP project ID (default: ${MANAGED2_PROJECT_ID:-${display_project}})
  --managed-project PROJECT_ID      Alias setting project for both managed clusters

  --cp-cluster NAME                 Control plane cluster name (default: ${CP_CLUSTER_NAME})
  --cp-location LOCATION            Control plane location (default: ${CP_LOCATION})
  --cp-network NETWORK              Control plane VPC network (default: ${CP_VPC_NETWORK})
  --cp-subnet SUBNET                Control plane subnet name (default: ${CP_SUBNET})

  --managed1-cluster NAME           Managed cluster 1 name (default: ${MANAGED1_CLUSTER_NAME})
  --managed1-location LOCATION      Managed cluster 1 location (default: ${MANAGED1_LOCATION})
  --managed1-network NETWORK        Managed cluster 1 VPC network (default: ${MANAGED1_VPC_NETWORK})
  --managed1-subnet SUBNET          Managed cluster 1 subnet name (default: ${MANAGED1_SUBNET})

  --managed2-cluster NAME           Managed cluster 2 name (default: ${MANAGED2_CLUSTER_NAME})
  --managed2-location LOCATION      Managed cluster 2 location (default: ${MANAGED2_LOCATION})
  --managed2-network NETWORK        Managed cluster 2 VPC network (default: ${MANAGED2_VPC_NETWORK})
  --managed2-subnet SUBNET          Managed cluster 2 subnet name (default: ${MANAGED2_SUBNET})

  --gsa-name NAME                   GCP Service Account name for Workload Identity (default: ${ARGOCD_GSA_NAME})
  -m, --machine-type TYPE           GKE node machine type (default: ${MACHINE_TYPE})
  -n, --num-nodes NUM               Nodes per zone (default: ${NUM_NODES})
  -d, --delete                      Delete all 3 GKE clusters
  -y, --yes                         Auto-approve deletion without interactive prompt
  -h, --help                        Show this help message

Environment Variables:
  PROJECT_ID, CP_PROJECT_ID, MANAGED1_PROJECT_ID, MANAGED2_PROJECT_ID,
  CP_CLUSTER_NAME, MANAGED1_CLUSTER_NAME, MANAGED2_CLUSTER_NAME, DELETE_CLUSTERS, AUTO_APPROVE
EOF
}

#######################################
# Parse command line flags.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--project)
        PROJECT_ID="$2"
        shift 2
        ;;
      --cp-project)
        CP_PROJECT_ID="$2"
        shift 2
        ;;
      --managed-project)
        MANAGED1_PROJECT_ID="$2"
        MANAGED2_PROJECT_ID="$2"
        shift 2
        ;;
      --managed1-project)
        MANAGED1_PROJECT_ID="$2"
        shift 2
        ;;
      --managed2-project)
        MANAGED2_PROJECT_ID="$2"
        shift 2
        ;;
      --cp-cluster)
        CP_CLUSTER_NAME="$2"
        shift 2
        ;;
      --cp-location)
        CP_LOCATION="$2"
        shift 2
        ;;
      --cp-network)
        CP_VPC_NETWORK="$2"
        shift 2
        ;;
      --cp-subnet)
        CP_SUBNET="$2"
        shift 2
        ;;
      --managed1-cluster|--managed-cluster)
        MANAGED1_CLUSTER_NAME="$2"
        shift 2
        ;;
      --managed1-location|--managed-location)
        MANAGED1_LOCATION="$2"
        shift 2
        ;;
      --managed1-network|--managed-network)
        MANAGED1_VPC_NETWORK="$2"
        shift 2
        ;;
      --managed1-subnet|--managed-subnet)
        MANAGED1_SUBNET="$2"
        shift 2
        ;;
      --managed2-cluster)
        MANAGED2_CLUSTER_NAME="$2"
        shift 2
        ;;
      --managed2-location)
        MANAGED2_LOCATION="$2"
        shift 2
        ;;
      --managed2-network)
        MANAGED2_VPC_NETWORK="$2"
        shift 2
        ;;
      --managed2-subnet)
        MANAGED2_SUBNET="$2"
        shift 2
        ;;
      --gsa-name)
        ARGOCD_GSA_NAME="$2"
        shift 2
        ;;
      -m|--machine-type)
        MACHINE_TYPE="$2"
        shift 2
        ;;
      -n|--num-nodes)
        NUM_NODES="$2"
        shift 2
        ;;
      -d|--delete)
        DELETE_CLUSTERS=true
        shift
        ;;
      -y|--yes)
        AUTO_APPROVE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown flag: $1"
        usage
        exit 1
        ;;
    esac
  done
}

#######################################
# Validate prerequisites and resolve GCP project IDs.
#######################################
check_prerequisites() {
  log_info "Verifying required tools..."
  local tool
  for tool in gcloud kubectl argocd curl; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Missing required CLI tool: ${tool}. Please install it before proceeding."
      return 1
    fi
  done

  if [[ -z "${PROJECT_ID}" ]]; then
    log_info "Fetching active GCP project ID from 'gcloud config list'..."
    PROJECT_ID="$(get_gcloud_config_project)"
  fi

  if [[ -z "${PROJECT_ID}" && -z "${CP_PROJECT_ID}" ]]; then
    log_error "No active GCP project found in 'gcloud config list'. Please provide via -p/--project or run 'gcloud config set project <PROJECT_ID>'."
    return 1
  fi

  CP_PROJECT_ID="${CP_PROJECT_ID:-${PROJECT_ID}}"
  MANAGED1_PROJECT_ID="${MANAGED1_PROJECT_ID:-${PROJECT_ID}}"
  MANAGED2_PROJECT_ID="${MANAGED2_PROJECT_ID:-${PROJECT_ID}}"
  PROJECT_ID="${CP_PROJECT_ID}"

  log_info "Control Plane GCP Project: ${CP_PROJECT_ID}"
  log_info "Managed Cluster 1 Project: ${MANAGED1_PROJECT_ID}"
  log_info "Managed Cluster 2 Project: ${MANAGED2_PROJECT_ID}"
  gcloud config set project "${CP_PROJECT_ID}" >/dev/null
}

#######################################
# Format location flag based on location string.
# Arguments:
#   Location string (e.g. europe-west1 or europe-west1-b)
#######################################
format_location_flag() {
  local location="$1"
  if [[ "${location}" =~ -[a-z]$ ]]; then
    echo "--zone=${location}"
  else
    echo "--region=${location}"
  fi
}

#######################################
# Check if a GKE cluster exists.
# Arguments:
#   Cluster name
#   Cluster location
#   Project ID (optional)
#######################################
cluster_exists() {
  local cluster_name="$1"
  local location="$2"
  local project_id="${3:-${PROJECT_ID}}"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"
  gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${project_id}" &>/dev/null
}

#######################################
# Launch creation of a single GKE cluster asynchronously.
# Arguments:
#   Cluster name
#   Cluster location
#   Subnet name
#   VPC network
#   Project ID
#######################################
launch_cluster_creation() {
  local cluster_name="$1"
  local location="$2"
  local subnet_name="$3"
  local vpc_network="$4"
  local project_id="${5:-${PROJECT_ID}}"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  if cluster_exists "${cluster_name}" "${location}" "${project_id}"; then
    log_info "Cluster '${cluster_name}' already exists in ${location} (project '${project_id}'). Skipping creation."
    return 0
  fi

  log_info "Initiating creation of cluster '${cluster_name}' in ${location} (VPC '${vpc_network}', subnet '${subnet_name}')..."
  gcloud container clusters create "${cluster_name}" \
    "${loc_flag}" \
    --project "${project_id}" \
    --network "${vpc_network}" \
    --subnetwork "${subnet_name}" \
    --cluster-secondary-range-name "${POD_RANGE}" \
    --services-secondary-range-name "${SERVICE_RANGE}" \
    --enable-ip-alias \
    --workload-pool="${project_id}.svc.id.goog" \
    --num-nodes "${NUM_NODES}" \
    --machine-type "${MACHINE_TYPE}" \
    --release-channel "regular" \
    --async
  log_info "Cluster creation request submitted for '${cluster_name}'."
}

#######################################
# Wait for a cluster to reach RUNNING status.
# Arguments:
#   Cluster name
#   Cluster location
#   Project ID
#######################################
wait_for_cluster_running() {
  local cluster_name="$1"
  local location="$2"
  local project_id="${3:-${PROJECT_ID}}"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Waiting for cluster '${cluster_name}' in ${location} (project '${project_id}') to reach RUNNING status..."
  while true; do
    local status
    status="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${project_id}" --format="value(status)" 2>/dev/null || echo "PENDING")"
    if [[ "${status}" == "RUNNING" ]]; then
      log_success "Cluster '${cluster_name}' is RUNNING."
      break
    elif [[ "${status}" == "ERROR" || "${status}" == "DEGRADED" ]]; then
      log_error "Cluster '${cluster_name}' entered status: ${status}."
      return 1
    fi
    sleep 15
  done
}

#######################################
# Obtain kubeconfig credentials for a cluster.
# Arguments:
#   Cluster name
#   Cluster location
#   Project ID
#######################################
fetch_cluster_credentials() {
  local cluster_name="$1"
  local location="$2"
  local project_id="${3:-${PROJECT_ID}}"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Fetching kubeconfig credentials for '${cluster_name}' in ${location} (project '${project_id}')..."
  gcloud container clusters get-credentials "${cluster_name}" "${loc_flag}" --project "${project_id}"
}

#######################################
# Deploy Argo CD to the control plane cluster.
#######################################
install_argocd_control_plane() {
  local cp_context="gke_${CP_PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"

  log_info "Switching kubectl context to control plane: ${cp_context}..."
  kubectl config use-context "${cp_context}"

  log_info "Checking if Argo CD is already deployed in '${ARGOCD_NAMESPACE}'..."
  if kubectl get deployment/argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_info "Argo CD server already exists in '${ARGOCD_NAMESPACE}'. Checking health..."
  else
    log_info "Installing Argo CD in '${ARGOCD_NAMESPACE}' on '${CP_CLUSTER_NAME}'..."
    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    local manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
    kubectl apply --server-side --force-conflicts -n "${ARGOCD_NAMESPACE}" -f "${manifest_url}"
  fi

  log_info "Waiting for Argo CD components rollout on control plane..."
  kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}" --timeout=300s
  log_success "Argo CD control plane is fully operational."
}

#######################################
# Setup GCP Workload Identity for Argo CD to access both managed clusters.
#######################################
setup_workload_identity_for_argocd() {
  local cp_context="gke_${CP_PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed1_context="gke_${MANAGED1_PROJECT_ID}_${MANAGED1_LOCATION}_${MANAGED1_CLUSTER_NAME}"
  local managed2_context="gke_${MANAGED2_PROJECT_ID}_${MANAGED2_LOCATION}_${MANAGED2_CLUSTER_NAME}"
  local gsa_email="${ARGOCD_GSA_NAME}@${CP_PROJECT_ID}.iam.gserviceaccount.com"

  log_info "Configuring GCP Workload Identity for Argo CD..."
  log_info "  - Control plane GCP project (GSA host): ${CP_PROJECT_ID}"
  log_info "  - Managed GKE cluster 1 project:       ${MANAGED1_PROJECT_ID}"
  log_info "  - Managed GKE cluster 2 project:       ${MANAGED2_PROJECT_ID}"
  log_info "  - GSA email:                           ${gsa_email}"

  # 1. Create Google Cloud Service Account (GSA) in the control plane cluster GCP project
  if ! gcloud iam service-accounts describe "${gsa_email}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    log_info "Creating GCP Service Account '${ARGOCD_GSA_NAME}' in control plane cluster project '${CP_PROJECT_ID}'..."
    gcloud iam service-accounts create "${ARGOCD_GSA_NAME}" \
      --project="${CP_PROJECT_ID}" \
      --display-name="Argo CD Cluster Manager Workload Identity"
  else
    log_info "GCP Service Account '${gsa_email}' already exists in control plane cluster project '${CP_PROJECT_ID}'."
  fi

  # 2. Grant IAM roles in both managed GKE cluster projects
  local project role
  for project in "${MANAGED1_PROJECT_ID}" "${MANAGED2_PROJECT_ID}"; do
    for role in roles/container.developer roles/container.clusterViewer; do
      log_info "Granting '${role}' to '${gsa_email}' on project '${project}'..."
      gcloud projects add-iam-policy-binding "${project}" \
        --member="serviceAccount:${gsa_email}" \
        --role="${role}" \
        --quiet >/dev/null
    done
  done

  # 3. Bind Kubernetes SAs in Argo CD namespace to GSA via roles/iam.workloadIdentityUser
  local ksa
  for ksa in argocd-application-controller argocd-server; do
    log_info "Binding KSA '${ksa}' to GSA '${gsa_email}' via Workload Identity..."
    gcloud iam service-accounts add-iam-policy-binding "${gsa_email}" \
      --project="${CP_PROJECT_ID}" \
      --role="roles/iam.workloadIdentityUser" \
      --member="serviceAccount:${CP_PROJECT_ID}.svc.id.goog[${ARGOCD_NAMESPACE}/${ksa}]" \
      --quiet >/dev/null

    kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" annotate serviceaccount "${ksa}" \
      "iam.gke.io/gcp-service-account=${gsa_email}" --overwrite >/dev/null
  done

  # 4. Grant GSA cluster-admin RBAC on both managed clusters
  log_info "Granting cluster-admin RBAC to '${gsa_email}' on managed cluster 1 '${MANAGED1_CLUSTER_NAME}'..."
  kubectl --context="${managed1_context}" create clusterrolebinding argocd-workload-identity-admin \
    --clusterrole=cluster-admin \
    --user="${gsa_email}" \
    --dry-run=client -o yaml | kubectl --context="${managed1_context}" apply -f - >/dev/null

  log_info "Granting cluster-admin RBAC to '${gsa_email}' on managed cluster 2 '${MANAGED2_CLUSTER_NAME}'..."
  kubectl --context="${managed2_context}" create clusterrolebinding argocd-workload-identity-admin \
    --clusterrole=cluster-admin \
    --user="${gsa_email}" \
    --dry-run=client -o yaml | kubectl --context="${managed2_context}" apply -f - >/dev/null

  # 5. Restart Argo CD controller and server to mount Workload Identity tokens
  log_info "Restarting Argo CD workloads to activate Workload Identity tokens..."
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout restart statefulset/argocd-application-controller >/dev/null
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout restart deployment/argocd-server >/dev/null
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout status statefulset/argocd-application-controller --timeout=180s
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=180s
  log_success "GCP Workload Identity configured successfully for Argo CD."
}

#######################################
# Register a managed cluster into Argo CD using GCP Workload Identity execProviderConfig.
# Arguments:
#   Cluster name
#   Cluster location
#   Project ID
#######################################
register_managed_cluster() {
  local cluster_name="$1"
  local location="$2"
  local project_id="$3"
  local cp_context="gke_${CP_PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Registering managed cluster '${cluster_name}' into Argo CD via GCP Workload Identity..."

  # Fetch endpoint and CA certificate from GKE
  local endpoint ca_cert
  endpoint="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project="${project_id}" --format="value(endpoint)")"
  ca_cert="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project="${project_id}" --format="value(masterAuth.clusterCaCertificate)")"

  # Delete any legacy cluster secret for this cluster to avoid duplicates
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" delete secret "cluster-${cluster_name}" 2>/dev/null || true

  # Create Argo CD cluster secret configured with execProviderConfig (argocd-k8s-auth gcp)
  log_info "Creating Argo CD cluster secret for '${cluster_name}' (execProviderConfig: argocd-k8s-auth gcp)..."
  cat <<EOF | kubectl --context="${cp_context}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster_name}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster_name}
  server: https://${endpoint}
  config: |
    {
      "execProviderConfig": {
        "command": "argocd-k8s-auth",
        "args": ["gcp"],
        "apiVersion": "client.authentication.k8s.io/v1beta1"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca_cert}"
      }
    }
EOF

  log_success "Managed cluster '${cluster_name}' successfully registered into Argo CD using GCP Workload Identity."
}

#######################################
# Print final deployment summary.
#######################################
print_summary() {
  local cp_context="gke_${CP_PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed1_context="gke_${MANAGED1_PROJECT_ID}_${MANAGED1_LOCATION}_${MANAGED1_CLUSTER_NAME}"
  local managed2_context="gke_${MANAGED2_PROJECT_ID}_${MANAGED2_LOCATION}_${MANAGED2_CLUSTER_NAME}"
  local gsa_email="${ARGOCD_GSA_NAME}@${CP_PROJECT_ID}.iam.gserviceaccount.com"

  kubectl config set-context "${cp_context}" --namespace="${ARGOCD_NAMESPACE}" >/dev/null
  kubectl config use-context "${cp_context}" >/dev/null
  local admin_password
  admin_password="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "[password already rotated or not yet generated]")"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}  Multi-Cluster GKE Setup with Argo CD Control Plane (3 Clusters)    ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}Control Plane Project:${COLOR_NC}       ${CP_PROJECT_ID}"
  echo -e "${COLOR_BOLD}Managed 1 Project:${COLOR_NC}           ${MANAGED1_PROJECT_ID}"
  echo -e "${COLOR_BOLD}Managed 2 Project:${COLOR_NC}           ${MANAGED2_PROJECT_ID}"
  echo -e "${COLOR_BOLD}Workload Identity GSA:${COLOR_NC}       ${gsa_email}"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 1 (Control Plane):${COLOR_NC}   ${CP_CLUSTER_NAME}"
  echo -e "  - Location:                ${CP_LOCATION}"
  echo -e "  - VPC Network:             ${CP_VPC_NETWORK}"
  echo -e "  - Subnet:                  ${CP_SUBNET}"
  echo -e "  - Kube Context:            ${cp_context}"
  echo -e "  - Argo CD Namespace:       ${ARGOCD_NAMESPACE}"
  echo -e "  - Admin Username:          admin"
  echo -e "  - Admin Password:          ${admin_password}"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 2 (Managed 1):${COLOR_NC}       ${MANAGED1_CLUSTER_NAME}"
  echo -e "  - Location:                ${MANAGED1_LOCATION}"
  echo -e "  - VPC Network:             ${MANAGED1_VPC_NETWORK}"
  echo -e "  - Subnet:                  ${MANAGED1_SUBNET}"
  echo -e "  - Kube Context:            ${managed1_context}"
  echo -e "  - Managed By:              ${CP_CLUSTER_NAME} (Argo CD via Workload Identity)"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 3 (Managed 2):${COLOR_NC}       ${MANAGED2_CLUSTER_NAME}"
  echo -e "  - Location:                ${MANAGED2_LOCATION}"
  echo -e "  - VPC Network:             ${MANAGED2_VPC_NETWORK}"
  echo -e "  - Subnet:                  ${MANAGED2_SUBNET}"
  echo -e "  - Kube Context:            ${managed2_context}"
  echo -e "  - Managed By:              ${CP_CLUSTER_NAME} (Argo CD via Workload Identity)"
  echo ""
  echo -e "${COLOR_BOLD}Argo CD Registered Clusters:${COLOR_NC}"
  argocd cluster list --core --kube-context "${cp_context}" --loglevel debug || true
  echo ""
  echo -e "${COLOR_BOLD}Access Argo CD UI:${COLOR_NC}"
  echo "  kubectl config use-context ${cp_context}"
  echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
  echo "  Open: https://localhost:8080"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

#######################################
# Delete all 3 GKE clusters.
#######################################
delete_clusters() {
  local cp_loc_flag
  cp_loc_flag="$(format_location_flag "${CP_LOCATION}")"
  local managed1_loc_flag
  managed1_loc_flag="$(format_location_flag "${MANAGED1_LOCATION}")"
  local managed2_loc_flag
  managed2_loc_flag="$(format_location_flag "${MANAGED2_LOCATION}")"

  local confirm="${AUTO_APPROVE}"
  if [[ "${confirm}" != "true" ]]; then
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} You are about to permanently DELETE all 3 clusters:"
    echo "  - Control plane: '${CP_CLUSTER_NAME}' in ${CP_LOCATION} (project: ${CP_PROJECT_ID})"
    echo "  - Managed 1:     '${MANAGED1_CLUSTER_NAME}' in ${MANAGED1_LOCATION} (project: ${MANAGED1_PROJECT_ID})"
    echo "  - Managed 2:     '${MANAGED2_CLUSTER_NAME}' in ${MANAGED2_LOCATION} (project: ${MANAGED2_PROJECT_ID})"
    echo -n "Are you sure you want to proceed? [y/N]: "
    read -r confirm
  fi

  if [[ ! "${confirm}" =~ ^[Yy]$ && "${confirm}" != "true" ]]; then
    log_info "Cluster deletion cancelled by user."
    return 0
  fi

  if cluster_exists "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_PROJECT_ID}"; then
    log_info "Deleting control plane cluster '${CP_CLUSTER_NAME}' (${CP_LOCATION}, project: ${CP_PROJECT_ID})..."
    gcloud container clusters delete "${CP_CLUSTER_NAME}" "${cp_loc_flag}" --project "${CP_PROJECT_ID}" --quiet --async
  fi

  if cluster_exists "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_PROJECT_ID}"; then
    log_info "Deleting managed cluster 1 '${MANAGED1_CLUSTER_NAME}' (${MANAGED1_LOCATION}, project: ${MANAGED1_PROJECT_ID})..."
    gcloud container clusters delete "${MANAGED1_CLUSTER_NAME}" "${managed1_loc_flag}" --project "${MANAGED1_PROJECT_ID}" --quiet --async
  fi

  if cluster_exists "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_PROJECT_ID}"; then
    log_info "Deleting managed cluster 2 '${MANAGED2_CLUSTER_NAME}' (${MANAGED2_LOCATION}, project: ${MANAGED2_PROJECT_ID})..."
    gcloud container clusters delete "${MANAGED2_CLUSTER_NAME}" "${managed2_loc_flag}" --project "${MANAGED2_PROJECT_ID}" --quiet --async
  fi

  log_info "Waiting for cluster deletions to complete..."
  while cluster_exists "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_PROJECT_ID}" || \
        cluster_exists "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_PROJECT_ID}" || \
        cluster_exists "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_PROJECT_ID}"; do
    sleep 10
  done

  log_success "All 3 GKE clusters deleted successfully."
}

#######################################
# Main execution function.
#######################################
main() {
  parse_flags "$@"
  check_prerequisites

  if [[ "${DELETE_CLUSTERS}" == "true" ]]; then
    delete_clusters
    return 0
  fi

  log_info "Phase 1: Ensuring all 3 GKE clusters exist..."
  launch_cluster_creation "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_SUBNET}" "${CP_VPC_NETWORK}" "${CP_PROJECT_ID}"
  launch_cluster_creation "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_SUBNET}" "${MANAGED1_VPC_NETWORK}" "${MANAGED1_PROJECT_ID}"
  launch_cluster_creation "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_SUBNET}" "${MANAGED2_VPC_NETWORK}" "${MANAGED2_PROJECT_ID}"

  log_info "Phase 2: Waiting for all 3 clusters to reach RUNNING status..."
  wait_for_cluster_running "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_PROJECT_ID}"
  wait_for_cluster_running "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_PROJECT_ID}"
  wait_for_cluster_running "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_PROJECT_ID}"

  log_info "Phase 3: Fetching credentials for all 3 clusters..."
  fetch_cluster_credentials "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_PROJECT_ID}"
  fetch_cluster_credentials "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_PROJECT_ID}"
  fetch_cluster_credentials "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_PROJECT_ID}"

  log_info "Phase 4: Deploying Argo CD to control plane cluster..."
  install_argocd_control_plane

  log_info "Phase 5: Configuring Workload Identity and registering both managed clusters..."
  setup_workload_identity_for_argocd
  register_managed_cluster "${MANAGED1_CLUSTER_NAME}" "${MANAGED1_LOCATION}" "${MANAGED1_PROJECT_ID}"
  register_managed_cluster "${MANAGED2_CLUSTER_NAME}" "${MANAGED2_LOCATION}" "${MANAGED2_PROJECT_ID}"

  print_summary
}

main "$@"
