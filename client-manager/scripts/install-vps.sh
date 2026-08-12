#!/usr/bin/env bash
set -Eeuo pipefail

# One-click installer for VLAN Agent V2 client-manager on a fresh VPS/VM.
# Supports both source repositories and private runtime-package repositories.
# Default usage:
#   curl -fsSL https://raw.githubusercontent.com/caotranquochoai/VLAN-agent-V2/main/client-manager/scripts/install-vps.sh | bash
# Optional overrides:
#   INSTALL_DIR=/opt/client-manager PORT=8090 BRANCH=main bash install-vps.sh

REPO_URL="${REPO_URL:-https://github.com/caotranquochoai/VLAN-agent-V2.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/client-manager}"
SERVICE_NAME="${SERVICE_NAME:-lan-proxy-client-manager}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
PORT="${PORT:-8090}"
NODE_MAJOR="${NODE_MAJOR:-22}"
GO_VERSION="${GO_VERSION:-1.25.4}"
PROXY_PORT_RANGE="${PROXY_PORT_RANGE:-14000:20000}"
SKIP_UFW="${SKIP_UFW:-0}"
SKIP_FIREWALL_CMD="${SKIP_FIREWALL_CMD:-0}"
BUILD_ROOT="${BUILD_ROOT:-/tmp/vlan-agent-v2-build}"
RUN_AS_ROOT_ONLY="${RUN_AS_ROOT_ONLY:-1}"
INSTALL_STARTED_AT="$(date --iso-8601=seconds)"

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_BLUE="\033[34m"

log() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

success() {
  printf "%b[OK]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

fail() {
  printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$*" >&2
  exit 1
}

run() {
  log "Chạy: $*"
  "$@"
}

need_root() {
  if [[ "${RUN_AS_ROOT_ONLY}" == "1" && "${EUID}" -ne 0 ]]; then
    fail "Script cần chạy bằng root. Hãy dùng: sudo bash install-vps.sh"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"
    OS_LIKE=""
  fi
}

install_base_packages() {
  log "Cài dependency hệ thống cơ bản"
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get install -y ca-certificates curl wget git unzip tar build-essential iproute2 net-tools
  elif command_exists dnf; then
    run dnf install -y ca-certificates curl wget git unzip tar gcc gcc-c++ make iproute net-tools
  elif command_exists yum; then
    run yum install -y ca-certificates curl wget git unzip tar gcc gcc-c++ make iproute net-tools
  else
    fail "Không tìm thấy apt-get/dnf/yum để cài dependency. Hãy cài thủ công: git curl wget tar unzip gcc make iproute2."
  fi
}

install_nodejs() {
  if command_exists node && command_exists npm; then
    local node_major
    node_major="$(node -v | sed 's/^v//' | cut -d. -f1 || true)"
    if [[ "${node_major:-0}" -ge 18 ]]; then
      success "Node.js đã có: $(node -v)"
      return
    fi
    warn "Node.js hiện tại quá cũ: $(node -v). Sẽ cài Node.js ${NODE_MAJOR}.x"
  fi

  log "Cài Node.js ${NODE_MAJOR}.x"
  if command_exists apt-get; then
    run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
    run apt-get install -y nodejs
  elif command_exists dnf; then
    run bash -c "curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
    run dnf install -y nodejs
  elif command_exists yum; then
    run bash -c "curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
    run yum install -y nodejs
  else
    fail "Không thể tự cài Node.js trên OS này."
  fi

  success "Node.js: $(node -v), npm: $(npm -v)"
}

install_go() {
  if command_exists go; then
    local current_go
    current_go="$(go version | awk '{print $3}' | sed 's/^go//' || true)"
    success "Go đã có: $(go version)"
    return
  fi

  local arch go_arch tarball url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) go_arch="amd64" ;;
    aarch64|arm64) go_arch="arm64" ;;
    *) fail "Kiến trúc CPU chưa hỗ trợ tự cài Go: ${arch}" ;;
  esac

  tarball="go${GO_VERSION}.linux-${go_arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"

  log "Cài Go ${GO_VERSION} từ ${url}"
  run rm -rf /usr/local/go
  run bash -c "curl -fL '${url}' -o '/tmp/${tarball}'"
  run tar -C /usr/local -xzf "/tmp/${tarball}"
  run ln -sf /usr/local/go/bin/go /usr/local/bin/go
  run ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

  success "Go: $(go version)"
}

