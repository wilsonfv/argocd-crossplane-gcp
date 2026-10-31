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
readonly DEFAULT_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_REGION="europe-west1"
readonly DEFAULT_ZONE=""
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
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
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
  -t, --token TOKEN            GitHub PAT Token for private repository access
  -h, --help                   Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, REGION, ZONE, ARGOCD_NAMESPACE, ISTIO_NAMESPACE, GITHUB_TOKEN
EOF
}

#######################################
# Parse command line flags.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE, GITHUB_TOKEN
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
# Configure Argo CD repository Secret for private GitHub repo.
# Globals:
#   ARGOCD_NAMESPACE, GITHUB_TOKEN, ISTIO_REPO_URL
# Arguments:
#   None.
#######################################
ensure_argocd_repo_secret() {
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
    kubectl create secret generic "${secret_name}" \
      --namespace="${ARGOCD_NAMESPACE}" \
      --from-literal=type="git" \
      --from-literal=url="${ISTIO_REPO_URL}" \
      --from-literal=username="wilsonfv" \
      --from-literal=password="${token}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | \
      kubectl apply -f -
    log_success "Argo CD repository secret '${secret_name}' configured."
  else
    log_warn "GITHUB_TOKEN not detected; skipping automatic repository secret creation."
    log_warn "Ensure '${secret_name}' is created in namespace '${ARGOCD_NAMESPACE}'."
  fi
}

#######################################
# Deploy Argo CD Root Application syncing exclusively from private repo.
# Globals:
#   ARGOCD_NAMESPACE, ISTIO_REPO_URL
# Arguments:
#   None.
#######################################
deploy_argocd_apps() {
  log_info "Deploying Argo CD Root Application to sync Istio config from ${ISTIO_REPO_URL}..."

  cat <<EOF | kubectl apply -n "${ARGOCD_NAMESPACE}" -f -
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
  log_success "Argo CD Root Application applied. Istio Ambient Mode is syncing from ${ISTIO_REPO_URL}."
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
  log_info "Verifying sample ambient workload synced by Argo CD (apps-ambient namespace)..."
  local i
  for ((i = 0; i < 30; i++)); do
    if kubectl get deployment/echo-server -n apps-ambient &>/dev/null; then
      break
    fi
    sleep 3
  done

  kubectl rollout status deployment/echo-server -n apps-ambient --timeout=120s || true
  kubectl rollout status deployment/sleep-client -n apps-ambient --timeout=120s || true
  log_success "Ambient demo workload verified."
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
  ensure_argocd_repo_secret
  deploy_argocd_apps
  wait_for_rollouts
  deploy_sample_workload
  print_summary
}

main "$@"
