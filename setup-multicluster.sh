#!/usr/bin/env bash
#
# Multi-Cluster GKE Setup with Argo CD Control Planes (Dual-Topology).
#
# Environment 1 (Full Argo CD Control Plane):
#   - Control Plane: 'argocd-control-plane' in GCP 'mq-usecase-1', VPC 'mq-usecase-1-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke'
#   - Managed 1:     'gke-managed-cluster' in GCP 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke'
#   - Managed 2:     'gke-managed-cluster-2' in GCP 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke2'
#
# Environment 2 (Headless Argo CD Core Control Plane):
#   - Headless CP:   'argocd-control-plane-headless' in GCP 'mq-usecase-1', VPC 'mq-usecase-1-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke'
#   - Managed 1:     'gke-managed-vpc2-1' in GCP 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke'
#   - Managed 2:     'gke-managed-vpc2-2' in GCP 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke2'
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
readonly DEFAULT_POD_RANGE="gke-pod"
readonly DEFAULT_SERVICE_RANGE="gke-service"
readonly DEFAULT_MACHINE_TYPE="e2-standard-4"
readonly DEFAULT_NUM_NODES="1"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ARGOCD_GSA_NAME="argocd-cluster-manager"

# -----------------------------------------------------------------------------
# Environment 1: Full Control Plane (VPC1)
# -----------------------------------------------------------------------------
readonly DEFAULT_ENV1_CP_PROJECT_ID="mq-usecase-1"
readonly DEFAULT_ENV1_CP_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_ENV1_CP_LOCATION="europe-west1"
readonly DEFAULT_ENV1_CP_VPC="mq-usecase-1-internal-vpc1"
readonly DEFAULT_ENV1_CP_SUBNET="internal-vpc1-europe-west1-gke"

readonly DEFAULT_ENV1_MANAGED_PROJECT_ID="mq-usecase-2"
readonly DEFAULT_ENV1_MANAGED_VPC="mq-usecase-2-internal-vpc1"

readonly DEFAULT_ENV1_MANAGED1_CLUSTER_NAME="gke-managed-cluster"
readonly DEFAULT_ENV1_MANAGED1_LOCATION="europe-west1-b"
readonly DEFAULT_ENV1_MANAGED1_SUBNET="internal-vpc1-europe-west1-gke"

readonly DEFAULT_ENV1_MANAGED2_CLUSTER_NAME="gke-managed-cluster-2"
readonly DEFAULT_ENV1_MANAGED2_LOCATION="europe-west1-b"
readonly DEFAULT_ENV1_MANAGED2_SUBNET="internal-vpc1-europe-west1-gke2"

# -----------------------------------------------------------------------------
# Environment 2: Headless Control Plane (VPC2)
# -----------------------------------------------------------------------------
readonly DEFAULT_ENV2_CP_PROJECT_ID="mq-usecase-1"
readonly DEFAULT_ENV2_CP_CLUSTER_NAME="argocd-control-plane-headless"
readonly DEFAULT_ENV2_CP_LOCATION="europe-west1"
readonly DEFAULT_ENV2_CP_VPC="mq-usecase-1-internal-vpc2"
readonly DEFAULT_ENV2_CP_SUBNET="internal-vpc2-europe-west1-gke"

readonly DEFAULT_ENV2_MANAGED_PROJECT_ID="mq-usecase-2"
readonly DEFAULT_ENV2_MANAGED_VPC="mq-usecase-2-internal-vpc2"

readonly DEFAULT_ENV2_MANAGED1_CLUSTER_NAME="gke-managed-vpc2-1"
readonly DEFAULT_ENV2_MANAGED1_LOCATION="europe-west1-b"
readonly DEFAULT_ENV2_MANAGED1_SUBNET="internal-vpc2-europe-west1-gke"

readonly DEFAULT_ENV2_MANAGED2_CLUSTER_NAME="gke-managed-vpc2-2"
readonly DEFAULT_ENV2_MANAGED2_LOCATION="europe-west1-b"
readonly DEFAULT_ENV2_MANAGED2_SUBNET="internal-vpc2-europe-west1-gke2"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
SETUP_TARGET="${SETUP_TARGET:-all}" # all, full, headless
DELETE_CLUSTERS="${DELETE_CLUSTERS:-false}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

