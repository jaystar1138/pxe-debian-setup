#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 jaystar1138. Released under the MIT licence; see the LICENSE file.
#
# pxe-setup.sh - turns a fresh Debian 13 install with two network cards into a PXE deployment server.
#
# Does Parts 2 to 5.1 of the "PXE deployment server on plain Debian" guide:
#   - fixed address 10.10.10.1/24 on the deploy NIC (no gateway)
#   - installs dnsmasq (DHCP + TFTP), nginx (HTTP) and Samba (SMB shares)
#   - creates the accounts, folders and config files
#   - copies in the boot files if you have put them in a folder
#   - starts the services and checks them
#
# Run as root, after installing Debian and logging in over SSH on the internet NIC:
#   ./pxe-setup.sh                      auto-detect both NICs
#   ./pxe-setup.sh --dry-run            show what it would do, change nothing
#   ./pxe-setup.sh --deploy-nic enp2s0  choose the deploy NIC yourself
#
set -euo pipefail

# ---------------------------------------------------------------- settings
DEPLOY_IP="10.10.10.1"
DEPLOY_PREFIX="24"
DHCP_START="10.10.10.100"
DHCP_END="10.10.10.199"
DEPLOY_NIC=""
INET_NIC=""
BOOT_FILES_DIR="/root"
DATA_DISK=""
PROMPT_PASSWORDS=0
RESET_PASSWORDS=0
ASSUME_YES=0
DRY_RUN=0
LOG_FILE="/var/log/pxe-setup.log"
PASSWORD_FILE="/root/pxe-setup-passwords.txt"
BOOT_FILES=(ipxe-shim.efi ipxe.efi wimboot BCD boot.sdi boot.wim)

# ---------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step()  { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
ok()    { printf '  %s[ok]%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s[warn]%s %s\n' "$Y" "$N" "$*"; }
info()  { printf '       %s\n' "$*"; }
die()   { printf '\n%s[error]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 [options]

  --deploy-nic NAME     the card that faces the PCs to be imaged (default: auto-detect)
  --inet-nic NAME       the card that reaches your office/internet (default: the default-route card)
  --boot-files DIR      folder holding ipxe-shim.efi ipxe.efi wimboot BCD boot.sdi boot.wim (default: /root)
  --data-disk DEVICE    OPTIONAL: format this empty disk (ERASES IT) and mount it at /srv
  --prompt-passwords    ask for the Samba passwords instead of generating them
  --reset-passwords     on a re-run, set new Samba passwords (default: keep the existing ones)
  --yes                 do not ask for confirmation
  --dry-run             print what would happen and change nothing
  -h, --help            this text
EOF
}

# ---------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-nic)       DEPLOY_NIC="${2:-}"; shift 2 ;;
    --inet-nic)         INET_NIC="${2:-}"; shift 2 ;;
    --boot-files)       BOOT_FILES_DIR="${2:-}"; shift 2 ;;
    --data-disk)        DATA_DISK="${2:-}"; shift 2 ;;
    --prompt-passwords) PROMPT_PASSWORDS=1; shift ;;
    --reset-passwords)  RESET_PASSWORDS=1; shift ;;
    --yes|-y)           ASSUME_YES=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

