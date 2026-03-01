#!/usr/bin/env bash

set -Eeuo pipefail

# OpenTopoData single-entry installer
# - Minimal mode: --minimal (dev server via Flask, no memcache/uwsgi/systemd)
# - Full mode (default): sets up venv, memcached, uwsgi, and a systemd service
# - Handles modern pip/venv usage; pins pyproj to the version in requirements.txt first

# Defaults (overridable via flags)
REPO_URL=${REPO_URL:-"https://github.com/ajnisbet/opentopodata.git"}
TARGET_DIR=${TARGET_DIR:-"/home/opentopodata"}
PYTHON_BIN=${PYTHON_BIN:-"python3"}
SERVICE_NAME=${SERVICE_NAME:-"opentopodata"}
SYSTEM_USER=${SYSTEM_USER:-"www-data"}
SYSTEM_GROUP=${SYSTEM_GROUP:-"www-data"}
UWSGI_PORT=${UWSGI_PORT:-"9090"}
FLASK_PORT=${FLASK_PORT:-"5000"}
PROCESSES=${PROCESSES:-"10"}
MINIMAL=${MINIMAL:-"0"}
DATASET_SLUG=${DATASET_SLUG:-""}
# By default, bind-mount external dataset into target dir to avoid AppArmor issues
BIND_DATASET=${BIND_DATASET:-"1"}
PERSIST_BIND=${PERSIST_BIND:-"0"}
RESOLVED_DATASET_DIR=""
# Optional: decompress .hgt.gz tiles in dataset
DECOMPRESS_HGT=${DECOMPRESS_HGT:-"0"}
DECOMPRESS_WORKERS=${DECOMPRESS_WORKERS:-"8"}
DELETE_GZ=${DELETE_GZ:-"0"}

# Attempt to default dataset directory to a local ./mapzen if present
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_DATASET_DIR="${SCRIPT_DIR}/mapzen"
DATASET_DIR=${DATASET_DIR:-""}

if [[ -z "${DATASET_DIR}" && -d "${DEFAULT_DATASET_DIR}" ]]; then
  DATASET_DIR="${DEFAULT_DATASET_DIR}"
fi

usage() {
  cat <<EOF2
Usage: $0 [options]

Options:
  --minimal                 Perform minimal install (Flask dev server).
  --target-dir DIR          Install/clone to DIR (default: ${TARGET_DIR}).
  --repo-url URL            Repo URL (default: ${REPO_URL}).
  --python PY               Python executable (default: ${PYTHON_BIN}).
  --dataset-dir DIR         Directory of dataset (default: ./mapzen if exists).
  --service-name NAME       systemd service name (default: ${SERVICE_NAME}).
  --system-user USER        User for service (default: ${SYSTEM_USER}).
  --system-group GROUP      Group for service (default: ${SYSTEM_GROUP}).
  --uwsgi-port PORT         Port for uwsgi http-socket (default: ${UWSGI_PORT}).
  --flask-port PORT         Port for Flask in minimal mode (default: ${FLASK_PORT}).
  --processes N             uWSGI processes (default: ${PROCESSES}).
  -h, --help                Show this help.

Notes:
  - This script will use a Python virtual environment at "<target-dir>/.venv".
  - Full mode attempts to configure memcached + systemd and requires sudo.
  - If dataset is adjacent in a folder named 'mapzen', it's auto-detected.
EOF2
}

log() { echo -e "\033[1;34m[opentopo]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing required command: $1"; return 1;
  }
}