POD_RANGE="${POD_RANGE:-${DEFAULT_POD_RANGE}}"
SERVICE_RANGE="${SERVICE_RANGE:-${DEFAULT_SERVICE_RANGE}}"
MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
NUM_NODES="${NUM_NODES:-${DEFAULT_NUM_NODES}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ARGOCD_GSA_NAME="${ARGOCD_GSA_NAME:-${DEFAULT_ARGOCD_GSA_NAME}}"

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
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sets up Multi-Cluster GKE environments with Argo CD Control Planes:

Environment 1 (Full Control Plane + 2 Managed Clusters in VPC1):
  - Control Plane: 'argocd-control-plane' in 'mq-usecase-1', VPC 'mq-usecase-1-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke'
  - Managed 1:     'gke-managed-cluster' in 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke'
  - Managed 2:     'gke-managed-cluster-2' in 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc1', subnet 'internal-vpc1-europe-west1-gke2'

Environment 2 (Headless Control Plane + 2 Managed Clusters in VPC2):
  - Headless CP:   'argocd-control-plane-headless' in 'mq-usecase-1', VPC 'mq-usecase-1-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke'
  - Managed 1:     'gke-managed-vpc2-1' in 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke'
  - Managed 2:     'gke-managed-vpc2-2' in 'mq-usecase-2', VPC 'mq-usecase-2-internal-vpc2', subnet 'internal-vpc2-europe-west1-gke2'

Options:
  --all                       Provision both environments (all 6 clusters, default)
  --full                      Provision only Environment 1 (Full Argo CD Control Plane + 2 Managed Clusters)
  --headless, --core          Provision only Environment 2 (Headless Argo CD Core Control Plane + 2 Managed Clusters)
  -m, --machine-type TYPE     GKE node machine type (default: ${MACHINE_TYPE})
  -n, --num-nodes NUM         Nodes per zone (default: ${NUM_NODES})
  -d, --delete                Delete clusters for the selected environment
  -y, --yes                   Auto-approve deletion without interactive prompt
  -h, --help                  Show this help message

Environment Variables:
  SETUP_TARGET (all, full, headless), DELETE_CLUSTERS, AUTO_APPROVE
EOF
}

#######################################
# Parse command line flags.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        SETUP_TARGET="all"
        shift
        ;;
      --full)
        SETUP_TARGET="full"
        shift
        ;;
      --headless|--core)
        SETUP_TARGET="headless"
        shift
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
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

#######################################
# Validate required tools and APIs.
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

  # Verify and enable GKE APIs if needed
  local project
  for project in "${DEFAULT_ENV1_CP_PROJECT_ID}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"; do
    if ! gcloud services list --project="${project}" --enabled --filter="name:container.googleapis.com" --format="value(name)" 2>/dev/null | grep -q "container.googleapis.com"; then
      log_info "Enabling Kubernetes Engine API on '${project}'..."
      gcloud services enable container.googleapis.com --project="${project}"
    fi
  done
}

#######################################
# Format location string to gcloud location flag.
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
#######################################
cluster_exists() {
  local cluster_name="$1"
  local location="$2"
  local project_id="$3"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"
  gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${project_id}" &>/dev/null
}

