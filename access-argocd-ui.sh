#!/usr/bin/env bash
#
# Port-forward and access Argo CD Web UI on the GKE Control Plane cluster.
# Retrieves admin credentials and establishes a secure local port-forward.
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
readonly DEFAULT_LOCATION="europe-west1"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_LOCAL_PORT="8080"

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
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
LOCATION="${LOCATION:-${DEFAULT_LOCATION}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
LOCAL_PORT="${LOCAL_PORT:-${DEFAULT_LOCAL_PORT}}"
OPEN_BROWSER=false

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
# Format location string to gcloud location flag.
#######################################
format_location_flag() {
  local loc="$1"
  if [[ "${loc}" =~ -[a-z]$ ]]; then
    echo "--zone=${loc}"
  else
    echo "--region=${loc}"
  fi
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

Port-forwards the Argo CD Web UI server and displays admin login credentials:
  - Target Cluster: '${CLUSTER_NAME}' in '${LOCATION}'
  - Local URL:      https://localhost:${LOCAL_PORT}
  - Username:       admin

Options:
  -p, --project PROJECT_ID    GCP Project ID (default: ${display_project})
  -c, --cluster NAME          Control plane cluster name (default: ${CLUSTER_NAME})
  -l, --location LOCATION     Cluster location (region or zone, default: ${LOCATION})
  -r, --region REGION         Alias for --location
  -z, --zone ZONE             Alias for --location
  -n, --namespace NAMESPACE   Argo CD namespace (default: ${ARGOCD_NAMESPACE})
      --port PORT             Local port to forward to (default: ${LOCAL_PORT})
  -o, --open                  Automatically open the UI URL in default web browser
  -h, --help                  Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, LOCATION, ARGOCD_NAMESPACE, LOCAL_PORT
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
      -c|--cluster)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      -l|--location|-r|--region|-z|--zone)
        LOCATION="$2"
        shift 2
        ;;
      -n|--namespace)
        ARGOCD_NAMESPACE="$2"
        shift 2
        ;;
      --port)
        LOCAL_PORT="$2"
        shift 2
        ;;
      -o|--open)
        OPEN_BROWSER=true
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
# Validate required tools and active GCP project.
#######################################
check_prerequisites() {
  local tool
  for tool in gcloud kubectl; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Missing required CLI tool: ${tool}. Please install it before proceeding."
      return 1
    fi
  done

  if [[ -z "${PROJECT_ID}" ]]; then
    PROJECT_ID="$(get_gcloud_config_project)"
  fi

  if [[ -z "${PROJECT_ID}" ]]; then
    log_error "No active GCP project found in 'gcloud config list'. Please provide via -p/--project or run 'gcloud config set project <PROJECT_ID>'."
    return 1
  fi
}

#######################################
# Ensure credentials for the target GKE cluster.
#######################################
ensure_cluster_connection() {
  local expected_context="gke_${PROJECT_ID}_${LOCATION}_${CLUSTER_NAME}"
  local loc_flag
  loc_flag="$(format_location_flag "${LOCATION}")"

  if ! kubectl config get-contexts "${expected_context}" &>/dev/null; then
    log_info "Fetching credentials for '${CLUSTER_NAME}' (${LOCATION})..."
    gcloud container clusters get-credentials "${CLUSTER_NAME}" "${loc_flag}" --project "${PROJECT_ID}"
  fi

  kubectl config set-context "${expected_context}" --namespace="${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || true
  kubectl config use-context "${expected_context}" >/dev/null
}

#######################################
# Retrieve Argo CD admin password from initial-admin-secret.
#######################################
get_admin_password() {
  local expected_context="gke_${PROJECT_ID}_${LOCATION}_${CLUSTER_NAME}"
  local raw_pwd
  raw_pwd="$(kubectl --context="${expected_context}" -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || true)"
  if [[ -n "${raw_pwd}" ]]; then
    echo "${raw_pwd}" | base64 -d 2>/dev/null || echo "[unable to base64-decode secret]"
  else
    echo "[password already rotated or secret not found]"
  fi
}

#######################################
# Optionally open the Argo CD UI URL in default web browser.
# Arguments:
#   URL string
#######################################
open_url_in_browser() {
  local url="$1"
  if [[ "${OPEN_BROWSER}" != "true" ]]; then
    return 0
  fi

  log_info "Opening ${url} in your default browser..."
  if command -v open &>/dev/null; then
    open "${url}" >/dev/null 2>&1 &
  elif command -v xdg-open &>/dev/null; then
    xdg-open "${url}" >/dev/null 2>&1 &
  elif command -v sensible-browser &>/dev/null; then
    sensible-browser "${url}" >/dev/null 2>&1 &
  fi
}

#######################################
# Main execution function.
#######################################
main() {
  parse_flags "$@"
  check_prerequisites
  ensure_cluster_connection

  local expected_context="gke_${PROJECT_ID}_${LOCATION}_${CLUSTER_NAME}"
  local admin_password
  admin_password="$(get_admin_password)"
  local ui_url="https://localhost:${LOCAL_PORT}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}                 Argo CD Control Plane Web UI Access                 ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}         ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}         ${CLUSTER_NAME} (${LOCATION})"
  echo -e "${COLOR_BOLD}Kube Context:${COLOR_NC}        ${expected_context}"
  echo -e "${COLOR_BOLD}Namespace:${COLOR_NC}           ${ARGOCD_NAMESPACE}"
  echo ""
  echo -e "${COLOR_BOLD}Web UI URL:${COLOR_NC}          ${COLOR_CYAN}${ui_url}${COLOR_NC}"
  echo -e "${COLOR_BOLD}Username:${COLOR_NC}            ${COLOR_BOLD}admin${COLOR_NC}"
  echo -e "${COLOR_BOLD}Password:${COLOR_NC}            ${COLOR_YELLOW}${admin_password}${COLOR_NC}"
  echo ""
  echo -e "Starting port-forward: ${COLOR_BLUE}svc/argocd-server (443 -> localhost:${LOCAL_PORT})${COLOR_NC}"
  echo -e "${COLOR_YELLOW}[NOTE]${COLOR_NC} Press ${COLOR_BOLD}Ctrl+C${COLOR_NC} at any time to stop port-forwarding."
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo ""

  # Open browser in the background if requested
  open_url_in_browser "${ui_url}"

  # Execute kubectl port-forward
  exec kubectl --context="${expected_context}" port-forward \
    svc/argocd-server -n "${ARGOCD_NAMESPACE}" "${LOCAL_PORT}:443"
}

main "$@"
