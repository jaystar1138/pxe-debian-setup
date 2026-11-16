#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 jaystar1138. Released under the MIT licence; see the LICENSE file.
#
# build-unattended-iso.sh - builds a Debian 13 installer ISO that installs itself with no questions
# (like a Windows autounattend.xml) and then runs pxe-setup.sh on first boot.
#
# Run it on a Linux machine (Debian, Ubuntu, WSL). It needs: xorriso cpio gzip openssl wget sha256sum
#   sudo apt install xorriso cpio openssl wget
#
# WARNING: the ISO it makes ERASES A DISK without asking. Only boot it on a machine you mean to wipe.
#
#   ./build-unattended-iso.sh --boot-files ~/boot-files
#
# Then write the ISO to a USB stick (Balena Etcher, or Rufus in "DD mode") and boot the server from it.
#
set -euo pipefail

# ---------------------------------------------------------------- settings
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_TAG="v1.2.0"
CDIMAGE_BASE="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
RAW_BASE="https://raw.githubusercontent.com/jaystar1138/pxe-debian-setup"
ISO=""
ISO_SHA256=""
OUT="pxe-debian-unattended.iso"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pxe-debian-setup"
BOOT_FILES_DIR=""
BOOT_FILES_URL=""
SCRIPT_FILE=""
SCRIPT_URL=""
SETUP_ARGS=""
DISK="smallest"
DISK_MIN_GB=30
DISK_MAX_GB=4000
PASSWORDS="prompt"
HASH_FILE=""
SSH_KEY_FILE=""
HOSTNAME_VALUE="pxe-server"
ADMIN_USER="pxeadmin"
TIMEZONE="US/Central"
KEYBOARD="us"
LOCALE="en_US.UTF-8"
MIRROR="deb.debian.org"
FINISH="poweroff"
MENU_TIMEOUT=10
FIRST_BOOT=1
ASSUME_YES=0
BOOT_FILES=(ipxe-shim.efi ipxe.efi wimboot BCD boot.sdi boot.wim)

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s[ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$Y" "$N" "$*"; }
info() { printf '       %s\n' "$*"; }
die()  { printf '\n%s[error]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $0 [options]

Output
  --out FILE               the ISO to create (default: $OUT)
  --iso FILE               start from this Debian netinst ISO instead of downloading one
  --sha256 HASH            expected checksum of --iso (skipped if not given)

Boot files (the six PXE files are not in this repository)
  --boot-files DIR         copy the six files from DIR onto the ISO (they end up in /root on the server)
  --boot-files-url URL     the server downloads them from URL/<file> on first boot
  (neither)                the server is set up without boot files; copy them in later and re-run pxe-setup.sh

Which disk to erase
  --disk smallest          use the smallest internal disk, with a size guard (default)
  --disk /dev/sdX          always use this device
  --disk ask               stop and ask which disk (not fully unattended)
  --disk-min-gb N          with 'smallest': refuse if the disk is smaller than N GB (default: $DISK_MIN_GB)
  --disk-max-gb N          with 'smallest': refuse if the disk is larger than N GB (default: $DISK_MAX_GB)

Passwords for root and the admin account
  --passwords prompt       ask for both now; only hashes go on the ISO (default)
  --passwords generate     make random ones, print them once at the end
  --passwords hash-file    read root_hash=... and user_hash=... from --hash-file FILE (openssl passwd -6)
  --hash-file FILE
  --admin-user NAME        the login account to create (default: $ADMIN_USER)
  --ssh-key FILE           also allow this public key to log in as that account

Setup
  --setup-args "ARGS"      extra arguments for pxe-setup.sh, e.g. "--data-disk /dev/sdb --deploy-nic enp2s0"
  --script FILE            pxe-setup.sh to put on the ISO (default: ../pxe-setup.sh, else downloaded)
  --script-url URL         the server downloads pxe-setup.sh from URL on first boot (falls back to the copy on the ISO)
  --no-first-boot          install Debian only; do not run pxe-setup.sh

Machine
  --hostname NAME          (default: $HOSTNAME_VALUE)
  --timezone ZONE          (default: $TIMEZONE)      e.g. America/Chicago
  --keyboard LAYOUT        (default: $KEYBOARD)
  --locale LOCALE          (default: $LOCALE)
  --mirror HOST            Debian mirror (default: $MIRROR)
  --finish poweroff|reboot what to do when the install ends (default: $FINISH).
                           'reboot' can start the install again if the USB stick is left in.
  --menu-timeout SECONDS   countdown before the unattended entry starts (default: $MENU_TIMEOUT)
  --yes                    do not ask for confirmation
  -h, --help
EOF
}

# ---------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2 ;;
    --iso) ISO="${2:?}"; shift 2 ;;
    --sha256) ISO_SHA256="${2:?}"; shift 2 ;;
    --boot-files) BOOT_FILES_DIR="${2:?}"; shift 2 ;;
    --boot-files-url) BOOT_FILES_URL="${2:?}"; shift 2 ;;
    --disk) DISK="${2:?}"; shift 2 ;;
    --disk-min-gb) DISK_MIN_GB="${2:?}"; shift 2 ;;
    --disk-max-gb) DISK_MAX_GB="${2:?}"; shift 2 ;;
    --passwords) PASSWORDS="${2:?}"; shift 2 ;;
    --hash-file) HASH_FILE="${2:?}"; shift 2 ;;
    --ssh-key) SSH_KEY_FILE="${2:?}"; shift 2 ;;
    --setup-args) SETUP_ARGS="${2:-}"; shift 2 ;;
    --script) SCRIPT_FILE="${2:?}"; shift 2 ;;
    --script-url) SCRIPT_URL="${2:?}"; shift 2 ;;
    --no-first-boot) FIRST_BOOT=0; shift ;;
    --hostname) HOSTNAME_VALUE="${2:?}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?}"; shift 2 ;;
    --timezone) TIMEZONE="${2:?}"; shift 2 ;;
    --keyboard) KEYBOARD="${2:?}"; shift 2 ;;
    --locale) LOCALE="${2:?}"; shift 2 ;;
    --mirror) MIRROR="${2:?}"; shift 2 ;;
    --finish) FINISH="${2:?}"; shift 2 ;;
    --menu-timeout) MENU_TIMEOUT="${2:?}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------- checks
