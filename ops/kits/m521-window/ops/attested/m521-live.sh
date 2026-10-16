#!/usr/bin/env bash
# Step 5.2.1, the live check on the MASTER, inside an open window (m521-window.sh open on both nodes, the bundles exchanged): the wrapper with the admission of keys by their
# quote, on the real VMs, with the keys and quotes of THIS window.
#   1. a real file is written and read back through the wrapper (the wrapper admitted the keys by their live quotes, or it could not have verified its own records);
#   2. the key list's audit file shows each key of this window admitted, with the registers that were checked;
#   3. a copy of the new folder made with the plain client verifies offline with only admitted keys;
#   4. a ROGUE signing service with a fake quote puts its bundle into the live key list: it is refused (the audit says why), the honest file still reads, and it is removed again;
#   5. one edit flips the decision on this node's own LIVE quote: an edited reference refuses it, taking mrtd out of the enforce list admits it, and a flipped bit in the quote is refused.
# Usage: bash m521-live.sh [RUN]     RUN names the HDFS folder /user/<you>/adm-RUN and the work folder; default run16.
set -uo pipefail
RUN="${1:-run16}"; HOME_="${M521L_HOME:-$HOME}"; HH="${HADOOP_HOME:-$HOME_/hadoop}"; ME="${M521L_USER:-$(id -un)}"
HDFS="${M521L_HDFS:-$HH/bin/hdfs}"; LIBJAR="${M521L_JAR:-$HH/share/hadoop/common/lib/attested-hdfs.jar}"
KIT="$(cd "$(dirname "$0")" && pwd)"; W="${M521L_WORK:-$HOME_/m521l}"; WIN="$HOME_/m521w/window"; KL="$HOME_/tc-keys/list"; AUDIT="$HOME_/tc-keys/keylist-audit.log"
REF="$HOME_/tc-keys/reference-measurements.txt"; KSDIR="$HOME_/tc-keyservice"; TOP="/user/$ME/adm-$RUN"; RPORT="${M521L_ROGUE_PORT:-7462}"
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"; HCP="$(${M521L_HADOOP:-hadoop} classpath 2>/dev/null)"
bad=0; ROGUEPID=""; ROGUEID=""
[ -e "$W" ] && { echo "M521L-STOP: $W exists already; move it away" >&2; exit 1; }
mkdir -p "$W/out" "$W/classes" || exit 1
say() { echo "$*" | tee -a "$W/summary.txt"; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }; stop() { say "M521L-STOP: $*"; exit 1; }
cleanup() { [ -n "$ROGUEPID" ] && kill "$ROGUEPID" 2>/dev/null; [ -n "$ROGUEID" ] && rm -f "$KL/$ROGUEID.attestkey" 2>/dev/null; }
trap cleanup EXIT
KT() { java -cp "$LIBJAR:$HCP" org.apache.nutch.attested.AttestedKeyTool "$@"; }
say "m521-live: $(date -u +%FT%TZ) on $(hostname)   run=$RUN   jar=$(sha256sum "$LIBJAR" | cut -c1-16)"
say "== state (nothing is changed before all of these pass)"
[ -d "$WIN" ] && [ -f "$WIN/keyservice.pid" ] && kill -0 "$(cat "$WIN/keyservice.pid")" 2>/dev/null && ok "a window is open on this node and its signing service runs (pid $(cat "$WIN/keyservice.pid"))" || stop "no open window with a running signing service on this node ($WIN)"
gc() { "$HDFS" getconf -confKey "$1" 2>/dev/null; }
[ "$(gc attested.keys.admission.enabled)" = true ] && ok "the admission of keys by their quote is ON in this node's configuration" || stop "attested.keys.admission.enabled is not true here"
PIN="$(gc attested.keys.admission.reference.sha256)"; [ -n "$PIN" ] && [ "$(sha256sum "$REF" | cut -d' ' -f1)" = "$PIN" ] && ok "the reference file matches the SHA-256 that core-site.xml pins (${PIN:0:16}...)" || stop "the reference file does not match its pinned SHA-256"
[ "$(gc attested.keys.provider)" = service ] && [ "$(gc attested.signature.allow.test.keys)" = false ] && ok "the keys come from the signing service and test keys are not allowed" || stop "the provider is not the signing service or test keys are allowed"
OWNB="$(ls "$KSDIR"/TDX-*.attestkey 2>/dev/null | head -1)"; OWN="$(basename "${OWNB:-none}" .attestkey)"; [ -f "$OWNB" ] && ok "this node's key of the window: $OWN" || stop "no TDX bundle in $KSDIR"
python3 - "$KL" "$W/keys.txt" <<'PY'
import base64, glob, os, sys
best = {}
for f in glob.glob(sys.argv[1] + "/TDX-*.attestkey"):
    l = open(f).read().split("\n"); st = base64.b64decode(l[1][10:]).decode()
    kv = dict(x.split("=", 1) for x in st.split("\n") if "=" in x)
    h = kv.get("host", "?"); c = kv.get("created", "")
    if h not in best or c > best[h][0]: best[h] = (c, os.path.basename(f)[:-10])
