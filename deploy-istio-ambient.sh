#!/usr/bin/env bash
#
# Deploy Istio Service Mesh (Ambient Mode) to Multi-Cluster GKE using Argo CD.
# Deploys to both:
# 1. Control Plane Cluster (argocd-control-plane)
# 2. Managed Cluster (gke-managed-cluster)
#
# Style Guide: Google Shell Style Guide
# https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Global Constants and Defaults
# -----------------------------------------------------------------------------
readonly DEFAULT_CP_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_CP_LOCATION="europe-west1"
readonly DEFAULT_MANAGED_CLUSTER_NAME="gke-managed-cluster"
readonly DEFAULT_MANAGED_LOCATION="europe-west1-b"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ISTIO_NAMESPACE="istio-system"
readonly DEFAULT_ISTIO_REPO_URL="https://github.com/wilsonfv/istio-ambient-config.git"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
CP_CLUSTER_NAME="${CP_CLUSTER_NAME:-${DEFAULT_CP_CLUSTER_NAME}}"
CP_LOCATION="${CP_LOCATION:-${DEFAULT_CP_LOCATION}}"
MANAGED_CLUSTER_NAME="${MANAGED_CLUSTER_NAME:-${DEFAULT_MANAGED_CLUSTER_NAME}}"
MANAGED_LOCATION="${MANAGED_LOCATION:-${DEFAULT_MANAGED_LOCATION}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-${DEFAULT_ISTIO_NAMESPACE}}"
ISTIO_REPO_URL="${ISTIO_REPO_URL:-${DEFAULT_ISTIO_REPO_URL}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

#######################################
# Print current timestamp in ISO format.
# Outputs:
#   Formatted timestamp string (YYYY-MM-DD HH:MM:SS).
#######################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