step "Checking the options and tools"
for t in xorriso cpio gzip openssl wget sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed. Try: sudo apt install xorriso cpio openssl wget"
done
ok "tools present"

case "$PASSWORDS" in prompt|generate|hash-file) ;; *) die "--passwords must be prompt, generate or hash-file" ;; esac
[[ "$PASSWORDS" != "hash-file" || -f "$HASH_FILE" ]] || die "--passwords hash-file needs --hash-file FILE (with root_hash= and user_hash= lines)"
case "$FINISH" in poweroff|reboot) ;; *) die "--finish must be poweroff or reboot" ;; esac
[[ "$MENU_TIMEOUT" =~ ^[0-9]+$ ]] || die "--menu-timeout must be a number of seconds"
[[ "$DISK_MIN_GB" =~ ^[0-9]+$ && "$DISK_MAX_GB" =~ ^[0-9]+$ ]] || die "--disk-min-gb and --disk-max-gb must be numbers"
case "$DISK" in smallest|ask|/dev/*) ;; *) die "--disk must be 'smallest', 'ask' or a device such as /dev/sda" ;; esac
[[ "$HOSTNAME_VALUE" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "--hostname '$HOSTNAME_VALUE' is not a valid host name"
[[ "$ADMIN_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "--admin-user must be a simple lower-case account name"
case "$ADMIN_USER" in deploy|publisher|root) die "--admin-user cannot be '$ADMIN_USER'" ;; esac
[[ -z "$SSH_KEY_FILE" || -f "$SSH_KEY_FILE" ]] || die "--ssh-key file not found: $SSH_KEY_FILE"
[[ -z "$SETUP_ARGS$BOOT_FILES_URL$SCRIPT_URL" || "$FIRST_BOOT" -eq 1 ]] || warn "--no-first-boot: --setup-args and the URL options are ignored"
# these values go into a shell file on the ISO, so refuse anything that could break out of it
for v in "$SETUP_ARGS" "$BOOT_FILES_URL" "$SCRIPT_URL" "$TIMEZONE" "$KEYBOARD" "$LOCALE" "$MIRROR"; do
  [[ "$v" != *[\'\"\`\$\\]* ]] || die "Quotes, backticks, \$ and backslashes are not allowed in option values: $v"
done

if [[ -n "$BOOT_FILES_DIR" ]]; then
  [[ -d "$BOOT_FILES_DIR" ]] || die "--boot-files: $BOOT_FILES_DIR is not a folder"
  missing=()
  for f in "${BOOT_FILES[@]}"; do [[ -f "$BOOT_FILES_DIR/$f" ]] || missing+=("$f"); done
  [[ ${#missing[@]} -eq 0 ]] || die "--boot-files: missing in $BOOT_FILES_DIR: ${missing[*]}"
  ok "six boot files found in $BOOT_FILES_DIR"
fi
[[ -z "$BOOT_FILES_DIR" || -z "$BOOT_FILES_URL" ]] || die "Use either --boot-files or --boot-files-url, not both."

# ---------------------------------------------------------------- passwords
step "Passwords"
ROOT_PW=""; USER_PW=""
hash_pw() { printf '%s' "$1" | openssl passwd -6 -stdin; }
case "$PASSWORDS" in
  prompt)
    for who in root "$ADMIN_USER"; do
      while :; do
        read -r -s -p "  Password for $who: " p1; echo
        read -r -s -p "  Again: " p2; echo
        [[ -n "$p1" && "$p1" == "$p2" ]] && break
        warn "empty or not matching, try again"
      done
      [[ "$who" == "root" ]] && ROOT_PW="$p1" || USER_PW="$p1"
    done
    ROOT_HASH="$(hash_pw "$ROOT_PW")"; USER_HASH="$(hash_pw "$USER_PW")"; ROOT_PW=""; USER_PW="" ;;
  generate)
    gen() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
    ROOT_PW="$(gen)"; USER_PW="$(gen)"
    ROOT_HASH="$(hash_pw "$ROOT_PW")"; USER_HASH="$(hash_pw "$USER_PW")" ;;
  hash-file)
    ROOT_HASH="$(grep -m1 '^root_hash=' "$HASH_FILE" | cut -d= -f2-)"
    USER_HASH="$(grep -m1 '^user_hash=' "$HASH_FILE" | cut -d= -f2-)"
    [[ "$ROOT_HASH" == \$6\$* && "$USER_HASH" == \$6\$* ]] || die "$HASH_FILE must contain root_hash= and user_hash= lines holding SHA-512 hashes (start with \$6\$)" ;;
esac
ok "password hashes ready (no plain-text passwords go on the ISO)"

# ---------------------------------------------------------------- confirm
if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\n%sThe ISO this makes ERASES A DISK without asking.%s\n' "$R" "$N"
  printf '  disk choice : %s\n  when done   : %s\n  first boot  : %s\n' "$DISK" "$FINISH" "$([[ $FIRST_BOOT -eq 1 ]] && echo "runs pxe-setup.sh" || echo "nothing")"
  read -r -p "Build it? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled."
fi

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ---------------------------------------------------------------- the Debian ISO
step "Getting the Debian netinst ISO"
if [[ -z "$ISO" ]]; then
  mkdir -p "$CACHE_DIR"
  sums="$(wget -qO- "$CDIMAGE_BASE/SHA256SUMS")" || die "Could not reach $CDIMAGE_BASE (no internet?). Use --iso FILE to supply an ISO."
  name="$(awk '/-amd64-netinst\.iso$/ {print $2; exit}' <<<"$sums")"
  [[ -n "$name" ]] || die "Could not find the netinst ISO name in $CDIMAGE_BASE/SHA256SUMS"
  ISO_SHA256="$(awk -v n="$name" '$2==n {print $1}' <<<"$sums")"
  ISO="$CACHE_DIR/$name"
  if [[ -f "$ISO" ]] && [[ "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$ISO_SHA256" ]]; then ok "using cached $name"
  else info "downloading $name (about 800 MB)"; wget -q --show-progress -O "$ISO" "$CDIMAGE_BASE/$name"; fi
fi
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
if [[ -n "$ISO_SHA256" ]]; then
  [[ "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$ISO_SHA256" ]] && ok "checksum matches" || die "Checksum of $ISO does not match. Delete it and try again."
else warn "no --sha256 given for $ISO; its checksum was not verified"; fi

step "Reading the ISO"
has() { xorriso -indev "$ISO" -find "$1" -maxdepth 0 2>/dev/null | grep -q . ; }
has /install.amd/initrd.gz || die "$ISO has no /install.amd/initrd.gz. Use a Debian 13 amd64 netinst ISO."
has /boot/grub/grub.cfg    || die "$ISO has no /boot/grub/grub.cfg."
BIOS_BOOT=0; has /isolinux/txt.cfg && BIOS_BOOT=1
mkdir -p "$W/x"
xorriso -osirrox on -indev "$ISO" \
  -extract /install.amd/initrd.gz "$W/x/initrd.gz" \
  -extract /boot/grub/grub.cfg "$W/x/grub.cfg" >/dev/null 2>&1
if [[ $BIOS_BOOT -eq 1 ]]; then
  xorriso -osirrox on -indev "$ISO" \
    -extract /isolinux/txt.cfg "$W/x/txt.cfg" \
    -extract /isolinux/isolinux.cfg "$W/x/isolinux.cfg" >/dev/null 2>&1
  for f in gtk.cfg spkgtk.cfg; do
    has "/isolinux/$f" && xorriso -osirrox on -indev "$ISO" -extract "/isolinux/$f" "$W/x/$f" >/dev/null 2>&1 || true
  done
  ok "BIOS (isolinux) and UEFI (GRUB) boot menus found"
else
  warn "no isolinux menu on this ISO; only the UEFI menu will be set to unattended"
fi
chmod -R u+w "$W/x"

# ---------------------------------------------------------------- files that go on the ISO under /pxe
step "Preparing the unattended files"
P="$W/pxe"; mkdir -p "$P"

# the script
if [[ -z "$SCRIPT_FILE" ]]; then
  if [[ -f "$HERE/../pxe-setup.sh" ]]; then SCRIPT_FILE="$HERE/../pxe-setup.sh"
  else
    wget -q -O "$W/pxe-setup.sh" "$RAW_BASE/$RELEASE_TAG/pxe-setup.sh" || die "Could not download pxe-setup.sh. Use --script FILE."
    SCRIPT_FILE="$W/pxe-setup.sh"
  fi
fi
[[ -f "$SCRIPT_FILE" ]] || die "--script file not found: $SCRIPT_FILE"
bash -n "$SCRIPT_FILE" || die "$SCRIPT_FILE has a syntax error."
cp "$SCRIPT_FILE" "$P/pxe-setup.sh"; ok "pxe-setup.sh included ($(wc -l < "$P/pxe-setup.sh") lines)"

if [[ -n "$BOOT_FILES_DIR" ]]; then
  mkdir -p "$P/boot-files"
  for f in "${BOOT_FILES[@]}"; do cp "$BOOT_FILES_DIR/$f" "$P/boot-files/$f"; done
  ok "boot files included ($(du -sh "$P/boot-files" | cut -f1))"
fi
[[ -z "$SSH_KEY_FILE" ]] || { cp "$SSH_KEY_FILE" "$P/authorized_keys"; ok "SSH key included for $ADMIN_USER"; }

cat > "$P/install.conf" <<EOF
DISK_MODE='$DISK'
DISK_MIN_GB='$DISK_MIN_GB'
DISK_MAX_GB='$DISK_MAX_GB'
HOSTNAME_VALUE='$HOSTNAME_VALUE'
ADMIN_USER='$ADMIN_USER'
FIRST_BOOT='$FIRST_BOOT'
EOF

cat > "$P/firstboot.conf" <<EOF
SETUP_ARGS='--admin-user $ADMIN_USER $SETUP_ARGS'
SCRIPT_URL='$SCRIPT_URL'
BOOT_FILES_URL='$BOOT_FILES_URL'
EOF

# runs in the installer, before partitioning: choose the disk
cat > "$P/select-disk.sh" <<'EOF'
#!/bin/sh
# Chooses the disk to erase. Runs inside the Debian installer (busybox sh).
. /cdrom/pxe/install.conf
say() { echo "PXE-UNATTENDED: $*" > /dev/console 2>/dev/null; logger -t pxe-unattended "$*"; }
stop_install() {
  say "$*"; say "Installation stopped. Nothing was erased. Powering off in 60 seconds."
  # the reason is in the installer log (Alt+F4 on the machine's screen)
  sleep 60; poweroff -f 2>/dev/null || halt -f
  exit 1
}
case "$DISK_MODE" in
  ask) say "disk selection: the installer will ask"; exit 0 ;;
  /dev/*)
    [ -b "$DISK_MODE" ] || stop_install "disk $DISK_MODE does not exist"
    debconf-set partman-auto/disk "$DISK_MODE"; debconf-set grub-installer/bootdev "$DISK_MODE"
    say "using $DISK_MODE"; exit 0 ;;
esac
# find the disk the installer itself was started from, so it is never chosen
media=$(awk '$2=="/cdrom" {print $1; exit}' /proc/mounts)
mediadisk=""
if [ -n "$media" ]; then
  m=${media#/dev/}
  p=$(readlink -f "/sys/class/block/$m" 2>/dev/null)
  case "$p" in */block/*/*) mediadisk=$(basename "$(dirname "$p")") ;; *) mediadisk=$m ;; esac
fi
best=""; bestgb=0
for d in $(list-devices disk); do
  n=${d#/dev/}
  [ "$n" = "$mediadisk" ] && continue
  [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" = "1" ] && continue
  sectors=$(cat "/sys/block/$n/size" 2>/dev/null) || continue
  gb=$((sectors / 2097152))
  say "found $d: ${gb} GB"
  if [ -z "$best" ] || [ "$gb" -lt "$bestgb" ]; then best=$d; bestgb=$gb; fi
done
[ -n "$best" ] || stop_install "no internal disk found"
if [ "$bestgb" -lt "$DISK_MIN_GB" ] || [ "$bestgb" -gt "$DISK_MAX_GB" ]; then
  stop_install "the smallest disk ($best, ${bestgb} GB) is outside the allowed range ${DISK_MIN_GB}-${DISK_MAX_GB} GB"
fi
say "ERASING $best (${bestgb} GB)"
debconf-set partman-auto/disk "$best"
debconf-set grub-installer/bootdev "$best"
EOF

# runs in the installer, after the system is installed: put files on the new system
cat > "$P/late.sh" <<'EOF'
#!/bin/sh
# Runs inside the Debian installer after the base system is installed.
. /cdrom/pxe/install.conf
T=/target
echo "$HOSTNAME_VALUE" > $T/etc/hostname
if grep -q '^127.0.1.1' $T/etc/hosts 2>/dev/null; then sed -i "s/^127.0.1.1.*/127.0.1.1\t$HOSTNAME_VALUE/" $T/etc/hosts
else printf '127.0.1.1\t%s\n' "$HOSTNAME_VALUE" >> $T/etc/hosts; fi
mkdir -p $T/root $T/usr/local/sbin
cp /cdrom/pxe/pxe-setup.sh $T/root/pxe-setup.sh; chmod 700 $T/root/pxe-setup.sh
[ -d /cdrom/pxe/boot-files ] && cp -a /cdrom/pxe/boot-files/. $T/root/
if [ -f /cdrom/pxe/authorized_keys ]; then
  mkdir -p $T/home/$ADMIN_USER/.ssh
  cp /cdrom/pxe/authorized_keys $T/home/$ADMIN_USER/.ssh/authorized_keys
  chmod 700 $T/home/$ADMIN_USER/.ssh; chmod 600 $T/home/$ADMIN_USER/.ssh/authorized_keys
  in-target chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
