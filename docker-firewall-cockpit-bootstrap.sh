#!/usr/bin/env bash
# ============================================================
# Ubuntu Secure Bootstrap: Firewalld + Docker + Cockpit
# (Multi-interface aware version)
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
PUBLIC_IFS=()
ALL_IFACES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports) PORTS_CSV="${2:-}"; shift 2;;
    --allow-ssh-from) SSH_ALLOW_CIDR="${2:-}"; shift 2;;
    --iface) PUBLIC_IF="${2:-}"; shift 2;;
    --all-ifaces) ALL_IFACES=true; shift;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

require_root

# ----------------------------
# Interface Detection
# ----------------------------
detect_iface() {
  if [[ -n "$PUBLIC_IF" ]]; then
    ip link show "$PUBLIC_IF" >/dev/null 2>&1 || die "Interface not found: $PUBLIC_IF"
    PUBLIC_IFS=("$PUBLIC_IF")
    return 0
  fi

  log "Auto-detecting network interfaces..."

  if [[ "$ALL_IFACES" = true ]]; then
    mapfile -t PUBLIC_IFS < <(
      ip -o link show | awk -F': ' '{print $2}' \
      | grep -vE '^(lo|docker|veth|br-)'
    )
  else
    mapfile -t PUBLIC_IFS < <(
      ip -o link show up | awk -F': ' '{print $2}' \
      | grep -vE '^(lo|docker|veth|br-)'
    )
  fi

  [[ "${#PUBLIC_IFS[@]}" -gt 0 ]] || die "No suitable interfaces found."

  log "Detected interfaces: ${PUBLIC_IFS[*]}"
}

parse_ports() {
  IFS=',' read -r -a PORTS <<< "$PORTS_CSV"
  [[ "${#PORTS[@]}" -gt 0 ]] || die "No ports parsed"

  for p in "${PORTS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid port: $p"
    (( p >= 1 && p <= 65535 )) || die "Port out of range: $p"
  done
}

# ----------------------------
# Firewalld Reset
# ----------------------------
reset_firewalld() {
  log "Resetting firewalld..."
  systemctl stop firewalld >/dev/null 2>&1 || true
  apt-get -y purge firewalld >/dev/null 2>&1 || true
  rm -rf /etc/firewalld /var/lib/firewalld

  apt-get update -y
  apt-get install -y firewalld

  systemctl enable --now firewalld
  firewall-offline-cmd --check-config >/dev/null
}

configure_firewalld() {
  log "Configuring firewalld..."

  firewall-cmd --set-default-zone=public
  firewall-cmd --permanent --zone=public --set-target=DROP

  for IFACE in "${PUBLIC_IFS[@]}"; do
    log "Adding interface: $IFACE"
    firewall-cmd --permanent --zone=public --add-interface="$IFACE"
  done

  firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true

  for p in "${PORTS[@]}"; do
    firewall-cmd --permanent --zone=public --add-port="${p}/tcp"
  done

  if [[ -n "$SSH_ALLOW_CIDR" ]]; then
    log "Allowing SSH only from ${SSH_ALLOW_CIDR}"
    firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${SSH_ALLOW_CIDR} port port=22 protocol=tcp accept"
  else
    warn "SSH completely blocked!"
  fi

  firewall-cmd --reload
}

# ----------------------------
# Cockpit
# ----------------------------
install_cockpit() {
  log "Installing Cockpit..."
  apt-get install -y cockpit
  systemctl enable --now cockpit.socket
}

# ----------------------------
# Docker Rules
# ----------------------------
apply_docker_rules() {
  if ! have_cmd docker; then
    warn "Docker not found, skipping..."
    return
  fi

  apt-get install -y iptables

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

# ----------------------------
# Status
# ----------------------------
print_status() {
  echo "======================================"
  echo " Interfaces : ${PUBLIC_IFS[*]}"
  echo " Ports      : ${PORTS_CSV}"
  echo " SSH        : ${SSH_ALLOW_CIDR:-BLOCKED}"
  echo "======================================"

  firewall-cmd --zone=public --list-all || true

  if have_cmd iptables; then
    iptables -L DOCKER-USER -n -v || true
  fi
}

# ----------------------------
# Main
# ----------------------------
detect_iface
parse_ports
reset_firewalld
configure_firewalld
install_cockpit
apply_docker_rules
print_status
