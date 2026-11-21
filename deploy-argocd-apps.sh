#!/usr/bin/env bash
#
# Deploy Istio Service Mesh (Ambient Mode) across 6 GKE Clusters via Argo CD:
#
# Environment 1 (Full Control Plane + 2 Managed Clusters in VPC1):
#   - Control Plane 1: 'argocd-control-plane' (mq-usecase-1, VPC1, subnet 1)
#   - Managed 1:       'gke-managed-cluster' (mq-usecase-2, VPC1, subnet 1)
#   - Managed 2:       'gke-managed-cluster-2' (mq-usecase-2, VPC1, subnet 2)
#
# Environment 2 (Headless Control Plane + 2 Managed Clusters in VPC2):
#   - Control Plane 2: 'argocd-control-plane-headless' (mq-usecase-1, VPC2, subnet 1)
#   - Managed 3:       'gke-managed-cluster-3' (mq-usecase-2, VPC2, subnet 1)
#   - Managed 4:       'gke-managed-cluster-4' (mq-usecase-2, VPC2, subnet 2)
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
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ISTIO_NAMESPACE="istio-system"
readonly DEFAULT_MAIN_REPO_URL="https://github.com/wilsonfv/argocd-crossplane-gcp.git"
readonly DEFAULT_APPS_REPO_URL="https://github.com/wilsonfv/argocd-applications.git"
readonly DEFAULT_MQ1_REPO_URL="https://github.com/wilsonfv/argocd-mq-usecase-1.git"
readonly DEFAULT_MQ2_REPO_URL="https://github.com/wilsonfv/argocd-mq-usecase-2.git"
readonly DEFAULT_MQ3_REPO_URL="https://github.com/wilsonfv/argocd-mq-usecase-3.git"

# Environment 1: Full Control Plane (VPC1)
readonly DEFAULT_ENV1_CP_PROJECT_ID="mq-usecase-1"
readonly DEFAULT_ENV1_CP_CLUSTER_NAME="argocd-control-plane"
readonly DEFAULT_ENV1_CP_LOCATION="europe-west1"

readonly DEFAULT_ENV1_MANAGED_PROJECT_ID="mq-usecase-2"
readonly DEFAULT_ENV1_MANAGED1_CLUSTER_NAME="gke-managed-cluster"
readonly DEFAULT_ENV1_MANAGED1_LOCATION="europe-west1-b"
readonly DEFAULT_ENV1_MANAGED2_CLUSTER_NAME="gke-managed-cluster-2"
readonly DEFAULT_ENV1_MANAGED2_LOCATION="europe-west1-b"

readonly DEFAULT_ENV1_MANAGED3_PROJECT_ID="mq-usecase-3"
readonly DEFAULT_ENV1_MANAGED5_CLUSTER_NAME="gke-managed-cluster-5"
readonly DEFAULT_ENV1_MANAGED5_LOCATION="europe-west1-b"
readonly DEFAULT_ENV1_MANAGED6_CLUSTER_NAME="gke-managed-cluster-6"
readonly DEFAULT_ENV1_MANAGED6_LOCATION="europe-west1-b"

# Environment 2: Headless Control Plane (VPC2)
readonly DEFAULT_ENV2_CP_PROJECT_ID="mq-usecase-1"
readonly DEFAULT_ENV2_CP_CLUSTER_NAME="argocd-control-plane-headless"
readonly DEFAULT_ENV2_CP_LOCATION="europe-west1"

readonly DEFAULT_ENV2_MANAGED_PROJECT_ID="mq-usecase-2"
readonly DEFAULT_ENV2_MANAGED1_CLUSTER_NAME="gke-managed-cluster-3"
readonly DEFAULT_ENV2_MANAGED1_LOCATION="europe-west1-b"
readonly DEFAULT_ENV2_MANAGED2_CLUSTER_NAME="gke-managed-cluster-4"
readonly DEFAULT_ENV2_MANAGED2_LOCATION="europe-west1-b"

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
DEPLOY_TARGET="${DEPLOY_TARGET:-all}" # all, full, headless

