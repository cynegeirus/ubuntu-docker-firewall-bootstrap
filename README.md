# Ubuntu Secure Bootstrap: Firewalld + Docker + Cockpit

A production-oriented bootstrap script for Ubuntu servers that performs a **clean (from-scratch) firewalld reset**, applies a **default-deny inbound firewall posture**, hardens Docker-published ports via the **DOCKER-USER** chain, and installs/enables **Cockpit** on port **9090**.

This repository is designed for operators who care about **security, determinism, and repeatability**—and who prefer to avoid “mystery rules” and snowflake servers.

---

## What this script does (high-level)

### 1) Firewalld: clean reset + deterministic configuration
- Stops `firewalld` (if running)
- **Purges** `firewalld` and removes legacy configuration directories:
  - `/etc/firewalld`
  - `/var/lib/firewalld`
- Reinstalls `firewalld`, enables and starts it
- Sets default zone to `public`
- Binds your primary interface to the `public` zone
- Sets `public` zone target to **DROP** (default deny)

### 2) Inbound allowlist (TCP ports)
By default, the script only allows inbound TCP traffic to:
- `80/tcp`
- `443/tcp`
- `9090/tcp` (Cockpit)

Everything else inbound is dropped.

### 3) SSH policy (secure by default)
- By default, inbound `22/tcp` is **blocked**
- Optionally, you can allow SSH from a specific trusted CIDR/IP using:
  - `--allow-ssh-from 203.0.113.10/32`

This uses **firewalld rich rules** to allow SSH only from the provided source range.

> Critical warning: running this script remotely **without** SSH whitelisting will terminate your SSH access. Ensure console/KVM/IPMI access.

### 4) Cockpit installation & enablement
Installs and enables Cockpit services (socket activation):
- Installs packages:
  - `cockpit`
  - `cockpit-bridge`
  - `cockpit-networkmanager`
  - `cockpit-packagekit`
  - `cockpit-storaged`
  - `cockpit-ws`
  - `cockpit-system`
- Enables and starts:
  - `cockpit.socket`

Access:
- `https://<server-ip>:9090`

> Cockpit often uses a self-signed certificate by default; browser warnings are expected unless you replace it.

### 5) Docker hardening via DOCKER-USER (allowlist)
If Docker is detected, the script programs the `DOCKER-USER` chain as an inbound allowlist for Docker-published ports.

Rules applied (conceptually):
- `RELATED,ESTABLISHED` -> ACCEPT
- Allow inbound TCP ports you specify (default: `80,443,9090`) -> ACCEPT
- Optional SSH allow from `--allow-ssh-from` -> ACCEPT (port 22)
- Everything else -> DROP

This protects you from the common “Docker published a port, now it’s reachable from the internet” surprise.

### 6) Persistence across reboots (without iptables-save pitfalls)
Instead of freezing the entire iptables ruleset with `iptables-save` / `iptables-persistent` (which can create long-term conflicts with firewalld and Docker’s dynamic rule management), the script persists **only what we need**:

- Creates:
  - `/usr/local/sbin/docker-user-firewall.sh`
  - `/etc/systemd/system/docker-user-firewall.service`
- Enables and starts the service:
  - `docker-user-firewall.service`

On every boot (and after Docker starts), systemd re-applies the deterministic `DOCKER-USER` allowlist rules.

This approach is:
- More maintainable
- Less invasive
- More compatible with firewalld + Docker realities

---

## Supported OS / Requirements

- Ubuntu (APT-based)
- Root privileges (`sudo`)
- Internet access (to install packages)
- Docker is optional:
  - If Docker is not installed, the DOCKER-USER hardening step is skipped.

---

## Files

- `docker-firewall-cockpit-bootstrap.sh`
  - The main bootstrap script (clean firewalld install, allowlist, Cockpit, Docker hardening, persistence)

At runtime, it generates:
- `/usr/local/sbin/docker-user-firewall.sh`
- `/etc/systemd/system/docker-user-firewall.service`