#######################################
# Launch creation of a single GKE cluster asynchronously.
#######################################
launch_cluster_creation() {
  local cluster_name="$1"
  local location="$2"
  local subnet_name="$3"
  local vpc_network="$4"
  local project_id="$5"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  if cluster_exists "${cluster_name}" "${location}" "${project_id}"; then
    log_info "Cluster '${cluster_name}' already exists in ${location} (project '${project_id}'). Skipping creation."
    return 0
  fi

  log_info "Initiating creation of cluster '${cluster_name}' in ${location} (project '${project_id}', VPC '${vpc_network}', subnet '${subnet_name}')..."
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
#######################################
wait_for_cluster_running() {
  local cluster_name="$1"
  local location="$2"
  local project_id="$3"
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
#######################################
fetch_cluster_credentials() {
  local cluster_name="$1"
  local location="$2"
  local project_id="$3"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Fetching kubeconfig credentials for '${cluster_name}' in ${location} (project '${project_id}')..."
  gcloud container clusters get-credentials "${cluster_name}" "${loc_flag}" --project "${project_id}"
}

#######################################
# Deploy Full Argo CD to control plane cluster.
#######################################
install_argocd_full_control_plane() {
  local cp_context="gke_${DEFAULT_ENV1_CP_PROJECT_ID}_${DEFAULT_ENV1_CP_LOCATION}_${DEFAULT_ENV1_CP_CLUSTER_NAME}"

  log_info "Deploying Full Argo CD on control plane: ${cp_context}..."
  kubectl config use-context "${cp_context}"

  if kubectl get deployment/argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_info "Argo CD server already exists in '${ARGOCD_NAMESPACE}'. Checking health..."
  else
    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    local manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
    kubectl apply --server-side --force-conflicts -n "${ARGOCD_NAMESPACE}" -f "${manifest_url}"
  fi

  log_info "Waiting for Full Argo CD components rollout..."
  kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}" --timeout=300s
  log_success "Full Argo CD control plane is operational."
}

#######################################
# Deploy Headless Argo CD Core to control plane cluster.
#######################################
install_argocd_core_control_plane() {
  local cp_context="gke_${DEFAULT_ENV2_CP_PROJECT_ID}_${DEFAULT_ENV2_CP_LOCATION}_${DEFAULT_ENV2_CP_CLUSTER_NAME}"

  log_info "Deploying Headless Argo CD Core on control plane: ${cp_context}..."
  kubectl config use-context "${cp_context}"

  if kubectl get statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    log_info "Argo CD Core already deployed in '${ARGOCD_NAMESPACE}'. Checking health..."
  else
    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    local core_url="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/core-install.yaml"
    kubectl apply --server-side --force-conflicts -n "${ARGOCD_NAMESPACE}" -f "${core_url}"
  fi

  log_info "Waiting for Argo CD Core components rollout..."
  kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-applicationset-controller -n "${ARGOCD_NAMESPACE}" --timeout=300s
  kubectl rollout status statefulset/argocd-application-controller -n "${ARGOCD_NAMESPACE}" --timeout=300s
  log_success "Headless Argo CD Core control plane is operational."
}

#######################################
# Setup GCP Workload Identity for a control plane cluster.
# Arguments:
#   Control plane context
#   Is full Argo CD (true/false)
#######################################
setup_workload_identity() {
  local cp_context="$1"
  local is_full="$2"
  local gsa_email="${ARGOCD_GSA_NAME}@${DEFAULT_ENV1_CP_PROJECT_ID}.iam.gserviceaccount.com"

  log_info "Configuring GCP Workload Identity for ${cp_context}..."

  # 1. Create GSA in mq-usecase-1 if not existing
  if ! gcloud iam service-accounts describe "${gsa_email}" --project="${DEFAULT_ENV1_CP_PROJECT_ID}" &>/dev/null; then
    log_info "Creating GSA '${gsa_email}' in project '${DEFAULT_ENV1_CP_PROJECT_ID}'..."
    gcloud iam service-accounts create "${ARGOCD_GSA_NAME}" \
      --project="${DEFAULT_ENV1_CP_PROJECT_ID}" \
      --display-name="Argo CD Cluster Manager Workload Identity"
  fi

  # 2. Grant roles in target managed projects
  local role
  for role in roles/container.developer roles/container.clusterViewer; do
    gcloud projects add-iam-policy-binding "${DEFAULT_ENV1_MANAGED_PROJECT_ID}" \
      --member="serviceAccount:${gsa_email}" \
      --role="${role}" \
      --quiet >/dev/null
  done

  # 3. Bind KSA to GSA
  local ksas=("argocd-application-controller")
  if [[ "${is_full}" == "true" ]]; then
    ksas+=("argocd-server")
  fi

  local ksa
  for ksa in "${ksas[@]}"; do
    gcloud iam service-accounts add-iam-policy-binding "${gsa_email}" \
      --project="${DEFAULT_ENV1_CP_PROJECT_ID}" \
      --role="roles/iam.workloadIdentityUser" \
      --member="serviceAccount:${DEFAULT_ENV1_CP_PROJECT_ID}.svc.id.goog[${ARGOCD_NAMESPACE}/${ksa}]" \
      --quiet >/dev/null

    kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" annotate serviceaccount "${ksa}" \
      "iam.gke.io/gcp-service-account=${gsa_email}" --overwrite >/dev/null
  done

  # 4. Restart controller to activate Workload Identity
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout restart statefulset/argocd-application-controller >/dev/null
  if [[ "${is_full}" == "true" ]]; then
    kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout restart deployment/argocd-server >/dev/null
    kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=180s
  fi
  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" rollout status statefulset/argocd-application-controller --timeout=180s
  log_success "Workload Identity configured on ${cp_context}."
}

#######################################
# Grant cluster-admin RBAC on a managed cluster to the GSA.
# Arguments:
#   Managed cluster context
#######################################
grant_managed_rbac() {
  local managed_context="$1"
  local gsa_email="${ARGOCD_GSA_NAME}@${DEFAULT_ENV1_CP_PROJECT_ID}.iam.gserviceaccount.com"

  log_info "Granting cluster-admin RBAC to GSA on ${managed_context}..."
  kubectl --context="${managed_context}" create clusterrolebinding argocd-workload-identity-admin \
    --clusterrole=cluster-admin \
    --user="${gsa_email}" \
    --dry-run=client -o yaml | kubectl --context="${managed_context}" apply -f - >/dev/null
}

#######################################
# Register a managed cluster into an Argo CD control plane using execProviderConfig.
# Arguments:
#   Control plane context
#   Managed cluster name
#   Managed cluster location
#   Managed cluster project ID
#######################################
register_managed_cluster() {
  local cp_context="$1"
  local cluster_name="$2"
  local location="$3"
  local project_id="$4"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Registering '${cluster_name}' into control plane ${cp_context}..."

  local endpoint ca_cert
  endpoint="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project="${project_id}" --format="value(endpoint)")"
  ca_cert="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project="${project_id}" --format="value(masterAuth.clusterCaCertificate)")"

  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" delete secret "cluster-${cluster_name}" 2>/dev/null || true

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
  log_success "Cluster '${cluster_name}' registered into ${cp_context}."
}

#######################################
# Setup Environment 1 (Full Control Plane + 2 Managed Clusters in VPC1)
#######################################
setup_environment_1() {
  local cp_ctx="gke_${DEFAULT_ENV1_CP_PROJECT_ID}_${DEFAULT_ENV1_CP_LOCATION}_${DEFAULT_ENV1_CP_CLUSTER_NAME}"
  local m1_ctx="gke_${DEFAULT_ENV1_MANAGED_PROJECT_ID}_${DEFAULT_ENV1_MANAGED1_LOCATION}_${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}"
  local m2_ctx="gke_${DEFAULT_ENV1_MANAGED_PROJECT_ID}_${DEFAULT_ENV1_MANAGED2_LOCATION}_${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}  Setting up Environment 1: Full Argo CD Control Plane (VPC1)        ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"

  launch_cluster_creation "${DEFAULT_ENV1_CP_CLUSTER_NAME}" "${DEFAULT_ENV1_CP_LOCATION}" "${DEFAULT_ENV1_CP_SUBNET}" "${DEFAULT_ENV1_CP_VPC}" "${DEFAULT_ENV1_CP_PROJECT_ID}"
  launch_cluster_creation "${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED1_LOCATION}" "${DEFAULT_ENV1_MANAGED1_SUBNET}" "${DEFAULT_ENV1_MANAGED_VPC}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
  launch_cluster_creation "${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED2_LOCATION}" "${DEFAULT_ENV1_MANAGED2_SUBNET}" "${DEFAULT_ENV1_MANAGED_VPC}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"

  wait_for_cluster_running "${DEFAULT_ENV1_CP_CLUSTER_NAME}" "${DEFAULT_ENV1_CP_LOCATION}" "${DEFAULT_ENV1_CP_PROJECT_ID}"
  wait_for_cluster_running "${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED1_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
  wait_for_cluster_running "${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED2_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"

  fetch_cluster_credentials "${DEFAULT_ENV1_CP_CLUSTER_NAME}" "${DEFAULT_ENV1_CP_LOCATION}" "${DEFAULT_ENV1_CP_PROJECT_ID}"
  fetch_cluster_credentials "${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED1_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
  fetch_cluster_credentials "${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED2_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"

  install_argocd_full_control_plane
  setup_workload_identity "${cp_ctx}" "true"

  grant_managed_rbac "${m1_ctx}"
  grant_managed_rbac "${m2_ctx}"

  register_managed_cluster "${cp_ctx}" "${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED1_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
  register_managed_cluster "${cp_ctx}" "${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV1_MANAGED2_LOCATION}" "${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
}

#######################################
# Setup Environment 2 (Headless Argo CD Core Control Plane + 2 Managed Clusters in VPC2)
#######################################
setup_environment_2() {
  local cp_ctx="gke_${DEFAULT_ENV2_CP_PROJECT_ID}_${DEFAULT_ENV2_CP_LOCATION}_${DEFAULT_ENV2_CP_CLUSTER_NAME}"
  local m1_ctx="gke_${DEFAULT_ENV2_MANAGED_PROJECT_ID}_${DEFAULT_ENV2_MANAGED1_LOCATION}_${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}"
  local m2_ctx="gke_${DEFAULT_ENV2_MANAGED_PROJECT_ID}_${DEFAULT_ENV2_MANAGED2_LOCATION}_${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_CYAN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_CYAN}  Setting up Environment 2: Headless Argo CD Core Control Plane (VPC2)${COLOR_NC}"
  echo -e "${COLOR_CYAN}=====================================================================${COLOR_NC}"

  launch_cluster_creation "${DEFAULT_ENV2_CP_CLUSTER_NAME}" "${DEFAULT_ENV2_CP_LOCATION}" "${DEFAULT_ENV2_CP_SUBNET}" "${DEFAULT_ENV2_CP_VPC}" "${DEFAULT_ENV2_CP_PROJECT_ID}"
  launch_cluster_creation "${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED1_LOCATION}" "${DEFAULT_ENV2_MANAGED1_SUBNET}" "${DEFAULT_ENV2_MANAGED_VPC}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
  launch_cluster_creation "${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED2_LOCATION}" "${DEFAULT_ENV2_MANAGED2_SUBNET}" "${DEFAULT_ENV2_MANAGED_VPC}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"

  wait_for_cluster_running "${DEFAULT_ENV2_CP_CLUSTER_NAME}" "${DEFAULT_ENV2_CP_LOCATION}" "${DEFAULT_ENV2_CP_PROJECT_ID}"
  wait_for_cluster_running "${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED1_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
  wait_for_cluster_running "${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED2_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"

  fetch_cluster_credentials "${DEFAULT_ENV2_CP_CLUSTER_NAME}" "${DEFAULT_ENV2_CP_LOCATION}" "${DEFAULT_ENV2_CP_PROJECT_ID}"
  fetch_cluster_credentials "${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED1_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
  fetch_cluster_credentials "${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED2_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"

  install_argocd_core_control_plane
  setup_workload_identity "${cp_ctx}" "false"

  grant_managed_rbac "${m1_ctx}"
  grant_managed_rbac "${m2_ctx}"

  register_managed_cluster "${cp_ctx}" "${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED1_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
  register_managed_cluster "${cp_ctx}" "${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}" "${DEFAULT_ENV2_MANAGED2_LOCATION}" "${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
}

#######################################
# Print final deployment summary.
#######################################
print_summary() {
  local env1_cp_ctx="gke_${DEFAULT_ENV1_CP_PROJECT_ID}_${DEFAULT_ENV1_CP_LOCATION}_${DEFAULT_ENV1_CP_CLUSTER_NAME}"
  local env2_cp_ctx="gke_${DEFAULT_ENV2_CP_PROJECT_ID}_${DEFAULT_ENV2_CP_LOCATION}_${DEFAULT_ENV2_CP_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}                 Multi-Cluster GKE Deployment Summary                ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "full" ]]; then
    local admin_pwd
    admin_pwd="$(kubectl --context="${env1_cp_ctx}" -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "[rotated]")"
    echo -e "${COLOR_BOLD}▶ ENVIRONMENT 1: Full Argo CD Control Plane (VPC1)${COLOR_NC}"
    echo "  Control Plane:  ${DEFAULT_ENV1_CP_CLUSTER_NAME} (${DEFAULT_ENV1_CP_LOCATION}, ${DEFAULT_ENV1_CP_PROJECT_ID}, ${DEFAULT_ENV1_CP_VPC})"
    echo "  Admin Password: ${admin_pwd}"
    echo "  Managed 1:      ${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME} (${DEFAULT_ENV1_MANAGED1_LOCATION}, ${DEFAULT_ENV1_MANAGED_PROJECT_ID}, subnet: ${DEFAULT_ENV1_MANAGED1_SUBNET})"
    echo "  Managed 2:      ${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME} (${DEFAULT_ENV1_MANAGED2_LOCATION}, ${DEFAULT_ENV1_MANAGED_PROJECT_ID}, subnet: ${DEFAULT_ENV1_MANAGED2_SUBNET})"
    echo "  Registered Clusters in Environment 1:"
    argocd cluster list --core --kube-context "${env1_cp_ctx}" 2>/dev/null || true
    echo ""
  fi

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "headless" ]]; then
    echo -e "${COLOR_BOLD}▶ ENVIRONMENT 2: Headless Argo CD Core Control Plane (VPC2)${COLOR_NC}"
    echo "  Headless CP:    ${DEFAULT_ENV2_CP_CLUSTER_NAME} (${DEFAULT_ENV2_CP_LOCATION}, ${DEFAULT_ENV2_CP_PROJECT_ID}, ${DEFAULT_ENV2_CP_VPC})"
    echo "  Installation:   Argo CD Core (no API server / no UI)"
    echo "  Managed 1:      ${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME} (${DEFAULT_ENV2_MANAGED1_LOCATION}, ${DEFAULT_ENV2_MANAGED_PROJECT_ID}, subnet: ${DEFAULT_ENV2_MANAGED1_SUBNET})"
    echo "  Managed 2:      ${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME} (${DEFAULT_ENV2_MANAGED2_LOCATION}, ${DEFAULT_ENV2_MANAGED_PROJECT_ID}, subnet: ${DEFAULT_ENV2_MANAGED2_SUBNET})"
    echo "  Registered Clusters in Environment 2:"
    argocd cluster list --core --kube-context "${env2_cp_ctx}" 2>/dev/null || true
    echo ""
  fi
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