# keep a log of everything (not in dry-run)
if [[ $DRY_RUN -eq 0 && $EUID -eq 0 ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "--- pxe-setup started $(date -Is) ---"
fi

# run a command, or just show it in dry-run
run() {
  if [[ $DRY_RUN -eq 1 ]]; then info "would run: $*"; else "$@"; fi
}
# write stdin to a file, backing up any existing different file; dry-run only reports
put_file() {
  local path="$1" mode="${2:-644}" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [[ $DRY_RUN -eq 1 ]]; then info "would write $path"; rm -f "$tmp"; return; fi
  if [[ -f "$path" ]] && ! cmp -s "$tmp" "$path"; then
    cp -a "$path" "$path.bak-$(date +%Y%m%d%H%M%S)"
    info "backed up old $path"
  fi
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"
  ok "wrote $path"
}

# ---------------------------------------------------------------- 1. preflight
step "Checking this machine"

if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
  die "Run this as root (type 'su -' first, or use sudo)."
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then die "This script is for Debian. Found: ${PRETTY_NAME:-unknown}."; fi
  if [[ "${VERSION_ID:-0}" -lt 13 ]]; then warn "Written for Debian 13; you have ${PRETTY_NAME:-unknown}. Continuing."; else ok "${PRETTY_NAME}"; fi
else
  die "Cannot read /etc/os-release."
fi

[[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" == "0" ]] \
  && ok "IP forwarding is off (the two networks will stay separate)" \
  || die "IP forwarding is ON. The deploy network must not be routed to the office. Turn it off first: grep -r ip_forward /etc/sysctl.conf /etc/sysctl.d/"

# physical NICs only (they have a 'device' link; bridges, tunnels and veths do not)
mapfile -t PHYS < <(for n in /sys/class/net/*; do
  name="$(basename "$n")"; [[ "$name" == "lo" ]] && continue
  [[ -e "$n/device" ]] && echo "$name"
done)
[[ ${#PHYS[@]} -ge 2 ]] || die "Found ${#PHYS[@]} network card(s) (${PHYS[*]:-none}). You need two: one for the internet, one for the deploy network."

if [[ -z "$INET_NIC" ]]; then
  INET_NIC="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
[[ -n "$INET_NIC" ]] || die "No default route found, so I cannot tell which card is the internet card. Pass --inet-nic NAME."

if [[ -z "$DEPLOY_NIC" ]]; then
  CANDIDATES=()
  for n in "${PHYS[@]}"; do [[ "$n" != "$INET_NIC" ]] && CANDIDATES+=("$n"); done
  if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    DEPLOY_NIC="${CANDIDATES[0]}"
  else
    die "More than one spare card (${CANDIDATES[*]}). Pass --deploy-nic NAME to choose."
  fi
fi

[[ "$DEPLOY_NIC" != "$INET_NIC" ]] || die "The deploy NIC and the internet NIC are the same card ($DEPLOY_NIC)."
[[ -e "/sys/class/net/$DEPLOY_NIC" ]] || die "No network card called '$DEPLOY_NIC'. Run: ip -br link"
[[ -e "/sys/class/net/$INET_NIC" ]]   || die "No network card called '$INET_NIC'. Run: ip -br link"

if ip -4 route show default 2>/dev/null | grep >/dev/null "dev $DEPLOY_NIC"; then
  die "$DEPLOY_NIC carries the default route, so it is the internet card. Choose the other one with --deploy-nic."
fi
EXISTING_V4="$(ip -4 -br addr show dev "$DEPLOY_NIC" 2>/dev/null | awk '{for(i=3;i<=NF;i++) print $i}' | grep -v "^${DEPLOY_IP}/" || true)"
if [[ -n "$EXISTING_V4" ]]; then
  die "$DEPLOY_NIC already has the address(es) $EXISTING_V4. It looks in use. If that is right, remove them first."
fi

ok "internet NIC: $INET_NIC   (office side)"
ok "deploy NIC:   $DEPLOY_NIC (will become ${DEPLOY_IP}/${DEPLOY_PREFIX}, no gateway)"

if [[ -n "$DATA_DISK" ]]; then
  [[ -b "$DATA_DISK" ]] || die "$DATA_DISK is not a disk."
  if findmnt -rn -S "$DATA_DISK" >/dev/null 2>&1 || lsblk -nr -o MOUNTPOINT "$DATA_DISK" | grep >/dev/null .; then die "$DATA_DISK (or a partition on it) is mounted."; fi
  if [[ -n "$(lsblk -nr -o NAME "$DATA_DISK" | tail -n +2)" || -n "$(blkid -o value -s TYPE "$DATA_DISK" 2>/dev/null || true)" ]]; then
    die "$DATA_DISK has partitions or a filesystem already. Refusing to erase it. Empty it yourself first if you are sure."
  fi
  warn "$DATA_DISK will be ERASED and mounted at /srv"
fi

missing=()
for f in "${BOOT_FILES[@]}"; do [[ -f "$BOOT_FILES_DIR/$f" ]] || missing+=("$f"); done
if [[ ${#missing[@]} -eq 0 ]]; then ok "all six boot files found in $BOOT_FILES_DIR"
else warn "boot files not found in $BOOT_FILES_DIR: ${missing[*]}"; info "the server will still be set up; copy them in later (see the summary)"; fi

if [[ $DRY_RUN -eq 1 ]]; then
  step "Dry run: what would happen"
  [[ -n "$DATA_DISK" ]] && info "- format $DATA_DISK (ERASING it) and mount it at /srv"
  info "- give $DEPLOY_NIC the address ${DEPLOY_IP}/${DEPLOY_PREFIX}"
  info "- apt install dnsmasq nginx samba curl"
  info "- create accounts deploy, publisher, nciadmin and the /srv folders"
  info "- copy the boot files and write boot.ipxe"
  info "- write the dnsmasq, nginx and Samba configs; turn off nmbd and samba-ad-dc"
  info "- start the services and check them"
  printf '\nNothing was changed. Run again without --dry-run to apply.\n'
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\nThis will configure %s as the deploy network and install services on this machine.\n' "$DEPLOY_NIC"
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled. Nothing was changed."
fi

# ---------------------------------------------------------------- 2. optional data disk
if [[ -n "$DATA_DISK" ]]; then
  step "Preparing the data disk"
  mkfs.ext4 -q -L srvdata "$DATA_DISK"
  mkdir -p /srv
  grep -q 'LABEL=srvdata' /etc/fstab || echo 'LABEL=srvdata /srv ext4 defaults 0 2' >> /etc/fstab
  systemctl daemon-reload
  mount /srv
  ok "mounted $(df -h --output=size /srv | tail -1 | tr -d ' ') at /srv"
fi

# ---------------------------------------------------------------- 3. deploy NIC address
step "Setting the deploy network card"
if command -v ifup >/dev/null 2>&1 && [[ -d /etc/network ]]; then
  mkdir -p /etc/network/interfaces.d
  grep -qs '^source.*interfaces.d' /etc/network/interfaces || warn "/etc/network/interfaces has no 'source /etc/network/interfaces.d/*' line; the deploy file may not load"
  put_file /etc/network/interfaces.d/deploy 644 <<EOF
auto $DEPLOY_NIC
iface $DEPLOY_NIC inet static
    address ${DEPLOY_IP}/${DEPLOY_PREFIX}
EOF
  ip link set "$DEPLOY_NIC" up || true
  ifup "$DEPLOY_NIC" 2>&1 | sed 's/^/       /' || true
elif systemctl is-active --quiet systemd-networkd; then
  put_file /etc/systemd/network/20-deploy.network 644 <<EOF
[Match]
Name=$DEPLOY_NIC

[Network]
Address=${DEPLOY_IP}/${DEPLOY_PREFIX}
ConfigureWithoutCarrier=yes
EOF
  networkctl reload || systemctl restart systemd-networkd
else
  die "This system uses neither ifupdown nor systemd-networkd, so I do not know how to set a fixed address. Set ${DEPLOY_IP}/${DEPLOY_PREFIX} on $DEPLOY_NIC yourself (no gateway), then run this script again."
fi
sleep 2
ip -4 -br addr show dev "$DEPLOY_NIC" | grep >/dev/null "${DEPLOY_IP}/${DEPLOY_PREFIX}" \
  && ok "$DEPLOY_NIC is up as ${DEPLOY_IP}/${DEPLOY_PREFIX}" \
  || die "$DEPLOY_NIC did not get ${DEPLOY_IP}/${DEPLOY_PREFIX}. Check: ip -br a"
ip -4 route show default | grep >/dev/null "dev $INET_NIC" && ok "default route still goes through $INET_NIC" || warn "default route is not on $INET_NIC; check: ip route"

# ---------------------------------------------------------------- 4. packages
step "Installing packages (this can take a few minutes)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dnsmasq nginx samba curl >/dev/null
ok "dnsmasq, nginx, samba, curl installed"
# first install starts these with no config; quieten them until the configs exist
systemctl stop dnsmasq 2>/dev/null || true

# ---------------------------------------------------------------- 5. accounts
step "Creating accounts"
for u in deploy publisher nciadmin; do
  if id "$u" >/dev/null 2>&1; then ok "$u already exists"
  else useradd -m -s /usr/sbin/nologin "$u" && ok "created $u (no shell login)"; fi
done

gen_pw() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
have_smb() { pdbedit -L 2>/dev/null | cut -d: -f1 | grep -x >/dev/null "$1"; }
declare -A PW
[[ -f "$PASSWORD_FILE" ]] || { : > "$PASSWORD_FILE"; }
chmod 600 "$PASSWORD_FILE"
for u in deploy publisher nciadmin; do
  if have_smb "$u" && [[ $RESET_PASSWORDS -eq 0 ]]; then
    ok "$u: Samba password already set, kept (use --reset-passwords to change it)"
    continue
  fi
  if [[ $PROMPT_PASSWORDS -eq 1 ]]; then
    smbpasswd -a "$u"
    PW[$u]="(typed by you)"
  else
    PW[$u]="$(gen_pw)"
    printf '%s\n%s\n' "${PW[$u]}" "${PW[$u]}" | smbpasswd -s -a "$u" >/dev/null
  fi
  sed -i "/^$u  /d" "$PASSWORD_FILE"
  printf '%s  %s\n' "$u" "${PW[$u]}" >> "$PASSWORD_FILE"
  ok "$u: Samba password set (saved in $PASSWORD_FILE, readable by root only)"
done

# ---------------------------------------------------------------- 6. folders and boot files
step "Creating folders"
mkdir -p /srv/tftp /srv/backup /srv/logs /srv/http/winpe
mkdir -p /srv/images/{apps,drivers,images,names,tools,manifests}
chown -R publisher /srv/images /srv/http/winpe
chown root /srv/images/manifests
chown deploy:www-data /srv/logs
chmod 2775 /srv/logs
ok "/srv/{tftp,http,images,logs,backup} ready"

step "Placing boot files"
place() { [[ -f "$BOOT_FILES_DIR/$1" ]] && { cp -f "$BOOT_FILES_DIR/$1" "$2"; ok "$1 -> $2"; } || warn "$1 missing - not copied"; }
place ipxe-shim.efi /srv/tftp/
place ipxe.efi      /srv/tftp/
place wimboot       /srv/http/
place BCD           /srv/http/winpe/
place boot.sdi      /srv/http/winpe/
place boot.wim      /srv/http/winpe/

put_file /srv/http/boot.ipxe 644 <<EOF
#!ipxe
kernel http://${DEPLOY_IP}/wimboot
initrd -n BCD      http://${DEPLOY_IP}/winpe/BCD      BCD
initrd -n boot.sdi http://${DEPLOY_IP}/winpe/boot.sdi boot.sdi
initrd -n boot.wim http://${DEPLOY_IP}/winpe/boot.wim boot.wim
boot
EOF
[[ -f /srv/images/list.json ]] || { echo '[]' > /srv/images/list.json; ok "placeholder /srv/images/list.json (replace it with your image list later)"; }
chown -R publisher /srv/http/winpe
chmod -R a+rX /srv/http /srv/tftp /srv/images

# ---------------------------------------------------------------- 7. service configs
step "Writing service configs"
put_file /etc/dnsmasq.d/bench.conf 644 <<EOF
# Deploy network only. Never answer on the internet NIC (office LAN).
interface=$DEPLOY_NIC
bind-interfaces
except-interface=$INET_NIC
port=0
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,4h
dhcp-option=option:router
dhcp-authoritative
log-dhcp

enable-tftp
tftp-root=/srv/tftp

dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-userclass=set:ipxe,iPXE
dhcp-boot=tag:efi64,tag:!ipxe,ipxe-shim.efi
dhcp-boot=tag:ipxe,http://${DEPLOY_IP}/boot.ipxe
EOF

rm -f /etc/nginx/sites-enabled/default
put_file /etc/nginx/sites-available/bench 644 <<EOF
server {
    listen ${DEPLOY_IP}:80;
    root /srv/http;
    sendfile on; tcp_nopush on;
    keepalive_timeout 120; send_timeout 300;
    location = /images/list { default_type application/json; alias /srv/images/list.json; }
    location /images/  { alias /srv/images/images/;  autoindex on; }
    location /drivers/ { alias /srv/images/drivers/; autoindex on; }
    location /apps/    { alias /srv/images/apps/;    autoindex on; }
    location /logs/ {
        alias /srv/logs/;
        client_max_body_size 500m;
        dav_methods PUT MKCOL;
        create_full_put_path on;
        dav_access user:rw group:rw all:r;
    }
}
EOF
ln -sf /etc/nginx/sites-available/bench /etc/nginx/sites-enabled/bench
nginx -t 2>&1 | sed 's/^/       /'

[[ -f /etc/samba/smb.conf.orig ]] || cp -a /etc/samba/smb.conf /etc/samba/smb.conf.orig
put_file /etc/samba/smb.conf 644 <<EOF
[global]
   interfaces = $DEPLOY_NIC
   bind interfaces only = yes
   server min protocol = SMB2_10
   server signing = mandatory
   map to guest = never
   use sendfile = yes
   aio read size = 1

[deploy]
   path = /srv/images
   read only = yes
   valid users = deploy
   hosts allow = 10.10.10.0/24

[logs]
   path = /srv/logs
   read only = no
   valid users = deploy publisher nciadmin
   create mask = 0664
   directory mask = 2775
   hosts allow = 10.10.10.0/24

[publish]
   path = /srv/images
   read only = no
   valid users = publisher nciadmin
   admin users = nciadmin
   create mask = 0644
   directory mask = 0755
   map archive = no
   hosts allow = 10.10.10.0/24

[boot]
   path = /srv/http/winpe
   read only = no
   valid users = publisher nciadmin
   admin users = nciadmin
   hosts allow = 10.10.10.0/24
EOF
testparm -s >/dev/null 2>&1 && ok "Samba config is valid" || die "Samba config check failed. Run: testparm -s"

# ---------------------------------------------------------------- 8. start and verify
step "Starting services"
systemctl disable --now nmbd samba-ad-dc >/dev/null 2>&1 || true
systemctl enable dnsmasq nginx smbd >/dev/null 2>&1
systemctl restart dnsmasq nginx smbd
sleep 2

FAIL=0
for s in dnsmasq nginx smbd; do
  if systemctl is-active --quiet "$s"; then ok "$s is active"; else warn "$s is NOT active (see: journalctl -u $s -n 30 --no-pager)"; FAIL=1; fi
done

SS="$(ss -lntu 2>/dev/null || true)"
for port in 80 445; do
  if grep -E "[:.]${port}\b" <<<"$SS" | grep >/dev/null "0\.0\.0\.0:${port}\b"; then warn "port $port is open on ALL addresses (exposed on the office card)"; FAIL=1
  elif grep -E "[:.]${port}\b" <<<"$SS" | grep >/dev/null "${DEPLOY_IP}:${port}\b"; then ok "port $port listens only on ${DEPLOY_IP}"
  else warn "nothing is listening on port $port"; FAIL=1; fi
done
grep -qE '[:.]67\b' <<<"$SS" && ok "DHCP (UDP 67) is listening" || { warn "DHCP (UDP 67) is not listening"; FAIL=1; }
grep -qE "${DEPLOY_IP}:69\b" <<<"$SS" && ok "TFTP (UDP 69) is listening on ${DEPLOY_IP}" || { warn "TFTP (UDP 69) is not listening on ${DEPLOY_IP}"; FAIL=1; }

if curl -fs -m 5 "http://${DEPLOY_IP}/boot.ipxe" | grep >/dev/null '^#!ipxe'; then ok "boot script served over HTTP"; else warn "could not fetch http://${DEPLOY_IP}/boot.ipxe"; FAIL=1; fi
if curl -s -m 3 -o /dev/null "http://$(ip -4 -br addr show dev "$INET_NIC" | awk '{print $3}' | cut -d/ -f1)/boot.ipxe" 2>/dev/null; then warn "HTTP also answers on the office address"; FAIL=1; else ok "HTTP does not answer on the office address"; fi

# ---------------------------------------------------------------- 9. summary
step "Summary"
if [[ $FAIL -eq 0 ]]; then printf '  %sThe server is set up.%s\n' "$G" "$N"; else printf '  %sSet up, but some checks above need attention.%s\n' "$Y" "$N"; fi
printf '\n  Samba passwords (also in %s):\n' "$PASSWORD_FILE"
for u in deploy publisher nciadmin; do printf '    %-10s %s\n' "$u" "${PW[$u]:-(unchanged from an earlier run)}"; done
cat <<EOF

  Still to do:
EOF
if [[ ${#missing[@]} -gt 0 ]]; then
  cat <<EOF
    1. Copy the missing boot files (${missing[*]}) to this server, then run this script again
       with  --boot-files <folder>  (it is safe to re-run), or place them by hand:
         ipxe-shim.efi, ipxe.efi  -> /srv/tftp/
         wimboot                  -> /srv/http/
         BCD, boot.sdi, boot.wim  -> /srv/http/winpe/
EOF
fi
cat <<EOF
    - /srv/images/list.json is a placeholder ([]). Replace it with your image list once you have images.
    - Test: connect a PC to $DEPLOY_NIC, open its boot menu and choose "UEFI: PXE IPv4".
      Watch it with:  journalctl -u dnsmasq -f
    - Log of this run: $LOG_FILE
EOF
exit $FAIL
