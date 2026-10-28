#!/usr/bin/env bash
#
# Deploy Istio Service Mesh (Ambient Mode) to GKE using Argo CD.
#
# Style Guide: Google Shell Style Guide
# https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Global Constants and Defaults
# -----------------------------------------------------------------------------
readonly DEFAULT_CLUSTER_NAME="argocd-cluster"
readonly DEFAULT_REGION="europe-west1"
readonly DEFAULT_ZONE=""
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ISTIO_NAMESPACE="istio-system"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GITOPS_DIR="${SCRIPT_DIR}/gitops"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-${DEFAULT_ISTIO_NAMESPACE}}"

#######################################
# Print an informational message to stdout.
# Arguments:
#   Message string.
#######################################
log_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

#######################################
# Print a success message to stdout.
# Arguments:
#   Message string.
#######################################
log_success() {
  echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

#######################################
# Print a warning message to stderr.
# Arguments:
#   Message string.
#######################################
log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

#######################################
# Print an error message to stderr.
# Arguments:
#   Message string.
#######################################
log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
}

#######################################
# Retrieve active GCP project ID from gcloud config list.
# Outputs:
#   Active project ID from gcloud config, or empty string.
#######################################
get_gcloud_config_project() {
  gcloud config list --format='value(core.project)' 2>/dev/null || true
}

#######################################
# Display help and usage instructions.
# Arguments:
#   None.
#######################################
usage() {
  local active_project
  active_project="$(get_gcloud_config_project)"
  local display_project="${PROJECT_ID:-${active_project:-[not set in gcloud config]}}"

  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploys Istio Ambient Mode to GKE via Argo CD GitOps manifests.

Options:
  -p, --project PROJECT_ID     GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  -c, --cluster CLUSTER_NAME   GKE Cluster name (default: ${CLUSTER_NAME})
  -r, --region REGION          GCP Region (default: ${REGION})
  -z, --zone ZONE              GCP Zone (optional, overrides region for zonal clusters)
  -h, --help                   Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, REGION, ZONE, ARGOCD_NAMESPACE, ISTIO_NAMESPACE
EOF
}

#######################################
# Parse command line flags.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE
# Arguments:
#   Command line arguments.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--project)
        PROJECT_ID="$2"
        shift 2
        ;;
      -c|--cluster)
        CLUSTER_NAME="$2"
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
# Resolve GCP Project ID using gcloud config list, env, or flags.
# Globals:
#   PROJECT_ID
# Arguments:
#   None.
# Returns:
#   0 on success, 1 on failure.
#######################################
resolve_project_id() {
  if [[ -z "${PROJECT_ID}" ]]; then
    log_info "Reading project ID from 'gcloud config list'..."
    local config_project
    config_project="$(get_gcloud_config_project)"
    if [[ -n "${config_project}" ]]; then
      PROJECT_ID="${config_project}"
      log_info "Detected project ID from 'gcloud config list': ${PROJECT_ID}"
    else
      log_error "No project ID found in 'gcloud config list', and none specified via -p/--project or PROJECT_ID."
      log_error "Please configure your project with 'gcloud config set project <PROJECT_ID>' or pass --project <PROJECT_ID>."
      return 1
    fi
  else
    log_info "Using specified project ID: ${PROJECT_ID}"
  fi

  log_info "Ensuring active gcloud project is set to: ${PROJECT_ID}"
  gcloud config set project "${PROJECT_ID}" >/dev/null
}

#######################################
# Verify required dependencies and active authentication.
# Arguments:
#   None.
# Returns:
#   0 if all checks pass, 1 otherwise.
#######################################
check_prerequisites() {
  log_info "Verifying required tools..."
  local tool
  for tool in gcloud kubectl; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Missing required CLI tool: ${tool}. Please install it before proceeding."
      return 1
    fi
  done

  local current_account
  current_account="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)"
  if [[ -z "${current_account}" ]]; then
    log_error "No active gcloud account found. Please run 'gcloud auth login'."
    return 1
  fi
  log_info "Active gcloud account: ${current_account}"

  resolve_project_id || return 1
}

#######################################
# Connect to target GKE cluster.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE
# Arguments:
#   None.
# Returns:
#   0 on success, non-zero on failure.
#######################################
connect_cluster() {
  local -a location_flags=()
  local location_desc=""

  if [[ -n "${ZONE}" ]]; then
    location_flags=(--zone="${ZONE}")
    location_desc="zone: ${ZONE}"
  else
    location_flags=(--region="${REGION}")
    location_desc="region: ${REGION}"
  fi

  log_info "Connecting to GKE cluster '${CLUSTER_NAME}' in ${location_desc}..."

  if ! gcloud container clusters describe "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}" &>/dev/null; then
    log_error "Cluster '${CLUSTER_NAME}' not found in project ${PROJECT_ID} (${location_desc})."
    return 1
  fi

  gcloud container clusters get-credentials "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}"
  log_success "Connected to cluster '${CLUSTER_NAME}'."
}