#######################################
# Print an informational message to stdout.
# Arguments:
#   Message string.
#######################################
log_info() {
  echo -e "[$(timestamp)] ${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

#######################################
# Print a success message to stdout.
# Arguments:
#   Message string.
#######################################
log_success() {
  echo -e "[$(timestamp)] ${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

#######################################
# Print a warning message to stderr.
# Arguments:
#   Message string.
#######################################
log_warn() {
  echo -e "[$(timestamp)] ${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

#######################################
# Print an error message to stderr.
# Arguments:
#   Message string.
#######################################
log_error() {
  echo -e "[$(timestamp)] ${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
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
# Format location string to corresponding gcloud flag.
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

Deploys Istio Ambient Mode to Multi-Cluster GKE via Argo CD GitOps manifests:
  - Control Plane Cluster: '${CP_CLUSTER_NAME}' in '${CP_LOCATION}'
  - Managed Cluster:       '${MANAGED_CLUSTER_NAME}' in '${MANAGED_LOCATION}'

Options:
  -p, --project PROJECT_ID          GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  --cp-cluster NAME                 Control plane cluster name (default: ${CP_CLUSTER_NAME})
  --cp-location LOCATION            Control plane cluster location (default: ${CP_LOCATION})
  --managed-cluster NAME            Managed cluster name (default: ${MANAGED_CLUSTER_NAME})
  --managed-location LOCATION       Managed cluster location (default: ${MANAGED_LOCATION})
  -c, --cluster CLUSTER_NAME        Alias for --cp-cluster
  -r, --region REGION               Alias for --cp-location
  -z, --zone ZONE                   Overrides --cp-location for zonal clusters
  -t, --token TOKEN                 GitHub PAT Token for private repository access
  -h, --help                        Show this help message

Environment Variables:
  PROJECT_ID, CP_CLUSTER_NAME, CP_LOCATION, MANAGED_CLUSTER_NAME, MANAGED_LOCATION,
  ARGOCD_NAMESPACE, ISTIO_NAMESPACE, GITHUB_TOKEN
EOF
}

#######################################
# Parse command line flags.
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
      --cp-cluster)
        CP_CLUSTER_NAME="$2"
        shift 2
        ;;
      --cp-location)
        CP_LOCATION="$2"
        shift 2
        ;;
      --managed-cluster)
        MANAGED_CLUSTER_NAME="$2"
        shift 2
        ;;
      --managed-location)
        MANAGED_LOCATION="$2"
        shift 2
        ;;
      -c|--cluster)
        CP_CLUSTER_NAME="$2"
        shift 2
        ;;
      -r|--region)
        CP_LOCATION="$2"
        shift 2
        ;;
      -z|--zone)
        CP_LOCATION="$2"
        shift 2
        ;;
      -t|--token)
        GITHUB_TOKEN="$2"
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
# Connect to both GKE clusters and verify credentials.
# Returns:
#   0 on success, non-zero on failure.
#######################################
connect_clusters() {
  local cp_loc_flag
  cp_loc_flag="$(format_location_flag "${CP_LOCATION}")"
  local managed_loc_flag
  managed_loc_flag="$(format_location_flag "${MANAGED_LOCATION}")"

  log_info "Connecting to Control Plane GKE cluster '${CP_CLUSTER_NAME}' (${CP_LOCATION})..."
  if ! gcloud container clusters describe "${CP_CLUSTER_NAME}" "${cp_loc_flag}" --project "${PROJECT_ID}" &>/dev/null; then
    log_error "Control plane cluster '${CP_CLUSTER_NAME}' not found in project ${PROJECT_ID} (${CP_LOCATION})."
    return 1
  fi
  gcloud container clusters get-credentials "${CP_CLUSTER_NAME}" "${cp_loc_flag}" --project "${PROJECT_ID}"
  log_success "Connected to control plane cluster '${CP_CLUSTER_NAME}'."

  log_info "Connecting to Managed GKE cluster '${MANAGED_CLUSTER_NAME}' (${MANAGED_LOCATION})..."
  if ! gcloud container clusters describe "${MANAGED_CLUSTER_NAME}" "${managed_loc_flag}" --project "${PROJECT_ID}" &>/dev/null; then
    log_error "Managed cluster '${MANAGED_CLUSTER_NAME}' not found in project ${PROJECT_ID} (${MANAGED_LOCATION})."
    return 1
  fi
  gcloud container clusters get-credentials "${MANAGED_CLUSTER_NAME}" "${managed_loc_flag}" --project "${PROJECT_ID}"
  log_success "Connected to managed cluster '${MANAGED_CLUSTER_NAME}'."
}

#######################################
# Ensure Cloud DNS private forwarding zone exists for istio.io.
#######################################
ensure_dns_zone() {
  log_info "Verifying Cloud DNS zone for istio.io registry access..."
  local network
  network="$(gcloud compute networks list --project="${PROJECT_ID}" --format="value(name)" --filter="name ~ internal" --limit=1 2>/dev/null || true)"
  if [[ -z "${network}" ]]; then
    network="$(gcloud compute networks list --project="${PROJECT_ID}" --format="value(name)" --limit=1 2>/dev/null || true)"
  fi
  network="${network:-default}"

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
# Ensure Kubernetes Gateway API CRDs exist on a cluster.
# Arguments:
#   Cluster context
#   Cluster label
#######################################
ensure_gateway_api_crds() {
  local context="$1"
  local cluster_name="$2"

  log_info "[${cluster_name}] Ensuring Kubernetes Gateway API CRDs..."
  kubectl --context="${context}" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml >/dev/null
  log_success "[${cluster_name}] Gateway API CRDs installed."
}

#######################################
# Configure Argo CD repository Secret for private GitHub repo.
#######################################
ensure_argocd_repo_secret() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  log_info "Verifying Argo CD credentials for private repository ${ISTIO_REPO_URL}..."
  local secret_name="repo-istio-ambient-config"
  local token="${GITHUB_TOKEN:-}"

  if [[ -z "${token}" ]]; then
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "${remote_url}" =~ oauth2:([^@]+)@ ]]; then
      token="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -n "${token}" ]]; then
    kubectl --context="${cp_context}" create secret generic "${secret_name}" \
      --namespace="${ARGOCD_NAMESPACE}" \
      --from-literal=type="git" \
      --from-literal=url="${ISTIO_REPO_URL}" \
      --from-literal=username="oauth2" \
      --from-literal=password="${token}" \
      --dry-run=client -o yaml | \
      kubectl --context="${cp_context}" label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | \
      kubectl --context="${cp_context}" apply -f -
    log_success "Argo CD repository secret '${secret_name}' configured."
  else
    log_warn "GITHUB_TOKEN not detected; skipping automatic repository secret creation."
    log_warn "Ensure '${secret_name}' is created in namespace '${ARGOCD_NAMESPACE}'."
  fi
}

