#!/usr/bin/env bash
# Prepare this VM for a safe one-time boot into Ubuntu 24.04's 6.17 gcp kernel.
# Backs up GRUB, pins the RUNNING kernel as the default, installs the 6.17 packages
# (checksum-verified), requests ONE boot into 6.17, then stops this node's Hadoop daemons.
# It does not reboot. It stops at the first problem.
set -euo pipefail
NEW=6.17.0-1022-gcp
RUN="$(uname -r)"
BOOT="${BOOT_DIR:-/boot}"
CFG="$BOOT/grub/grub.cfg"
GD="${GRUB_D:-/etc/default/grub.d}"
GF="${GRUB_FILE:-/etc/default/grub}"
EFI="${EFI_DIR:-/sys/firmware/efi}"
SBVAR="$EFI/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
URL=http://archive.ubuntu.com/ubuntu/pool/main/l
IMG="linux-image-6.17.0-1022-gcp_6.17.0-1022.25_amd64.deb"
MOD="linux-modules-6.17.0-1022-gcp_6.17.0-1022.25_amd64.deb"
SHA_IMG="${DEB_SHA_IMAGE:-d7d0052d4534fdca991efaf32af81864b577b13e27f4e5449f4d663598ea3b96}"
SHA_MOD="${DEB_SHA_MODULES:-b0ecac54e326ebad0aee134ed55a785c564a4b97a22d3cdebb72bcbea39ec76f}"
fail() { echo "ABORT: $*" >&2; exit 1; }
say() { echo "== $*"; }

say "pre-flight"
case "$RUN" in 6.8.0-*-gcp) ;; *) fail "unexpected running kernel: $RUN" ;; esac
[ -d "$EFI" ] || fail "not an EFI boot"
SB="$(sudo od -An -t u1 "$SBVAR" | awk '{print $NF}')"
[ "$SB" = "0" ] || fail "Secure Boot is not off (value $SB)"
[ -f "$GD/40-force-partuuid.cfg" ] || fail "initrdless setup (40-force-partuuid.cfg) not found"
FREE_KB="$(df --output=avail / | tail -1 | tr -d ' ')"
[ "$FREE_KB" -gt 1500000 ] || fail "less than 1.5 GB free on /"
TITLE="Ubuntu, with Linux $RUN"
sudo grep -q "menuentry '$TITLE' " "$CFG" || fail "no GRUB menu entry for the running kernel"
if yarn application -list -appStates RUNNING 2>/dev/null | grep -q '^application_'; then fail "a Hadoop application is running"; fi
echo "running kernel $RUN, ${FREE_KB} KB free, Secure Boot off"

say "backup GRUB files"
B="/root/grub-backup-$(date +%Y%m%d%H%M%S)"
sudo mkdir -p "$B"
sudo cp -a "$GF" "$GD" "$CFG" "$B"/
echo "saved in $B"

say "pin the running kernel as the default"
echo 'GRUB_DEFAULT=saved' | sudo tee "$GD/zz-saved-default.cfg" >/dev/null
sudo update-grub >/dev/null 2>&1 || fail "update-grub failed"
sudo grub-set-default "Advanced options for Ubuntu>$TITLE"
sudo grub-editenv list | grep -qxF "saved_entry=Advanced options for Ubuntu>$TITLE" || fail "pin not recorded"
sudo grep -qF 'set default="${saved_entry}"' "$CFG" || fail "grub.cfg does not use the saved entry"
echo "pinned: $TITLE"

say "download and verify the 6.17 packages"
D="$HOME/k617"; mkdir -p "$D"; cd "$D"
curl -fsSO "$URL/linux-signed-gcp-6.17/$IMG"
curl -fsSO "$URL/linux-gcp-6.17/$MOD"
printf '%s  %s\n' "$SHA_IMG" "$IMG" "$SHA_MOD" "$MOD" | sha256sum --strict -c - || fail "package checksum mismatch"

say "install"
sudo dpkg -i "$MOD" "$IMG" > "$D/dpkg.log" 2>&1 || { tail -30 "$D/dpkg.log"; fail "dpkg failed"; }
[ -f "$BOOT/vmlinuz-$NEW" ] || fail "kernel file missing after install"
grep -q '^CONFIG_TSM_MEASUREMENTS=y' "$BOOT/config-$NEW" || fail "measurement option not enabled in installed kernel"
sudo grep -q "menuentry 'Ubuntu, with Linux $NEW' " "$CFG" || fail "no GRUB menu entry for $NEW"
sudo grub-editenv list | grep -qxF "saved_entry=Advanced options for Ubuntu>$TITLE" || fail "pin changed by the install"
echo "installed $NEW; pin still $RUN"

say "request ONE boot into $NEW"
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux $NEW"
sudo grub-editenv list | grep -qxF "next_entry=Advanced options for Ubuntu>Ubuntu, with Linux $NEW" || fail "one-time boot not recorded"
sudo grub-editenv list

say "stop this node's Hadoop daemons"
yarn --daemon stop nodemanager || true
hdfs --daemon stop datanode || true
sleep 5
jps
echo
echo "READY. If everything above looks right, run:  sudo reboot"