clone_repo() {
  log "Clone source từ ${REPO_URL} nhánh ${BRANCH}"
  run rm -rf "$BUILD_ROOT"
  run mkdir -p "$BUILD_ROOT"

  if git ls-remote --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1; then
    run git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$BUILD_ROOT/repo"
  else
    warn "Không tìm thấy nhánh ${BRANCH}, clone nhánh mặc định của repository"
    run git clone --depth 1 "$REPO_URL" "$BUILD_ROOT/repo"
  fi
}

find_client_dir() {
  local candidate
  for candidate in "$BUILD_ROOT/repo/client-manager" "$BUILD_ROOT/repo"; do
    if [[ -f "$candidate/proxy-client-manager" && -f "$candidate/bin/bridge_linux" ]]; then
      CLIENT_SRC="$candidate"
      CLIENT_MODE="runtime"
      log "Client runtime package: ${CLIENT_SRC}"
      return
    fi
  done

  if [[ -f "$BUILD_ROOT/repo/client-manager/go.mod" ]]; then
    CLIENT_SRC="$BUILD_ROOT/repo/client-manager"
    CLIENT_MODE="source"
  elif [[ -f "$BUILD_ROOT/repo/go.mod" ]]; then
    CLIENT_SRC="$BUILD_ROOT/repo"
    CLIENT_MODE="source"
  else
    fail "Không tìm thấy runtime package (proxy-client-manager + bin/bridge_linux) hoặc source Go (client-manager/go.mod hoặc go.mod) trong repository."
  fi
  log "Client source: ${CLIENT_SRC}"
}

build_dashboard() {
  if [[ "${CLIENT_MODE:-source}" == "runtime" ]]; then
    if [[ -d "$CLIENT_SRC/web/dist" ]]; then
      success "Dùng dashboard web/dist có sẵn trong runtime package."
    else
      warn "Runtime package không có web/dist. Dashboard có thể không hoạt động."
    fi
    return
  fi

  if [[ ! -d "$CLIENT_SRC/web" || ! -f "$CLIENT_SRC/web/package.json" ]]; then
    warn "Không tìm thấy web/package.json, bỏ qua build dashboard."
    return
  fi

  log "Build dashboard Vite React"
  pushd "$CLIENT_SRC/web" >/dev/null
  if [[ -f package-lock.json ]]; then
    run npm ci
  else
    run npm install
  fi
  run npm run build
  popd >/dev/null
}

build_client_binary() {
  if [[ "${CLIENT_MODE:-source}" == "runtime" ]]; then
    log "Dùng proxy-client-manager binary có sẵn trong runtime package"
    run cp "$CLIENT_SRC/proxy-client-manager" "$BUILD_ROOT/proxy-client-manager"
    run chmod +x "$BUILD_ROOT/proxy-client-manager"
    [[ -x "$BUILD_ROOT/proxy-client-manager" ]] || fail "proxy-client-manager trong runtime package không chạy được."
    return
  fi

  log "Build proxy-client-manager Linux binary"
  pushd "$CLIENT_SRC" >/dev/null
  run go mod download
  run env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "$BUILD_ROOT/proxy-client-manager" ./cmd/proxy-client-manager
  popd >/dev/null

  [[ -x "$BUILD_ROOT/proxy-client-manager" ]] || fail "Build proxy-client-manager thất bại."
}

