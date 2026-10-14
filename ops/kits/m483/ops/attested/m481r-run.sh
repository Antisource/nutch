#!/usr/bin/env bash
# Milestone 4, baby step 4.8.1, part 2b: one wrapped crawl with the patched job, on the MASTER.
# It checks the state, prepares (log rotation, seeds, "before" listing), runs the crawl exactly as ops/run-crawl.sh does
# (same parameters; with MODE=on it adds the teammate's three settings), takes the "after" listing, cuts the NameNode's audit
# window and packs the master's logs. The WORKER must have been prepared first (its log rotation and NodeManager restart).
#
#   bash ops/attested/m481r-run.sh RUN MODE        RUN: a new name such as run11;  MODE: on (receipts on) | off (receipts off)
# Run it in tmux, from any folder. It never changes the cluster's configuration, and it stops before it starts if anything is off.
# Test hooks (rehearsal only): M481R_PATCHED, M481R_HDFS, M481R_YARN, M481R_JPS, M481R_ATT_TMP, M481R_NO_CRAWL_EXEC.
set -uo pipefail
U="usage: $0 RUN on|off"; RUN="${1:?$U}"; MODE="${2:?$U}"
case "$MODE" in on|off) ;; *) echo "$U" >&2; exit 2 ;; esac
PATCHED="${M481R_PATCHED:-$HOME/m481/patched}"; HDFS="${M481R_HDFS:-hdfs}"; YARN="${M481R_YARN:-yarn}"; JPS="${M481R_JPS:-jps}"
ATT_TMP="${M481R_ATT_TMP:-/tmp}"; HH="${HADOOP_HOME:-$HOME/hadoop}"; ATT="$PATCHED/ops/attested"; OUT="$HOME/$RUN"
JOB="$PATCHED/runtime/deploy/apache-nutch-1.22.job"; POL="$HOME/tc-policy/policy.json"; ME="$(whoami)"
SEEDS="/user/$ME/seeds-$RUN"; CRAWL="/user/$ME/crawl-$RUN"
bad=0; say() { echo "$*" | tee -a "$OUT/summary.txt" 2>/dev/null; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { echo "M481R-RUN-STOP: $*"; exit 1; }
fp() { sha256sum "$1" | cut -c1-64; }
[[ "$RUN" =~ ^[a-z0-9]+$ ]] || stop "RUN must be letters and digits only (for example run11)"
[ -e "$OUT" ] && stop "$OUT exists already; use a new run name"

echo "== state (nothing is changed before all of these pass)"
[ -f "$JOB" ] || stop "the patched job is not at $JOB"
WANT=$(awk '/^patched job /{print $3}' "$HOME/m481/evidence/fingerprints.txt" 2>/dev/null); [ -n "$WANT" ] || stop "no recorded fingerprint of the patched job (the build evidence is missing)"
[ "$(fp "$JOB")" = "$WANT" ] && echo "   ok:   the job is the patched job that the build proved (${WANT:0:16}...)" || stop "the job file is not the patched job of the build (sha256 $(fp "$JOB" | cut -c1-16), expected ${WANT:0:16})"
[ -f "$POL" ] && [ "$(fp "$POL")" = "$(cat "$POL.sha256" 2>/dev/null)" ] && echo "   ok:   the policy file is the one that was built and verified ($(fp "$POL" | cut -c1-16)...)" || stop "the policy file is missing or differs from its recorded fingerprint"
grep -q "AttestedHdfsFileSystem" "$HH/etc/hadoop/core-site.xml" && echo "   ok:   the cluster is in WRAPPED mode on this node" || stop "core-site.xml is not the wrapped version (run cluster-mode.sh wrapped first)"
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
say "m481r-run: $(date -u +%FT%TZ) on $(hostname)   run=$RUN mode=$MODE   job=${WANT:0:16}...   policy=$(fp "$POL" | cut -c1-16)..."
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
( cd "$OUT" && for f in before.tsv after.tsv nn-window.log master-logs.tar.gz crawl.log nonce policy.json crawl-command.sh; do [ -f "$f" ] && sha256sum "$f"; done ) >"$OUT/fingerprints.txt"; ok "fingerprints written ($(grep -c . "$OUT/fingerprints.txt") files)"
if [ $bad -eq 0 ]; then say "M481R-RUN-DONE ($RUN, mode $MODE, $((E-S)) s)"; exit 0; else say "M481R-RUN-FAILED ($bad): $RUN"; exit 1; fi
