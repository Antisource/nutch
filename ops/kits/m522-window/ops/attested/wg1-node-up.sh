#!/usr/bin/env bash
# Step 5.2.2, on a node: bring up the TEST mesh interface wg1 with exactly the peers that the doorman admitted. The production mesh wg0 and Hadoop are not touched.
#   bash wg1-node-up.sh SELF_MESH_IP PEER...        where each PEER is  PUBLICKEY,MESH_IP,VPC_IP
# wg1 uses the node's own WireGuard private key (the key whose public half the quote attested), another address (the mesh address of the policy table, /24) and UDP port 51821.
set -uo pipefail
SELF="${1:?usage: $0 SELF_MESH_IP PEER...}"; shift
[ $# -ge 1 ] || { echo "WG1-UP-STOP: no peer given: the doorman admitted nobody else" >&2; exit 1; }
SUDO="${W1_SUDO-sudo -n}"; WG="${W1_CONF_DIR:-/etc/wireguard}"; WGQ="${W1_WGQUICK:-wg-quick}"; WGB="${W1_WG:-wg}"; IPB="${W1_IP:-ip}"; PORT="${W1_PORT:-51821}"
stop() { echo "WG1-UP-STOP: $*" >&2; exit 1; }
printf '%s' "$SELF" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || stop "the mesh address is not an IPv4 address: $SELF"
$IPB link show wg1 >/dev/null 2>&1 && stop "wg1 exists already; run wg1-node-down.sh first"
$SUDO test -s "$WG/private.key" || stop "no private key in $WG (a root-only folder: this needs sudo without a password)"
CONF=""
for P in "$@"; do
  IFS=, read -r KEY IP VPC EXTRA <<<"$P"
  [ -z "${EXTRA:-}" ] || stop "a peer must be PUBLICKEY,MESH_IP,VPC_IP: $P"
  printf '%s' "$KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || stop "a peer key is not a WireGuard public key: ${KEY:0:12}"
  printf '%s' "$IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || stop "a peer's mesh address is not an address: $IP"
  printf '%s' "$VPC" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || stop "a peer's VPC address is not an address: $VPC"
  [ "$IP" != "$SELF" ] || stop "a peer has this node's own mesh address: $IP"
  CONF="$CONF
[Peer]
PublicKey = $KEY
AllowedIPs = $IP/32
Endpoint = $VPC:$PORT
PersistentKeepalive = 25
"
done
PRIV="$($SUDO cat "$WG/private.key" 2>/dev/null)"; [ -n "$PRIV" ] || stop "the private key cannot be read"
printf '[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\n%s' "$SELF" "$PORT" "$PRIV" "$CONF" | $SUDO sh -c "umask 077; cat > '$WG/wg1.conf'" || stop "could not write $WG/wg1.conf"
unset PRIV
$SUDO $WGQ up wg1 >/dev/null 2>&1 || { echo "wg-quick up wg1 failed; details:" >&2; $SUDO $WGQ up wg1 >&2; $SUDO rm -f "$WG/wg1.conf"; stop "wg1 did not come up (the config was removed)"; }
echo "WG1-UP-OK: wg1 is up with mesh address $SELF and $# peer(s): $(for P in "$@"; do printf '%s ' "${P%%,*}" | cut -c1-10; done)"
