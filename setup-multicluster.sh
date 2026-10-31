#!/usr/bin/env bash
#
# Multi-Cluster GKE Setup with Centralized Argo CD Control Plane.
#
# Creates two GKE clusters in VPC with internal subnets:
# 1. First GKE (Argo CD control plane) in subnet 'internal-vpc1-europe-west1-gke'
# 2. Second GKE (managed cluster) in subnet 'internal-vpc1-europe-west1-gke2'
# 3. Installs Argo CD on the first GKE cluster
# 4. Registers the second GKE cluster into the Argo CD control plane
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
readonly DEFAULT_CP_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_CP_LOCATION="europe-west1"
readonly DEFAULT_CP_SUBNET="internal-vpc1-europe-west1-gke"
readonly DEFAULT_MANAGED_CLUSTER_NAME="gke-managed-cluster"
readonly DEFAULT_MANAGED_LOCATION="europe-west1-b"
readonly DEFAULT_MANAGED_SUBNET="internal-vpc1-europe-west1-gke2"
readonly DEFAULT_POD_RANGE="gke-pod"
readonly DEFAULT_SERVICE_RANGE="gke-service"
readonly DEFAULT_MACHINE_TYPE="e2-standard-4"
readonly DEFAULT_NUM_NODES="1"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
VPC_NETWORK="${VPC_NETWORK:-${DEFAULT_VPC}}"
CP_CLUSTER_NAME="${CP_CLUSTER_NAME:-${DEFAULT_CP_CLUSTER_NAME}}"
CP_LOCATION="${CP_LOCATION:-${DEFAULT_CP_LOCATION}}"
CP_SUBNET="${CP_SUBNET:-${DEFAULT_CP_SUBNET}}"
MANAGED_CLUSTER_NAME="${MANAGED_CLUSTER_NAME:-${DEFAULT_MANAGED_CLUSTER_NAME}}"
MANAGED_LOCATION="${MANAGED_LOCATION:-${DEFAULT_MANAGED_LOCATION}}"
MANAGED_SUBNET="${MANAGED_SUBNET:-${DEFAULT_MANAGED_SUBNET}}"
POD_RANGE="${POD_RANGE:-${DEFAULT_POD_RANGE}}"
SERVICE_RANGE="${SERVICE_RANGE:-${DEFAULT_SERVICE_RANGE}}"
MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
NUM_NODES="${NUM_NODES:-${DEFAULT_NUM_NODES}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
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

Sets up a Multi-Cluster GKE environment with Argo CD control plane:
  - Cluster 1 (Control Plane): '${CP_CLUSTER_NAME}' in subnet '${CP_SUBNET}'
  - Cluster 2 (Managed):       '${MANAGED_CLUSTER_NAME}' in subnet '${MANAGED_SUBNET}'
  - Both clusters attach to VPC '${VPC_NETWORK}'

Options:
  -p, --project PROJECT_ID     GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  -r, --region REGION          GCP Region (default: ${REGION})
  -z, --zone ZONE              GCP Zone (optional, overrides region for zonal clusters)
  --network NETWORK            VPC network name (default: auto-detected from project)
  --cp-cluster NAME            Control plane cluster name (default: ${CP_CLUSTER_NAME})
  --cp-subnet SUBNET           Control plane subnet name (default: ${CP_SUBNET})
  --managed-cluster NAME       Managed cluster name (default: ${MANAGED_CLUSTER_NAME})
  --managed-subnet SUBNET      Managed subnet name (default: ${MANAGED_SUBNET})
  -m, --machine-type TYPE      GKE node machine type (default: ${MACHINE_TYPE})
  -n, --num-nodes NUM          Nodes per zone (default: ${NUM_NODES})
  -d, --delete                 Delete both GKE clusters
  -y, --yes                    Auto-approve deletion without interactive prompt
  -h, --help                   Show this help message

Environment Variables:
  PROJECT_ID, REGION, ZONE, VPC_NETWORK, CP_CLUSTER_NAME, MANAGED_CLUSTER_NAME, DELETE_CLUSTERS, AUTO_APPROVE
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
      -r|--region)
        REGION="$2"
        shift 2
        ;;
      -z|--zone)
        ZONE="$2"
        shift 2
        ;;
      --network)
        VPC_NETWORK="$2"
        shift 2
        ;;
      --cp-cluster)
        CP_CLUSTER_NAME="$2"
        shift 2
        ;;
      --cp-subnet)
        CP_SUBNET="$2"
        shift 2
        ;;
      --managed-cluster)
        MANAGED_CLUSTER_NAME="$2"
        shift 2
        ;;
      --managed-subnet)
        MANAGED_SUBNET="$2"
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
        DELETE_CLUSTERS="true"
        shift 1
        ;;
      -y|--yes)
        AUTO_APPROVE="true"
        shift 1
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
# Verify prerequisites and tools.
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

  if [[ -z "${PROJECT_ID}" ]]; then
    log_error "No active GCP project found in 'gcloud config list'. Please provide via -p/--project or run 'gcloud config set project <PROJECT_ID>'."
    return 1
  fi
  log_info "Target GCP Project: ${PROJECT_ID}"
  gcloud config set project "${PROJECT_ID}" >/dev/null
}