prepare_bridge_binary() {
  log "Chuẩn bị bridge_linux"
  mkdir -p "$BUILD_ROOT/bin"

  if [[ -f "$CLIENT_SRC/bin/bridge_linux" ]]; then
    cp "$CLIENT_SRC/bin/bridge_linux" "$BUILD_ROOT/bin/bridge_linux"
  elif [[ -f "$BUILD_ROOT/repo/bridge/bridge_linux" ]]; then
    cp "$BUILD_ROOT/repo/bridge/bridge_linux" "$BUILD_ROOT/bin/bridge_linux"
  elif [[ -d "$BUILD_ROOT/repo/bridge" && -f "$BUILD_ROOT/repo/bridge/go.mod" ]]; then
    warn "Không thấy bridge_linux có sẵn, sẽ build từ source bridge."
    pushd "$BUILD_ROOT/repo/bridge" >/dev/null
    run go mod download
    run env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "$BUILD_ROOT/bin/bridge_linux" ./cmd/bridge
    popd >/dev/null
  else
    fail "Không tìm thấy bin/bridge_linux hoặc source bridge để build. Hãy đưa bridge_linux vào repository."
  fi

  chmod +x "$BUILD_ROOT/bin/bridge_linux"
  success "Đã chuẩn bị bridge_linux"
}

process_pids_for_executable() {
  local expected_path="$1"
  local proc exe pid
  expected_path="$(readlink -f "$expected_path" 2>/dev/null || printf '%s' "$expected_path")"
  for proc in /proc/[0-9]*; do
    [[ -e "$proc/exe" ]] || continue
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    [[ "$exe" == "$expected_path" ]] || continue
    pid="${proc#/proc/}"
    printf '%s\n' "$pid"
  done
}

stop_executable_processes() {
  local executable="$1"
  local label="$2"
  local pids remaining attempt
  pids="$(process_pids_for_executable "$executable")"
  [[ -n "$pids" ]] || return 0

  warn "Dừng ${label} còn chạy: $(printf '%s' "$pids" | tr '\n' ' ')"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"

  for attempt in 1 2 3 4 5; do
    remaining="$(process_pids_for_executable "$executable")"
    [[ -z "$remaining" ]] && return 0
    sleep 1
  done

  warn "${label} không thoát sau SIGTERM; buộc dừng: $(printf '%s' "$remaining" | tr '\n' ' ')"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  done <<< "$remaining"

  sleep 1
  remaining="$(process_pids_for_executable "$executable")"
  [[ -z "$remaining" ]] || fail "Không thể dừng ${label}, PID còn lại: $(printf '%s' "$remaining" | tr '\n' ' ')"
}

stop_existing_service() {
  if command_exists systemctl; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
      warn "Dừng service cũ ${SERVICE_NAME}"
      if ! systemctl stop "$SERVICE_NAME"; then
        warn "systemctl stop ${SERVICE_NAME} thất bại; sẽ dừng theo executable path"
      fi
    fi
  fi

  # Also handle a differently named service or a manually started process.
  # Match /proc/<pid>/exe exactly to avoid killing unrelated commands.
  stop_executable_processes "$INSTALL_DIR/proxy-client-manager" "Client Manager"
  stop_executable_processes "$INSTALL_DIR/bin/bridge_linux" "Bridge"
}

