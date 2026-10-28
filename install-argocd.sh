#!/usr/bin/env bash
#
# Install the latest version of Argo CD on a GKE cluster in GCP.
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
readonly DEFAULT_SUBNET="internal-vpc1-europe-west1-gke"
readonly DEFAULT_POD_RANGE="gke-pod"
readonly DEFAULT_SERVICE_RANGE="gke-service"
readonly DEFAULT_NAMESPACE="argocd"
readonly DEFAULT_EXPOSE_TYPE="ClusterIP"
readonly DEFAULT_AUTOPILOT="false"
readonly DEFAULT_MACHINE_TYPE="e2-standard-4"
readonly DEFAULT_NUM_NODES="1"

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
NETWORK="${NETWORK:-}"
SUBNET="${SUBNET:-${DEFAULT_SUBNET}}"
POD_RANGE="${POD_RANGE:-${DEFAULT_POD_RANGE}}"
SERVICE_RANGE="${SERVICE_RANGE:-${DEFAULT_SERVICE_RANGE}}"
NAMESPACE="${NAMESPACE:-${DEFAULT_NAMESPACE}}"
EXPOSE_TYPE="${EXPOSE_TYPE:-${DEFAULT_EXPOSE_TYPE}}"
AUTOPILOT="${AUTOPILOT:-${DEFAULT_AUTOPILOT}}"
MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
NUM_NODES="${NUM_NODES:-${DEFAULT_NUM_NODES}}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
DELETE_CLUSTER="${DELETE_CLUSTER:-false}"

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

Installs the latest version of Argo CD on GKE, or deletes the GKE cluster.

Options:
  -p, --project PROJECT_ID     GCP Project ID (default: read from 'gcloud config list' -> ${display_project})
  -c, --cluster CLUSTER_NAME   GKE Cluster name (default: ${CLUSTER_NAME})
  -r, --region REGION          GCP Region (default: ${REGION})
  -z, --zone ZONE              GCP Zone (optional, overrides region for zonal clusters)
  -n, --namespace NAMESPACE    Argo CD namespace (default: ${NAMESPACE})
  -e, --expose TYPE            Service type: ClusterIP | LoadBalancer (default: ${EXPOSE_TYPE})
      --autopilot              Create GKE Autopilot cluster if cluster does not exist
  -d, --delete                 Delete the specified GKE cluster
  -y, --yes                    Auto-approve cluster creation or deletion
  -h, --help                   Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, REGION, ZONE, NETWORK, SUBNET, POD_RANGE, SERVICE_RANGE,
  NAMESPACE, EXPOSE_TYPE, AUTOPILOT, MACHINE_TYPE, NUM_NODES, AUTO_APPROVE, DELETE_CLUSTER
EOF
}