#######################################
# Deploy Argo CD Root Applications for both clusters.
#######################################
deploy_argocd_apps() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"

  log_info "Deploying Argo CD Root Application for Control Plane cluster..."
  cat <<EOF | kubectl --context="${cp_context}" apply -n "${ARGOCD_NAMESPACE}" -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-ambient-root
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${ISTIO_REPO_URL}
    targetRevision: HEAD
    path: argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
  log_success "Argo CD Root Application 'istio-ambient-root' applied for Control Plane."

  log_info "Deploying Argo CD Root Application for Managed cluster '${MANAGED_CLUSTER_NAME}'..."
  cat <<EOF | kubectl --context="${cp_context}" apply -n "${ARGOCD_NAMESPACE}" -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-ambient-root-managed
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${ISTIO_REPO_URL}
    targetRevision: HEAD
    path: argocd/apps-managed
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
  log_success "Argo CD Root Application 'istio-ambient-root-managed' applied for Managed cluster."
}

#######################################
# Wait for Istio Ambient Mode components to roll out on a cluster.
# Arguments:
#   Cluster context
#   Cluster name
#######################################
wait_for_rollouts_cluster() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Waiting for Argo CD to sync and roll out Istio components..."
  local i
  for ((i = 0; i < 40; i++)); do
    if kubectl --context="${ctx}" get deployment/istiod -n "${ISTIO_NAMESPACE}" &>/dev/null; then
      break
    fi
    sleep 3
  done

  log_info "[${name}] Waiting for Istiod Control Plane to reconcile..."
  kubectl --context="${ctx}" rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_info "[${name}] Waiting for Istio CNI Node DaemonSet on GKE..."
  kubectl --context="${ctx}" rollout status daemonset/istio-cni-node -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_info "[${name}] Waiting for Istio Ztunnel (Ambient Proxy) DaemonSet..."
  kubectl --context="${ctx}" rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=300s

  log_success "[${name}] All Istio Ambient components are healthy and running."
}

#######################################
# Wait for sample workload to roll out on a cluster.
# Arguments:
#   Cluster context
#   Cluster name
#######################################
wait_for_sample_workload() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Waiting for sample ambient workload in apps-ambient namespace..."
  local i
  for ((i = 0; i < 40; i++)); do
    if kubectl --context="${ctx}" get deployment/echo-server -n apps-ambient &>/dev/null; then
      break
    fi
    sleep 3
  done

  kubectl --context="${ctx}" rollout status deployment/echo-server -n apps-ambient --timeout=120s || true
  kubectl --context="${ctx}" rollout status deployment/sleep-client -n apps-ambient --timeout=120s || true
  kubectl --context="${ctx}" rollout status deployment/namespace-waypoint -n apps-ambient --timeout=120s || true
  log_success "[${name}] Ambient demo workload verified."
}

#######################################
# Test transparent mTLS & L7 ambient traffic on a cluster.
# Arguments:
#   Cluster context
#   Cluster name
#######################################
validate_ambient_traffic() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Validating ambient traffic (sleep-client -> echo-server)..."
  local response
  response="$(kubectl --context="${ctx}" exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/ || true)"
  if [[ -n "${response}" ]]; then
    log_success "[${name}] Ambient traffic validated successfully: ${response}"
  else
    log_warn "[${name}] Ambient curl test returned no response; retry manually once pods settle."
  fi
}