#######################################
# Delete clusters based on selected target.
#######################################
delete_clusters() {
  local clusters_to_delete=()

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "full" ]]; then
    clusters_to_delete+=(
      "${DEFAULT_ENV1_CP_CLUSTER_NAME},${DEFAULT_ENV1_CP_LOCATION},${DEFAULT_ENV1_CP_PROJECT_ID}"
      "${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME},${DEFAULT_ENV1_MANAGED1_LOCATION},${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
      "${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME},${DEFAULT_ENV1_MANAGED2_LOCATION},${DEFAULT_ENV1_MANAGED_PROJECT_ID}"
    )
  fi

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "headless" ]]; then
    clusters_to_delete+=(
      "${DEFAULT_ENV2_CP_CLUSTER_NAME},${DEFAULT_ENV2_CP_LOCATION},${DEFAULT_ENV2_CP_PROJECT_ID}"
      "${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME},${DEFAULT_ENV2_MANAGED1_LOCATION},${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
      "${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME},${DEFAULT_ENV2_MANAGED2_LOCATION},${DEFAULT_ENV2_MANAGED_PROJECT_ID}"
    )
  fi

  local confirm="${AUTO_APPROVE}"
  if [[ "${confirm}" != "true" ]]; then
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} You are about to DELETE the following clusters:"
    for entry in "${clusters_to_delete[@]}"; do
      echo "  - ${entry}"
    done
    echo -n "Are you sure you want to proceed? [y/N]: "
    read -r confirm
  fi

  if [[ ! "${confirm}" =~ ^[Yy]$ && "${confirm}" != "true" ]]; then
    log_info "Cluster deletion cancelled by user."
    return 0
  fi

  for entry in "${clusters_to_delete[@]}"; do
    IFS=',' read -r cname cloc cproj <<< "${entry}"
    if cluster_exists "${cname}" "${cloc}" "${cproj}"; then
      local loc_flag
      loc_flag="$(format_location_flag "${cloc}")"
      log_info "Deleting cluster '${cname}' in ${cloc} (${cproj})..."
      gcloud container clusters delete "${cname}" "${loc_flag}" --project "${cproj}" --quiet --async
    fi
  done

  log_info "Waiting for cluster deletions to complete..."
  while true; do
    local still_exists=false
    for entry in "${clusters_to_delete[@]}"; do
      IFS=',' read -r cname cloc cproj <<< "${entry}"
      if cluster_exists "${cname}" "${cloc}" "${cproj}"; then
        still_exists=true
        break
      fi
    done
    if [[ "${still_exists}" == "false" ]]; then
      break
    fi
    sleep 10
  done

  log_success "Selected GKE clusters deleted successfully."
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

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "full" ]]; then
    setup_environment_1
  fi

  if [[ "${SETUP_TARGET}" == "all" || "${SETUP_TARGET}" == "headless" ]]; then
    setup_environment_2
  fi

  print_summary
}

main "$@"
