#!/usr/bin/env bash
#
# Install Crossplane on a GKE cluster in GCP using Helm.
# Target Project ID is dynamically retrieved from 'gcloud config list'.
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
readonly DEFAULT_NAMESPACE="crossplane-system"
readonly DEFAULT_RELEASE_NAME="crossplane"
readonly HELM_REPO_NAME="crossplane-stable"
readonly HELM_REPO_URL="https://charts.crossplane.io/stable"
readonly HELM_CHART_NAME="crossplane-stable/crossplane"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables initialized with defaults (overridable via env / flags)
PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
NAMESPACE="${NAMESPACE:-${DEFAULT_NAMESPACE}}"
RELEASE_NAME="${RELEASE_NAME:-${DEFAULT_RELEASE_NAME}}"
CROSSPLANE_VERSION="${CROSSPLANE_VERSION:-}"

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

Installs Crossplane on GKE in the active GCP project.

Options:
  -p, --project PROJECT_ID       GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  -c, --cluster CLUSTER_NAME     GKE Cluster name (default: ${CLUSTER_NAME})
  -r, --region REGION            GCP Region (default: ${REGION})
  -z, --zone ZONE                GCP Zone (optional, overrides region for zonal clusters)
  -n, --namespace NAMESPACE      Kubernetes namespace (default: ${NAMESPACE})
  -v, --version VERSION          Crossplane chart version (default: latest stable)
  -h, --help                     Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, REGION, ZONE, NAMESPACE, RELEASE_NAME, CROSSPLANE_VERSION
EOF
}

#######################################
# Parse command line flags.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE, NAMESPACE, CROSSPLANE_VERSION
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
      -n|--namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      -v|--version)
        CROSSPLANE_VERSION="$2"
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
  for tool in gcloud kubectl helm; do
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
# Install or upgrade Crossplane using Helm.
# Globals:
#   NAMESPACE, RELEASE_NAME, CROSSPLANE_VERSION, HELM_REPO_NAME, HELM_REPO_URL, HELM_CHART_NAME
# Arguments:
#   None.
#######################################
install_crossplane() {
  log_info "Configuring Crossplane Helm repository..."
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" --force-update >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local -a helm_args=(
    upgrade --install "${RELEASE_NAME}" "${HELM_CHART_NAME}"
    --namespace "${NAMESPACE}"
    --create-namespace
    --wait
    --timeout 5m
  )

  if [[ -n "${CROSSPLANE_VERSION}" ]]; then
    helm_args+=(--version "${CROSSPLANE_VERSION}")
    log_info "Installing Crossplane version ${CROSSPLANE_VERSION}..."
  else
    log_info "Installing latest stable Crossplane..."
  fi

  helm "${helm_args[@]}"

  log_info "Verifying Crossplane deployments..."
  kubectl rollout status deployment/crossplane -n "${NAMESPACE}" --timeout=120s
  kubectl rollout status deployment/crossplane-rbac-manager -n "${NAMESPACE}" --timeout=120s

  log_success "Crossplane is healthy and running."
}

#######################################
# Display summary of Crossplane installation.
# Arguments:
#   None.
#######################################
print_summary() {
  local location_desc=""
  if [[ -n "${ZONE}" ]]; then
    location_desc="zone: ${ZONE}"
  else
    location_desc="region: ${REGION}"
  fi

  local chart_version
  chart_version="$(helm list -n "${NAMESPACE}" -f "^${RELEASE_NAME}$" -o json | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || echo "installed")"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}             Crossplane Installation Completed Successfully          ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}   ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}   ${CLUSTER_NAME} (${location_desc})"
  echo -e "${COLOR_BOLD}Namespace:${COLOR_NC}     ${NAMESPACE}"
  echo -e "${COLOR_BOLD}Release:${COLOR_NC}       ${RELEASE_NAME}"
  echo -e "${COLOR_BOLD}App Version:${COLOR_NC}   ${chart_version}"
  echo ""
  echo -e "${COLOR_BOLD}Verification Command:${COLOR_NC}"
  echo -e "  ${COLOR_BLUE}kubectl get pods -n ${NAMESPACE}${COLOR_NC}"
  echo ""
  echo -e "${COLOR_BOLD}Next Steps:${COLOR_NC}"
  echo "  Install Crossplane Providers (e.g., GCP Provider) and ProviderConfig:"
  echo "  https://docs.crossplane.io/latest/getting-started/provider-gcp/"
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
  install_crossplane
  print_summary
}

main "$@"
