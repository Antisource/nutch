#!/usr/bin/env bash
# Milestone 5, step 5.1.3: one crawl with the REAL key (the signing service on each node, hardware quotes, the key list), signing and folder binding ON and REQUIRED,
# with the job of step 5.1.3, on the MASTER, in a window.
# It checks the state, prepares (log rotation, seeds, "before" listing), runs the crawl exactly as ops/run-crawl.sh does
# (same parameters; with MODE=on it adds the teammate's three settings), takes the "after" listing, cuts the NameNode's audit
# window and packs the master's logs. Then it gets a copy of the whole crawl output and of the seeds with the PLAIN client and verifies them
# OFFLINE with the public key only: every folder's identity chain and every file's record bound to its folder and its name. The WORKER must have been
# prepared first (m513c-worker.sh prep) and the window must be open on both nodes (m513-window.sh open).
#
#   bash ops/attested/m513c-run.sh RUN MODE        RUN: a new name such as run11;  MODE: on (receipts on) | off (receipts off)
# Run it in tmux, from any folder. It never changes the cluster's configuration, and it stops before it starts if anything is off.
# Test hooks (rehearsal only): M513C_PATCHED, M513C_HDFS, M513C_YARN, M513C_JPS, M513C_ATT_TMP, M513C_NO_CRAWL_EXEC.
set -uo pipefail
U="usage: $0 RUN on|off"; RUN="${1:?$U}"; MODE="${2:?$U}"
case "$MODE" in on|off) ;; *) echo "$U" >&2; exit 2 ;; esac
PATCHED="${M513C_PATCHED:-$HOME/m513/tree}"; HDFS="${M513C_HDFS:-hdfs}"; YARN="${M513C_YARN:-yarn}"; JPS="${M513C_JPS:-jps}"
ATT_TMP="${M513C_ATT_TMP:-/tmp}"; HH="${HADOOP_HOME:-$HOME/hadoop}"; ATT="$PATCHED/ops/attested"; OUT="$HOME/$RUN"
JOB="$PATCHED/runtime/deploy/apache-nutch-1.22.job"; POL="$HOME/tc-policy/policy.json"; ME="${M513C_USER:-$(whoami)}"
KIT="$(cd "$(dirname "$0")" && pwd)"; BUSY="${M513C_BUSY:-/opt/tc-shared/state/BUSY}"; BUILD_FP="${M513C_BUILD_FP:-$HOME/m513b/evidence/fingerprints.txt}"
KSDIR="${M513C_KSDIR:-$HOME/tc-keyservice}"; KLDIR="${M513C_KLDIR:-$HOME/tc-keys/list}"; PORT="${M513C_PORT:-7461}"; JAVAC="${M513C_JAVAC:-javac}"; LIBJAR="${M513C_LIBJAR:-$HH/share/hadoop/common/lib/attested-hdfs.jar}"
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
SEEDS="/user/$ME/seeds-$RUN"; CRAWL="/user/$ME/crawl-$RUN"
bad=0; say() { echo "$*" | tee -a "$OUT/summary.txt" 2>/dev/null; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { echo "M513C-RUN-STOP: $*"; exit 1; }
fp() { sha256sum "$1" | cut -c1-64; }
[[ "$RUN" =~ ^[a-z0-9]+$ ]] || stop "RUN must be letters and digits only (for example run11)"
[ -e "$OUT" ] && stop "$OUT exists already; use a new run name"

echo "== state (nothing is changed before all of these pass)"
[ -f "$JOB" ] || stop "the patched job is not at $JOB"
WANT=$(awk '/^new job /{print $3}' "$BUILD_FP" 2>/dev/null); [ -n "$WANT" ] || stop "no recorded fingerprint of the job of step 5.1.3 (the build evidence $BUILD_FP is missing)"
[ "$(fp "$JOB")" = "$WANT" ] && echo "   ok:   the job is the job of step 5.1.3 that the build proved (${WANT:0:16}...)" || stop "the job file is not the job of step 5.1.3 that the build proved (sha256 $(fp "$JOB" | cut -c1-16), expected ${WANT:0:16})"
[ -f "$POL" ] && [ "$(fp "$POL")" = "$(cat "$POL.sha256" 2>/dev/null)" ] && echo "   ok:   the policy file is the one that was built and verified ($(fp "$POL" | cut -c1-16)...)" || stop "the policy file is missing or differs from its recorded fingerprint"
grep -q "AttestedHdfsFileSystem" "$HH/etc/hadoop/core-site.xml" && echo "   ok:   the cluster is in WRAPPED mode on this node" || stop "core-site.xml is not the wrapped version (run cluster-mode.sh wrapped first)"
for k in attested.signature.enabled attested.signature.required attested.folder.binding.enabled attested.folder.binding.required; do
  [ "$($HDFS getconf -confKey $k 2>/dev/null)" = true ] || stop "$k is not true on this node: the window is not open (run m513-window.sh open master ...)"
done; echo "   ok:   signing and folder binding are on and required on this node (the window is open)"
[ "$($HDFS getconf -confKey attested.keys.provider 2>/dev/null)" = service ] && [ "$($HDFS getconf -confKey attested.signature.allow.test.keys 2>/dev/null)" = false ] || stop "the keys do not come from the signing service, or test keys are still allowed: the window of step 5.1.3 is not open"
echo "   ok:   the keys come from the signing service and test keys are not allowed"
[ -f "$BUSY" ] && [ "$(cut -f1 "$BUSY")" = "$ME" ] && echo "   ok:   the cluster is reserved by you" || stop "the cluster is not reserved by you: tc-busy.sh start \"combined crawl\""
SKB="$(ls "$KSDIR"/TDX-*.attestkey 2>/dev/null | head -1)"; SKID="$(basename "${SKB:-none}" .attestkey)"
[ -n "$SKB" ] && echo "   ok:   the signing service of this node has the key $SKID" || stop "no TDX- key bundle in $KSDIR: the signing service is not running here"
ans="$( { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; printf 'AUTH %s\nID\n' "$(cat "$KSDIR/token")" >&3; read -r -t 5 l1 <&3; read -r -t 5 l2 <&3; echo "$l1 $l2"; exec 3>&-; } 2>/dev/null )"
[ "$ans" = "OK OK $SKID" ] && echo "   ok:   the signing service answers on 127.0.0.1:$PORT" || stop "the signing service does not answer on port $PORT (got: ${ans:-nothing})"
nk=$(ls "$KLDIR"/TDX-*.attestkey 2>/dev/null | wc -l); [ "$nk" -ge 2 ] && [ -f "$KLDIR/$SKID.attestkey" ] && echo "   ok:   the key list holds $nk TDX bundles, this node's key among them (the bundles of both nodes were exchanged)" || stop "the key list $KLDIR holds $nk TDX bundles: run m513-keylist-sync.sh in Cloud Shell first"
J="$($JPS 2>/dev/null)"; for d in NameNode ResourceManager; do grep -q -w "$d" <<<"$J" && echo "   ok:   $d is running" || stop "$d is not running on the master"; done
nodes=$($YARN node -list 2>/dev/null | awk '$2=="RUNNING"{n++} END{print n+0}'); [ "$nodes" -ge 1 ] && echo "   ok:   $nodes YARN node(s) registered and RUNNING (the worker's NodeManager is back)" || stop "no YARN node is RUNNING: the worker's NodeManager has not registered yet (wait a minute after its restart, then run again)"
n=$($YARN application -list -appStates RUNNING 2>/dev/null | grep -c 'application_[0-9]'); [ "$n" = 0 ] && echo "   ok:   no YARN application is running" || stop "$n YARN application(s) are running: wait until the cluster is quiet"
v=$(bash "$ATT/wrapper-jar.sh" verify "$JOB" 2>&1); grep -q "CLASSES-SAME" <<<"$v" && echo "   ok:   $(grep CLASSES-SAME <<<"$v")" || stop "the installed wrapper jar differs from the job's wrapper classes"
for p in "$SEEDS" "$CRAWL"; do $HDFS dfs -test -e "$p" 2>/dev/null && stop "$p exists already in HDFS"; done; echo "   ok:   the HDFS folders $SEEDS and $CRAWL are new"
[ -f "$PATCHED/seeds/seed.txt" ] || stop "no seed file at $PATCHED/seeds/seed.txt"
CMD="$(mktemp)"; trap 'rm -f "$CMD"' EXIT
if [ "$MODE" = on ]; then
  c=$(grep -c '^  --time-limit-fetch 10 \\$' "$PATCHED/ops/run-crawl.sh"); [ "$c" = 1 ] || stop "ops/run-crawl.sh does not have the expected single place for extra options ($c)"
  NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  sed "s#^  --time-limit-fetch 10 \\\\\$#  --time-limit-fetch 10 \\\\\n  -D tc.receipts.enabled=true \\\\\n  -D tc.nonce=$NONCE \\\\\n  -D tc.policy.file=$POL \\\\#" "$PATCHED/ops/run-crawl.sh" >"$CMD"
  [ "$(grep -c 'tc\.' "$CMD")" = 3 ] && echo "   ok:   the crawl command has exactly the three receipt settings added" || stop "could not add the three settings to the crawl command"
else cp "$PATCHED/ops/run-crawl.sh" "$CMD"; [ "$(grep -c 'tc\.' "$CMD")" = 0 ] && echo "   ok:   MODE off: no receipt setting in the crawl command" || stop "a receipt setting is present in an 'off' run"; fi

mkdir -p "$OUT" || stop "cannot create $OUT"
say "m513c-run: $(date -u +%FT%TZ) on $(hostname)   run=$RUN mode=$MODE   job=${WANT:0:16}...   policy=$(fp "$POL" | cut -c1-16)..."
[ "$MODE" = on ] && { echo "$NONCE" >"$OUT/nonce"; say "   nonce: $NONCE (kept in $OUT/nonce)"; cp "$POL" "$OUT/policy.json"; }
cp "$CMD" "$OUT/crawl-command.sh"
say "== prepare"
bash "$ATT/audit.sh" rotate >"$OUT/rotate.log" 2>&1 && ok "this node's old wrapper logs moved aside" || stop "audit.sh rotate failed (see $OUT/rotate.log)"
NNLOG="$HH/logs/hdfs-audit.log"; NN_START=$( [ -f "$NNLOG" ] && wc -l <"$NNLOG" || echo 0 ); ok "NameNode audit log marked at line $NN_START"
$HDFS dfs -mkdir -p "$SEEDS" && $HDFS dfs -put "$PATCHED/seeds/seed.txt" "$SEEDS/" >"$OUT/seeds.log" 2>&1 && ok "seed file put into $SEEDS (the wrapper makes its record)" || stop "putting the seed file failed (see $OUT/seeds.log)"
bash "$ATT/audit.sh" snapshot "$OUT/before.tsv" >"$OUT/before.log" 2>&1 && ok "before listing: $(grep -c . "$OUT/before.tsv") paths" || stop "the before listing failed (see $OUT/before.log)"
say "== crawl (several minutes)"
S=$(date +%s); ( cd "$PATCHED" && bash "$CMD" "$SEEDS" "$CRAWL" ) 2>&1 | tee "$OUT/crawl.log" >/dev/null; RC=${PIPESTATUS[0]}; E=$(date +%s)
[ "$RC" = 0 ] && ok "the crawl finished, exit code 0, $((E-S)) s" || no "the crawl exited with code $RC after $((E-S)) s (see $OUT/crawl.log)"
say "== right after the crawl"
bash "$ATT/audit.sh" snapshot "$OUT/after.tsv" >"$OUT/after.log" 2>&1 && ok "after listing: $(grep -c . "$OUT/after.tsv") paths" || no "the after listing failed (see $OUT/after.log)"
if [ -f "$NNLOG" ]; then NN_END=$(wc -l <"$NNLOG"); sed -n "$((NN_START+1)),${NN_END}p" "$NNLOG" >"$OUT/nn-window.log"; ok "NameNode window: lines $((NN_START+1)) to $NN_END ($(grep -c . "$OUT/nn-window.log") events)"; else no "no NameNode audit log at $NNLOG"; fi
( cd "$ATT_TMP" && tar czf "$OUT/master-logs.tar.gz" attested-audit attested-records ) 2>"$OUT/pack.log" && ok "master logs packed: $(tar tzf "$OUT/master-logs.tar.gz" | grep -c -v '/$') files" || no "packing the master logs failed (see $OUT/pack.log)"
say "== the whole output verified OFFLINE against the key list (a copy made with the plain client; the public bundles only, no private key anywhere)"
mkdir -p "$OUT/verify/classes"
$JAVAC -source 11 -target 11 -Xlint:-options -nowarn -cp "$LIBJAR" -d "$OUT/verify/classes" "$KIT/M513Tools.java" >"$OUT/verify/javac.log" 2>&1 && ok "the verification tool compiles against the installed jar" || no "the verification tool does not compile (see $OUT/verify/javac.log)"
mkdir -p "$OUT/verify/keylist" && cp "$KLDIR"/*.attestkey "$OUT/verify/keylist/" && ok "the key list at this moment is kept: $(ls "$OUT/verify/keylist" | wc -l) bundles"
for T in "$SEEDS" "$CRAWL"; do
  L="$OUT/verify/$(basename "$T")"; rm -rf "$L"
  if $HDFS dfs $PLAIN -get "$T" "$L" >"$OUT/verify/get-$(basename "$T").log" 2>&1; then
    n=$(find "$L" -type f | wc -l); ok "a local copy of $T was made ($n files, $(du -sk "$L" | cut -f1) KB)"
    java -cp "$LIBJAR:$OUT/verify/classes" org.apache.nutch.attested.M513Tools verify-tree-list "$OUT/verify/keylist" "$L" "$T" >"$OUT/verify/tree-$(basename "$T").txt" 2>&1; vrc=$?
    tail -2 "$OUT/verify/tree-$(basename "$T").txt" | sed 's/^/      /' | tee -a "$OUT/summary.txt"
    if [ $vrc = 0 ] && grep -q "^VERIFY-TREE-CLEAN" "$OUT/verify/tree-$(basename "$T").txt"; then ok "offline: every folder and every file of $T verifies against the key list ($(grep -o 'folders=[0-9]* files=[0-9]*' "$OUT/verify/tree-$(basename "$T").txt"))"; else no "offline: $T does not verify (see $OUT/verify/tree-$(basename "$T").txt; the first findings are below)"; grep "^BAD" "$OUT/verify/tree-$(basename "$T").txt" | head -5 | sed 's/^/      /'; fi
  else no "could not get a copy of $T with the plain client (see $OUT/verify/get-$(basename "$T").log)"; fi
done
CL="$OUT/verify/$(basename "$CRAWL")"
ids="$(grep -h '^OK ' "$OUT/verify/tree-$(basename "$SEEDS").txt" "$OUT/verify/tree-$(basename "$CRAWL").txt" 2>/dev/null | grep -o 'key=TDX-[0-9a-f]*' | sort -u | sed 's/key=//' | tr '\n' ' ')"
nid=$(wc -w <<<"$ids"); allin=1; for i in $ids; do [ -f "$OUT/verify/keylist/$i.attestkey" ] || allin=0; done
[ "$nid" -ge 1 ] && [ "$allin" = 1 ] && ok "the tree was signed by $nid key(s), all of them in the key list: $ids" || no "the keys that signed the tree ($ids) are not all in the key list"
mkdir -p "$OUT/verify/keylist-this-node-only" && cp "$KSDIR/$SKID.attestkey" "$OUT/verify/keylist-this-node-only/"
java -cp "$LIBJAR:$OUT/verify/classes" org.apache.nutch.attested.M513Tools verify-tree-list "$OUT/verify/keylist-this-node-only" "$CL" "$CRAWL" >"$OUT/verify/negative-this-node-only-list.txt" 2>&1; nrc=$?
if [ $nrc != 0 ] && grep -q "not trusted here" "$OUT/verify/negative-this-node-only-list.txt" && grep -q "^VERIFY-TREE-FINDINGS" "$OUT/verify/negative-this-node-only-list.txt"; then
  ok "negative control: with only this node's bundle in the list, the other machine's files are refused ($(grep -c '^BAD' "$OUT/verify/negative-this-node-only-list.txt") findings, not trusted here)"
else no "negative control failed: with only this node's bundle in the list the tree should have findings (rc $nrc; see $OUT/verify/negative-this-node-only-list.txt)"; fi
if [ -f "$KSDIR/audit.log" ]; then cp "$KSDIR/audit.log" "$OUT/service-audit-master.log"; ns=$(grep -c ' SIGNED ' "$OUT/service-audit-master.log"); nr=$(grep -c ' REFUSED ' "$OUT/service-audit-master.log"); [ "$ns" -gt 0 ] && [ "$nr" = 0 ] && ok "the signing service of this node signed $ns statements and refused none" || no "the service audit log says: $ns signed, $nr refused (see $OUT/service-audit-master.log)"; else no "no audit log of the signing service in $KSDIR"; fi
( cd "$OUT" && tar czf "$OUT/verify-results.tar.gz" verify/*.txt verify/*.log verify/keylist 2>/dev/null ) && ok "the verification results are packed"
( cd "$OUT" && for f in before.tsv after.tsv nn-window.log master-logs.tar.gz crawl.log nonce policy.json crawl-command.sh verify-results.tar.gz service-audit-master.log; do [ -f "$f" ] && sha256sum "$f"; done ) >"$OUT/fingerprints.txt"; ok "fingerprints written ($(grep -c . "$OUT/fingerprints.txt") files)"
if [ $bad -eq 0 ]; then say "M513C-RUN-DONE ($RUN, mode $MODE, $((E-S)) s)"; exit 0; else say "M513C-RUN-FAILED ($bad): $RUN"; exit 1; fi
