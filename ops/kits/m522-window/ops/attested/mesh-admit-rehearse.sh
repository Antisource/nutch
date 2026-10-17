#!/usr/bin/env bash
# Rehearsal of mesh-admit.sh, wg1-node-up.sh and wg1-node-down.sh away from the cluster: the REAL scripts, the REAL doorman (the jar's Java code) and the two REAL node bundles of 17 October as what the
# nodes "make"; stand-ins for gcloud (it runs the command in a sandbox per node), sudo, wg, wg-quick, ip and ping, and --now for the doorman's clock (the real bundles are old). The fake nodes can be
# made to misbehave to show that every check of the build can fail.   Usage: bash mesh-admit-rehearse.sh KITDIR JAR VECTORS_DIR REFERENCE
set -uo pipefail
KIT="$1"; JAR="$2"; VEC="$3"; REF="$4"; PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; mkdir -p "$R/fakebin"; export R
printf '# hosts that may join\ntdx-lab 10.20.0.1 10.128.0.2\ntdx-lab-worker 10.20.0.2 10.128.0.5\n' > "$R/policy.txt"
cat > "$R/fakebin/sudo" <<'EOS'
#!/bin/bash
[ "$1" = -n ] && shift
exec "$@"
EOS
cat > "$R/fakebin/wg" <<'EOS'
#!/bin/bash
S="$R/n/$FAKE_NODE/state"; CONF="$R/n/$FAKE_NODE/wg/wg1.conf"
case "$2 $3" in
  "wg1 public-key") if [ -n "${FAKE_WRONGKEY:-}" ]; then echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; else cat "$S/attested"; fi ;;
  "wg1 peers") grep '^PublicKey' "$CONF" 2>/dev/null | sed 's/PublicKey = //'; [ -n "${FAKE_EXTRA_PEER:-}" ] && echo "EXTRA0000000000000000000000000000000000000000="; true ;;
  "wg1 latest-handshakes") for k in $(grep '^PublicKey' "$CONF" 2>/dev/null | sed 's/PublicKey = //'); do printf '%s\t%s\n' "$k" "$([ -n "${FAKE_NOHS:-}" ] && echo 0 || echo 1760000000)"; done ;;
  "wg0 peers") cat "$R/n/$FAKE_NODE/wg0-peers"; [ -f "$S/wg1-up" ] && [ -n "${FAKE_WG0_CHANGES:-}" ] && echo "CHANGED00000000000000000000000000000000000000="; true ;;
  *) exit 2 ;;
esac
EOS
cat > "$R/fakebin/wg-quick" <<'EOS'
#!/bin/bash
S="$R/n/$FAKE_NODE/state"
case "$1 $2" in
  "up wg1") [ -n "${FAKE_WGUP_FAIL:-}" ] && { echo "wg-quick: fake failure" >&2; exit 1; }; [ -s "$R/n/$FAKE_NODE/wg/wg1.conf" ] || exit 1; touch "$S/wg1-up" ;;
  "down wg1") rm -f "$S/wg1-up" ;;
  *) exit 2 ;;