install_files() {
  log "Cài runtime vào ${INSTALL_DIR}"
  run mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/data"

  if [[ -f "$INSTALL_DIR/data/client.db" ]]; then
    local backup_path
    backup_path="$INSTALL_DIR/data/client.db.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    run cp -p "$INSTALL_DIR/data/client.db" "$backup_path"
    run chmod 600 "$backup_path"
    success "Đã backup SQLite: ${backup_path}"
  fi

  if [[ -d "$INSTALL_DIR/web/dist" ]]; then
    run rm -rf "$INSTALL_DIR/web/dist"
  fi
  run mkdir -p "$INSTALL_DIR/web"

  # Never overwrite a running executable in place: Linux may return ETXTBSY
  # ("Text file busy") when the service name differs or an old binary was
  # started manually. Copy to the same filesystem, then atomically rename it.
  run cp "$BUILD_ROOT/proxy-client-manager" "$INSTALL_DIR/.proxy-client-manager.new"
  run chmod 700 "$INSTALL_DIR/.proxy-client-manager.new"
  run mv -f "$INSTALL_DIR/.proxy-client-manager.new" "$INSTALL_DIR/proxy-client-manager"

  run cp "$BUILD_ROOT/bin/bridge_linux" "$INSTALL_DIR/bin/.bridge_linux.new"
  run chmod 700 "$INSTALL_DIR/bin/.bridge_linux.new"
  run mv -f "$INSTALL_DIR/bin/.bridge_linux.new" "$INSTALL_DIR/bin/bridge_linux"

  if [[ -d "$CLIENT_SRC/web/dist" ]]; then
    run cp -a "$CLIENT_SRC/web/dist" "$INSTALL_DIR/web/dist"
  else
    warn "Không có web/dist để copy. Dashboard có thể không hoạt động."
  fi

  if [[ -f "$CLIENT_SRC/README.md" ]]; then
    run cp "$CLIENT_SRC/README.md" "$INSTALL_DIR/README.md"
  fi

  run chown -R root:root "$INSTALL_DIR"
  run chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/data" "$INSTALL_DIR/web"
  run chmod 700 "$INSTALL_DIR/proxy-client-manager" "$INSTALL_DIR/bin/bridge_linux"
  find "$INSTALL_DIR/data" -maxdepth 1 -type f -exec chmod 600 {} +
}

create_systemd_service() {
  if ! command_exists systemctl; then
    warn "Không có systemctl, bỏ qua tạo service. Bạn có thể chạy thủ công: ${INSTALL_DIR}/proxy-client-manager serve --host ${LISTEN_HOST} --port ${PORT}"
    return
  fi

  log "Tạo systemd service ${SERVICE_NAME}"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF_SERVICE
[Unit]
Description=VLAN Agent V2 Client Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
Environment=CLIENT_MANAGER_ROOT=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/proxy-client-manager --root ${INSTALL_DIR} serve --host ${LISTEN_HOST} --port ${PORT}
Restart=always
RestartSec=3
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectClock=true
ProtectKernelLogs=true
ProtectControlGroups=true
ReadWritePaths=${INSTALL_DIR}/data

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  run systemctl daemon-reload
  run systemctl enable "$SERVICE_NAME"
  run systemctl restart "$SERVICE_NAME"
}

configure_firewall() {
  log "Cấu hình firewall nếu có"

  if [[ "$SKIP_UFW" != "1" ]] && command_exists ufw; then
    ufw allow "${PORT}/tcp" || true
    if [[ -n "$PROXY_PORT_RANGE" ]]; then
      ufw allow "${PROXY_PORT_RANGE}/tcp" || true
      ufw allow "${PROXY_PORT_RANGE}/udp" || true
    fi
    success "Đã thêm rule ufw cho dashboard và dải proxy."
    return
  fi

  if [[ "$SKIP_FIREWALL_CMD" != "1" ]] && command_exists firewall-cmd; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    if [[ -n "$PROXY_PORT_RANGE" ]]; then
      local fw_range
      fw_range="${PROXY_PORT_RANGE/:/-}"
      firewall-cmd --permanent --add-port="${fw_range}/tcp" || true
      firewall-cmd --permanent --add-port="${fw_range}/udp" || true
    fi
    firewall-cmd --reload || true
    success "Đã thêm rule firewalld cho dashboard và dải proxy."
    return
  fi

  warn "Không tìm thấy ufw/firewalld hoặc đã skip. Hãy tự mở port ${PORT}/tcp và dải ${PROXY_PORT_RANGE}."
}

check_ipv6() {
  log "Kiểm tra IPv6 public sơ bộ"
  if curl -6 -fsS --max-time 8 https://ifconfig.me >/tmp/vlan-agent-ipv6.txt 2>/dev/null; then
    success "IPv6 public: $(cat /tmp/vlan-agent-ipv6.txt)"
  else
    warn "Chưa xác nhận được IPv6 public bằng curl -6. Hãy kiểm tra IPv6/route của VPS trước khi tạo proxy."
  fi
}