---

## Installation

1) Copy the script to your server (or clone the repo).

2) Make it executable:
```bash
chmod +x docker-firewall-cockpit-bootstrap.sh
```

3) Run it:

### Safe option (recommended for remote servers)
Allow SSH from your current public IP:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --allow-ssh-from <YOUR_PUBLIC_IP>/32
```

### Console-only option
If you have console/KVM access and deliberately want SSH blocked:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh
```

---

## Configuration options

### `--iface <name>`
Manually specify the public interface to attach to the `public` zone.

Example:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --iface ens192
```

When to use:
- VMware / vSphere (often `ens192`)
- Multi-NIC servers
- Complex routing where auto-detection is not reliable

### `--ports <csv>`
Comma-separated list of inbound TCP ports to allow.

Example:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --ports 80,443,9090
```

Notes:
- This affects both:
  - firewalld `public` zone open ports
  - Docker `DOCKER-USER` allowlist

### `--allow-ssh-from <cidr>`
Allow inbound SSH only from a trusted source.

Example:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --allow-ssh-from 203.0.113.10/32
```

---

## Verification & Operational checks

### Check firewalld status and active rules
```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --zone=public --list-all
```

Expected highlights:
- `public` is active
- `target: DROP`
- `ports: 80/tcp 443/tcp 9090/tcp` (or your custom list)

### Check Cockpit
```bash
sudo systemctl status cockpit.socket
```

Access:
- `https://<server-ip>:9090`

### Check Docker DOCKER-USER chain
```bash
sudo iptables -L DOCKER-USER -n -v
```

### Check persistence service
```bash
sudo systemctl status docker-user-firewall.service
sudo systemctl cat docker-user-firewall.service
```

---

## Security notes (read this before production)

- **Default deny inbound** is the right baseline for servers.
- **SSH should not be globally exposed** in most modern deployments:
  - Prefer VPN/Zero Trust access
  - Or strictly whitelist source IPs (`--allow-ssh-from`)
  - Use MFA / hardware keys where possible
- **Cockpit exposure**:
  - Opening 9090 to the internet is usually not a great idea.
  - Recommended patterns:
    - Restrict 9090 with firewalld rich rules to your office/VPN CIDR
    - Or place it behind a reverse proxy + authentication (SSO/MFA)
- **Docker inbound exposure**:
  - DOCKER-USER allowlisting prevents accidental exposure of newly published ports.
  - If you intentionally need a new port, add it via `--ports`.

---

## Troubleshooting

### I lost my SSH session
That’s expected if you ran the script remotely without `--allow-ssh-from`.
Fix:
- Access the server via console/KVM/IPMI
- Re-run with your trusted IP:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --allow-ssh-from <YOUR_PUBLIC_IP>/32
```

### Cockpit is running but not reachable
- Ensure `9090/tcp` is in your allowed port list
- Confirm firewalld is active and targeting the correct interface:
```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --zone=public --list-all
```

### Docker published port is not reachable anymore
This is by design: only allowlisted ports are reachable.
Add the required port:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --ports 80,443,9090,<NEW_PORT>
```

### Interface auto-detection picked the wrong NIC
Pin it:
```bash
sudo ./docker-firewall-cockpit-bootstrap.sh --iface <correct-interface>
```

---

## Roadmap / hardening ideas (optional)
If you want to take this further:
- Restrict Cockpit access to office/VPN CIDR only (recommended)
- Add rate-limited logging for dropped inbound connections (SIEM-friendly)
- Add IPv6-first policy alignment (ip6tables/nftables)
- Integrate with CI/CD pipelines for immutable server bootstrapping

---

## License

This project is licensed under the [MIT License](LICENSE).

## Issues, Feature Requests or Support

Please use the Issue > New Issue button to submit issues, feature requests or support issues directly to me. You can also send an e-mail to akin.bicer@outlook.com.tr.