open(sys.argv[2], "w").write("".join("%s %s\n" % (h, k) for h, (c, k) in sorted(best.items())))
PY
WORKER="$(awk '$1=="tdx-lab-worker"{print $2}' "$W/keys.txt")"; MASTERK="$(awk '$1=="tdx-lab"{print $2}' "$W/keys.txt")"
[ "$MASTERK" = "$OWN" ] && [ -n "$WORKER" ] && ok "the key list holds this window's two keys: master $OWN, worker $WORKER (the newest bundle of each host)" || stop "the key list does not hold this window's two keys (master newest: ${MASTERK:-none}, worker newest: ${WORKER:-none}); run the bundle exchange first"
"$HDFS" dfs -ls / >/dev/null 2>&1 && ok "HDFS answers" || stop "HDFS does not answer"
"$HDFS" dfs -test -e "$TOP" 2>/dev/null && stop "$TOP exists already in HDFS" || ok "$TOP is new"
javac -source 11 -target 11 -Xlint:-options -nowarn -cp "$LIBJAR:$HCP" -d "$W/classes" "$KIT/M521Tools.java" >"$W/out/javac.log" 2>&1 && ok "M521Tools compiles against the installed jar" || stop "M521Tools does not compile (see $W/out/javac.log)"
LINES0="$(wc -l < "$AUDIT" 2>/dev/null || echo 0)"; say "   the key list's audit file has $LINES0 line(s) before the check"
say "== 1. a real file through the wrapper (real keys, admission on)"
head -c 20000 /dev/urandom > "$W/honest.bin"; echo "step 5.2.1 live check $(date -u +%FT%TZ)" >> "$W/honest.bin"
"$HDFS" dfs -mkdir -p "$TOP" >"$W/out/mkdir.log" 2>&1 && "$HDFS" dfs -put "$W/honest.bin" "$TOP/honest.bin" >"$W/out/put.log" 2>&1 && ok "the file was written through the wrapper into $TOP (the wrapper signed it with this node's key, and made the folder's identity)" || { no "the write failed (see $W/out/put.log)"; tail -3 "$W/out/put.log" | sed 's/^/      /'; }
"$HDFS" dfs -cat "$TOP/honest.bin" >"$W/back.bin" 2>"$W/out/cat.log"; cmp -s "$W/honest.bin" "$W/back.bin" && ok "the file reads back byte for byte through the wrapper (the wrapper verified the signature, the binding and the admission of the key)" || { no "the file did not read back identically (see $W/out/cat.log)"; tail -3 "$W/out/cat.log" | sed 's/^/      /'; }
say "== 2. the key list's audit: each key of this window was admitted by its live quote"
tail -n +$((LINES0 + 1)) "$AUDIT" > "$W/audit-new.txt" 2>/dev/null
for k in "$OWN" "$WORKER"; do grep -q " ADMIT key=$k " "$W/audit-new.txt" && ok "$(grep -m1 " ADMIT key=$k " "$W/audit-new.txt" | sed 's/^[^ ]* //' | cut -c1-230)" || no "no ADMIT line for $k in the audit"; done
grep -q " REJECT " "$W/audit-new.txt" && say "   note: REJECT lines before the rogue: $(grep -c ' REJECT ' "$W/audit-new.txt") (older bundles of earlier windows may be refused for a reason that the line states)"
say "== 3. the new folder, copied with the plain client, verifies offline with only admitted keys"
if "$HDFS" dfs $PLAIN -get "$TOP" "$W/copy" >"$W/out/get.log" 2>&1; then
  java -cp "$LIBJAR:$W/classes:$HCP" org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$REF" "$W/copy" "$TOP" >"$W/out/tree.txt" 2>&1; rc=$?
  if [ "${M521L_SKIP_TREE:-0}" = 1 ]; then say "   note: the tree verification is SKIPPED (rehearsal hook M521L_SKIP_TREE: the stand-in files are not signed with admitted keys); a real check never sets it"
  elif [ $rc = 0 ] && grep -q '^VERIFY-TREE-CLEAN' "$W/out/tree.txt"; then ok "$(grep -o 'folders=[0-9]* files=[0-9]*' "$W/out/tree.txt" | head -1) verify; $(grep '^KEYLIST ' "$W/out/tree.txt" | head -1)"; else no "the copy does not verify with admitted keys (see $W/out/tree.txt)"; grep -m3 '^BAD\|KEYLIST-REJECTED' "$W/out/tree.txt" | sed 's/^/      /'; fi