apt_install_if_missing() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing package: $pkg"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    log "Package already installed: $pkg"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --minimal) MINIMAL=1; shift; ;;
      --target-dir) TARGET_DIR="$2"; shift 2; ;;
      --repo-url) REPO_URL="$2"; shift 2; ;;
      --python|--python-bin) PYTHON_BIN="$2"; shift 2; ;;
      --dataset-dir) DATASET_DIR="$2"; shift 2; ;;
      --dataset-slug) DATASET_SLUG="$2"; shift 2; ;;
      --bind-dataset) BIND_DATASET=1; shift; ;;
      --no-bind-dataset) BIND_DATASET=0; shift; ;;
      --persist-bind) PERSIST_BIND=1; shift; ;;
      --decompress|--decompress-hgt) DECOMPRESS_HGT=1; shift; ;;
      --decompress-workers) DECOMPRESS_WORKERS="$2"; shift 2; ;;
      --delete-gz) DELETE_GZ=1; shift; ;;
      --service-name) SERVICE_NAME="$2"; shift 2; ;;
      --system-user) SYSTEM_USER="$2"; shift 2; ;;
      --system-group) SYSTEM_GROUP="$2"; shift 2; ;;
      --uwsgi-port) UWSGI_PORT="$2"; shift 2; ;;
      --flask-port) FLASK_PORT="$2"; shift 2; ;;
      --processes) PROCESSES="$2"; shift 2; ;;
      -h|--help) usage; exit 0; ;;
      *) err "Unknown option: $1"; usage; exit 1; ;;
    esac
  done
}

python_dev_pkg() {
  ${PYTHON_BIN} - <<'PY' 2>/dev/null || true
import sys
print(f"python{sys.version_info.major}.{sys.version_info.minor}-dev")
PY
}

ensure_system_prereqs() {
  need_cmd git
  need_cmd ${PYTHON_BIN}
  apt_install_if_missing gcc || warn "Could not ensure gcc installed"
  local pydev
  pydev=$(python_dev_pkg)
  [[ -n "$pydev" ]] && apt_install_if_missing "${pydev}" || warn "Could not ensure ${pydev} installed"
  apt_install_if_missing python3-venv || warn "Could not ensure python3-venv installed"
}

clone_or_update_repo() {
  if [[ -d "${TARGET_DIR}/.git" ]]; then
    log "Updating existing repo at ${TARGET_DIR}"
    git -C "${TARGET_DIR}" fetch --all --prune
    git -C "${TARGET_DIR}" pull --ff-only || warn "Git pull failed; continuing with existing checkout"
  else
    log "Cloning repo to ${TARGET_DIR}"
    sudo mkdir -p "${TARGET_DIR}" || true
    sudo chown "$(id -u)":"$(id -g)" "${TARGET_DIR}"
    git clone "${REPO_URL}" "${TARGET_DIR}"
  fi
}

setup_venv_and_python_deps() {
  local venv_dir="${TARGET_DIR}/.venv"
  if [[ ! -d "${venv_dir}" ]]; then
    log "Creating venv at ${venv_dir} (with system site packages)"
    ${PYTHON_BIN} -m venv --system-site-packages "${venv_dir}"
  else
    # Ensure system-site-packages is enabled
    if ! grep -q "include-system-site-packages = true" "${venv_dir}/pyvenv.cfg" 2>/dev/null; then
      warn "Recreating venv to enable system site packages"
      rm -rf "${venv_dir}"
      ${PYTHON_BIN} -m venv --system-site-packages "${venv_dir}"
    else
      log "Using existing venv at ${venv_dir}"
    fi
  fi
  # shellcheck disable=SC1091
  source "${venv_dir}/bin/activate"

  log "Upgrading pip/setuptools/wheel"
  pip install --upgrade pip setuptools wheel

  # If full mode, prefer system pylibmc to avoid building from source
  local constraints=""
  if [[ "${MINIMAL}" != "1" ]]; then
    if python -c 'import pylibmc' >/dev/null 2>&1; then
      local ver
      ver=$(python -c 'import pylibmc, sys; print(getattr(pylibmc,"__version__",""))' 2>/dev/null || true)
      if [[ -n "$ver" ]]; then
        constraints=$(mktemp)
        echo "pylibmc==${ver}" > "$constraints"
        log "Constraining pylibmc to system version ${ver} via $constraints"
      fi
    else
      warn "python3-pylibmc not found in system; build may be attempted"
    fi
  fi

  if [[ -f "${TARGET_DIR}/requirements.txt" ]]; then
    local pyproj_line pyproj_ver
    pyproj_line=$(grep -E '^pyproj(==|~=|>=|<=)' "${TARGET_DIR}/requirements.txt" || true)
    if [[ -n "${pyproj_line}" && "${pyproj_line}" =~ pyproj==([0-9.]+) ]]; then
      pyproj_ver="${BASH_REMATCH[1]}"
      log "Installing pinned pyproj==${pyproj_ver} first"
      pip install "pyproj==${pyproj_ver}"
    else
      warn "No pinned pyproj version found; installing pyproj separately to prefer wheel"
      pip install pyproj || warn "pyproj preinstall failed; continuing"
    fi
    log "Installing remaining requirements"
    if [[ -n "$constraints" ]]; then
      pip install -r "${TARGET_DIR}/requirements.txt" -c "$constraints"
    else
      pip install -r "${TARGET_DIR}/requirements.txt"
    fi
  else
    err "requirements.txt not found at ${TARGET_DIR}"
    return 1
  fi
}