#######################################
# Resolve VPC network dynamically if not provided.
#######################################
resolve_network() {
  if [[ -n "${VPC_NETWORK}" ]]; then
    return 0
  fi

  log_info "Resolving VPC Network from GCP project '${PROJECT_ID}'..."
  local detected_vpc
  detected_vpc="$(gcloud compute networks list --project="${PROJECT_ID}" --filter="name ~ internal-vpc1" --format="value(name)" --limit=1 2>/dev/null || true)"
  if [[ -n "${detected_vpc}" ]]; then
    VPC_NETWORK="${detected_vpc}"
    log_info "Discovered VPC Network: ${VPC_NETWORK}"
  else
    VPC_NETWORK="${PROJECT_ID}-internal-vpc1"
    log_info "Defaulting to inferred VPC Network: ${VPC_NETWORK}"
  fi
}

#######################################
# Build location flags (region or zone).
#######################################
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
#   Cluster name.
#   Cluster location.
# Returns:
#   0 if exists, 1 otherwise.
#######################################
cluster_exists() {
  local cluster_name="$1"
  local location="$2"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"
  gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${PROJECT_ID}" &>/dev/null
}

#######################################
# Launch creation of a single GKE cluster asynchronously.
# Arguments:
#   Cluster name
#   Cluster location
#   Subnet name
#######################################
launch_cluster_creation() {
  local cluster_name="$1"
  local location="$2"
  local subnet_name="$3"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  if cluster_exists "${cluster_name}" "${location}"; then
    log_info "Cluster '${cluster_name}' already exists in ${location}. Skipping creation."
    return 0
  fi

  log_info "Initiating creation of cluster '${cluster_name}' in ${location} (subnet '${subnet_name}')..."
  gcloud container clusters create "${cluster_name}" \
    "${loc_flag}" \
    --project "${PROJECT_ID}" \
    --network "${VPC_NETWORK}" \
    --subnetwork "${subnet_name}" \
    --cluster-secondary-range-name "${POD_RANGE}" \
    --services-secondary-range-name "${SERVICE_RANGE}" \
    --enable-ip-alias \
    --num-nodes "${NUM_NODES}" \
    --machine-type "${MACHINE_TYPE}" \
    --release-channel "regular" \
    --async
  log_info "Cluster creation request submitted for '${cluster_name}'."
}

#######################################
# Wait for a cluster to reach RUNNING status.
# Arguments:
#   Cluster name.
#   Cluster location.
#######################################
wait_for_cluster_running() {
  local cluster_name="$1"
  local location="$2"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Waiting for cluster '${cluster_name}' in ${location} to reach RUNNING status..."
  while true; do
    local status
    status="$(gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${PROJECT_ID}" --format="value(status)" 2>/dev/null || echo "PENDING")"
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
#   Cluster name.
#   Cluster location.
#######################################
fetch_cluster_credentials() {
  local cluster_name="$1"
  local location="$2"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  log_info "Fetching kubeconfig credentials for '${cluster_name}' in ${location}..."
  gcloud container clusters get-credentials "${cluster_name}" "${loc_flag}" --project "${PROJECT_ID}"
}

#######################################
# Deploy Argo CD to the control plane cluster.
#######################################
install_argocd_control_plane() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"

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
# Register the managed cluster into the Argo CD control plane.
#######################################
register_managed_cluster() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed_context="gke_${PROJECT_ID}_${MANAGED_LOCATION}_${MANAGED_CLUSTER_NAME}"

  log_info "Registering managed cluster '${MANAGED_CLUSTER_NAME}' into Argo CD..."

  # Set default namespace for control plane context to argocd
  kubectl config set-context "${cp_context}" --namespace="${ARGOCD_NAMESPACE}" >/dev/null
  kubectl config use-context "${cp_context}" >/dev/null

  # Register using argocd CLI direct kube-context mode (--core)
  log_info "Executing 'argocd cluster add' for context: ${managed_context}..."
  argocd cluster add "${managed_context}" \
    --name "${MANAGED_CLUSTER_NAME}" \
    --kube-context "${cp_context}" \
    --core \
    --yes \
    --upsert

  log_success "Managed cluster '${MANAGED_CLUSTER_NAME}' successfully registered into Argo CD."
}

