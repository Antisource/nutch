#!/usr/bin/env bash
# Milestone 5, baby step 5.1.1, part 3: the pass condition of the step, shown on the real HDFS.
# "A file rewritten together with its record, without the key, fails the read."
#
#   bash ops/attested/m511-demo.sh NEWJAR [WORKDIR]       run on the MASTER while the window is open (m511-window.sh open)
#
# It makes one small folder in HDFS, writes a file through the wrapper (so it is signed), and then plays the attacker with the PLAIN client
# (the wrapper cannot stop that, which is the whole point): each attack changes the file and/or its record behind the wrapper's back, and
# every read through the wrapper must fail with the right reason. It also checks the honest file reads, verifies the signed data offline
# on a local copy with the public key only, counts the VERIFY-FAIL lines in the audit log, and removes its folder.
# Attacks: (1) only the file changed  (2) file and an UNSIGNED record  (3) file and a record with the OLD signature copied
#          (4) file and a record signed with the attacker's key under the REAL key id  (5) the same under the attacker's OWN key id
#          (6) the record deleted  (7) a new file with no record at all.
# Test hooks (rehearsal only): M511D_HOST, M511D_USER, M511D_BUSY, M511D_AUDIT, M511D_JAVAC.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
NEWJAR="${1:?usage: $0 NEWJAR [WORKDIR]}"; W="${2:-$HOME/m511/demo}"
case "$NEWJAR" in /*) ;; *) NEWJAR="$PWD/$NEWJAR" ;; esac; case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
HH="${HADOOP_HOME:-$HOME/hadoop}"; HDFS="$HH/bin/hdfs"; ME="${M511D_USER:-$(id -un)}"; HOST="${M511D_HOST:-$(hostname)}"
BUSY="${M511D_BUSY:-/opt/tc-shared/state/BUSY}"; AUDIT="${M511D_AUDIT:-/tmp/attested-audit}"; JAVAC="${M511D_JAVAC:-javac}"
KEYFILE="$HOME/tc-test-key/test-key.txt"; PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
[ "$HOST" = tdx-lab ] || { echo "M511-DEMO-STOP: this runs on the master (tdx-lab), not on $HOST" >&2; exit 1; }
[ ! -e "$W" ] || { echo "M511-DEMO-STOP: $W exists already; nothing was changed" >&2; exit 1; }
mkdir -p "$W/logs" "$W/evidence" || exit 1
bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M511-DEMO-STOP: $*"; exit 1; }
say "m511-demo: $(date -u +%FT%TZ) on $HOST   user=$ME"

say "== checks"
[ -f "$BUSY" ] && [ "$(cut -f1 "$BUSY")" = "$ME" ] && ok "the cluster is reserved by you" || stop "reserve the cluster first: tc-busy.sh start \"signed wrapper test\""
[ -f "$NEWJAR" ] || stop "the new jar is not at $NEWJAR"
[ "$("$HDFS" getconf -confKey attested.signature.enabled 2>/dev/null)" = true ] && [ "$("$HDFS" getconf -confKey attested.signature.required 2>/dev/null)" = true ] && ok "signing is on and signatures are required here (the window is open)" || stop "the window is not open on this node: signing is not on (run m511-window.sh open master ...)"
[ -f "$KEYFILE" ] && ok "the test key file is there" || stop "no test key file at $KEYFILE"
mkdir -p "$W/tools-classes"
$JAVAC -source 11 -target 11 -Xlint:-options -nowarn -cp "$NEWJAR" -d "$W/tools-classes" "$KIT/M511Tools.java" > "$W/logs/javac.log" 2>&1 && ok "the demonstration tools compile against the new jar" || { cat "$W/logs/javac.log" | head -5; stop "the tools do not compile"; }
T() { java -cp "$NEWJAR:$W/tools-classes" org.apache.nutch.attested.M511Tools "$@"; }
java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool public "$KEYFILE" "$W/public-key.txt" > "$W/logs/pubkey.log" 2>&1 && ok "a public-only copy of the key is made for the offline check ($(grep -o 'TEST-[0-9a-f]*' "$W/logs/pubkey.log" | head -1))" || stop "cannot make the public copy (see $W/logs/pubkey.log)"
before_fail="$(cat "$AUDIT"/*.tsv 2>/dev/null | grep -c 'VERIFY-FAIL' || true)"

python3 - "$W" <<'PY'
import sys
w = sys.argv[1]
open(w + "/honest.bin", "wb").write(bytes((i * 7 + 1) % 256 for i in range(50000)))
open(w + "/evil.bin", "wb").write(bytes((i * 11 + 5) % 256 for i in range(50000)))
PY
D="/user/$ME/m511-demo-$(date +%s)"
say "== the honest file (written through the wrapper, so it is signed)"
"$HDFS" dfs -mkdir -p "$D" && "$HDFS" dfs -put "$W/honest.bin" "$D/a.bin" && ok "written to $D/a.bin" || stop "cannot write the honest file"
"$HDFS" dfs -cat "$D/a.bin" > "$W/read-honest.bin" 2>"$W/logs/read-honest.err" && cmp -s "$W/read-honest.bin" "$W/honest.bin" && ok "read back through the wrapper: identical (the signature was checked, signatures are required)" || { cat "$W/logs/read-honest.err" | head -3; stop "the honest file does not read back"; }
"$HDFS" dfs $PLAIN -get "$D/.a.bin.attested" "$W/rec.honest" 2>/dev/null
[ "$(head -c 8 "$W/rec.honest")" = "ATTEST02" ] && grep -aq "TEST-" "$W/rec.honest" && ok "its record is ATTEST02 and names a TEST- key" || no "the record of the honest file is not a signed ATTEST02 record"
rm -rf "$W/copy-honest"; "$HDFS" dfs $PLAIN -get "$D" "$W/copy-honest" 2>/dev/null
T verify "$W/public-key.txt" "$W/copy-honest" > "$W/logs/verify-honest.txt" 2>&1; tail -3 "$W/logs/verify-honest.txt" | sed 's/^/      /' | tee -a "$W/summary.txt"
grep -q "^VERIFY-DIR-CLEAN" "$W/logs/verify-honest.txt" && ok "offline: a local copy verifies with the public key only (signature, chunk hashes, length)" || no "the honest copy does not verify offline"

attack() { # attack <number> <name> <expected text>   (the attack has been applied; the read must fail)
  "$HDFS" dfs -cat "$D/a.bin" > /dev/null 2> "$W/logs/attack$1.err"; rc=$?
  msg="$(grep -m1 -o 'Attested verification failed.*' "$W/logs/attack$1.err" | cut -c1-170)"; [ -n "$msg" ] || msg="$(head -1 "$W/logs/attack$1.err" | cut -c1-170)"
  if [ $rc != 0 ] && grep -q "$3" "$W/logs/attack$1.err"; then ok "attack $1, $2: the read FAILS: ${msg#*: }"; else no "attack $1, $2: expected the read to fail with '$3'; exit code $rc, message: ${msg:-none}"; fi
}
restore_honest() { "$HDFS" dfs $PLAIN -put -f "$W/honest.bin" "$D/a.bin" >/dev/null 2>&1 && "$HDFS" dfs $PLAIN -put -f "$W/rec.honest" "$D/.a.bin.attested" >/dev/null 2>&1; }
say "== the attacker, with the plain client (behind the wrapper's back)"
"$HDFS" dfs $PLAIN -put -f "$W/evil.bin" "$D/a.bin" >/dev/null 2>&1 && attack 1 "only the file changed" "Attested verification failed"
for spec in "2:unsigned:file and an UNSIGNED record:not signed" "3:oldsig:file and a record with the OLD signature copied:does not verify" "4:attacker-real-id:file and a record signed by the attacker under the REAL key id:does not verify" "5:attacker-own-id:file and a record signed by the attacker under its OWN key id:not trusted"; do
  IFS=: read -r n mode name why <<<"$spec"
  T forge "$mode" "$W/evil.bin" "$W/rec.honest" "$W/forged$n.rec" > "$W/logs/forge$n.txt" 2>&1 || { cat "$W/logs/forge$n.txt"; stop "cannot forge the record for attack $n"; }
  "$HDFS" dfs $PLAIN -put -f "$W/forged$n.rec" "$D/.a.bin.attested" >/dev/null 2>&1 && attack "$n" "$name" "$why"
  if [ "$n" = 4 ]; then rm -rf "$W/copy-attack"; "$HDFS" dfs $PLAIN -get "$D" "$W/copy-attack" 2>/dev/null; T verify "$W/public-key.txt" "$W/copy-attack" > "$W/logs/verify-attack.txt" 2>&1; grep -q "does not verify" "$W/logs/verify-attack.txt" && ok "offline: the same forgery is found on a local copy ($(grep -m1 BAD "$W/logs/verify-attack.txt" | cut -c1-100))" || no "the offline check did not find attack 4"; fi
done
restore_honest && "$HDFS" dfs -cat "$D/a.bin" 2>/dev/null | cmp -s - "$W/honest.bin" && ok "the honest file and its honest record read again after the attacks were undone" || no "the honest file does not read after it was restored"
"$HDFS" dfs $PLAIN -rm "$D/.a.bin.attested" >/dev/null 2>&1 && attack 6 "the record deleted (the file stays)" "Attested verification failed"
restore_honest
"$HDFS" dfs $PLAIN -put "$W/evil.bin" "$D/b.bin" >/dev/null 2>&1; "$HDFS" dfs -cat "$D/b.bin" > /dev/null 2> "$W/logs/attack7.err"; rc=$?
[ $rc != 0 ] && grep -q "Attested verification failed" "$W/logs/attack7.err" && ok "attack 7, a new file with no record at all: the read FAILS: $(grep -m1 -o 'Attested verification failed.*' "$W/logs/attack7.err" | cut -c1-150 | sed 's/^[^:]*: //')" || no "attack 7: a file with no record was read (exit code $rc)"

say "== the audit log and the clean-up"
after_fail="$(cat "$AUDIT"/*.tsv 2>/dev/null | grep -c 'VERIFY-FAIL' || true)"
[ $((after_fail - before_fail)) -ge 7 ] && ok "the audit log has $((after_fail - before_fail)) new VERIFY-FAIL lines (one per refused read, 7 attacks)" || no "the audit log has only $((after_fail - before_fail)) new VERIFY-FAIL lines, expected at least 7"
cat "$AUDIT"/*.tsv 2>/dev/null | grep -F "$D/a.bin" | grep -F "OPEN" | grep -q "sig=ok-test" && ok "the honest reads are logged as verify=ok sig=ok-test" || no "no honest read is logged with sig=ok-test"
"$HDFS" dfs -rm -r -skipTrash "$D" >/dev/null 2>&1; "$HDFS" dfs $PLAIN -test -e "$D" && no "the demonstration folder is still there" || ok "the demonstration folder is removed ($D)"

cp "$W/summary.txt" "$W/evidence/"; cp "$W/logs/"*.err "$W/logs/"*.txt "$W/evidence/" 2>/dev/null; cp "$W/forged"*.rec "$W/rec.honest" "$W/evidence/" 2>/dev/null
if [ $bad -eq 0 ]; then say "M511-DEMO-OK (7 attacks were refused with the right reasons, the honest file reads, and the offline check agrees)"; else say "M511-DEMO-FAILED ($bad): see the FAIL lines above"; fi
cp "$W/summary.txt" "$W/evidence/"
( cd "$W/evidence" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
( cd "$W" && tar czf "$W/../evidence-m511-demo.tar.gz" evidence && sha256sum "$W/../evidence-m511-demo.tar.gz" | cut -c1-64 )
[ $bad -eq 0 ]