minimal_instructions() {
  cat <<EON

Minimal install complete.
To run the development server (no memcache, not for internet exposure):

  cd "${TARGET_DIR}" && \
  . .venv/bin/activate && \
  FLASK_APP=opentopodata/api.py DISABLE_MEMCACHE=1 flask run --port ${FLASK_PORT}

EON
}

ensure_full_system_builddeps() {
  # memcached runtime and build deps for pylibmc
  apt_install_if_missing memcached || warn "Could not ensure memcached installed"
  apt_install_if_missing pkg-config || warn "Could not ensure pkg-config installed"
  apt_install_if_missing libsasl2-dev || warn "Could not ensure libsasl2-dev installed"
  apt_install_if_missing zlib1g-dev || warn "Could not ensure zlib1g-dev installed"
  apt_install_if_missing build-essential || warn "Could not ensure build-essential installed"
  apt_install_if_missing uwsgi-core || warn "Could not ensure uwsgi-core installed"
  apt_install_if_missing uwsgi-plugin-python3 || warn "Could not ensure uwsgi-plugin-python3 installed"


  # Try both libmemcached dev package names (Debian/Ubuntu variants)
  if ! dpkg -s libmemcached-dev >/dev/null 2>&1; then
    set +e
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libmemcached-dev
    local rc=$?
    if [ $rc -ne 0 ]; then
      warn "libmemcached-dev not available; trying libmemcached-awesome-dev"
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libmemcached-awesome-dev
      rc=$?
    fi
    set -e
    if [ $rc -ne 0 ]; then
      warn "Could not install any libmemcached dev package; pylibmc may fail to build"
    fi
  fi

  # If headers are under libmemcached-1.0, export CFLAGS so pylibmc finds them
  if [[ -d /usr/include/libmemcached-1.0 ]]; then
    export CFLAGS="-I/usr/include/libmemcached-1.0 ${CFLAGS:-}"
  fi

  # Install system pylibmc to avoid building from source
  apt_install_if_missing python3-pylibmc || warn "Could not ensure python3-pylibmc installed"
}

install_full_python_tools() {
  # Install uwsgi and regex in the venv
  # shellcheck disable=SC1091
  source "${TARGET_DIR}/.venv/bin/activate"
  pip install regex
}

configure_memcached() {
  log "Configuring memcached for /tmp socket and shared tmp"
  # Ensure memcache user has primary group www-data (matches upstream guidance)
  if id memcache >/dev/null 2>&1; then
    sudo usermod -g "${SYSTEM_GROUP}" memcache || warn "usermod memcache failed"
  else
    warn "memcache user not present; skipping usermod"
  fi

  # Drop-in override for PrivateTmp=false
  sudo mkdir -p /etc/systemd/system/memcached.service.d/
  sudo bash -c 'cat > /etc/systemd/system/memcached.service.d/override.conf <<CONF
[Service]
PrivateTmp=false
CONF'
  sudo systemctl daemon-reload || true

  # Ensure socket and tuning in memcached.conf
  if ! grep -q "^-s /tmp/memcached\.sock" /etc/memcached.conf 2>/dev/null; then
    echo "-s /tmp/memcached.sock" | sudo tee -a /etc/memcached.conf >/dev/null
  fi
  if ! grep -q "^-a 0775" /etc/memcached.conf 2>/dev/null; then
    echo "-a 0775" | sudo tee -a /etc/memcached.conf >/dev/null
  fi
  if ! grep -q "^-c 1024" /etc/memcached.conf 2>/dev/null; then
    echo "-c 1024" | sudo tee -a /etc/memcached.conf >/dev/null
  fi
  if ! grep -q "^-I 8m" /etc/memcached.conf 2>/dev/null; then
    echo "-I 8m" | sudo tee -a /etc/memcached.conf >/dev/null
  fi

  sudo systemctl restart memcached || sudo service memcached restart || true
}