read_generated_admin_token() {
  local token_line token attempt
  if ! command_exists journalctl || ! command_exists systemctl; then
    return 1
  fi

  for attempt in {1..20}; do
    token_line="$(journalctl -u "$SERVICE_NAME" --since "$INSTALL_STARTED_AT" --no-pager -o cat 2>/dev/null \
      | grep -F 'Admin token generated. Save it now:' \
      | tail -n 1 || true)"
    token="${token_line#*Admin token generated. Save it now: }"
    token="$(printf '%s' "$token" | tr -d '\r\n')"
    if [[ -n "$token" && "$token" != "$token_line" ]]; then
      printf '%s' "$token"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

print_summary() {
  local public_ip dashboard_url service_status admin_token
  public_ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' || echo 'SERVER_IP')"
  dashboard_url="http://${public_ip}:${PORT}"
  admin_token="$(read_generated_admin_token || true)"

  if command_exists systemctl; then
    service_status="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  else
    service_status="manual"
  fi

  cat <<EOF_SUMMARY

============================================================
Cài đặt VLAN Agent V2 client-manager hoàn tất
============================================================
Install dir : ${INSTALL_DIR}
Service     : ${SERVICE_NAME} (${service_status})
Dashboard   : ${dashboard_url}
Listen      : ${LISTEN_HOST}:${PORT}
Proxy ports : ${PROXY_PORT_RANGE}
EOF_SUMMARY

  if [[ -n "$admin_token" ]]; then
    printf '\n%b============================================================%b\n' "$COLOR_GREEN" "$COLOR_RESET"
    printf '%bADMIN TOKEN: %s%b\n' "$COLOR_GREEN" "$admin_token" "$COLOR_RESET"
    printf '%bHãy lưu token này ngay. Token chỉ được in khi tạo lần đầu.%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
    printf '%b============================================================%b\n' "$COLOR_GREEN" "$COLOR_RESET"
  else
    cat <<EOF_TOKEN_HELP

Admin token không được tạo trong lần chạy này.
- Nếu đây là bản cập nhật, hãy tiếp tục dùng token hiện tại.
- Nếu mất token, đặt token mới trên VPS bằng lệnh:
  ${INSTALL_DIR}/proxy-client-manager --root ${INSTALL_DIR} admin-token reset
EOF_TOKEN_HELP
  fi

  cat <<EOF_SUMMARY

Bước tiếp theo:
1. Lưu admin token được in ở trên.
2. Mở dashboard: ${dashboard_url}
3. Nhập admin token tại bảng "Đăng nhập bằng admin token".
4. Vào tab License và kích hoạt LAN Agent key.
5. Vào tab Kiểm tra để xác nhận IPv6/bridge/quyền hệ thống.
6. Tạo proxy thử, sau đó Start Bridge.

Lệnh quản trị nhanh:
- Xem log service: journalctl -u ${SERVICE_NAME} -f
- Restart service: systemctl restart ${SERVICE_NAME}
- Stop service   : systemctl stop ${SERVICE_NAME}

Nếu không truy cập được dashboard, hãy kiểm tra firewall/security group port ${PORT}/tcp.
============================================================
EOF_SUMMARY
}

main() {
  need_root
  detect_os
  log "OS: ${OS_ID} ${OS_LIKE}"
  log "Repository: ${REPO_URL}"
  log "Install dir: ${INSTALL_DIR}"

  install_base_packages
  clone_repo
  find_client_dir
  if [[ "${CLIENT_MODE:-source}" == "source" ]]; then
    install_nodejs
    install_go
  else
    success "Runtime package mode: bỏ qua cài Node.js/Go và bỏ qua build source."
  fi
  build_dashboard
  build_client_binary
  prepare_bridge_binary
  stop_existing_service
  install_files
  create_systemd_service
  configure_firewall
  check_ipv6
  print_summary
}

main "$@"
