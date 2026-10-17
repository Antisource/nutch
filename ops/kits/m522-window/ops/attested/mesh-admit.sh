#!/usr/bin/env bash
# Step 5.2.2, in Cloud Shell: the doorman for the TEST mesh wg1. The operator is the trust root here (like every mesh script of Milestone 2); the decision itself is the Java code of the jar.
#   bash mesh-admit.sh admit JAR POLICY REFERENCE OUTDIR [--rogue]   ask each host of the policy table for a fresh node bundle, and let the doorman decide; --rogue adds a node with a fake quote
#   bash mesh-admit.sh build OUTDIR                                  bring wg1 up on the admitted nodes, with exactly the admitted peers, and prove it (key in use, peers, handshake, ping, wg0 untouched)
#   bash mesh-admit.sh down  OUTDIR                                  take wg1 down again
# Settings (environment): MA_MAX_AGE (freshness limit in seconds, default 900), MA_ZONE, MA_NODEKIT (where node-attest.sh is on the nodes), MA_OPTS (extra options for the doorman, e.g. --enforce).
set -uo pipefail
GC="${MA_GCLOUD:-gcloud}"; Z="${MA_ZONE:-us-central1-a}"; NODEKIT="${MA_NODEKIT:-m522ckit/m522ckit/m522c/ops/attested}"; MAXAGE="${MA_MAX_AGE:-900}"; OPTS="${MA_OPTS:-}"
KIT="$(cd "$(dirname "$0")" && pwd)"; ME="mesh-admit"; bad=0
say() { echo "$*"; [ -n "${LOG:-}" ] && echo "$*" >> "$LOG"; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }; stop() { echo "MESH-ADMIT-STOP: $*" >&2; exit 1; }
# ssh and scp read the standard input: inside a while-read loop they would swallow the rest of the list, so their input is always /dev/null
rssh() { $GC compute ssh "$1" --zone="$Z" --command="$2" 2>&1 </dev/null; }
HOSTRE='^[A-Za-z0-9._-]{1,63}$'; IPRE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
hosts_of() { grep -v '^[[:space:]]*#' "$1" | awk 'NF>=2{print $1" "$2" "($3==""?"-":$3)}'; }
CMD="${1:-}"; shift || true
case "$CMD" in
admit)
  JAR="${1:?usage}"; POLICY="${2:?usage}"; REF="${3:?usage}"; OUT="${4:?usage}"; ROGUE=0; [ "${5:-}" = "--rogue" ] && ROGUE=1
  [ -f "$JAR" ] && [ -f "$POLICY" ] && [ -f "$REF" ] || stop "the jar, the policy table or the reference file is missing"
  [ ! -e "$OUT" ] || stop "$OUT exists already; move it away"; mkdir -p "$OUT/bundles" || stop "cannot make $OUT"; LOG="$OUT/mesh-audit.log"
  say "$ME admit: $(date -u +%FT%TZ)   policy=$(sha256sum "$POLICY" | cut -c1-16)   reference=$(sha256sum "$REF" | cut -c1-16)   max-age=${MAXAGE}s   rogue=$ROGUE"
  say "== ask each host of the policy table for a fresh node bundle (the quote is made on the node, now)"
  N=0; FILES=""
  while read -r H IP VPC; do
    printf '%s' "$H" | grep -Eq "$HOSTRE" && printf '%s' "$IP" | grep -Eq "$IPRE" || stop "the policy line for '$H' is not usable"
    out="$(rssh "$H" "rm -f ~/node-bundle-$H.attestnode; bash ~/$NODEKIT/node-attest.sh ~/node-bundle-$H.attestnode $IP")"; echo "$out" > "$OUT/attest-$H.txt"
    grep -q '^NODE-ATTEST-OK' <<<"$out" || { echo "$out" | tail -3 | sed 's/^/   | /'; stop "$H could not make its node bundle (see $OUT/attest-$H.txt)"; }
    $GC compute scp "$H:~/node-bundle-$H.attestnode" "$OUT/bundles/" --zone="$Z" </dev/null >/dev/null 2>&1 && [ -s "$OUT/bundles/node-bundle-$H.attestnode" ] || stop "could not fetch the bundle of $H"
    ok "$H made its bundle: $(grep -o 'mesh-public=[^ ]*' <<<"$out" | head -1) $(grep -o 'quote=[0-9]* bytes' <<<"$out")"; N=$((N+1)); FILES="$FILES $OUT/bundles/node-bundle-$H.attestnode"
  done < <(hosts_of "$POLICY")
  USED="$POLICY"
  if [ $ROGUE = 1 ]; then
    cp "$POLICY" "$OUT/policy-with-rogue.txt"; echo "rogue-node 10.20.0.9 10.128.0.99" >> "$OUT/policy-with-rogue.txt"; USED="$OUT/policy-with-rogue.txt"
    MA_ROGUE_TIME="${MA_ROGUE_TIME:-}" python3 - "$OUT/bundles/rogue-node.attestnode" <<'PY'
