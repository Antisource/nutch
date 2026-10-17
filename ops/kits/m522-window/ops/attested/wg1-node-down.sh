#!/usr/bin/env bash
# Step 5.2.2, on a node: take the TEST mesh interface wg1 down and remove its config. The production mesh wg0 is not touched.
set -uo pipefail
SUDO="${W1_SUDO-sudo -n}"; WG="${W1_CONF_DIR:-/etc/wireguard}"; WGQ="${W1_WGQUICK:-wg-quick}"; IPB="${W1_IP:-ip}"
if $IPB link show wg1 >/dev/null 2>&1; then $SUDO $WGQ down wg1 >/dev/null 2>&1 || { echo "WG1-DOWN-STOP: wg-quick down wg1 failed" >&2; exit 1; }; fi
$SUDO rm -f "$WG/wg1.conf"
$IPB link show wg1 >/dev/null 2>&1 && { echo "WG1-DOWN-STOP: wg1 is still there" >&2; exit 1; }
echo "WG1-DOWN-OK: wg1 is gone (wg0 was not touched)"