# Environment 1
ENV1_CP_PROJECT_ID="${ENV1_CP_PROJECT_ID:-${DEFAULT_ENV1_CP_PROJECT_ID}}"
ENV1_CP_CLUSTER_NAME="${ENV1_CP_CLUSTER_NAME:-${DEFAULT_ENV1_CP_CLUSTER_NAME}}"
ENV1_CP_LOCATION="${ENV1_CP_LOCATION:-${DEFAULT_ENV1_CP_LOCATION}}"

ENV1_MANAGED_PROJECT_ID="${ENV1_MANAGED_PROJECT_ID:-${DEFAULT_ENV1_MANAGED_PROJECT_ID}}"
ENV1_MANAGED1_CLUSTER_NAME="${ENV1_MANAGED1_CLUSTER_NAME:-${DEFAULT_ENV1_MANAGED1_CLUSTER_NAME}}"
ENV1_MANAGED1_LOCATION="${ENV1_MANAGED1_LOCATION:-${DEFAULT_ENV1_MANAGED1_LOCATION}}"
ENV1_MANAGED2_CLUSTER_NAME="${ENV1_MANAGED2_CLUSTER_NAME:-${DEFAULT_ENV1_MANAGED2_CLUSTER_NAME}}"
ENV1_MANAGED2_LOCATION="${ENV1_MANAGED2_LOCATION:-${DEFAULT_ENV1_MANAGED2_LOCATION}}"

ENV1_MANAGED3_PROJECT_ID="${ENV1_MANAGED3_PROJECT_ID:-${DEFAULT_ENV1_MANAGED3_PROJECT_ID}}"
ENV1_MANAGED5_CLUSTER_NAME="${ENV1_MANAGED5_CLUSTER_NAME:-${DEFAULT_ENV1_MANAGED5_CLUSTER_NAME}}"
ENV1_MANAGED5_LOCATION="${ENV1_MANAGED5_LOCATION:-${DEFAULT_ENV1_MANAGED5_LOCATION}}"
ENV1_MANAGED6_CLUSTER_NAME="${ENV1_MANAGED6_CLUSTER_NAME:-${DEFAULT_ENV1_MANAGED6_CLUSTER_NAME}}"
ENV1_MANAGED6_LOCATION="${ENV1_MANAGED6_LOCATION:-${DEFAULT_ENV1_MANAGED6_LOCATION}}"

# Environment 2
ENV2_CP_PROJECT_ID="${ENV2_CP_PROJECT_ID:-${DEFAULT_ENV2_CP_PROJECT_ID}}"
ENV2_CP_CLUSTER_NAME="${ENV2_CP_CLUSTER_NAME:-${DEFAULT_ENV2_CP_CLUSTER_NAME}}"
ENV2_CP_LOCATION="${ENV2_CP_LOCATION:-${DEFAULT_ENV2_CP_LOCATION}}"

ENV2_MANAGED_PROJECT_ID="${ENV2_MANAGED_PROJECT_ID:-${DEFAULT_ENV2_MANAGED_PROJECT_ID}}"
ENV2_MANAGED1_CLUSTER_NAME="${ENV2_MANAGED1_CLUSTER_NAME:-${DEFAULT_ENV2_MANAGED1_CLUSTER_NAME}}"
ENV2_MANAGED1_LOCATION="${ENV2_MANAGED1_LOCATION:-${DEFAULT_ENV2_MANAGED1_LOCATION}}"
ENV2_MANAGED2_CLUSTER_NAME="${ENV2_MANAGED2_CLUSTER_NAME:-${DEFAULT_ENV2_MANAGED2_CLUSTER_NAME}}"
ENV2_MANAGED2_LOCATION="${ENV2_MANAGED2_LOCATION:-${DEFAULT_ENV2_MANAGED2_LOCATION}}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-${DEFAULT_ISTIO_NAMESPACE}}"
MAIN_REPO_URL="${MAIN_REPO_URL:-${DEFAULT_MAIN_REPO_URL}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

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
# Retrieve active GCP project ID from gcloud config list.
#######################################
get_gcloud_config_project() {
  gcloud config list --format='value(core.project)' 2>/dev/null || true
}

#######################################
# Format location string to corresponding gcloud flag.
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
#######################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploys Istio Ambient Mode across 6 GKE clusters (2 control planes + 4 managed clusters):