prepare_dataset_path() {
  # Decide dataset slug and optionally bind-mount into target tree to avoid restrictions.
  if [[ -z "${DATASET_DIR}" ]]; then
    RESOLVED_DATASET_DIR=""
    return 0
  fi

  local slug="${DATASET_SLUG}"
  if [[ -z "${slug}" ]]; then
    slug="$(basename "${DATASET_DIR}")"
  fi

  local dest_base="${TARGET_DIR}/datasets"
  local mount_point="${dest_base}/${slug}"

  if [[ "${BIND_DATASET}" == "1" ]]; then
    sudo mkdir -p "${mount_point}"
    if mountpoint -q "${mount_point}"; then
      log "Bind already present: ${mount_point}"
    else
      log "Bind-mounting dataset: ${DATASET_DIR} -> ${mount_point}"
      sudo mount --bind "${DATASET_DIR%/}" "${mount_point}"
    fi
    if [[ "${PERSIST_BIND}" == "1" ]]; then
      local fstab_line
      fstab_line="${DATASET_DIR%/} ${mount_point} none bind 0 0"
      if ! grep -qsF "${fstab_line}" /etc/fstab; then
        log "Persisting bind mount in /etc/fstab"
        echo "${fstab_line}" | sudo tee -a /etc/fstab >/dev/null
      fi
    fi
    RESOLVED_DATASET_DIR="${mount_point}"
  else
    RESOLVED_DATASET_DIR="${DATASET_DIR%/}"
  fi
}

write_config_yaml() {
  # Generate a minimal config.yaml so the dataset slug resolves.
  # If DATASET_DIR is provided, default slug to its basename unless overridden.
  if [[ -z "${DATASET_DIR}" ]]; then
    warn "DATASET_DIR not set; skipping config.yaml generation"
    return 0
  fi

  local cfg_path="${TARGET_DIR}/config.yaml"
  local slug="${DATASET_SLUG}"
  if [[ -z "${slug}" ]]; then
    slug="$(basename "${DATASET_DIR}")"
  fi
  local path_for_config="${RESOLVED_DATASET_DIR:-${DATASET_DIR%/}}/"
  log "Writing ${cfg_path} with dataset '${slug}' -> ${path_for_config}"
  sudo bash -c "cat > '${cfg_path}' <<CFG
# OpenTopoData server configuration (generated by installer)
max_locations_per_request: 100
access_control_allow_origin: '*'

datasets:
- name: ${slug}
  path: ${path_for_config}
CFG"
  sudo chown ${SYSTEM_USER}:${SYSTEM_GROUP} "${cfg_path}" || true
}

decompress_dataset_tiles() {
  # Decompress all .hgt.gz files to .hgt alongside, skipping ones already done.
  # Uses pigz if present; falls back to gzip. Runs in parallel.
  if [[ "${DECOMPRESS_HGT}" != "1" ]]; then
    return 0
  fi

  local root="${RESOLVED_DATASET_DIR:-${DATASET_DIR%/}}"
  if [[ -z "${root}" || ! -d "${root}" ]]; then
    warn "Dataset dir not found for decompression: ${root}"
    return 0
  fi

  local tool="gzip"
  if command -v pigz >/dev/null 2>&1; then tool="pigz"; fi

  log "Decompressing *.hgt.gz under ${root} using ${tool} with ${DECOMPRESS_WORKERS} workers"
  # shellcheck disable=SC2016
  sudo bash -lc "find '${root}' -type f -name '*.hgt.gz' -print0 | xargs -0 -n1 -P ${DECOMPRESS_WORKERS} bash -c 'src=\"\$0\"; dst=\"\${src%.gz}\"; if [ -s \"\$dst\" ]; then echo \"skip \$dst\"; else ${tool} -dc -- \"\$src\" > \"\$dst\" && touch -r \"\$src\" \"\$dst\" && echo \"wrote \$dst\"; fi'"

  if [[ "${DELETE_GZ}" == "1" ]]; then
    log "Removing original .hgt.gz files that have been decompressed"
    sudo bash -lc "find '${root}' -type f -name '*.hgt.gz' -print0 | while IFS= read -r -d '' gz; do hgt=\"\${gz%.gz}\"; [ -s \"\$hgt\" ] && rm -f -- \"\$gz\"; done"
  fi
}

