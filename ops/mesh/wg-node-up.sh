#!/usr/bin/env bash
# Run on a node: write /etc/wireguard/wg0.conf for one peer and bring wg0 up.
# Usage: wg-node-up.sh <this-node-mesh-ip> <peer-public-key> <peer-vpc-ip> <peer-mesh-ip>
set -euo pipefail
SELF="$1"; PEERPUB="$2"; PEERVPC="$3"; PEERMESH="$4"
WG="${WG_DIR:-/etc/wireguard}"
[ "${#PEERPUB}" -eq 44 ] || { echo "peer public key is not 44 characters" >&2; exit 1; }
sudo test -s "$WG/private.key" || { echo "no private key in $WG" >&2; exit 1; }
if ip link show wg0 >/dev/null 2>&1; then echo "wg0 already exists; run: sudo wg-quick down wg0" >&2; exit 1; fi
KEY="$(sudo cat "$WG/private.key")"
sudo sh -c "umask 077; cat > '$WG/wg0.conf'" <<CONF
[Interface]
Address = ${SELF}/24
ListenPort = 51820
PrivateKey = ${KEY}

[Peer]
PublicKey = ${PEERPUB}
AllowedIPs = ${PEERMESH}/32
Endpoint = ${PEERVPC}:51820
PersistentKeepalive = 25
CONF
sudo wg-quick up wg0 >/dev/null 2>&1 || { echo "wg-quick up failed; details:" >&2; sudo wg-quick up wg0; exit 1; }
sudo systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
echo "wg0 is up with mesh address ${SELF}"