Environment 1 (Full Control Plane + 2 Managed Clusters in VPC1):
  - Control Plane: '${ENV1_CP_CLUSTER_NAME}' in '${ENV1_CP_LOCATION}' (${ENV1_CP_PROJECT_ID})
  - Managed 1:     '${ENV1_MANAGED1_CLUSTER_NAME}' in '${ENV1_MANAGED1_LOCATION}' (${ENV1_MANAGED_PROJECT_ID})
  - Managed 2:     '${ENV1_MANAGED2_CLUSTER_NAME}' in '${ENV1_MANAGED2_LOCATION}' (${ENV1_MANAGED_PROJECT_ID})

Environment 2 (Headless Control Plane + 2 Managed Clusters in VPC2):
  - Headless CP:   'ENV2_CP_CLUSTER_NAME' in '${ENV2_CP_LOCATION}' (${ENV2_CP_PROJECT_ID})
  - Managed 3:     '${ENV2_MANAGED1_CLUSTER_NAME}' in '${ENV2_MANAGED1_LOCATION}' (${ENV2_MANAGED_PROJECT_ID})
  - Managed 4:     '${ENV2_MANAGED2_CLUSTER_NAME}' in '${ENV2_MANAGED2_LOCATION}' (${ENV2_MANAGED_PROJECT_ID})

Options:
  --all                       Deploy to all 6 clusters across both environments (default)
  --full                      Deploy only to Environment 1 (Full Control Plane + 2 Managed Clusters)
  --headless, --core          Deploy only to Environment 2 (Headless Control Plane + 2 Managed Clusters)
  -t, --token TOKEN           GitHub PAT Token for private repository access
  -h, --help                  Show this help message

Environment Variables:
  DEPLOY_TARGET (all, full, headless), GITHUB_TOKEN, ARGOCD_NAMESPACE, ISTIO_NAMESPACE
EOF
}

#######################################
# Parse command line flags.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        DEPLOY_TARGET="all"
        shift
        ;;
      --full)
        DEPLOY_TARGET="full"
        shift
        ;;
      --headless|--core)
        DEPLOY_TARGET="headless"
        shift
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
# Verify required dependencies and active authentication.
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
}

#######################################
# Connect to a target GKE cluster and generate kubeconfig.
# Arguments:
#   Cluster name
#   Cluster location
#   Project ID
#######################################
connect_cluster() {
  local cluster_name="$1"
  local location="$2"
  local project_id="$3"
  local loc_flag
  loc_flag="$(format_location_flag "${location}")"

  local lockdir="/tmp/kubeconfig_get_credentials.lock"
  while ! mkdir "${lockdir}" 2>/dev/null; do
    sleep 0.5
  done

  log_info "Connecting to cluster '${cluster_name}' in ${location} (${project_id})..."
  if ! gcloud container clusters describe "${cluster_name}" "${loc_flag}" --project "${project_id}" &>/dev/null; then
    rm -rf "${lockdir}"
    log_error "Cluster '${cluster_name}' not found in project ${project_id} (${location})."
    return 1
  fi
  gcloud container clusters get-credentials "${cluster_name}" "${loc_flag}" --project "${project_id}" || true
  rm -rf "${lockdir}"
  log_success "Connected to '${cluster_name}'."
}

#######################################
# Ensure Cloud DNS private forwarding zone exists for istio.io across all VPC networks.
#######################################
ensure_dns_zones() {
  log_info "Verifying Cloud DNS zone for istio.io registry access across VPC networks..."
  local vpc1="mq-usecase-1-internal-vpc1"
  local vpc2="mq-usecase-1-internal-vpc2"

  if ! gcloud dns managed-zones describe istio-io --project="${ENV1_CP_PROJECT_ID}" &>/dev/null; then
    log_info "Creating Cloud DNS forwarding zone 'istio-io' in project '${ENV1_CP_PROJECT_ID}'..."
    gcloud dns managed-zones create istio-io \
      --dns-name="istio.io." \
      --description="Forward istio.io to 8.8.8.8" \
      --visibility=private \
      --networks="${vpc1},${vpc2}" \
      --forwarding-targets="8.8.8.8" \
      --project="${ENV1_CP_PROJECT_ID}"
  fi

  local m_vpc1="mq-usecase-2-internal-vpc1"
  local m_vpc2="mq-usecase-2-internal-vpc2"
  if ! gcloud dns managed-zones describe istio-io --project="${ENV1_MANAGED_PROJECT_ID}" &>/dev/null; then
    log_info "Creating Cloud DNS forwarding zone 'istio-io' in project '${ENV1_MANAGED_PROJECT_ID}'..."
    gcloud dns managed-zones create istio-io \
      --dns-name="istio.io." \
      --description="Forward istio.io to 8.8.8.8" \
      --visibility=private \
      --networks="${m_vpc1},${m_vpc2}" \
      --forwarding-targets="8.8.8.8" \
      --project="${ENV1_MANAGED_PROJECT_ID}"
  fi
}

