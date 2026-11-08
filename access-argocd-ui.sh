#!/usr/bin/env bash
#
# Port-forward and access Argo CD Web UI on the GKE Control Plane cluster.
# Retrieves admin credentials, establishes a secure local port-forward, and provides
# a 1-click auto-login URL that logs into the Web UI directly without prompting for credentials.
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
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
LOCATION="${LOCATION:-${DEFAULT_LOCATION}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
LOCAL_PORT="${LOCAL_PORT:-${DEFAULT_LOCAL_PORT}}"

PF_PID=""
SSL_KEY=""
SSL_CRT=""

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
# Clean up background processes and temporary files on exit.
#######################################
cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SSL_KEY}" && -f "${SSL_KEY}" ]]; then
    rm -f "${SSL_KEY}" 2>/dev/null || true
  fi
  if [[ -n "${SSL_CRT}" && -f "${SSL_CRT}" ]]; then
    rm -f "${SSL_CRT}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

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
# Find an available free TCP port on localhost.
#######################################
find_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
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

Port-forwards the Argo CD Web UI server with 1-click auto-login support:
  - Target Cluster: '${CLUSTER_NAME}' in '${LOCATION}'
  - Local URL:      https://localhost:${LOCAL_PORT}
  - Auto-Login:     Passes username & password in URL to log in directly without prompts

Options:
  -p, --project PROJECT_ID    GCP Project ID (default: ${display_project})
  -c, --cluster NAME          Control plane cluster name (default: ${CLUSTER_NAME})
  -l, --location LOCATION     Cluster location (region or zone, default: ${LOCATION})
  -r, --region REGION         Alias for --location
  -z, --zone ZONE             Alias for --location
  -n, --namespace NAMESPACE   Argo CD namespace (default: ${ARGOCD_NAMESPACE})
      --port PORT             Local port to listen on (default: ${LOCAL_PORT})
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
  for tool in gcloud kubectl python3 openssl nc; do
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
    echo "${raw_pwd}" | base64 -d 2>/dev/null || echo ""
  else
    echo ""
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

  if [[ -z "${admin_password}" ]]; then
    log_warn "Admin password could not be retrieved from secret/argocd-initial-admin-secret."
    admin_password="[already rotated or custom password]"
  fi

  # Allocate an internal port for the raw kubectl port-forward
  local internal_port
  internal_port="$(find_free_port)"

  log_info "Establishing cluster port-forward to Argo CD server..."
  kubectl --context="${expected_context}" port-forward \
    svc/argocd-server -n "${ARGOCD_NAMESPACE}" "${internal_port}:443" >/dev/null 2>&1 &
  PF_PID=$!

  # Wait for the internal port-forward to start accepting connections
  local i=0
  while ! nc -z 127.0.0.1 "${internal_port}" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
    if [[ $i -ge 40 ]]; then
      log_error "Timed out waiting for kubectl port-forward to start."
      return 1
    fi
  done

  # Generate temporary TLS certificate for localhost proxy with SAN
  SSL_KEY="/tmp/argocd-ui-$$.key"
  SSL_CRT="/tmp/argocd-ui-$$.crt"
  openssl req -x509 -newkey rsa:2048 -keyout "${SSL_KEY}" -out "${SSL_CRT}" -days 1 -nodes \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

  local autologin_url="https://localhost:${LOCAL_PORT}/?username=admin&password=${admin_password}"
  local basicauth_url="https://admin:${admin_password}@localhost:${LOCAL_PORT}/"
  local base_url="https://localhost:${LOCAL_PORT}"

  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}         Argo CD Control Plane Web UI — 1-Click Auto-Login           ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}GCP Project:${COLOR_NC}         ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}         ${CLUSTER_NAME} (${LOCATION})"
  echo -e "${COLOR_BOLD}Kube Context:${COLOR_NC}        ${expected_context}"
  echo -e "${COLOR_BOLD}Namespace:${COLOR_NC}           ${ARGOCD_NAMESPACE}"
  echo ""
  echo -e "${COLOR_BOLD}▶ 1-Click Direct Login URL (Click to login without typing credentials):${COLOR_NC}"
  echo -e "  ${COLOR_CYAN}${autologin_url}${COLOR_NC}"
  echo ""
  echo -e "${COLOR_BOLD}▶ Alternative Direct Login URL (Basic Auth format):${COLOR_NC}"
  echo -e "  ${COLOR_MAGENTA}${basicauth_url}${COLOR_NC}"
  echo ""
  echo -e "${COLOR_BOLD}Manual Credentials:${COLOR_NC}"
  echo -e "  Web UI URL:        ${base_url}"
  echo -e "  Username:          ${COLOR_BOLD}admin${COLOR_NC}"
  echo -e "  Password:          ${COLOR_YELLOW}${admin_password}${COLOR_NC}"
  echo ""
  echo -e "${COLOR_YELLOW}[NOTE]${COLOR_NC} Once you click either 1-click URL, you will be logged in"
  echo -e "       instantly without entering a username or password."
  echo -e "       Press ${COLOR_BOLD}Ctrl+C${COLOR_NC} at any time to stop port-forwarding."
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo ""

  # Run auto-login proxy in python3
  python3 -c "
