#!/usr/bin/env bash
# ============================================================
# Ubuntu Secure Bootstrap: Firewalld + Docker (DOCKER-USER) + Cockpit
# ============================================================
# Clean install / reset:
# - Purge + reinstall firewalld, remove old configs
# - Default zone: public, target: DROP
# - Allow only selected TCP ports (default: 80,443,9090)
# - SSH blocked by default; optional whitelist via rich-rule + DOCKER-USER allow
# - Install & enable Cockpit (9090/tcp)
# - Harden Docker via DOCKER-USER allowlist
# - Persist DOCKER-USER rules using a systemd oneshot service (preferred over iptables-save)
#
# Usage:
#   sudo ./docker-firewall-cockpit-bootstrap.sh
#   sudo ./docker-firewall-cockpit-bootstrap.sh --iface ens192
#   sudo ./docker-firewall-cockpit-bootstrap.sh --ports 80,443,9090
#   sudo ./docker-firewall-cockpit-bootstrap.sh --allow-ssh-from 203.0.113.10/32
#
# Notes:
# - Cockpit: https://<server-ip>:9090
# - SSH default blocked unless --allow-ssh-from provided.
# ============================================================

set -euo pipefail

log() { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die() { echo -e "[x] $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Root required. Run with sudo."
}

# ----------------------------
# Defaults / Args
# ----------------------------
PORTS_CSV="80,443,9090"
SSH_ALLOW_CIDR=""
PUBLIC_IF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports) PORTS_CSV="${2:-}"; shift 2;;
    --allow-ssh-from) SSH_ALLOW_CIDR="${2:-}"; shift 2;;
    --iface) PUBLIC_IF="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

require_root

# ----------------------------
# Helpers
# ----------------------------
detect_iface() {
  if [[ -n "$PUBLIC_IF" ]]; then
    ip link show "$PUBLIC_IF" >/dev/null 2>&1 || die "Interface not found: $PUBLIC_IF"
    return 0
  fi

  PUBLIC_IF="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "$PUBLIC_IF" ]] || die "Could not auto-detect public interface. Use --iface <name>."
}

parse_ports() {
  IFS=',' read -r -a PORTS <<< "$PORTS_CSV"
  [[ "${#PORTS[@]}" -gt 0 ]] || die "No ports parsed from --ports"

  for p in "${PORTS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid port: $p"
    (( p >= 1 && p <= 65535 )) || die "Port out of range: $p"
  done
}

# ----------------------------
# Clean Firewalld install
# ----------------------------
reset_firewalld() {
  log "Stopping firewalld (if running)..."
  systemctl stop firewalld >/dev/null 2>&1 || true

  log "Purging firewalld for clean state..."
  apt-get -y purge firewalld >/dev/null 2>&1 || true

  log "Removing old firewalld config directories..."
  rm -rf /etc/firewalld /var/lib/firewalld

  log "Installing firewalld..."
  apt-get update -y
  apt-get install -y firewalld

  log "Enabling + starting firewalld..."
  systemctl enable --now firewalld

  log "Validating firewalld config..."
  firewall-offline-cmd --check-config >/dev/null
}

configure_firewalld() {
  log "Configuring firewalld: zone=public, target=DROP, iface=${PUBLIC_IF}"

  firewall-cmd --set-default-zone=public
  firewall-cmd --permanent --zone=public --add-interface="${PUBLIC_IF}"
  firewall-cmd --permanent --zone=public --set-target=DROP

  # Best-effort cleanup
  firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --remove-service=http >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --remove-service=https >/dev/null 2>&1 || true

  # Allow required ports
  for p in "${PORTS[@]}"; do
    firewall-cmd --permanent --zone=public --add-port="${p}/tcp"
  done

  # Optional SSH whitelist
  if [[ -n "$SSH_ALLOW_CIDR" ]]; then
    log "Whitelisting SSH (22/tcp) for ${SSH_ALLOW_CIDR}"
    firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${SSH_ALLOW_CIDR} port port=22 protocol=tcp accept"
    firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv6 source address=${SSH_ALLOW_CIDR} port port=22 protocol=tcp accept" >/dev/null 2>&1 || true
  else
    warn "SSH whitelist not set: inbound TCP/22 will be blocked."
  fi

  firewall-cmd --reload
}