#######################################
# Ensure Cloud DNS private forwarding zone exists for istio.io.
# Arguments:
#   None.
#######################################
ensure_dns_zone() {
  log_info "Verifying Cloud DNS zone for istio.io registry access..."
  local network="${PROJECT_ID}-internal-vpc1"

  if ! gcloud dns managed-zones describe istio-io --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Creating Cloud DNS forwarding zone 'istio-io'..."
    gcloud dns managed-zones create istio-io \
      --dns-name="istio.io." \
      --description="Forward istio.io to 8.8.8.8" \
      --visibility=private \
      --networks="${network}" \
      --forwarding-targets="8.8.8.8" \
      --project="${PROJECT_ID}"
  else
    log_info "Cloud DNS zone 'istio-io' already configured."
  fi
}

#######################################
# Apply GKE baseline configurations (namespaces, policies).
# Arguments:
#   None.
#######################################
apply_gke_baseline() {
  log_info "Applying GKE namespaces, quotas, and baseline configuration..."
  kubectl apply -f "${GITOPS_DIR}/gke/namespaces.yaml"
  kubectl apply -f "${GITOPS_DIR}/gke/resource-quotas.yaml"
  kubectl apply -f "${GITOPS_DIR}/gke/network-policies.yaml"
}

#######################################
# Deploy Argo CD Applications for Istio Ambient Mode.
# Globals:
#   ARGOCD_NAMESPACE, GITOPS_DIR
# Arguments:
#   None.
#######################################
deploy_argocd_apps() {
  log_info "Deploying Istio Ambient Mode via Argo CD Applications..."

  local -a app_files=(
    "${GITOPS_DIR}/argocd-apps/istio-base.yaml"
    "${GITOPS_DIR}/argocd-apps/istio-cni.yaml"
    "${GITOPS_DIR}/argocd-apps/istiod.yaml"
    "${GITOPS_DIR}/argocd-apps/istio-ztunnel.yaml"
  )

  local file
  for file in "${app_files[@]}"; do
    log_info "Applying Argo CD Application: $(basename "${file}")..."
    kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${file}"
  done
}

#######################################
# Wait for Istio Ambient Mode components to be fully rolled out.
# Globals:
#   ISTIO_NAMESPACE
# Arguments:
#   None.
#######################################
wait_for_rollouts() {
  log_info "Waiting for Argo CD to sync and roll out Istio components..."
  local i
  for ((i = 0; i < 30; i++)); do
    if kubectl get deployment/istiod -n "${ISTIO_NAMESPACE}" &>/dev/null; then
      break
    fi
    sleep 3
  done

  log_info "Waiting for Istio CRDs and Control Plane to reconcile..."
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_info "Waiting for Istio CNI Node DaemonSet on GKE..."
  kubectl rollout status daemonset/istio-cni-node -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_info "Waiting for Istio Ztunnel (Ambient Proxy) DaemonSet..."
  kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_success "All Istio Ambient components are healthy and running."
}

#######################################
# Deploy sample workload to validate Ambient mesh.
# Arguments:
#   None.
#######################################
deploy_sample_workload() {
  log_info "Deploying sample workload to validate Ambient Mesh (apps-ambient namespace)..."
  kubectl apply -f "${GITOPS_DIR}/istio/samples/ambient-sample.yaml"
  kubectl rollout status deployment/echo-server -n apps-ambient --timeout=120s
  kubectl rollout status deployment/sleep-client -n apps-ambient --timeout=120s
  log_success "Ambient demo workload deployed."
}

#######################################
# Print final deployment summary.
# Arguments:
#   None.
#######################################
print_summary() {
  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}       Istio Service Mesh (Ambient Mode) Deployed via Argo CD        ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}       ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}       ${CLUSTER_NAME}"
  echo -e "${COLOR_BOLD}Istio Namespace:${COLOR_NC}   ${ISTIO_NAMESPACE}"
  echo -e "${COLOR_BOLD}Argo CD Namespace:${COLOR_NC} ${ARGOCD_NAMESPACE}"
  echo ""
  echo -e "${COLOR_BOLD}Components in istio-system:${COLOR_NC}"
  kubectl get pods -n "${ISTIO_NAMESPACE}" -o wide
  echo ""
  echo -e "${COLOR_BOLD}Ambient Test Workload (apps-ambient):${COLOR_NC}"
  kubectl get pods -n apps-ambient
  echo ""
  echo -e "${COLOR_BOLD}Testing Ambient Traffic (mTLS without sidecars):${COLOR_NC}"
  echo "  Run a curl request from the sleep client inside apps-ambient:"
  echo -e "  ${COLOR_BLUE}kubectl exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server:8080${COLOR_NC}"
  echo ""
  echo -e "${COLOR_BOLD}Argo CD Applications Status:${COLOR_NC}"
  kubectl get applications.argoproj.io -n "${ARGOCD_NAMESPACE}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

#######################################
# Main entry point.
# Arguments:
#   Command line arguments.
#######################################
main() {
  parse_flags "$@"
  check_prerequisites
  connect_cluster
  ensure_dns_zone
  apply_gke_baseline
  deploy_argocd_apps
  wait_for_rollouts
  deploy_sample_workload
  print_summary
}

main "$@"
