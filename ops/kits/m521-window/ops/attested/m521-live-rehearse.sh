#!/usr/bin/env bash
# Rehearsal of m521-live.sh away from the cluster. The REAL live script runs with the REAL wrapper jar (the key tool, the signing service for the rogue key, the admission code), the REAL
# reference file and the two REAL key bundles of run 15 (so the master's "own" key and the worker's key are real bundles that the admission really admits). Stand-ins: hdfs (a script
# that keeps files in a local folder and, on every cat, writes to the key list's audit file what the real list would write: it asks the real key tool about each bundle in the live list),
# and the hook M521L_SKIP_TREE (the stand-in files are not signed with admitted keys, so the offline tree verification, which the real run does, is skipped and said so).
# Usage: bash m521-live-rehearse.sh KITDIR JAR_FILE HADOOP_PACK_JARS TOOLS_CLASSES_DIR
set -uo pipefail
KIT="$1"; JAR="$2"; JARS="$3"; TOOLS="$4"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; CP="$(ls "$JARS"/*.jar | tr '\n' ':')"
VEC="${M521R_VECTORS:-$KIT/../../testdata}"; [ -d "$VEC" ] || VEC="$(dirname "$KIT")/testdata"
cat > "$R/hadoop" <<EOH
#!/bin/bash
[ "\$1" = classpath ] && echo "$CP$TOOLS"
EOH
cat > "$R/hdfs" <<'EOH'
#!/usr/bin/env bash
# a stand-in for hdfs: files in $FAKE_ROOT; getconf from $FAKE_CONF; on cat it writes the key list's audit lines (asking the real key tool about every bundle in the live list)
case "$1" in
  getconf) shift; [ "$1" = -confKey ] && grep -m1 "^$2=" "$FAKE_CONF" | cut -d= -f2-; exit 0 ;;
esac
[ "$1" = dfs ] || exit 2; shift
[ -e "$FAKE_ROOT/DOWN" ] && exit 1
args=(); while [ $# -gt 0 ]; do case "$1" in -D) shift 2 ;; *) args+=("$1"); shift ;; esac; done; set -- "${args[@]}"
case "$1" in
  -ls) exit 0 ;;
  -test) [ -e "$FAKE_ROOT$3" ] ;;
  -mkdir) mkdir -p "$FAKE_ROOT$3" ;;
  -put) cp "$2" "$FAKE_ROOT$3" ;;
  -get) mkdir -p "$(dirname "$3")"; cp -r "$FAKE_ROOT$2" "$3" ;;
  -cat)
    for b in "$FAKE_KL"/TDX-*.attestkey; do
      out="$(java -cp "$FAKE_JAR" org.apache.nutch.attested.AttestedKeyTool bundle-admit "$b" "$FAKE_REF" 2>&1)"; rc=$?
      if [ $rc = 0 ]; then echo "$(date -u +%FT%TZ) ADMIT key=$(basename "$b" .attestkey) host=$(grep -o 'host [a-z-]*' <<<"$out" | head -1 | cut -d' ' -f2) admitted by quote: mrtd=c1ee9c16e3af(enforced)" >> "$FAKE_AUDIT"
      elif [ -z "${FAKE_NO_REJECT:-}" ]; then echo "$(date -u +%FT%TZ) REJECT file=$(basename "$b") reason=$(tail -1 <<<"$out" | sed 's/^ATTESTED-KEY-TOOL-STOP: //')" >> "$FAKE_AUDIT"; fi
    done
    if [ -n "${FAKE_CORRUPT:-}" ]; then { head -c 100 "$FAKE_ROOT$2"; printf 'X'; tail -c +102 "$FAKE_ROOT$2"; }; else cat "$FAKE_ROOT$2"; fi ;;
  *) exit 2 ;;
esac
EOH
chmod +x "$R/hadoop" "$R/hdfs"
mknode() { # a node that has an open window, the live key list with the two real bundles of run 15, the reference file, and the master's own bundle
  rm -rf "$R/n"; N="$R/n"; mkdir -p "$N/home/m521w/window" "$N/home/tc-keys/list" "$N/home/tc-keyservice" "$N/root/user/rishabsdp17"
  cp "$VEC"/TDX-428f3734fdb03238.attestkey "$VEC"/TDX-5fdb825500807c66.attestkey "$N/home/tc-keys/list/"; cp "$VEC/TDX-428f3734fdb03238.attestkey" "$N/home/tc-keyservice/"
  cp "$KIT/reference-measurements-m521.txt" "$N/home/tc-keys/reference-measurements.txt"
  ( sleep 600 & echo $! > "$N/home/m521w/window/keyservice.pid" ); cat "$N/home/m521w/window/keyservice.pid" >> "$R/pids"; : > "$N/audit.log"
  printf 'attested.keys.admission.enabled=true\nattested.keys.admission.reference.sha256=%s\nattested.keys.provider=service\nattested.signature.allow.test.keys=false\n' "$(sha256sum "$N/home/tc-keys/reference-measurements.txt" | cut -d' ' -f1)" > "$N/conf.txt"
}
live() { ( cd "$KIT" && M521L_HOME="$R/n/home" HADOOP_HOME="$R/n/home/hadoop" M521L_USER=rishabsdp17 M521L_HDFS="$R/hdfs" M521L_JAR="$JAR" M521L_HADOOP="$R/hadoop" M521L_WORK="$R/n/work" M521L_ROGUE_PORT=17462 M521L_SKIP_TREE=1 \
    FAKE_ROOT="$R/n/root" FAKE_CONF="$R/n/conf.txt" FAKE_KL="$R/n/home/tc-keys/list" FAKE_JAR="$JAR" FAKE_REF="$R/n/home/tc-keys/reference-measurements.txt" FAKE_AUDIT="$R/n/home/tc-keys/keylist-audit.log" PATH="$R:$PATH" \
    bash m521-live.sh run16 ) 2>&1; }
