#!/usr/bin/env bash
# Step 5.2.2, part 1: a node asks the hardware for a quote that binds its WireGuard PUBLIC key (and the mesh address that it asks for) to this machine. Nothing on the cluster
# changes: it reads the public key, writes one file, and asks the TDX guest interface for a quote (sudo, as attest/quote.sh always did).
#   bash node-attest.sh OUTFILE MESH_IP        e.g.  bash node-attest.sh ~/node-bundle-tdx-lab.attestnode 10.20.0.1
# The file is an ATTESTED-NODE-BUNDLE: a statement (host, WireGuard public key, requested mesh address, time, random nonce) and the quote whose REPORTDATA is the SHA-512 of that
# statement, the same rule as the signing keys' bundles. The reader (the admission step) decides whether the quote is genuine and whether the address is allowed for this host.
set -uo pipefail
OUT="${1:?usage: $0 OUTFILE MESH_IP}"; MIP="${2:?usage: $0 OUTFILE MESH_IP}"
KITDIR="$(cd "$(dirname "$0")" && pwd)"; QUOTE="${NA_QUOTE:-$KITDIR/quote.sh}"; VB="${NA_VERIFY:-$KITDIR/verify-binding.sh}"; WGPUB="${NA_WGPUB:-/etc/wireguard/public.key}"; HOST="${NA_HOST:-$(hostname)}"
# /etc/wireguard is root only (mode 700, made by wg-node-prep.sh), so the key file and the running interface are read with sudo, as the quote is
SUDO="${NA_SUDO-sudo -n}"; WGSHOW="${NA_WGSHOW-$SUDO wg show wg0 public-key}"
stop() { echo "NODE-ATTEST-STOP: $*" >&2; rm -rf "${W:-/nonexistent-dir}"; exit 1; }
[ ! -e "$OUT" ] || stop "$OUT exists already; move it away"
PUB="$($SUDO cat "$WGPUB" 2>/dev/null | tr -d ' \n\r')"
[ -n "$PUB" ] || stop "the WireGuard public key cannot be read: $WGPUB (the folder is root only, so this needs sudo without a password)"
printf '%s' "$PUB" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || stop "the file $WGPUB does not hold a WireGuard public key (44 base64 characters)"
LIVE="$(eval "$WGSHOW" 2>/dev/null | tr -d ' \n\r')"
if [ -n "$LIVE" ]; then
  [ "$LIVE" = "$PUB" ] || stop "the key of the running wg0 (${LIVE:0:10}...) is not the key in $WGPUB (${PUB:0:10}...): attest the key that is really in use, or fix the file"
  echo "   ok: the public key in $WGPUB is the key that the running wg0 uses (${PUB:0:10}...)"
else
  echo "   note: wg0 is not up here, so the key file is used (${PUB:0:10}...)"
fi
printf '%s' "$MIP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || stop "the mesh address is not an IPv4 address: $MIP"
printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9._-]{1,63}$' || stop "the host name is not usable: $HOST"
[ -f "$QUOTE" ] && [ -f "$VB" ] || stop "the quote script or verify-binding.sh is missing next to this script"
W="$(mktemp -d)" || stop "no temporary folder"
NONCE="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
printf 'ATTESTED-NODE-STATEMENT 1\nhost=%s\nmesh-public=%s\nmesh-ip=%s\ncreated=%s\nnonce=%s\n' "$HOST" "$PUB" "$MIP" "$(date -u +%FT%TZ)" "$NONCE" > "$W/statement.txt"
bash "$QUOTE" "$W/statement.txt" "$W/quote.bin" >"$W/quote.log" 2>&1 || { tail -3 "$W/quote.log" | sed 's/^/   | /' >&2; stop "the quote could not be made (a TDX guest, sudo and xxd are needed)"; }
[ -s "$W/quote.bin" ] || stop "the quote file is empty"
bash "$VB" "$W/statement.txt" "$W/quote.bin" 2>&1 | grep -q '^MATCH' || stop "the quote's REPORTDATA is not the SHA-512 of the statement"
{ echo "ATTESTED-NODE-BUNDLE 1"; echo "statement=$(base64 -w0 "$W/statement.txt")"; echo "quote=$(base64 -w0 "$W/quote.bin")"; } > "$OUT" || stop "could not write $OUT"
echo "NODE-ATTEST-OK host=$HOST mesh-public=${PUB:0:10}... mesh-ip=$MIP quote=$(stat -c %s "$W/quote.bin") bytes -> $OUT"
rm -rf "$W"