import base64, hashlib, os, sys, datetime
# the time of the rogue statement is now; MA_ROGUE_TIME is a rehearsal hook (the rehearsal fixes the doorman's clock because its real bundles are old)
when = os.environ.get("MA_ROGUE_TIME") or datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
st = ("ATTESTED-NODE-STATEMENT 1\nhost=rogue-node\nmesh-public=%s\nmesh-ip=10.20.0.9\ncreated=%s\nnonce=%s\n" % (base64.b64encode(os.urandom(32)).decode(), when, os.urandom(16).hex())).encode()
q = bytearray(b"\x04\x00" + b"\x00" * 630); q[568:632] = hashlib.sha512(st).digest()
open(sys.argv[1], "w").write("ATTESTED-NODE-BUNDLE 1\nstatement=%s\nquote=%s\n" % (base64.b64encode(st).decode(), base64.b64encode(bytes(q)).decode()))
PY
    [ -s "$OUT/bundles/rogue-node.attestnode" ] && ok "a ROGUE node bundle was made: a fresh random mesh key, a fake 632-byte quote with the right REPORTDATA, a host name that the (extended) policy table allows" || stop "could not make the rogue bundle"; FILES="$FILES $OUT/bundles/rogue-node.attestnode"
  fi
  say "== the doorman decides (the Java code of the jar: binding, policy table, freshness, genuine quote, reference)"
  java -cp "$JAR" org.apache.nutch.attested.AttestedKeyTool node-admit-all "$REF" "$USED" "$OUT/admitted.tsv" --max-age "$MAXAGE" $OPTS $FILES > "$OUT/admit.txt" 2>&1; rc=$?
  grep '^ADMIT-NODE\|^REJECT-NODE\|^NODES' "$OUT/admit.txt" | cut -c1-230 | sed 's/^/   | /'
  while read -r l; do echo "$(date -u +%FT%TZ) $l" >> "$OUT/mesh-audit.log"; done < <(grep '^ADMIT-NODE\|^REJECT-NODE' "$OUT/admit.txt")
  ADM="$(grep -c '^ADMIT-NODE' "$OUT/admit.txt")"; REJ="$(grep -c '^REJECT-NODE' "$OUT/admit.txt")"; WANT=$([ $ROGUE = 1 ] && echo 1 || echo 0)
  [ "$ADM" = "$N" ] && ok "every host of the policy table was admitted ($ADM of $N)" || no "only $ADM of $N hosts were admitted"
  if [ $ROGUE = 1 ]; then
    [ "$REJ" = 1 ] && grep -q '^REJECT-NODE rogue-node.attestnode: the quote is too short' "$OUT/admit.txt" && ok "the rogue node was REFUSED by the quote check ('the quote is too short'), and only it" || no "the rogue node was not refused as expected (refused: $REJ)"
    ! cut -f2 "$OUT/admitted.tsv" | grep -q "$(python3 -c "import re,sys; print(re.search(r'mesh-public=(\S+)', open('$OUT/bundles/rogue-node.attestnode').read() and __import__('base64').b64decode(open('$OUT/bundles/rogue-node.attestnode').read().split(chr(10))[1][10:]).decode()).group(1))" 2>/dev/null || echo NOKEY)" && ok "the rogue node's key is not in the table of admitted nodes" || no "the rogue node's key IS in the table of admitted nodes"
  else
    [ "$REJ" = 0 ] && ok "nobody was refused" || no "$REJ node(s) were refused"
  fi
  if [ $bad -eq 0 ]; then say "MESH-ADMIT-OK ($ADM admitted, $REJ refused as expected; the table of admitted nodes is $OUT/admitted.tsv)"; else say "MESH-ADMIT-FAILED ($bad)"; fi
  [ $bad -eq 0 ] ;;