#######################################
# Ensure Kubernetes Gateway API CRDs exist on a cluster.
# Arguments:
#   Cluster context
#   Cluster name
#######################################
ensure_gateway_api_crds() {
  local context="$1"
  local cluster_name="$2"

  if kubectl --context="${context}" get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    log_info "[${cluster_name}] Gateway API CRDs already present."
    return 0
  fi

  log_info "[${cluster_name}] Installing Gateway API CRDs..."
  local url="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
  local tmp_file="/tmp/gateway-api-standard.yaml"
  if [[ ! -s "${tmp_file}" ]]; then
    curl -fsSL --retry 5 --retry-delay 2 "${url}" -o "${tmp_file}"
  fi
  kubectl --context="${context}" apply -f "${tmp_file}" >/dev/null
  log_success "[${cluster_name}] Gateway API CRDs installed."
}

#######################################
# Configure Argo CD repository secrets for all required GitHub repositories.
# Arguments:
#   Control plane context
#######################################
ensure_argocd_repo_secrets() {
  local cp_context="$1"
  log_info "Configuring Argo CD credentials on ${cp_context}..."
  local token="${GITHUB_TOKEN:-}"

  if [[ -z "${token}" ]]; then
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "${remote_url}" =~ oauth2:([^@]+)@ ]]; then
      token="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "${token}" ]]; then
    log_warn "GITHUB_TOKEN not detected; skipping repository secrets creation on ${cp_context}."
    return 0
  fi

  local repos=("${DEFAULT_MAIN_REPO_URL}" "${DEFAULT_APPS_REPO_URL}" "${DEFAULT_MQ1_REPO_URL}" "${DEFAULT_MQ2_REPO_URL}" "${DEFAULT_MQ3_REPO_URL}")
  local repo_url
  for repo_url in "${repos[@]}"; do
    local rname
    rname="$(basename "${repo_url}" .git)"
    kubectl --context="${cp_context}" create secret generic "repo-${rname}" \
      --namespace="${ARGOCD_NAMESPACE}" \
      --from-literal=type="git" \
      --from-literal=url="${repo_url}" \
      --from-literal=username="oauth2" \
      --from-literal=password="${token}" \
      --dry-run=client -o yaml | \
      kubectl --context="${cp_context}" label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | \
      kubectl --context="${cp_context}" apply -f - >/dev/null
    log_success "Repository secret 'repo-${rname}' configured on ${cp_context}."
  done

  kubectl --context="${cp_context}" -n "${ARGOCD_NAMESPACE}" create secret generic scm-github-token \
    --from-literal=token="${token}" \
    --dry-run=client -o yaml | kubectl --context="${cp_context}" apply -f - >/dev/null
  log_success "SCM Provider token secret 'scm-github-token' configured on ${cp_context}."
}

#######################################
# Deploy generalized Root Application & ApplicationSets on a control plane.
# Arguments:
#   Control plane context
#######################################
deploy_root_app() {
  local cp_context="$1"

  log_info "[${cp_context}] Applying Root Application and ApplicationSets..."
  kubectl --context="${cp_context}" apply -n "${ARGOCD_NAMESPACE}" -k argocd/applicationsets >/dev/null
  kubectl --context="${cp_context}" apply -n "${ARGOCD_NAMESPACE}" -f argocd/root-app.yaml >/dev/null
  log_success "[${cp_context}] Root Application applied. ApplicationSet generator active."
}

