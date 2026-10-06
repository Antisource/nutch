#!/usr/bin/env bash
# Run on a node: install the WireGuard tools, make a key pair if none exists, print ONLY the public key.
# The private key stays in /etc/wireguard (root only) and is never printed.
set -euo pipefail
WG="${WG_DIR:-/etc/wireguard}"
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wireguard-tools >/dev/null 2>&1 \
  || { echo "apt-get install wireguard-tools failed" >&2; exit 1; }
command -v wg >/dev/null || { echo "wg tool not found after install" >&2; exit 1; }
sudo install -d -m 700 "$WG"
if ! sudo test -s "$WG/private.key"; then
  sudo sh -c "umask 077; wg genkey > '$WG/private.key'"
fi
sudo sh -c "wg pubkey < '$WG/private.key' > '$WG/public.key'; chmod 644 '$WG/public.key'"
sudo cat "$WG/public.key"