listening() { python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except Exception: sys.exit(1)
PY
}
trap 'for p in $(cat "$R/pids" 2>/dev/null) $(cat "$R"/n/work/rogue.pid 2>/dev/null); do kill $p 2>/dev/null; done' EXIT
echo "=== 1. the happy path: the real live script, real bundles and quotes, a real rogue service"
mknode; out="$(live)"; rc=$?; echo "$out" | tail -26 | cut -c1-200
chk "the script exits 0 and says M521L-OK" $([ $rc = 0 ] && grep -q "^M521L-OK" <<<"$out"; echo $?)
chk "both keys of the window are found in the key list (the newest bundle of each host)" $(grep -q "this window's two keys: master TDX-428f3734fdb03238, worker TDX-5fdb825500807c66" <<<"$out"; echo $?)
chk "the file read back byte for byte" $(grep -q "reads back byte for byte" <<<"$out"; echo $?)
chk "the audit shows each key admitted, with the registers" $([ "$(grep -c "ok:   .*ADMIT\|ok:   [0-9TZ:.-]* ADMIT" <<<"$out")" -ge 2 ]; echo $?)
chk "the rogue key was REFUSED by the list, with its reason (too short: no Intel chain)" $(grep -q "REFUSED the rogue key and wrote why: reason=.*too short" <<<"$out"; echo $?)
chk "bundle-admit refuses the rogue bundle too" $(grep -q "bundle-admit refuses the rogue bundle too" <<<"$out"; echo $?)
chk "the rogue bundle is removed from the live key list and its port is closed" $([ "$(ls "$R/n/home/tc-keys/list" | wc -l)" = 2 ] && ! listening 17462; echo $?)
chk "EDIT 1, EDIT 2 and the tampered live quote all flip as they should" $([ "$(grep -c "EDIT 1: with one changed MRTD\|EDIT 2: with mrtd out\|a flipped bit in MRTD of this node's live quote is refused" <<<"$out")" = 3 ]; echo $?)
chk "the results are packed, and the skipped tree check is said so" $([ -f "$R/n/work/m521-live-results.tar.gz" ] && grep -q "tree verification is SKIPPED" <<<"$out"; echo $?)
echo "=== 2. faults: the script must stop, or report FAILED, with the reason"
f() { mknode; eval "$2"; out="$(live)"; rc=$?; chk "fault: $1 -> $3" $([ $rc != 0 ] && grep -q "$4" <<<"$out"; echo $?); if ! { [ $rc != 0 ] && grep -q "$4" <<<"$out"; }; then echo "$out" | tail -4 | cut -c1-200 | sed 's/^/      | /'; fi; }
f "no window is open on this node" 'rm -f "$R/n/home/m521w/window/keyservice.pid"' "stops" "no open window"
f "the admission is not on in this node's configuration" 'sed -i "s/admission.enabled=true/admission.enabled=false/" "$R/n/conf.txt"' "stops" "attested.keys.admission.enabled is not true"
f "the reference file does not match the SHA-256 that core-site.xml pins" 'echo "# changed" >> "$R/n/home/tc-keys/reference-measurements.txt"' "stops" "does not match its pinned SHA-256"
f "the live key list lacks the worker's key" 'rm -f "$R/n/home/tc-keys/list/TDX-5fdb825500807c66.attestkey"' "stops" "does not hold this window's two keys"
f "HDFS does not answer" 'touch "$R/n/root/DOWN"' "stops" "HDFS does not answer"
f "the HDFS test folder exists already" 'mkdir -p "$R/n/root/user/rishabsdp17/adm-run16"' "stops" "exists already in HDFS"
f "the work folder exists already" 'mkdir -p "$R/n/work"' "stops" "exists already; move it away"
f "the read-back is corrupted (a byte changed)" 'export FAKE_CORRUPT=1' "reports FAILED" "M521L-FAILED"
unset FAKE_CORRUPT
f "the key list does not report the rogue key (no REJECT line)" 'export FAKE_NO_REJECT=1' "reports FAILED" "the audit has no REJECT line for the rogue key"
unset FAKE_NO_REJECT
chk "   and even then the rogue bundle was removed from the key list again" $([ "$(ls "$R/n/home/tc-keys/list" | wc -l)" = 2 ] && ! listening 17462; echo $?)
cat > "$R/busy.py" <<'EOB'
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 17462)); s.listen(1); time.sleep(120)
EOB
mknode; python3 "$R/busy.py" & BP=$!; sleep 2
chk "the port of the rogue service is really taken before the run (the helper listens on it)" $(listening 17462; echo $?)
out="$(live)"; rc=$?; kill $BP 2>/dev/null
chk "fault: the port of the rogue service is taken (it cannot start) -> stops" $([ $rc != 0 ] && grep -q "the rogue service did not start, or did not put its bundle into the key list" <<<"$out"; echo $?)
if ! { [ $rc != 0 ] && grep -q "the rogue service did not start, or did not put its bundle into the key list" <<<"$out"; }; then echo "$out" | tail -4 | cut -c1-200 | sed 's/^/      | /'; fi
chk "   and nothing of the rogue was left in the key list" $([ "$(ls "$R/n/home/tc-keys/list" | wc -l)" = 2 ]; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the real live script passes with real bundles and a real rogue service, and its faults are all reported; $PASS checks"; else echo "REHEARSAL-FAIL"; fi