fi
if [ "$FIRST_BOOT" = "1" ]; then
  cp /cdrom/pxe/pxe-firstboot.sh $T/usr/local/sbin/pxe-firstboot.sh; chmod 755 $T/usr/local/sbin/pxe-firstboot.sh
  cp /cdrom/pxe/pxe-firstboot.service $T/etc/systemd/system/pxe-firstboot.service
  cp /cdrom/pxe/firstboot.conf $T/etc/pxe-firstboot.conf; chmod 600 $T/etc/pxe-firstboot.conf
  in-target systemctl enable pxe-firstboot.service
fi
EOF

# runs on the new server, first boot: run pxe-setup.sh
cat > "$P/pxe-firstboot.service" <<'EOF'
[Unit]
Description=Finish PXE server setup (first boot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/pxe-firstboot.conf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pxe-firstboot.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

cat > "$P/pxe-firstboot.sh" <<'EOF'
#!/bin/bash
# Runs once on the new server: waits for the network, fetches anything missing, runs pxe-setup.sh.
# It tries up to 3 boots, then gives up. Result: /root/PXE-SETUP-RESULT.txt and /etc/motd.
set -u
. /etc/pxe-firstboot.conf
LOG=/var/log/pxe-firstboot.log
umask 077
exec >>"$LOG" 2>&1
echo "=== pxe-firstboot $(date -Is) ==="

COUNT_FILE=/var/lib/pxe-firstboot.count
tries=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); echo "$tries" > "$COUNT_FILE"