# ----------------------------
# Cockpit install
# ----------------------------
install_cockpit() {
  log "Installing Cockpit packages..."
  apt-get update -y
  apt-get install -y \
    cockpit cockpit-bridge cockpit-networkmanager cockpit-packagekit \
    cockpit-storaged cockpit-ws cockpit-system

  log "Enabling cockpit.socket..."
  systemctl enable --now cockpit.socket
}

# ----------------------------
# Docker hardening (DOCKER-USER)
# ----------------------------
apply_docker_user_rules_now() {
  if ! have_cmd docker; then
    warn "Docker not detected; skipping DOCKER-USER rules."
    return 0
  fi

  if ! have_cmd iptables; then
    log "Installing iptables (required for DOCKER-USER)..."
    apt-get update -y
    apt-get install -y iptables
  fi

  log "Applying DOCKER-USER allowlist rules now..."
  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -F DOCKER-USER

  iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  if [[ -n "$SSH_ALLOW_CIDR" ]]; then
    iptables -A DOCKER-USER -p tcp --dport 22 -s "$SSH_ALLOW_CIDR" -j ACCEPT
  fi

  for p in "${PORTS[@]}"; do
    iptables -A DOCKER-USER -p tcp --dport "$p" -j ACCEPT
  done

  iptables -A DOCKER-USER -j DROP
}

install_docker_user_persistence() {
  if ! have_cmd iptables; then
    warn "iptables not present; skipping DOCKER-USER persistence."
    return 0
  fi

  log "Installing systemd persistence for DOCKER-USER rules..."

  install -m 0755 /dev/null /usr/local/sbin/docker-user-firewall.sh
  cat > /usr/local/sbin/docker-user-firewall.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PORTS_CSV="${PORTS_CSV:-80,443,9090}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { echo "[docker-user-fw] $*"; }

if ! have_cmd iptables; then
  log "iptables not found; exiting."
  exit 0
fi

iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER

iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

if [[ -n "$SSH_ALLOW_CIDR" ]]; then
  iptables -A DOCKER-USER -p tcp --dport 22 -s "$SSH_ALLOW_CIDR" -j ACCEPT
fi

IFS=',' read -r -a PORTS <<< "$PORTS_CSV"
for p in "${PORTS[@]}"; do
  [[ "$p" =~ ^[0-9]+$ ]] || continue
  iptables -A DOCKER-USER -p tcp --dport "$p" -j ACCEPT
done

iptables -A DOCKER-USER -j DROP

log "Applied DOCKER-USER allowlist: ${PORTS_CSV} (SSH whitelist: ${SSH_ALLOW_CIDR:-none})"
EOF
  chmod 0755 /usr/local/sbin/docker-user-firewall.sh

  cat > /etc/systemd/system/docker-user-firewall.service <<EOF
[Unit]
Description=Apply DOCKER-USER firewall rules (allowlist)
Wants=docker.service
After=network-online.target docker.service
ConditionPathExists=/usr/local/sbin/docker-user-firewall.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-user-firewall.sh
Environment=PORTS_CSV=${PORTS_CSV}
Environment=SSH_ALLOW_CIDR=${SSH_ALLOW_CIDR}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now docker-user-firewall.service
}

# ----------------------------
# Status
# ----------------------------
print_status() {
  echo "============================================"
  echo " Final Firewall Status (firewalld)"
  echo "============================================"
  firewall-cmd --get-active-zones || true
  firewall-cmd --zone=public --list-all || true

  echo
  echo "============================================"
  echo " Cockpit"
  echo "============================================"
  systemctl --no-pager --full status cockpit.socket || true
  echo "URL: https://<server-ip>:9090"

  if have_cmd iptables; then
    echo
    echo "============================================"
    echo " DOCKER-USER (iptables)"
    echo "============================================"
    iptables -L DOCKER-USER -n -v || true
  fi

  echo
  echo "============================================"
  echo " Setup Complete"
  echo "============================================"
  echo " Interface      : ${PUBLIC_IF}"
  echo " Allowed ports  : ${PORTS_CSV} (tcp)"
  if [[ -n "$SSH_ALLOW_CIDR" ]]; then
    echo " SSH (22)       : ALLOWED only from ${SSH_ALLOW_CIDR}"
  else
    echo " SSH (22)       : BLOCKED"
  fi
  echo " Firewalld      : public target DROP"
  echo " Cockpit        : enabled on 9090"
  echo "============================================"
}

# ----------------------------
# Main
# ----------------------------
detect_iface
parse_ports
reset_firewalld
configure_firewalld
install_cockpit
apply_docker_user_rules_now
install_docker_user_persistence
print_status