#######################################
# Parse command line flags.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE, NAMESPACE, EXPOSE_TYPE, AUTOPILOT, AUTO_APPROVE, DELETE_CLUSTER
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
      -e|--expose)
        EXPOSE_TYPE="$2"
        shift 2
        ;;
      --autopilot)
        AUTOPILOT="true"
        shift
        ;;
      -d|--delete)
        DELETE_CLUSTER="true"
        shift
        ;;
      -y|--yes)
        AUTO_APPROVE="true"
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
# Resolve GCP Project ID using gcloud config list, env, or flags.
# Globals:
#   PROJECT_ID, NETWORK
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

  if [[ -z "${NETWORK}" ]]; then
    local detected_net
    detected_net="$(gcloud compute networks list --project="${PROJECT_ID}" --format="value(name)" --filter="name ~ internal" --limit=1 2>/dev/null || true)"
    if [[ -z "${detected_net}" ]]; then
      detected_net="$(gcloud compute networks list --project="${PROJECT_ID}" --format="value(name)" --limit=1 2>/dev/null || true)"
    fi
    NETWORK="${detected_net:-default}"
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
  for tool in gcloud kubectl curl; do
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
# Connect to existing GKE cluster or prompt to create one.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE, NETWORK, SUBNET,
#   POD_RANGE, SERVICE_RANGE, AUTOPILOT, MACHINE_TYPE, NUM_NODES, AUTO_APPROVE
# Arguments:
#   None.
# Returns:
#   0 on success, non-zero on failure.
#######################################
setup_cluster() {
  local -a location_flags=()
  local location_desc=""

  if [[ -n "${ZONE}" ]]; then
    location_flags=(--zone="${ZONE}")
    location_desc="zone: ${ZONE}"
  else
    location_flags=(--region="${REGION}")
    location_desc="region: ${REGION}"
  fi

  log_info "Checking if GKE cluster '${CLUSTER_NAME}' exists in ${location_desc}..."

  if gcloud container clusters describe "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}" &>/dev/null; then
    log_info "Cluster '${CLUSTER_NAME}' found. Connecting..."
    gcloud container clusters get-credentials "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}"
    return 0
  fi

  log_warn "Cluster '${CLUSTER_NAME}' does not exist in project ${PROJECT_ID}."
  local confirm="${AUTO_APPROVE}"
  if [[ "${confirm}" != "true" ]]; then
    echo -n "Do you want to create a new cluster '${CLUSTER_NAME}'? [y/N]: "
    read -r confirm
  fi

  if [[ ! "${confirm}" =~ ^[Yy]$ && "${confirm}" != "true" ]]; then
    log_error "Cluster creation aborted. Please provide an existing cluster name using -c/--cluster."
    return 1
  fi

  local -a net_flags=()
  if gcloud compute networks describe "${NETWORK}" --project "${PROJECT_ID}" &>/dev/null; then
    log_info "Using VPC network: ${NETWORK}"
    net_flags+=(--network="${NETWORK}")

    local subnet_region="${ZONE%-*}"
    if [[ -z "${subnet_region}" ]]; then
      subnet_region="${REGION}"
    fi

    if gcloud compute networks subnets describe "${SUBNET}" --region="${subnet_region}" --project "${PROJECT_ID}" &>/dev/null; then
      log_info "Using Subnet: ${SUBNET}"
      net_flags+=(--subnetwork="${SUBNET}")

      if [[ -n "${POD_RANGE}" ]]; then
        net_flags+=(--cluster-secondary-range-name="${POD_RANGE}")
      fi
      if [[ -n "${SERVICE_RANGE}" ]]; then
        net_flags+=(--services-secondary-range-name="${SERVICE_RANGE}")
      fi
    fi
  fi

  if [[ "${AUTOPILOT}" == "true" ]]; then
    log_info "Creating GKE Autopilot cluster '${CLUSTER_NAME}'..."
    gcloud container clusters create-auto "${CLUSTER_NAME}" \
      "${location_flags[@]}" \
      --project "${PROJECT_ID}" \
      "${net_flags[@]}"
  else
    log_info "Creating Standard GKE cluster '${CLUSTER_NAME}' (${NUM_NODES} nodes/zone x ${MACHINE_TYPE})..."
    gcloud container clusters create "${CLUSTER_NAME}" \
      "${location_flags[@]}" \
      --project "${PROJECT_ID}" \
      "${net_flags[@]}" \
      --enable-ip-alias \
      --num-nodes "${NUM_NODES}" \
      --machine-type "${MACHINE_TYPE}" \
      --release-channel regular
  fi

  log_info "Obtaining credentials for newly created cluster '${CLUSTER_NAME}'..."
  gcloud container clusters get-credentials "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}"
}

#######################################
# Delete the specified GKE cluster.
# Globals:
#   PROJECT_ID, CLUSTER_NAME, REGION, ZONE, AUTO_APPROVE
# Arguments:
#   None.
# Returns:
#   0 on success, non-zero on failure.
#######################################
delete_cluster() {
  local -a location_flags=()
  local location_desc=""

  if [[ -n "${ZONE}" ]]; then
    location_flags=(--zone="${ZONE}")
    location_desc="zone: ${ZONE}"
  else
    location_flags=(--region="${REGION}")
    location_desc="region: ${REGION}"
  fi

  log_info "Checking if GKE cluster '${CLUSTER_NAME}' exists in ${location_desc}..."

  if ! gcloud container clusters describe "${CLUSTER_NAME}" "${location_flags[@]}" --project "${PROJECT_ID}" &>/dev/null; then
    log_warn "Cluster '${CLUSTER_NAME}' does not exist in project ${PROJECT_ID} (${location_desc}). Nothing to delete."
    return 0
  fi

  local confirm="${AUTO_APPROVE}"
  if [[ "${confirm}" != "true" ]]; then
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} You are about to permanently DELETE cluster '${CLUSTER_NAME}' in project '${PROJECT_ID}' (${location_desc})."
    echo -n "Are you sure you want to proceed? [y/N]: "
    read -r confirm
  fi

  if [[ ! "${confirm}" =~ ^[Yy]$ && "${confirm}" != "true" ]]; then
    log_info "Cluster deletion cancelled by user."
    return 0
  fi

  log_info "Deleting GKE cluster '${CLUSTER_NAME}' (${location_desc})..."
  gcloud container clusters delete "${CLUSTER_NAME}" \
    "${location_flags[@]}" \
    --project "${PROJECT_ID}" \
    --quiet

  log_success "GKE cluster '${CLUSTER_NAME}' successfully deleted."
}

#######################################
# Fetch the latest Argo CD release tag from GitHub.
# Outputs:
#   Release tag (e.g., v3.5.6) or "stable".
#######################################
fetch_latest_argocd_version() {
  local latest_tag
  latest_tag="$(curl -sSL "https://api.github.com/repos/argoproj/argo-cd/releases/latest" 2>/dev/null \
    | grep '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/' || true)"

  if [[ -z "${latest_tag}" ]]; then
    echo "stable"
  else
    echo "${latest_tag}"
  fi
}