for i in $(seq 1 90); do ip -4 route show default | grep -q . && break; sleep 2; done
ip -4 route show default | grep -q . || echo "no default route after 3 minutes; trying anyway"

cd /root || exit 1
if [[ -n "$SCRIPT_URL" ]]; then
  wget -q -O /root/pxe-setup.sh.new "$SCRIPT_URL" && bash -n /root/pxe-setup.sh.new && mv /root/pxe-setup.sh.new /root/pxe-setup.sh \
    || { echo "could not use $SCRIPT_URL; using the copy from the ISO"; rm -f /root/pxe-setup.sh.new; }
fi
chmod 700 /root/pxe-setup.sh
if [[ -n "$BOOT_FILES_URL" ]]; then
  for f in ipxe-shim.efi ipxe.efi wimboot BCD boot.sdi boot.wim; do
    [[ -s "/root/$f" ]] || wget -q -c -O "/root/$f" "${BOOT_FILES_URL%/}/$f" || echo "could not download $f"
  done
fi

# shellcheck disable=SC2086
/root/pxe-setup.sh --yes --boot-files /root $SETUP_ARGS
rc=$?

if [[ $rc -eq 0 ]]; then
  msg="PXE server setup finished OK on $(date -Is). Samba passwords: /root/pxe-setup-passwords.txt. Log: /var/log/pxe-setup.log"
  echo "$msg" > /root/PXE-SETUP-RESULT.txt
  printf '\n%s\n\n' "$msg" > /etc/motd
  systemctl disable pxe-firstboot.service; rm -f /etc/pxe-firstboot.conf