import socket, ssl, threading, urllib.parse, urllib.request, json, select, base64, sys

BACKEND_HOST = '127.0.0.1'
BACKEND_PORT = ${internal_port}
LISTEN_PORT = ${LOCAL_PORT}

ssl_backend = ssl.create_default_context()
ssl_backend.check_hostname = False
ssl_backend.verify_mode = ssl.CERT_NONE

def get_session_token(username, password):
    login_data = json.dumps({'username': username, 'password': password}).encode('utf-8')
    req = urllib.request.Request(
        f'https://{BACKEND_HOST}:{BACKEND_PORT}/api/v1/session',
        data=login_data,
        headers={'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req, context=ssl_backend, timeout=10) as r:
        return json.loads(r.read())['token']

def send_login_redirect(client_sock, token):
    resp = (
        b'HTTP/1.1 302 Found\r\n'
        b'Location: /\r\n'
        b'Set-Cookie: argocd.token=' + token.encode('utf-8') + b'; Path=/; SameSite=Lax; Secure\r\n'
        b'Content-Length: 0\r\n'
        b'Connection: close\r\n\r\n'
    )
    client_sock.sendall(resp)
    try: client_sock.shutdown(socket.SHUT_WR)
    except: pass
    client_sock.close()

def pipe(src, dst):
    try:
        while True:
            buf = src.recv(8192)
            if not buf:
                break
            dst.sendall(buf)
    except:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass
        try: dst.close()
        except: pass
        try: src.close()
        except: pass

def handle_client(client_sock):
    try:
        initial_data = client_sock.recv(4096)
        if not initial_data:
            client_sock.close()
            return

        lines = initial_data.split(b'\r\n')
        first_line = lines[0].decode('utf-8', errors='ignore')
        parts = first_line.split()

        # 1. Check URL query parameters for username and password
        if len(parts) >= 2:
            parsed = urllib.parse.urlparse(parts[1])
            qs = urllib.parse.parse_qs(parsed.query)
            if 'username' in qs and 'password' in qs:
                user = qs['username'][0]
                pwd = qs['password'][0]
                try:
                    token = get_session_token(user, pwd)
                    if token:
                        send_login_redirect(client_sock, token)
                        return
                except Exception as e:
                    pass

        # 2. Check Authorization header for Basic auth credentials
        for line in lines[1:]:
            if line.lower().startswith(b'authorization: basic '):
                try:
                    b64_creds = line.split(b' ', 2)[2].strip().decode('ascii')
                    decoded = base64.b64decode(b64_creds).decode('utf-8')
                    if ':' in decoded:
                        user, pwd = decoded.split(':', 1)
                        token = get_session_token(user, pwd)
                        if token:
                            send_login_redirect(client_sock, token)
                            return
                except Exception as e:
                    pass

        # 3. Transparent proxying for all other requests (APIs, static assets, websockets)
        backend_raw = socket.create_connection((BACKEND_HOST, BACKEND_PORT), timeout=10)
        backend_sock = ssl_backend.wrap_socket(backend_raw)
        backend_sock.sendall(initial_data)

        t1 = threading.Thread(target=pipe, args=(client_sock, backend_sock), daemon=True)
        t2 = threading.Thread(target=pipe, args=(backend_sock, client_sock), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception:
        try: client_sock.close()
        except: pass

server_raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server_raw.bind(('127.0.0.1', LISTEN_PORT))
server_raw.listen(50)

server_ssl = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server_ssl.load_cert_chain('${SSL_CRT}', '${SSL_KEY}')

while True:
    try:
        raw_conn, _ = server_raw.accept()
        ssl_conn = server_ssl.wrap_socket(raw_conn, server_side=True)
        threading.Thread(target=handle_client, args=(ssl_conn,), daemon=True).start()
    except (KeyboardInterrupt, SystemExit):
        break
    except Exception:
        continue
"
}

main "$@"