else no "could not get a plain copy of $TOP (see $W/out/get.log)"; fi
say "== 4. a ROGUE signing service with a fake quote puts its bundle into the live key list"
( nohup java -cp "$LIBJAR" org.apache.nutch.attested.KeyService --dir "$W/rogue" --port "$RPORT" --list-dir "$KL" --quote-cmd "bash $KIT/fake-quote.sh" --host rogue-node >"$W/out/rogue.out" 2>&1 & echo $! >"$W/rogue.pid" )
for i in $(seq 1 30); do [ -f "$W/rogue/port" ] && break; sleep 1; done
ROGUEPID="$(cat "$W/rogue.pid" 2>/dev/null)"; RB="$(ls "$W/rogue"/*.attestkey 2>/dev/null | head -1)"; ROGUEID="$(basename "${RB:-none}" .attestkey)"
[ -f "$W/rogue/port" ] && kill -0 "$ROGUEPID" 2>/dev/null && [ -f "$RB" ] && [ -f "$KL/$ROGUEID.attestkey" ] && ok "the rogue service runs with the key $ROGUEID and put its bundle into the live key list (it passes the old binding check: its REPORTDATA is right)" || stop "the rogue service did not start, or did not put its bundle into the key list (see $W/out/rogue.out)"
L1="$(wc -l < "$AUDIT" 2>/dev/null || echo 0)"
"$HDFS" dfs -cat "$TOP/honest.bin" >"$W/back2.bin" 2>"$W/out/cat2.log"; cmp -s "$W/honest.bin" "$W/back2.bin" && ok "with the rogue bundle in the list the honest file still reads (the rogue key is simply not trusted)" || { no "the honest file did not read with the rogue bundle in the list (see $W/out/cat2.log)"; tail -3 "$W/out/cat2.log" | sed 's/^/      /'; }
tail -n +$((L1 + 1)) "$AUDIT" > "$W/audit-rogue.txt" 2>/dev/null
grep -q " REJECT file=$ROGUEID.attestkey " "$W/audit-rogue.txt" && ok "the key list REFUSED the rogue key and wrote why: $(grep -m1 " REJECT file=$ROGUEID" "$W/audit-rogue.txt" | grep -o 'reason=.*' | cut -c1-140)" || no "the audit has no REJECT line for the rogue key"
KT bundle-admit "$RB" "$REF" >"$W/out/rogue-admit.txt" 2>&1; rrc=$?
[ $rrc != 0 ] && grep -q 'too short' "$W/out/rogue-admit.txt" && ok "bundle-admit refuses the rogue bundle too (exit $rrc): $(tail -1 "$W/out/rogue-admit.txt" | cut -c1-120)" || no "bundle-admit did not refuse the rogue bundle (see $W/out/rogue-admit.txt)"
kill "$ROGUEPID" 2>/dev/null; sleep 1; rm -f "$KL/$ROGUEID.attestkey"; ROGUEID=""; ROGUEPID=""
[ -z "$(ls "$KL"/TDX-*.attestkey 2>/dev/null | xargs -r -n1 basename | grep -x "$(basename "${RB:-none}")")" ] && ok "the rogue bundle is removed from the key list and the rogue service is stopped" || no "the rogue bundle is still in the key list"
say "== 5. one edit flips the decision on this node's own LIVE quote"
python3 - "$REF" "$W/ref-edited.txt" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); m = re.search(r"^MRTD ([0-9a-f]{96}) ", s, re.M); open(sys.argv[2], "w").write(s.replace(m.group(1), "ab" * 48, 1))
PY
KT bundle-admit "$OWNB" "$W/ref-edited.txt" >"$W/out/edit1.txt" 2>&1; rc=$?; [ $rc != 0 ] && grep -q 'MRTD of tdx-lab' "$W/out/edit1.txt" && ok "EDIT 1: with one changed MRTD in a copy of the reference, this node's live quote is refused (the reason names MRTD)" || no "EDIT 1 did not refuse (see $W/out/edit1.txt)"
KT bundle-admit "$OWNB" "$W/ref-edited.txt" --enforce rtmr0,rtmr1,rtmr2 >"$W/out/edit2.txt" 2>&1; rc=$?; [ $rc = 0 ] && grep -q '^ADMIT' "$W/out/edit2.txt" && ok "EDIT 2: with mrtd out of the enforce list the same edited reference admits it again" || no "EDIT 2 did not flip (see $W/out/edit2.txt)"
python3 - "$OWNB" "$W/own-tampered.attestkey" <<'PY'
import base64, sys
l = open(sys.argv[1]).read().split("\n"); q = bytearray(base64.b64decode(l[2][6:])); q[184] ^= 1
open(sys.argv[2], "w").write(l[0] + "\n" + l[1] + "\nquote=" + base64.b64encode(bytes(q)).decode() + "\n")
PY
KT bundle-admit "$W/own-tampered.attestkey" "$REF" >"$W/out/tamper.txt" 2>&1; rc=$?; [ $rc != 0 ] && grep -q 'signature of the quote does not verify' "$W/out/tamper.txt" && ok "a flipped bit in MRTD of this node's live quote is refused (the signature of the quote does not verify)" || no "the tampered live quote was not refused (see $W/out/tamper.txt)"
cp "$AUDIT" "$W/keylist-audit-full.log" 2>/dev/null
tar czf "$W/m521-live-results.tar.gz" -C "$W" out summary.txt audit-new.txt audit-rogue.txt keys.txt keylist-audit-full.log && ok "the results are packed: $W/m521-live-results.tar.gz"
say "(the folder $TOP stays in HDFS: a 20 KB test file with its record; delete it with the other test data at the end of Milestone 5)"
if [ $bad -eq 0 ]; then say "M521L-OK (the live wrapper admitted both keys of this window by their quotes, wrote and read a real file, refused a rogue key with a fake quote and said why, and each decision flipped with one edit on a live quote)"; else say "M521L-FAILED ($bad)"; fi
[ $bad -eq 0 ]