else
  msg="PXE server setup did NOT finish (exit $rc, attempt $tries of 3). Read /var/log/pxe-setup.log and /var/log/pxe-firstboot.log. Fix the cause, then run: /root/pxe-setup.sh"
  echo "$msg" > /root/PXE-SETUP-RESULT.txt
  printf '\n%s\n\n' "$msg" > /etc/motd
  if [[ $tries -ge 3 ]]; then systemctl disable pxe-firstboot.service; fi
fi
exit 0
EOF
chmod 755 "$P"/*.sh
ok "installer helpers written"

# ---------------------------------------------------------------- the answer file (preseed)
case "$FINISH" in poweroff) FINISH_LINE='d-i debian-installer/exit/poweroff boolean true' ;; *) FINISH_LINE='# reboot when finished' ;; esac
cat > "$W/preseed.cfg" <<EOF
# Generated by build-unattended-iso.sh. Answers every Debian installer question.
d-i debian-installer/locale string $LOCALE
d-i keyboard-configuration/xkb-keymap select $KEYBOARD
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $HOSTNAME_VALUE
d-i netcfg/get_domain string
d-i netcfg/wireless_wep string
d-i mirror/country string manual
d-i mirror/http/hostname string $MIRROR
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-password-crypted password $ROOT_HASH
d-i passwd/make-user boolean true
d-i passwd/user-fullname string $ADMIN_USER
d-i passwd/username string $ADMIN_USER
d-i passwd/user-password-crypted password $USER_HASH
d-i clock-setup/utc boolean true
d-i time/zone string $TIMEZONE
d-i clock-setup/ntp boolean false
d-i partman/early_command string sh /cdrom/pxe/select-disk.sh
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect ssh-server, standard
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/bootdev string default
d-i preseed/late_command string sh /cdrom/pxe/late.sh
$FINISH_LINE
d-i finish-install/reboot_in_progress note
EOF
ok "answer file written"

# put the answer file at the root of the installer's initial RAM disk, where Debian loads it by itself
mkdir -p "$W/irfs"; cp "$W/preseed.cfg" "$W/irfs/preseed.cfg"
( cd "$W/irfs" && echo preseed.cfg | cpio -H newc -o -R 0:0 --quiet | gzip -9 ) > "$W/preseed.cpio.gz"
cat "$W/x/initrd.gz" "$W/preseed.cpio.gz" > "$W/x/initrd.new.gz"

# ---------------------------------------------------------------- boot menus
step "Making the unattended entry the default"
LABEL="UNATTENDED install (ERASES A DISK)"
ARGS="auto=true priority=critical"
{
cat <<EOF
set default=0
set timeout=$MENU_TIMEOUT
menuentry --hotkey=u '$LABEL' {
    linux /install.amd/vmlinuz $ARGS --- quiet
    initrd /install.amd/initrd.gz
}

EOF
cat "$W/x/grub.cfg"
printf '\n# unattended: start the first entry after the countdown\nset default=0\nset timeout=%s\n' "$MENU_TIMEOUT"
} > "$W/x/grub.new"
ok "UEFI menu: '$LABEL' starts after $MENU_TIMEOUT s"

MAPS=(-map "$W/x/initrd.new.gz" /install.amd/initrd.gz -map "$W/x/grub.new" /boot/grub/grub.cfg)
if [[ $BIOS_BOOT -eq 1 ]]; then
  {
  printf 'label unattended\n\tmenu label ^%s\n\tmenu default\n\tkernel /install.amd/vmlinuz\n\tappend %s vga=788 initrd=/install.amd/initrd.gz --- quiet\n\n' "$LABEL" "$ARGS"
  sed '/^[[:space:]]*menu default/d' "$W/x/txt.cfg"
  } > "$W/x/txt.new"
  if grep -q '^timeout' "$W/x/isolinux.cfg"; then sed "s/^timeout.*/timeout $((MENU_TIMEOUT*10))/" "$W/x/isolinux.cfg" > "$W/x/isolinux.new"
  else { cat "$W/x/isolinux.cfg"; echo "timeout $((MENU_TIMEOUT*10))"; } > "$W/x/isolinux.new"; fi
  MAPS+=(-map "$W/x/txt.new" /isolinux/txt.cfg -map "$W/x/isolinux.new" /isolinux/isolinux.cfg)
  # Debian's graphical entry also claims to be the default, and the speech-synthesis file sets its own
  # timeout and "ontimeout" action later in the menu. Both would override ours, so rewrite them.
  if [[ -f "$W/x/gtk.cfg" ]]; then
    sed -e '/^[[:space:]]*default[[:space:]]/d' -e '/^[[:space:]]*menu default/d' "$W/x/gtk.cfg" > "$W/x/gtk.new"
    MAPS+=(-map "$W/x/gtk.new" /isolinux/gtk.cfg)
  fi
  if [[ -f "$W/x/spkgtk.cfg" ]]; then
    {
      sed -e '/^[[:space:]]*timeout[[:space:]]/d' -e '/^[[:space:]]*ontimeout[[:space:]]/d' -e '/^[[:space:]]*menu autoboot/d' "$W/x/spkgtk.cfg"
      printf 'timeout %s\nontimeout unattended\nmenu autoboot Starting the UNATTENDED install (it ERASES A DISK) in # second{,s}... Press a key to choose another entry.\n' "$((MENU_TIMEOUT*10))"
    } > "$W/x/spkgtk.new"
    MAPS+=(-map "$W/x/spkgtk.new" /isolinux/spkgtk.cfg)
  fi
  ok "BIOS menu: '$LABEL' starts after $MENU_TIMEOUT s"