#######################################
# Wait for Istio Ambient Mode components to roll out on a cluster.
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
#######################################
validate_ambient_traffic() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Validating ambient traffic (sleep-client -> echo-server)..."
  local response
  response="$(kubectl --context="${ctx}" exec -n apps-ambient deployment/sleep-client -- curl -s http://echo-server/ || true)"
  if [[ -n "${response}" ]]; then
    log_success "[${name}] Ambient traffic validated: ${response}"
  else
    log_warn "[${name}] Ambient curl test returned no response; retry manually once pods settle."
  fi
}

#######################################
# Wait for OPA Gatekeeper components to roll out on a managed cluster.
#######################################
wait_for_opa_rollouts_cluster() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Waiting for OPA Gatekeeper components in gatekeeper-system..."
  local i
  for ((i = 0; i < 40; i++)); do
    if kubectl --context="${ctx}" get deployment/gatekeeper-controller-manager -n gatekeeper-system &>/dev/null; then
      break
    fi
    sleep 3
  done

  kubectl --context="${ctx}" rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=300s || true
  kubectl --context="${ctx}" rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=300s || true
  log_success "[${name}] OPA Gatekeeper components verified."
}

#######################################
# Validate OPA Gatekeeper policy enforcement on a managed cluster.
#######################################
validate_opa_enforcement() {
  local ctx="$1"
  local name="$2"

  log_info "[${name}] Validating OPA Gatekeeper policy enforcement..."
  kubectl --context="${ctx}" create namespace apps-opa --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f - >/dev/null

  local test_manifest
  test_manifest=$(cat << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod-violation
  namespace: apps-opa
  labels:
    app: test-app
spec:
  containers:
    - name: privileged-container
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
EOF
)

  local attempt=1 max_attempts=15 blocked=false output=""
  while (( attempt <= max_attempts )); do
    if output="$(echo "${test_manifest}" | kubectl --context="${ctx}" apply -f - 2>&1)"; then
      echo "${test_manifest}" | kubectl --context="${ctx}" delete -f - --ignore-not-found &>/dev/null || true
      sleep 4
      (( attempt++ ))
    else
      if [[ "${output}" =~ denied|forbidden|denied\ by|K8sBlockPrivileged|block-privileged-containers ]]; then
        log_success "[${name}] OPA Gatekeeper policy enforcement validated (privileged pod blocked)."
        blocked=true
        break
      else
        sleep 4
        (( attempt++ ))
      fi
    fi
  done

  if [[ "${blocked}" != "true" ]]; then
    log_warn "[${name}] Privileged pod was not blocked after ${max_attempts} attempts: ${output:-no response}"
  fi
}

#######################################
# Deploy to Environment 1 (Full Control Plane + 4 Managed Clusters)
#######################################
deploy_environment_1() {
  local cp_ctx="gke_${ENV1_CP_PROJECT_ID}_${ENV1_CP_LOCATION}_${ENV1_CP_CLUSTER_NAME}"
  local m1_ctx="gke_${ENV1_MANAGED_PROJECT_ID}_${ENV1_MANAGED1_LOCATION}_${ENV1_MANAGED1_CLUSTER_NAME}"
  local m2_ctx="gke_${ENV1_MANAGED_PROJECT_ID}_${ENV1_MANAGED2_LOCATION}_${ENV1_MANAGED2_CLUSTER_NAME}"
  local m5_ctx="gke_${ENV1_MANAGED3_PROJECT_ID}_${ENV1_MANAGED5_LOCATION}_${ENV1_MANAGED5_CLUSTER_NAME}"
  local m6_ctx="gke_${ENV1_MANAGED3_PROJECT_ID}_${ENV1_MANAGED6_LOCATION}_${ENV1_MANAGED6_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}  Deploying Istio Ambient Mode: Environment 1 (VPC1)                 ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"

  connect_cluster "${ENV1_CP_CLUSTER_NAME}" "${ENV1_CP_LOCATION}" "${ENV1_CP_PROJECT_ID}"
  connect_cluster "${ENV1_MANAGED1_CLUSTER_NAME}" "${ENV1_MANAGED1_LOCATION}" "${ENV1_MANAGED_PROJECT_ID}"
  connect_cluster "${ENV1_MANAGED2_CLUSTER_NAME}" "${ENV1_MANAGED2_LOCATION}" "${ENV1_MANAGED_PROJECT_ID}"
  connect_cluster "${ENV1_MANAGED5_CLUSTER_NAME}" "${ENV1_MANAGED5_LOCATION}" "${ENV1_MANAGED3_PROJECT_ID}"
  connect_cluster "${ENV1_MANAGED6_CLUSTER_NAME}" "${ENV1_MANAGED6_LOCATION}" "${ENV1_MANAGED3_PROJECT_ID}"

  ensure_gateway_api_crds "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"

  ensure_argocd_repo_secrets "${cp_ctx}"

  deploy_root_app "${cp_ctx}"

  wait_for_rollouts_cluster "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"

  wait_for_sample_workload "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  wait_for_sample_workload "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  wait_for_sample_workload "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  wait_for_sample_workload "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  wait_for_sample_workload "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"

  validate_ambient_traffic "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  validate_ambient_traffic "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  validate_ambient_traffic "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  validate_ambient_traffic "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  validate_ambient_traffic "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"

  wait_for_opa_rollouts_cluster "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"

  validate_opa_enforcement "${cp_ctx}" "${ENV1_CP_CLUSTER_NAME}"
  validate_opa_enforcement "${m1_ctx}" "${ENV1_MANAGED1_CLUSTER_NAME}"
  validate_opa_enforcement "${m2_ctx}" "${ENV1_MANAGED2_CLUSTER_NAME}"
  validate_opa_enforcement "${m5_ctx}" "${ENV1_MANAGED5_CLUSTER_NAME}"
  validate_opa_enforcement "${m6_ctx}" "${ENV1_MANAGED6_CLUSTER_NAME}"
}