write_uwsgi_ini() {
  local ini_path="${TARGET_DIR}/uwsgi.ini"
  local venv_dir="${TARGET_DIR}/.venv"
  log "Writing ${ini_path}"
  # Optional dataset env line for uwsgi (no quotes around directive)
  local dataset_env_line=""
  if [[ -n "${DATASET_DIR}" ]]; then
    dataset_env_line="env = OPENTOPODATA_DATA_DIR=${DATASET_DIR}"
  fi

  sudo bash -c "cat > '${ini_path}' <<UWSGI
[uwsgi]
strict = true
need-app = true

http-socket = :${UWSGI_PORT}
vacuum = true
uid = ${SYSTEM_USER}
gid = ${SYSTEM_GROUP}

master = true

plugins = python3

chdir = ${TARGET_DIR}
pythonpath = ${TARGET_DIR}
wsgi-file = ${TARGET_DIR}/opentopodata/api.py
callable = app
manage-script-name = true

die-on-term = true
buffer-size = 65535

virtualenv = ${venv_dir}
env = DISABLE_MEMCACHE=0



${dataset_env_line}
UWSGI"
  sudo chown ${SYSTEM_USER}:${SYSTEM_GROUP} "${ini_path}" || true
}

write_systemd_unit() {
  local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
  local venv_dir="${TARGET_DIR}/.venv"
  log "Writing systemd unit ${unit_path}"
  # Optional dataset env for systemd; quote the value to allow spaces
  local systemd_env_line=""
  if [[ -n "${DATASET_DIR}" ]]; then
    systemd_env_line="Environment=\"OPENTOPODATA_DATA_DIR=${DATASET_DIR}\""
  fi

  sudo bash -c "cat > '${unit_path}' <<UNIT
[Unit]
Description=OpenTopoData web application
After=network.target memcached.service

[Service]
User=${SYSTEM_USER}
Group=${SYSTEM_GROUP}
WorkingDirectory=${TARGET_DIR}
${systemd_env_line}
ExecStart=/usr/bin/uwsgi ${TARGET_DIR}/uwsgi.ini --processes ${PROCESSES}
Restart=always

[Install]
WantedBy=multi-user.target
UNIT"
  sudo systemctl daemon-reload || true
}

full_instructions() {
  cat <<EOF3

Full install complete.

Next steps to manage the service:

  sudo systemctl enable ${SERVICE_NAME}.service
  sudo systemctl start ${SERVICE_NAME}.service

Service listens on uWSGI http-socket port ${UWSGI_PORT}.
Dataset dir: ${DATASET_DIR:-"(not set)"}

To view logs:
  sudo journalctl -u ${SERVICE_NAME} -f

EOF3
}

main() {
  parse_args "$@"

  log "Installing to: ${TARGET_DIR} (minimal=${MINIMAL})"
  if [[ -n "${DATASET_DIR}" ]]; then
    log "Using dataset dir: ${DATASET_DIR}"
  else
    warn "No dataset dir provided; you can pass --dataset-dir /path/to/mapzen"
  fi

  ensure_system_prereqs
  if [[ "${MINIMAL}" != "1" ]]; then
    ensure_full_system_builddeps
  fi
  clone_or_update_repo
  setup_venv_and_python_deps

  if [[ "${MINIMAL}" == "1" ]]; then
    minimal_instructions
    exit 0
  fi

  install_full_python_tools
  configure_memcached
  prepare_dataset_path
  decompress_dataset_tiles
  write_config_yaml
  write_uwsgi_ini
  write_systemd_unit
  full_instructions
}

main "$@"
