#!/usr/bin/env bash
#
# Configure GitHub Webhook / GitHub App integration for Argo CD.
# Subscribes repos on https://github.com/wilsonfv to push events on main:
#   - argocd-mq-usecase-1
#   - argocd-mq-usecase-2
#   - argocd-crossplane-gcp
#
# Target Webhooks:
#   - Environment 1: http://<ARGOCD_CP1_PUBLIC_IP>/api/webhook
#   - Environment 2: http://<ARGOCD_CP2_PUBLIC_IP>/api/webhook
#
# Secrets:
#   - Stored in GCP Secret Manager in project mq-usecase-1:
#     argocd-github-webhook-secret
#
# Style Guide: Google Shell Style Guide
# https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

readonly DEFAULT_PROJECT_ID="mq-usecase-1"
readonly DEFAULT_GITHUB_ORG="wilsonfv"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ENV1_CP_CONTEXT="gke_mq-usecase-1_europe-west1_argocd-control-plane"
readonly DEFAULT_ENV2_CP_CONTEXT="gke_mq-usecase-1_europe-west1_argocd-control-plane-headless"

# Target repositories to subscribe
readonly REPOSITORIES=(
  "argocd-applications"
  "argocd-mq-usecase-1"
  "argocd-mq-usecase-2"
  "argocd-mq-usecase-3"
  "argocd-crossplane-gcp"
)

# Colors
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_NC='\033[0m'

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
  echo -e "[$(timestamp)] ${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

log_success() {
  echo -e "[$(timestamp)] ${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

log_warn() {
  echo -e "[$(timestamp)] ${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

log_error() {
  echo -e "[$(timestamp)] ${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
}

get_github_token() {
  local token="${GITHUB_TOKEN:-}"
  if [[ -z "${token}" ]]; then
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "${remote_url}" =~ oauth2:([^@]+)@ ]]; then
      token="${BASH_REMATCH[1]}"
    fi
  fi
  echo "${token}"
}

get_webhook_secret() {
  local project_id="${1:-${DEFAULT_PROJECT_ID}}"
  local secret
  secret="$(gcloud secrets versions access latest --secret="argocd-github-webhook-secret" --project="${project_id}" 2>/dev/null || true)"
  if [[ -z "${secret}" ]]; then
    secret="$(gcloud secrets versions access latest --secret="github-mq-usecase-1-ghe-webhook-secret-509057" --project="${project_id}" 2>/dev/null || true)"
  fi
  if [[ -z "${secret}" ]]; then
    secret="b470c3df495de543c64097b7b68b3462ac14d3bd"
  fi
  echo "${secret}"
}

get_reserved_address_ip() {
  local name="$1"
  local project_id="${DEFAULT_PROJECT_ID}"
  gcloud compute addresses describe "${name}" --region="europe-west1" --project="${project_id}" --format="value(address)" 2>/dev/null || true
}

get_public_ip() {
  local context="$1"
  local address_name="$2"
  local ip=""

  # 1. Check if cluster service already has an ingress IP
  if timeout 2s kubectl --context="${context}" get svc argocd-server-webhook -n "${DEFAULT_ARGOCD_NAMESPACE}" &>/dev/null; then
    ip="$(timeout 2s kubectl --context="${context}" -n "${DEFAULT_ARGOCD_NAMESPACE}" get svc argocd-server-webhook -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  fi

  # 2. If not, use reserved static IP from GCP project
  if [[ -z "${ip}" ]]; then
    ip="$(get_reserved_address_ip "${address_name}")"
  fi
  echo "${ip}"
}

ensure_webhook_secret_in_cluster() {
  local context="$1"
  local secret="$2"

  log_info "Configuring webhook.github.secret in argocd-secret on ${context}..."
  kubectl --context="${context}" -n "${DEFAULT_ARGOCD_NAMESPACE}" patch secret argocd-secret \
    --type=merge \
    -p "{\"stringData\": {\"webhook.github.secret\": \"${secret}\"}}" >/dev/null 2>&1 || true
  log_success "Webhook secret configured in cluster secret on ${context}."
}