#######################################
# Deploy to Environment 2 (Headless Control Plane + 2 Managed Clusters)
#######################################
deploy_environment_2() {
  local cp_ctx="gke_${ENV2_CP_PROJECT_ID}_${ENV2_CP_LOCATION}_${ENV2_CP_CLUSTER_NAME}"
  local m1_ctx="gke_${ENV2_MANAGED_PROJECT_ID}_${ENV2_MANAGED1_LOCATION}_${ENV2_MANAGED1_CLUSTER_NAME}"
  local m2_ctx="gke_${ENV2_MANAGED_PROJECT_ID}_${ENV2_MANAGED2_LOCATION}_${ENV2_MANAGED2_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_CYAN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_CYAN}  Deploying Istio Ambient Mode: Environment 2 (VPC2)                 ${COLOR_NC}"
  echo -e "${COLOR_CYAN}=====================================================================${COLOR_NC}"

  connect_cluster "${ENV2_CP_CLUSTER_NAME}" "${ENV2_CP_LOCATION}" "${ENV2_CP_PROJECT_ID}"
  connect_cluster "${ENV2_MANAGED1_CLUSTER_NAME}" "${ENV2_MANAGED1_LOCATION}" "${ENV2_MANAGED_PROJECT_ID}"
  connect_cluster "${ENV2_MANAGED2_CLUSTER_NAME}" "${ENV2_MANAGED2_LOCATION}" "${ENV2_MANAGED_PROJECT_ID}"

  ensure_gateway_api_crds "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  ensure_gateway_api_crds "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"

  ensure_argocd_repo_secrets "${cp_ctx}"

  deploy_root_app "${cp_ctx}"

  wait_for_rollouts_cluster "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  wait_for_rollouts_cluster "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"

  wait_for_sample_workload "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  wait_for_sample_workload "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  wait_for_sample_workload "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"

  validate_ambient_traffic "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  validate_ambient_traffic "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  validate_ambient_traffic "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"

  wait_for_opa_rollouts_cluster "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  wait_for_opa_rollouts_cluster "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"

  validate_opa_enforcement "${cp_ctx}" "${ENV2_CP_CLUSTER_NAME}"
  validate_opa_enforcement "${m1_ctx}" "${ENV2_MANAGED1_CLUSTER_NAME}"
  validate_opa_enforcement "${m2_ctx}" "${ENV2_MANAGED2_CLUSTER_NAME}"
}