esac
EOS
cat > "$R/fakebin/ip" <<'EOS'
#!/bin/bash
[ "$1 $2 $3" = "link show wg1" ] && [ -f "$R/n/$FAKE_NODE/state/wg1-up" ]
EOS
cat > "$R/fakebin/ping" <<'EOS'
#!/bin/bash
[ -n "${FAKE_PING_FAIL:-}" ] && { echo "3 packets transmitted, 0 received, 100% packet loss, time 2000ms"; exit 1; }
if [ -f "$R/n/tdx-lab/state/wg1-up" ] && [ -f "$R/n/tdx-lab-worker/state/wg1-up" ]; then echo "3 packets transmitted, 3 received, 0% packet loss, time 2003ms"; echo "rtt min/avg/max/mdev = 0.4/0.5/0.6/0.1 ms"; else echo "3 packets transmitted, 0 received, 100% packet loss"; exit 1; fi
EOS
chmod +x "$R/fakebin"/*
cat > "$R/gcloud" <<'EOS'
#!/bin/bash
# a fake gcloud: "compute ssh HOST --zone=Z --command=CMD" runs CMD in the sandbox of HOST; "compute scp" copies between the sandboxes and local folders
shift  # compute
op="$1"; shift
if [ "$op" = ssh ] || [ "$op" = scp ]; then cat >/dev/null 2>&1 <&0 || true; fi   # the real ssh and scp read the standard input
if [ "$op" = ssh ]; then
  H="$1"; shift; CMD=""; for a in "$@"; do case "$a" in --command=*) CMD="${a#--command=}" ;; esac; done
  home="$R/n/$H/home"; [ -d "$home" ] || { echo "no such node $H" >&2; exit 1; }
  if [[ "$CMD" == *node-attest.sh* ]]; then
    [ "${FAKE_ATTEST_FAIL:-}" = "$H" ] && { echo "NODE-ATTEST-STOP: the quote could not be made (a TDX guest, sudo and xxd are needed)" >&2; exit 1; }
    ip="${CMD##* }"; cp "$FAKE_VECTORS/node-bundle-$H.attestnode" "$home/node-bundle-$H.attestnode"
    echo "NODE-ATTEST-OK host=$H mesh-public=xxxxxxxxxx... mesh-ip=$ip quote=8000 bytes -> $home/node-bundle-$H.attestnode"; exit 0
  fi
  cd "$home" && HOME="$home" FAKE_NODE="$H" PATH="$R/fakebin:$PATH" W1_SUDO="" W1_CONF_DIR="$R/n/$H/wg" W1_WGQUICK="$R/fakebin/wg-quick" W1_IP="$R/fakebin/ip" bash -c "${CMD//\~/$home}"
else
  args=(); for a in "$@"; do case "$a" in --zone=*) ;; *) args+=("$a") ;; esac; done
  dest="${args[-1]}"; unset 'args[-1]'
  if [[ "$dest" == *:* ]]; then h="${dest%%:*}"; for s in "${args[@]}"; do cp "$s" "$R/n/$h/home/"; done
  else for s in "${args[@]}"; do h="${s%%:*}"; f="${s#*:}"; cp "$R/n/$h/home/${f#\~/}" "$dest"; done; fi
fi
EOS
chmod +x "$R/gcloud"
mknodes() { rm -rf "$R/n" "$R/out"; for H in tdx-lab tdx-lab-worker; do mkdir -p "$R/n/$H/home" "$R/n/$H/wg" "$R/n/$H/state"; head -c 32 /dev/urandom | base64 > "$R/n/$H/wg/private.key"; echo "peer-of-$H-on-wg0" > "$R/n/$H/wg0-peers"; python3 - "$VEC/node-bundle-$H.attestnode" > "$R/n/$H/state/attested" <<'PY'
import base64, sys
st = base64.b64decode(open(sys.argv[1]).read().split("\n")[1][10:]).decode(); print([l for l in st.split("\n") if l.startswith("mesh-public=")][0][12:])
PY
  done; }
ma() { ( export MA_GCLOUD="$R/gcloud" MA_OPTS="${MA_OPTS_T---now 2026-10-17T08:20:00Z}" MA_SETTLE=0 MA_ROGUE_TIME="2026-10-17T08:19:00Z" FAKE_VECTORS="$VEC"; bash "$KIT/mesh-admit.sh" "$@" ) 2>&1; }
J="$JAR"
echo "=== 1. the happy path: admit, build, prove, take down"
mknodes; out="$(ma admit "$J" "$R/policy.txt" "$REF" "$R/out")"; rc=$?; echo "$out" | tail -9 | cut -c1-200
chk "admit exits 0 and says MESH-ADMIT-OK (2 admitted, 0 refused)" $([ $rc = 0 ] && grep -q '^MESH-ADMIT-OK (2 admitted, 0 refused' <<<"$out"; echo $?)
chk "the table of admitted nodes has the two hosts with their mesh keys, mesh addresses and VPC addresses" $([ "$(cut -f1,3,4 "$R/out/admitted.tsv" | tr '\n' ' ')" = "tdx-lab	10.20.0.1	10.128.0.2 tdx-lab-worker	10.20.0.2	10.128.0.5 " ]; echo $?)
chk "the audit file has an ADMIT-NODE line for each node, with a time" $([ "$(grep -c ' ADMIT-NODE host=' "$R/out/mesh-audit.log")" = 2 ] && grep -Eq '^20[0-9-]+T[0-9:]+Z ADMIT-NODE' "$R/out/mesh-audit.log"; echo $?)
out="$(ma build "$R/out")"; rc=$?; echo "$out" | tail -16 | cut -c1-190
chk "build exits 0 and says MESH-BUILD-OK" $([ $rc = 0 ] && grep -q '^MESH-BUILD-OK' <<<"$out"; echo $?)
C="$R/n/tdx-lab/wg/wg1.conf"; PK="$(cat "$R/n/tdx-lab/wg/private.key")"; WK="$(cut -f2 "$R/out/admitted.tsv" | sed -n 2p)"
chk "the master's wg1.conf: its mesh address /24, port 51821, its OWN private key (the attested one)" $(grep -q '^Address = 10.20.0.1/24$' "$C" && grep -q '^ListenPort = 51821$' "$C" && grep -q "^PrivateKey = $PK\$" "$C"; echo $?)
chk "... and exactly one peer: the worker's attested key, AllowedIPs its address /32, Endpoint its VPC address on 51821" $([ "$(grep -c '^\[Peer\]' "$C")" = 1 ] && grep -q "^PublicKey = $WK\$" "$C" && grep -q '^AllowedIPs = 10.20.0.2/32$' "$C" && grep -q '^Endpoint = 10.128.0.5:51821$' "$C"; echo $?)
chk "the config file is readable by its owner only (mode 600)" $([ "$(stat -c %a "$C")" = 600 ]; echo $?)
chk "the output says that the key in use is the attested key, each node reaches the other, no handshake is missing and wg0 is untouched" $(grep -q 'the key that wg1 runs is the key that the quote attested' <<<"$out" && grep -q 'reaches tdx-lab-worker over wg1' <<<"$out" && grep -q 'every peer has made a handshake' <<<"$out" && grep -q 'wg0 is untouched' <<<"$out"; echo $?)
out="$(ma down "$R/out")"; rc=$?
chk "down exits 0 and says MESH-DOWN-OK; wg1 and its config are gone on both nodes" $([ $rc = 0 ] && grep -q '^MESH-DOWN-OK' <<<"$out" && [ ! -e "$R/n/tdx-lab/wg/wg1.conf" ] && [ ! -e "$R/n/tdx-lab-worker/state/wg1-up" ]; echo $?)
echo "=== 2. a rogue node with a fake quote: refused, and no peer is ever added"
mknodes; out="$(ma admit "$J" "$R/policy.txt" "$REF" "$R/out" --rogue)"; rc=$?; echo "$out" | grep -i "rogue\|REJECT\|OK\|NODES" | cut -c1-200 | head -8
chk "admit --rogue exits 0: two nodes admitted and exactly the rogue refused by the quote check" $([ $rc = 0 ] && grep -q '^MESH-ADMIT-OK (2 admitted, 1 refused' <<<"$out" && grep -q 'REJECT-NODE rogue-node.attestnode: the quote is too short' <<<"$out"; echo $?)
chk "the audit file records the refusal of the rogue node" $(grep -q ' REJECT-NODE rogue-node.attestnode' "$R/out/mesh-audit.log"; echo $?)
chk "the rogue node's key is not in the table of admitted nodes (2 rows)" $([ "$(grep -c . "$R/out/admitted.tsv")" = 2 ]; echo $?)
out="$(ma build "$R/out")"; chk "the build that follows has exactly the two honest peers and no third (one [Peer] on each node)" $([ "$(grep -c '^\[Peer\]' "$R/n/tdx-lab/wg/wg1.conf")" = 1 ] && [ "$(grep -c '^\[Peer\]' "$R/n/tdx-lab-worker/wg/wg1.conf")" = 1 ] && grep -q '^MESH-BUILD-OK' <<<"$out"; echo $?)
ma down "$R/out" >/dev/null
echo "=== 3. faults of admit: it must stop, or report FAILED, with the reason"
fa() { mknodes; out="$(eval "$2")"; rc=$?; chk "fault: $1 -> $3" $([ $rc != 0 ] && grep -q "$4" <<<"$out"; echo $?); if ! { [ $rc != 0 ] && grep -q "$4" <<<"$out"; }; then echo "$out" | tail -3 | cut -c1-200 | sed 's/^/      | /'; fi; }
fa "a node cannot make its bundle" 'FAKE_ATTEST_FAIL=tdx-lab-worker ma admit "$J" "$R/policy.txt" "$REF" "$R/out"' "stops" "could not make its node bundle"
fa "the statements are stale (the doorman's clock is an hour later)" 'MA_OPTS_T="--now 2026-10-17T09:30:00Z" ma admit "$J" "$R/policy.txt" "$REF" "$R/out"' "reports FAILED" "the statement is stale"
fa "the policy table gives the master another address" 'printf "tdx-lab 10.20.0.5 10.128.0.2\ntdx-lab-worker 10.20.0.2 10.128.0.5\n" > "$R/p2.txt"; ma admit "$J" "$R/p2.txt" "$REF" "$R/out"' "reports FAILED" "asks for the mesh address 10.20.0.1 but the policy table gives it 10.20.0.5"
fa "the reference has another MRTD" 'python3 -c "import re,sys; s=open(\"$REF\").read(); open(\"$R/ref2.txt\",\"w\").write(re.sub(r\"^MRTD [0-9a-f]{96}\", \"MRTD \"+\"ab\"*48, s, count=1, flags=re.M))"; ma admit "$J" "$R/policy.txt" "$R/ref2.txt" "$R/out"' "reports FAILED" "MRTD of tdx-lab is c1ee9c16e3af"
fa "the output folder exists already" 'mkdir -p "$R/out"; ma admit "$J" "$R/policy.txt" "$REF" "$R/out"' "stops" "exists already"
fa "the jar is missing" 'ma admit "$R/none.jar" "$R/policy.txt" "$REF" "$R/out"' "stops" "is missing"
echo "=== 4. faults of build: every proof can fail"
fb() { mknodes; ma admit "$J" "$R/policy.txt" "$REF" "$R/out" >/dev/null; out="$(eval "$2")"; rc=$?; chk "fault: $1 -> $3" $([ $rc != 0 ] && grep -q "$4" <<<"$out"; echo $?); if ! { [ $rc != 0 ] && grep -q "$4" <<<"$out"; }; then echo "$out" | tail -4 | cut -c1-200 | sed 's/^/      | /'; fi; ma down "$R/out" >/dev/null 2>&1; }
fb "wg1 does not come up" 'FAKE_WGUP_FAIL=1 ma build "$R/out"' "reports FAILED" "wg1 did not come up"
chk "   and then no wg1.conf (with the private key in it) is left on the node" $([ ! -e "$R/n/tdx-lab/wg/wg1.conf" ]; echo $?)
fb "wg1 runs another key than the attested one" 'FAKE_WRONGKEY=1 ma build "$R/out"' "reports FAILED" "but the attested key is"
fb "wg1 has an extra peer that was not admitted" 'FAKE_EXTRA_PEER=1 ma build "$R/out"' "reports FAILED" "the admitted peers are"
fb "the nodes cannot reach each other" 'FAKE_PING_FAIL=1 ma build "$R/out"' "reports FAILED" "cannot reach"
fb "a peer made no handshake" 'FAKE_NOHS=1 ma build "$R/out"' "reports FAILED" "a peer has made no handshake"
fb "wg0 changes while wg1 is built" 'FAKE_WG0_CHANGES=1 ma build "$R/out"' "reports FAILED" "wg0 peers changed"
fb "there is no table of admitted nodes" 'rm -f "$R/out/admitted.tsv"; ma build "$R/out"' "stops" "no admitted.tsv"
fb "only one node was admitted" 'head -1 "$R/out/admitted.tsv" > "$R/out/one.tsv"; mv "$R/out/one.tsv" "$R/out/admitted.tsv"; ma build "$R/out"' "stops" "a mesh needs two"
fb "wg1 exists already on a node" 'touch "$R/n/tdx-lab/state/wg1-up"; ma build "$R/out"' "reports FAILED" "wg1 did not come up"
echo; echo "pass: $PASS   fail: $FAILN"; [ "$FAILN" = 0 ] && echo "REHEARSAL-PASS: the real scripts and the real doorman pass, a rogue node is refused and never becomes a peer, and the 15 faults are all reported; $PASS checks" || echo "REHEARSAL-FAIL"