#######################################
# Print final deployment summary.
#######################################
print_summary() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed_context="gke_${PROJECT_ID}_${MANAGED_LOCATION}_${MANAGED_CLUSTER_NAME}"

  kubectl config use-context "${cp_context}" >/dev/null
  local admin_password
  admin_password="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "[password already rotated or not yet generated]")"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}    Multi-Cluster GKE Setup with Argo CD Control Plane Complete      ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}                 ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}VPC Network:${COLOR_NC}                 ${VPC_NETWORK}"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 1 (Control Plane):${COLOR_NC}   ${CP_CLUSTER_NAME}"
  echo -e "  - Location:                ${CP_LOCATION}"
  echo -e "  - Subnet:                  ${CP_SUBNET}"
  echo -e "  - Kube Context:            ${cp_context}"
  echo -e "  - Argo CD Namespace:       ${ARGOCD_NAMESPACE}"
  echo -e "  - Admin Username:          admin"
  echo -e "  - Admin Password:          ${admin_password}"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 2 (Managed):${COLOR_NC}         ${MANAGED_CLUSTER_NAME}"
  echo -e "  - Location:                ${MANAGED_LOCATION}"
  echo -e "  - Subnet:                  ${MANAGED_SUBNET}"
  echo -e "  - Kube Context:            ${managed_context}"
  echo -e "  - Managed By:              ${CP_CLUSTER_NAME} (Argo CD)"
  echo ""
  echo -e "${COLOR_BOLD}Argo CD Managed Clusters:${COLOR_NC}"
  argocd cluster list --core --kube-context "${cp_context}" 2>/dev/null || true
  echo ""
  echo -e "${COLOR_BOLD}Access Argo CD UI:${COLOR_NC}"
  echo "  kubectl config use-context ${cp_context}"
  echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
  echo "  Open: https://localhost:8080"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

#######################################
# Delete both GKE clusters.
#######################################
delete_clusters() {
  local cp_loc_flag
  cp_loc_flag="$(format_location_flag "${CP_LOCATION}")"
  local managed_loc_flag
  managed_loc_flag="$(format_location_flag "${MANAGED_LOCATION}")"

  local confirm="${AUTO_APPROVE}"
  if [[ "${confirm}" != "true" ]]; then
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} You are about to permanently DELETE:"
    echo "  - Control plane cluster: '${CP_CLUSTER_NAME}' in ${CP_LOCATION}"
    echo "  - Managed cluster:       '${MANAGED_CLUSTER_NAME}' in ${MANAGED_LOCATION}"
    echo -n "Are you sure you want to proceed? [y/N]: "
    read -r confirm
  fi

  if [[ ! "${confirm}" =~ ^[Yy]$ && "${confirm}" != "true" ]]; then
    log_info "Cluster deletion cancelled by user."
    return 0
  fi

  if cluster_exists "${CP_CLUSTER_NAME}" "${CP_LOCATION}"; then
    log_info "Deleting control plane cluster '${CP_CLUSTER_NAME}' (${CP_LOCATION})..."
    gcloud container clusters delete "${CP_CLUSTER_NAME}" "${cp_loc_flag}" --project "${PROJECT_ID}" --quiet --async
  fi

  if cluster_exists "${MANAGED_CLUSTER_NAME}" "${MANAGED_LOCATION}"; then
    log_info "Deleting managed cluster '${MANAGED_CLUSTER_NAME}' (${MANAGED_LOCATION})..."
    gcloud container clusters delete "${MANAGED_CLUSTER_NAME}" "${managed_loc_flag}" --project "${PROJECT_ID}" --quiet --async
  fi

  log_info "Waiting for cluster deletions to complete..."
  while cluster_exists "${CP_CLUSTER_NAME}" "${CP_LOCATION}" || cluster_exists "${MANAGED_CLUSTER_NAME}" "${MANAGED_LOCATION}"; do
    sleep 10
  done

  log_success "All GKE clusters deleted successfully."
}

#######################################
# Main execution function.
#######################################
main() {
  parse_flags "$@"
  check_prerequisites
  resolve_network

  if [[ "${DELETE_CLUSTERS}" == "true" ]]; then
    delete_clusters
    return 0
  fi

  log_info "Phase 1: Ensuring GKE clusters exist..."
  launch_cluster_creation "${CP_CLUSTER_NAME}" "${CP_LOCATION}" "${CP_SUBNET}"
  launch_cluster_creation "${MANAGED_CLUSTER_NAME}" "${MANAGED_LOCATION}" "${MANAGED_SUBNET}"

  log_info "Phase 2: Waiting for both clusters to reach RUNNING status..."
  wait_for_cluster_running "${CP_CLUSTER_NAME}" "${CP_LOCATION}"
  wait_for_cluster_running "${MANAGED_CLUSTER_NAME}" "${MANAGED_LOCATION}"

  log_info "Phase 3: Fetching cluster credentials..."
  fetch_cluster_credentials "${CP_CLUSTER_NAME}" "${CP_LOCATION}"
  fetch_cluster_credentials "${MANAGED_CLUSTER_NAME}" "${MANAGED_LOCATION}"

  log_info "Phase 4: Deploying Argo CD to control plane cluster..."
  install_argocd_control_plane

  log_info "Phase 5: Registering managed cluster into Argo CD..."
  register_managed_cluster

  print_summary
}

main "$@"