build)
  OUT="${1:?usage}"; [ -s "$OUT/admitted.tsv" ] || stop "no admitted.tsv in $OUT: run admit first"; LOG="$OUT/mesh-build.log"; : > "$LOG"
  NN="$(grep -c . "$OUT/admitted.tsv")"; [ "$NN" -ge 2 ] || stop "only $NN node admitted: a mesh needs two"
  say "$ME build: $(date -u +%FT%TZ)   admitted nodes: $NN"
  declare -A KEY IP VPC; HOSTS=()
  while IFS=$'\t' read -r H K I V; do printf '%s' "$H" | grep -Eq "$HOSTRE" || stop "bad host in admitted.tsv"; KEY[$H]="$K"; IP[$H]="$I"; VPC[$H]="$V"; HOSTS+=("$H"); done < "$OUT/admitted.tsv"
  say "== wg0 (production) before: untouched afterwards"
  declare -A WG0; for H in "${HOSTS[@]}"; do WG0[$H]="$(rssh "$H" 'sudo -n wg show wg0 peers | sort | tr "\n" " "')"; ok "$H: wg0 peers: ${WG0[$H]:0:24}..."; done
  say "== bring wg1 up on each admitted node with exactly the other admitted nodes as peers"
  for H in "${HOSTS[@]}"; do
    $GC compute scp "$KIT/wg1-node-up.sh" "$KIT/wg1-node-down.sh" "$H:~/" --zone="$Z" </dev/null >/dev/null 2>&1 || stop "could not send the wg1 scripts to $H"
    PEERS=""; for P in "${HOSTS[@]}"; do [ "$P" = "$H" ] || PEERS="$PEERS ${KEY[$P]},${IP[$P]},${VPC[$P]}"; done
    out="$(rssh "$H" "bash ~/wg1-node-up.sh ${IP[$H]} $PEERS")"; echo "$out" >> "$LOG"
    grep -q '^WG1-UP-OK' <<<"$out" && ok "$H: $(grep '^WG1-UP-OK' <<<"$out")" || { echo "$out" | tail -3 | sed 's/^/   | /'; no "$H: wg1 did not come up"; }
  done
  sleep "${MA_SETTLE:-4}"
  say "== prove it"
  for H in "${HOSTS[@]}"; do
    PUBNOW="$(rssh "$H" 'sudo -n wg show wg1 public-key')"; [ "$PUBNOW" = "${KEY[$H]}" ] && ok "$H: the key that wg1 runs is the key that the quote attested (${PUBNOW:0:10}...)" || no "$H: wg1 runs ${PUBNOW:0:10}... but the attested key is ${KEY[$H]:0:10}..."
    WANT="$(for P in "${HOSTS[@]}"; do [ "$P" = "$H" ] || echo "${KEY[$P]}"; done | sort | tr '\n' ' ')"; GOT="$(rssh "$H" 'sudo -n wg show wg1 peers | sort | tr "\n" " "')"
    [ "$GOT" = "$WANT" ] && ok "$H: wg1 has exactly the admitted peers and no other" || no "$H: wg1 peers are '$GOT' but the admitted peers are '$WANT'"
    for P in "${HOSTS[@]}"; do [ "$P" = "$H" ] && continue
      pg="$(rssh "$H" "ping -c 3 -W 3 -I wg1 ${IP[$P]} | tail -2")"; grep -q ' 0% packet loss' <<<"$pg" && ok "$H reaches $P over wg1 (${IP[$P]}): $(grep -o '[0-9]* received' <<<"$pg")" || { echo "$pg" | sed 's/^/   | /'; no "$H cannot reach $P over wg1"; }
    done
    hs="$(rssh "$H" 'sudo -n wg show wg1 latest-handshakes | awk "{print \$2}" | sort -n | head -1')"; [ -n "$hs" ] && [ "$hs" != 0 ] && ok "$H: every peer has made a handshake (the oldest is at $hs)" || no "$H: a peer has made no handshake"
    W0N="$(rssh "$H" 'sudo -n wg show wg0 peers | sort | tr "\n" " "')"; [ "$W0N" = "${WG0[$H]}" ] && ok "$H: wg0 is untouched (same peers as before)" || no "$H: wg0 peers changed"
  done
  if [ $bad -eq 0 ]; then say "MESH-BUILD-OK (wg1 is up on $NN nodes with exactly the admitted peers; wg0 untouched)"; else say "MESH-BUILD-FAILED ($bad)"; fi
  [ $bad -eq 0 ] ;;
down)
  OUT="${1:?usage}"; [ -s "$OUT/admitted.tsv" ] || stop "no admitted.tsv in $OUT"; LOG="$OUT/mesh-down.log"; : > "$LOG"
  say "$ME down: $(date -u +%FT%TZ)"
  while IFS=$'\t' read -r H K I V; do
    out="$(rssh "$H" 'bash ~/wg1-node-down.sh')"; echo "$out" >> "$LOG"; grep -q '^WG1-DOWN-OK' <<<"$out" && ok "$H: $(grep '^WG1-DOWN-OK' <<<"$out")" || no "$H: wg1 did not go down ($(echo "$out" | tail -1))"
  done < "$OUT/admitted.tsv"
  if [ $bad -eq 0 ]; then say "MESH-DOWN-OK"; else say "MESH-DOWN-FAILED ($bad)"; fi; [ $bad -eq 0 ] ;;
*) echo "usage: bash mesh-admit.sh admit JAR POLICY REFERENCE OUTDIR [--rogue] | build OUTDIR | down OUTDIR" >&2; exit 2 ;;
esac