#######################################
# Print final deployment summary.
#######################################
print_summary() {
  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed_context="gke_${PROJECT_ID}_${MANAGED_LOCATION}_${MANAGED_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}   Multi-Cluster Istio Ambient Mode Deployed via Argo CD Complete    ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}                  ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}Istio Namespace:${COLOR_NC}              ${ISTIO_NAMESPACE}"
  echo -e "${COLOR_BOLD}Argo CD Namespace:${COLOR_NC}            ${ARGOCD_NAMESPACE}"
  echo ""
  echo -e "${COLOR_BOLD}Cluster 1 (Control Plane):${COLOR_NC}    ${CP_CLUSTER_NAME} (${CP_LOCATION})"
  echo -e "${COLOR_BOLD}Cluster 2 (Managed):${COLOR_NC}          ${MANAGED_CLUSTER_NAME} (${MANAGED_LOCATION})"
  echo ""
  echo -e "${COLOR_BOLD}Argo CD Applications Status:${COLOR_NC}"
  kubectl --context="${cp_context}" get applications.argoproj.io -n "${ARGOCD_NAMESPACE}"
  echo ""
  echo -e "${COLOR_BOLD}[Cluster 1: ${CP_CLUSTER_NAME}] istio-system Pods:${COLOR_NC}"
  kubectl --context="${cp_context}" get pods -n "${ISTIO_NAMESPACE}" -o wide
  echo ""
  echo -e "${COLOR_BOLD}[Cluster 1: ${CP_CLUSTER_NAME}] apps-ambient Pods:${COLOR_NC}"
  kubectl --context="${cp_context}" get pods -n apps-ambient -o wide
  echo ""
  echo -e "${COLOR_BOLD}[Cluster 2: ${MANAGED_CLUSTER_NAME}] istio-system Pods:${COLOR_NC}"
  kubectl --context="${managed_context}" get pods -n "${ISTIO_NAMESPACE}" -o wide
  echo ""
  echo -e "${COLOR_BOLD}[Cluster 2: ${MANAGED_CLUSTER_NAME}] apps-ambient Pods:${COLOR_NC}"
  kubectl --context="${managed_context}" get pods -n apps-ambient -o wide
  echo ""
  echo -e "${COLOR_BOLD}Validate Ambient Traffic Command:${COLOR_NC}"
  echo "  # Control Plane Cluster:"
  echo "  kubectl --context ${cp_context} exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/"
  echo "  # Managed Cluster:"
  echo "  kubectl --context ${managed_context} exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/"
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
  connect_clusters

  local cp_context="gke_${PROJECT_ID}_${CP_LOCATION}_${CP_CLUSTER_NAME}"
  local managed_context="gke_${PROJECT_ID}_${MANAGED_LOCATION}_${MANAGED_CLUSTER_NAME}"

  ensure_dns_zone

  # Ensure Gateway API CRDs on both clusters
  ensure_gateway_api_crds "${cp_context}" "${CP_CLUSTER_NAME}"
  ensure_gateway_api_crds "${managed_context}" "${MANAGED_CLUSTER_NAME}"

  ensure_argocd_repo_secret
  deploy_argocd_apps

  # Wait for Istio Ambient components
  wait_for_rollouts_cluster "${cp_context}" "${CP_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${managed_context}" "${MANAGED_CLUSTER_NAME}"

  # Wait for sample workloads
  wait_for_sample_workload "${cp_context}" "${CP_CLUSTER_NAME}"
  wait_for_sample_workload "${managed_context}" "${MANAGED_CLUSTER_NAME}"

  # Validate transparent mTLS traffic
  validate_ambient_traffic "${cp_context}" "${CP_CLUSTER_NAME}"
  validate_ambient_traffic "${managed_context}" "${MANAGED_CLUSTER_NAME}"

  print_summary
}

main "$@"