fi

# ---------------------------------------------------------------- build
step "Building $OUT"
rm -f "$OUT"
xorriso -indev "$ISO" -outdev "$OUT" -boot_image any replay "${MAPS[@]}" -map "$P" /pxe -commit >"$W/xorriso.log" 2>&1 \
  || { tail -20 "$W/xorriso.log" >&2; die "xorriso failed (see above)."; }
[[ -s "$OUT" ]] || die "No ISO was produced."
ok "$OUT ($(du -h "$OUT" | cut -f1)), sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"

step "Done"
cat <<EOF
  1. Write $OUT to a USB stick: Balena Etcher, or Rufus in "DD mode". This erases the stick.
  2. Plug the INTERNET cable into the server. Leave the deploy cable out until the install ends.
  3. Boot the server from the USB stick. After a $MENU_TIMEOUT second countdown it installs by itself.
     The disk choice is: $DISK.
  4. The server $( [[ "$FINISH" == "poweroff" ]] && echo "powers off when the install ends. Remove the USB stick, plug in the deploy cable, power on." || echo "reboots when the install ends. Remove the USB stick first or it will install again." )
  5. $( [[ $FIRST_BOOT -eq 1 ]] && echo "On first boot it runs pxe-setup.sh by itself (about 5 minutes). Log in as $ADMIN_USER and read /etc/motd; the Samba passwords are in /root/pxe-setup-passwords.txt." || echo "Nothing runs automatically. Run pxe-setup.sh yourself as in the guide." )
EOF
if [[ "$PASSWORDS" == "generate" ]]; then
  printf '\n  Generated passwords (shown once, not stored):\n    root      %s\n    %-9s %s\n' "$ROOT_PW" "$ADMIN_USER" "$USER_PW"
fi
[[ $FIRST_BOOT -eq 0 || -n "$BOOT_FILES_DIR$BOOT_FILES_URL" ]] || warn "no boot files were given: the server is set up without them. Copy them to /root and run /root/pxe-setup.sh again."