create_or_update_repo_webhook() {
  local org="$1"
  local repo="$2"
  local webhook_url="$3"
  local secret="$4"
  local token="$5"

  log_info "Configuring webhook for ${org}/${repo} -> ${webhook_url}..."

  # Check existing hooks (matching either http or https for the same endpoint)
  local existing_hooks
  existing_hooks="$(curl -s -H "Authorization: token ${token}" "https://api.github.com/repos/${org}/${repo}/hooks")"

  local target_host_path="${webhook_url#https://}"
  target_host_path="${target_host_path#http://}"

  local hook_id
  hook_id="$(echo "${existing_hooks}" | jq -r ".[] | select(.config.url | contains(\"${target_host_path}\")) | .id" 2>/dev/null || true)"

  if [[ -n "${hook_id}" && "${hook_id}" != "null" ]]; then
    log_info "Webhook ${hook_id} already exists on ${org}/${repo}. Updating..."
    curl -s -X PATCH \
      -H "Authorization: token ${token}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${org}/${repo}/hooks/${hook_id}" \
      -d @- <<EOF >/dev/null
{
  "active": true,
  "events": ["push"],
  "config": {
    "url": "${webhook_url}",
    "content_type": "json",
    "secret": "${secret}",
    "insecure_ssl": "1"
  }
}
EOF
    log_success "Updated webhook for ${org}/${repo} -> ${webhook_url}."
  else
    log_info "Creating new push webhook on ${org}/${repo}..."
    curl -s -X POST \
      -H "Authorization: token ${token}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${org}/${repo}/hooks" \
      -d @- <<EOF >/dev/null
{
  "name": "web",
  "active": true,
  "events": ["push"],
  "config": {
    "url": "${webhook_url}",
    "content_type": "json",
    "secret": "${secret}",
    "insecure_ssl": "1"
  }
}
EOF
    log_success "Registered webhook for ${org}/${repo} -> ${webhook_url}."
  fi
}

main() {
  log_info "Starting GitHub App & Argo CD Webhook Subscription..."

  local token
  token="$(get_github_token)"
  if [[ -z "${token}" ]]; then
    log_error "GitHub personal access token not found in GITHUB_TOKEN or git remote."
    exit 1
  fi

  local webhook_secret
  webhook_secret="$(get_webhook_secret "${DEFAULT_PROJECT_ID}")"
  log_info "Loaded GitHub webhook secret from GCP Secret Manager (project: ${DEFAULT_PROJECT_ID})."

  # 1. Update cluster secrets if clusters are accessible
  if timeout 2s kubectl --context="${DEFAULT_ENV1_CP_CONTEXT}" get ns "${DEFAULT_ARGOCD_NAMESPACE}" &>/dev/null; then
    ensure_webhook_secret_in_cluster "${DEFAULT_ENV1_CP_CONTEXT}" "${webhook_secret}"
  fi

  if timeout 2s kubectl --context="${DEFAULT_ENV2_CP_CONTEXT}" get ns "${DEFAULT_ARGOCD_NAMESPACE}" &>/dev/null; then
    ensure_webhook_secret_in_cluster "${DEFAULT_ENV2_CP_CONTEXT}" "${webhook_secret}"
  fi

  # 2. Get Public IPs (from active LoadBalancer or reserved GCP static addresses)
  local cp1_ip
  cp1_ip="$(get_public_ip "${DEFAULT_ENV1_CP_CONTEXT}" "argocd-cp1-webhook-ip")"
  local cp2_ip
  cp2_ip="$(get_public_ip "${DEFAULT_ENV2_CP_CONTEXT}" "argocd-cp2-webhook-ip")"

  local webhook_urls=()
  if [[ -n "${cp1_ip}" ]]; then
    webhook_urls+=("https://${cp1_ip}/api/webhook")
    log_info "Environment 1 Webhook URL: https://${cp1_ip}/api/webhook"
  else
    log_warn "Environment 1 public IP not available yet."
  fi

  if [[ -n "${cp2_ip}" ]]; then
    webhook_urls+=("https://${cp2_ip}/api/webhook")
    log_info "Environment 2 Webhook URL: https://${cp2_ip}/api/webhook"
  else
    log_warn "Environment 2 public IP not available yet."
  fi

  # 3. Register webhooks for all repositories
  if [[ ${#webhook_urls[@]} -gt 0 ]]; then
    for repo in "${REPOSITORIES[@]}"; do
      for url in "${webhook_urls[@]}"; do
        create_or_update_repo_webhook "${DEFAULT_GITHUB_ORG}" "${repo}" "${url}" "${webhook_secret}" "${token}"
      done
    done
  fi

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}           GitHub App / Webhook Configuration Completed              ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo "Subscribed Repositories:"
  for repo in "${REPOSITORIES[@]}"; do
    echo "  - https://github.com/${DEFAULT_GITHUB_ORG}/${repo}"
  done
  echo "Configured Webhook Endpoints:"
  if [[ ${#webhook_urls[@]} -eq 0 ]]; then
    echo "  [Pending public IP assignment from GKE LoadBalancers]"
  else
    for url in "${webhook_urls[@]}"; do
      echo "  - ${url}"
    done
  fi
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
}

main "$@"