#######################################
# Deploy Argo CD manifests to GKE.
# Globals:
#   NAMESPACE
# Arguments:
#   version: Argo CD version tag.
#######################################
deploy_argocd() {
  local version="$1"
  local manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/${version}/manifests/install.yaml"

  log_info "Target Argo CD Version: ${COLOR_BOLD}${version}${COLOR_NC}"
  log_info "Ensuring namespace '${NAMESPACE}' exists..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  log_info "Applying Argo CD manifests from ${manifest_url}..."
  kubectl apply --server-side --force-conflicts -n "${NAMESPACE}" -f "${manifest_url}"

  log_info "Waiting for Argo CD components to be ready..."
  kubectl rollout status deployment/argocd-server -n "${NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-repo-server -n "${NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/argocd-applicationset-controller -n "${NAMESPACE}" --timeout=300s
  log_success "Argo CD deployments are healthy and running."
}

#######################################
# Configure service exposure (LoadBalancer or ClusterIP).
# Globals:
#   NAMESPACE, EXPOSE_TYPE
# Outputs:
#   External IP if LoadBalancer is configured, otherwise empty string.
#######################################
configure_service_exposure() {
  if [[ "${EXPOSE_TYPE}" != "LoadBalancer" ]]; then
    echo ""
    return 0
  fi

  log_info "Patching argocd-server service to type LoadBalancer..."
  kubectl patch svc argocd-server -n "${NAMESPACE}" -p '{"spec": {"type": "LoadBalancer"}}'
  log_info "Waiting for external IP address..."

  local external_ip=""
  local i
  for ((i = 0; i < 30; i++)); do
    external_ip="$(kubectl get svc argocd-server -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${external_ip}" ]]; then
      echo "${external_ip}"
      return 0
    fi
    sleep 5
  done

  log_warn "Timed out waiting for external IP address."
  echo ""
}

#######################################
# Retrieve initial admin password from Kubernetes secret.
# Globals:
#   NAMESPACE
# Outputs:
#   Decoded admin password or empty string.
#######################################
get_initial_admin_password() {
  local password=""
  local i
  for ((i = 0; i < 15; i++)); do
    password="$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "${password}" ]]; then
      echo "${password}"
      return 0
    fi
    sleep 2
  done
  echo ""
}

#######################################
# Display final installation summary and login instructions.
# Arguments:
#   version: Argo CD version.
#   admin_password: Admin initial password.
#   external_ip: External LoadBalancer IP (optional).
#######################################
print_summary() {
  local version="$1"
  local admin_password="$2"
  local external_ip="$3"
  local location_desc=""

  if [[ -n "${ZONE}" ]]; then
    location_desc="zone: ${ZONE}"
  else
    location_desc="region: ${REGION}"
  fi

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}             Argo CD Installation Completed Successfully             ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}   ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}   ${CLUSTER_NAME} (${location_desc})"
  echo -e "${COLOR_BOLD}Namespace:${COLOR_NC}     ${NAMESPACE}"
  echo -e "${COLOR_BOLD}Argo CD Vers:${COLOR_NC}  ${version}"
  echo -e "${COLOR_BOLD}Username:${COLOR_NC}      admin"

  if [[ -n "${admin_password}" ]]; then
    echo -e "${COLOR_BOLD}Password:${COLOR_NC}      ${admin_password}"
  else
    echo -e "${COLOR_YELLOW}Password:${COLOR_NC}      Secret 'argocd-initial-admin-secret' not yet ready."
    echo "               Retrieve later with:"
    echo "               kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
  fi

  echo ""
  echo -e "${COLOR_BOLD}Access Instructions:${COLOR_NC}"
  if [[ "${EXPOSE_TYPE}" == "LoadBalancer" && -n "${external_ip}" ]]; then
    echo -e "  🌐 Web UI: https://${external_ip}"
    echo "  🔑 Login via CLI:"
    echo "     argocd login ${external_ip} --username admin --password \"${admin_password}\" --insecure"
  else
    echo "  🌐 Port-Forward to local machine:"
    echo -e "     ${COLOR_BLUE}kubectl port-forward svc/argocd-server -n ${NAMESPACE} 8080:443${COLOR_NC}"
    echo "     Then navigate to: https://localhost:8080"
    echo ""
    echo "  🔑 Login via CLI with Port-Forward:"
    echo "     argocd login localhost:8080 --username admin --password \"${admin_password}\" --insecure"
  fi
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

  if [[ "${DELETE_CLUSTER}" == "true" ]]; then
    delete_cluster
    return 0
  fi

  setup_cluster

  local argocd_version
  argocd_version="$(fetch_latest_argocd_version)"

  deploy_argocd "${argocd_version}"

  local external_ip=""
  external_ip="$(configure_service_exposure)"

  local admin_password=""
  admin_password="$(get_initial_admin_password)"

  print_summary "${argocd_version}" "${admin_password}" "${external_ip}"
}

main "$@"