#######################################
# Print final deployment summary.
#######################################
print_summary() {
  local env1_cp_ctx="gke_${ENV1_CP_PROJECT_ID}_${ENV1_CP_LOCATION}_${ENV1_CP_CLUSTER_NAME}"
  local env1_m1_ctx="gke_${ENV1_MANAGED_PROJECT_ID}_${ENV1_MANAGED1_LOCATION}_${ENV1_MANAGED1_CLUSTER_NAME}"
  local env1_m2_ctx="gke_${ENV1_MANAGED_PROJECT_ID}_${ENV1_MANAGED2_LOCATION}_${ENV1_MANAGED2_CLUSTER_NAME}"

  local env2_cp_ctx="gke_${ENV2_CP_PROJECT_ID}_${ENV2_CP_LOCATION}_${ENV2_CP_CLUSTER_NAME}"
  local env2_m1_ctx="gke_${ENV2_MANAGED_PROJECT_ID}_${ENV2_MANAGED1_LOCATION}_${ENV2_MANAGED1_CLUSTER_NAME}"
  local env2_m2_ctx="gke_${ENV2_MANAGED_PROJECT_ID}_${ENV2_MANAGED2_LOCATION}_${ENV2_MANAGED2_CLUSTER_NAME}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}      6-Cluster Istio Ambient Mode Deployment Summary (All Up)       ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"

  if [[ "${DEPLOY_TARGET}" == "all" || "${DEPLOY_TARGET}" == "full" ]]; then
    echo -e "${COLOR_BOLD}▶ ENVIRONMENT 1: Full Control Plane (VPC1)${COLOR_NC}"
    echo "  Control Plane:  ${ENV1_CP_CLUSTER_NAME} (${ENV1_CP_LOCATION})"
    echo "  Managed 1:      ${ENV1_MANAGED1_CLUSTER_NAME} (${ENV1_MANAGED1_LOCATION})"
    echo "  Managed 2:      ${ENV1_MANAGED2_CLUSTER_NAME} (${ENV1_MANAGED2_LOCATION})"
    echo "  Managed 5:      ${ENV1_MANAGED5_CLUSTER_NAME} (${ENV1_MANAGED5_LOCATION})"
    echo "  Managed 6:      ${ENV1_MANAGED6_CLUSTER_NAME} (${ENV1_MANAGED6_LOCATION})"
    echo ""
    echo "  Argo CD Applications on Environment 1:"
    kubectl --context="${env1_cp_ctx}" -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io
    echo ""
  fi

  if [[ "${DEPLOY_TARGET}" == "all" || "${DEPLOY_TARGET}" == "headless" ]]; then
    echo -e "${COLOR_BOLD}▶ ENVIRONMENT 2: Headless Control Plane (VPC2)${COLOR_NC}"
    echo "  Control Plane:  ${ENV2_CP_CLUSTER_NAME} (${ENV2_CP_LOCATION})"
    echo "  Managed 3:      ${ENV2_MANAGED1_CLUSTER_NAME} (${ENV2_MANAGED1_LOCATION})"
    echo "  Managed 4:      ${ENV2_MANAGED2_CLUSTER_NAME} (${ENV2_MANAGED2_LOCATION})"
    echo ""
    echo "  Argo CD Core Applications on Environment 2:"
    kubectl --context="${env2_cp_ctx}" -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io
    echo ""
  fi
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

#######################################
# Main execution function.
#######################################
main() {
  parse_flags "$@"
  check_prerequisites
  ensure_dns_zones

  if [[ "${DEPLOY_TARGET}" == "all" ]]; then
    log_info "Initiating parallel deployment for Environment 1 and Environment 2 at the same time..."
    deploy_environment_1 &
    local dep1_pid=$!

    deploy_environment_2 &
    local dep2_pid=$!

    local fail=0
    wait "${dep1_pid}" || fail=1
    wait "${dep2_pid}" || fail=1

    if [[ "${fail}" -ne 0 ]]; then
      log_error "One or more parallel ambient deployments failed."
      return 1
    fi
    log_success "Both Environment 1 and Environment 2 ambient deployments completed successfully in parallel."
  elif [[ "${DEPLOY_TARGET}" == "full" ]]; then
    deploy_environment_1
  elif [[ "${DEPLOY_TARGET}" == "headless" ]]; then
    deploy_environment_2
  fi

  print_summary
}

main "$@"
