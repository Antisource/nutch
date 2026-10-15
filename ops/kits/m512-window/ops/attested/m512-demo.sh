#!/usr/bin/env bash
# Milestone 5, baby step 5.1.2, part 3: the folder binding, shown on the real HDFS.
# "A signed file moved or copied into another folder, or under another name, fails the read; a rename signs one new record; a folder rename
#  signs only the folder's own identity file."
#
#   bash ops/attested/m512-demo.sh NEWJAR [WORKDIR]       run on the MASTER while the window is open (m512-window.sh open master ...)
#
# It makes a small folder tree in HDFS through the wrapper (so every folder has a signed identity and every file a record bound to its folder),
# shows the honest operations (a file rename and a folder rename, with the records inside a renamed folder byte for byte unchanged), and then
# plays the attacker with the PLAIN client (the wrapper cannot stop that, which is the point): every attack must make the read through the wrapper fail,
# with the right reason. The honest state is put back after each attack, and a copy of the whole tree is checked offline with the public key only.
# Attacks: 1 swap two same-named files between two folders  2 a file and its record copied under another name  3 a file and its record moved into
# another folder  4 a whole folder copied elsewhere (4b: under another parent with the same name)  5 another folder's identity planted
# 6 the identity deleted  7 the identity signed with the attacker's key  8 a folder renamed behind the wrapper's back (and the wrapper then refuses to
# sign it again)  9 an unsigned file added  10 a forged record that the wrapper must not sign again when asked to rename the file.
# Test hooks (rehearsal only): M512D_HOST, M512D_USER, M512D_BUSY, M512D_AUDIT, M512D_JAVAC.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
NEWJAR="${1:?usage: $0 NEWJAR [WORKDIR]}"; W="${2:-$HOME/m512w/demo}"
case "$NEWJAR" in /*) ;; *) NEWJAR="$PWD/$NEWJAR" ;; esac; case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
HH="${HADOOP_HOME:-$HOME/hadoop}"; HDFS="$HH/bin/hdfs"; ME="${M512D_USER:-$(id -un)}"; HOST="${M512D_HOST:-$(hostname)}"
BUSY="${M512D_BUSY:-/opt/tc-shared/state/BUSY}"; AUDIT="${M512D_AUDIT:-/tmp/attested-audit}"; JAVAC="${M512D_JAVAC:-javac}"
# the full path that the top folder's identity records (rehearsal hook M512D_TOPPREFIX: the rehearsal keeps its fake HDFS root inside a local folder)
TOPPREFIX="${M512D_TOPPREFIX:-}"
KEYFILE="$HOME/tc-test-key/test-key.txt"; PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
[ "$HOST" = tdx-lab ] || { echo "M512-DEMO-STOP: this runs on the master (tdx-lab), not on $HOST" >&2; exit 1; }
[ ! -e "$W" ] || { echo "M512-DEMO-STOP: $W exists already; nothing was changed" >&2; exit 1; }
mkdir -p "$W/logs" "$W/evidence" || exit 1
bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M512-DEMO-STOP: $*"; exit 1; }
say "m512-demo: $(date -u +%FT%TZ) on $HOST   user=$ME"

say "== checks"
[ -f "$BUSY" ] && [ "$(cut -f1 "$BUSY")" = "$ME" ] && ok "the cluster is reserved by you" || stop "reserve the cluster first: tc-busy.sh start \"folder binding test\""
[ -f "$NEWJAR" ] || stop "the new jar is not at $NEWJAR"
for k in attested.signature.enabled attested.signature.required attested.folder.binding.enabled attested.folder.binding.required; do
  [ "$("$HDFS" getconf -confKey $k 2>/dev/null)" = true ] || stop "$k is not true here: the window is not open on this node (run m512-window.sh open master ...)"
done
ok "signing and folder binding are on and required here (the window is open)"
[ -f "$KEYFILE" ] && ok "the test key file is there" || stop "no test key file at $KEYFILE"
mkdir -p "$W/tools-classes"
$JAVAC -source 11 -target 11 -Xlint:-options -nowarn -cp "$NEWJAR" -d "$W/tools-classes" "$KIT/M512Tools.java" > "$W/logs/javac.log" 2>&1 && ok "the demonstration tools compile against the new jar" || { head -5 "$W/logs/javac.log"; stop "the tools do not compile"; }
T() { java -cp "$NEWJAR:$W/tools-classes" org.apache.nutch.attested.M512Tools "$@"; }
java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool public "$KEYFILE" "$W/public-key.txt" > "$W/logs/pubkey.log" 2>&1 && ok "a public-only copy of the key is made for the offline check ($(grep -o 'TEST-[0-9a-f]*' "$W/logs/pubkey.log" | head -1))" || stop "cannot make the public copy (see $W/logs/pubkey.log)"
before_fail="$(cat "$AUDIT"/*.tsv 2>/dev/null | grep -c 'VERIFY-FAIL' || true)"

python3 - "$W" <<'PY'
import sys
w = sys.argv[1]
open(w + "/honestA.bin", "wb").write(bytes((i * 7 + 1) % 256 for i in range(50000)))
open(w + "/honestB.bin", "wb").write(bytes((i * 13 + 3) % 256 for i in range(40000)))
open(w + "/evil.bin", "wb").write(bytes((i * 11 + 5) % 256 for i in range(50000)))
PY
D="/user/$ME/m512-demo-$(date +%s)"; TOP="$TOPPREFIX$D"; A="$D/seg1/part-r-00000"; B="$D/seg2/part-r-00000"
same() { cmp -s "$1" "$2"; }
catw() { "$HDFS" dfs -cat "$1" > "$2" 2> "$3"; }     # catw <hdfs path> <local out> <local err>
snap() { rm -rf "$W/$1"; "$HDFS" dfs $PLAIN -get "$D" "$W/$1" 2>/dev/null; }

say "== the honest tree (made through the wrapper: identities and bound records)"
"$HDFS" dfs -mkdir -p "$D/seg1" "$D/seg2" && "$HDFS" dfs -put "$W/honestA.bin" "$A" && "$HDFS" dfs -put "$W/honestB.bin" "$B" && ok "made $D with seg1 and seg2 and a file in each" || stop "cannot make the honest tree"
catw "$A" "$W/readA.bin" "$W/logs/readA.err" && same "$W/readA.bin" "$W/honestA.bin" && catw "$B" "$W/readB.bin" "$W/logs/readB.err" && same "$W/readB.bin" "$W/honestB.bin" && ok "both files read back through the wrapper: identical (record, folder identity chain and signatures checked)" || { head -3 "$W/logs/readA.err"; stop "the honest files do not read back"; }
snap snap0
T verify-tree "$W/public-key.txt" "$W/snap0" "$TOP" > "$W/logs/verify-snap0.txt" 2>&1; tail -3 "$W/logs/verify-snap0.txt" | sed 's/^/      /' | tee -a "$W/summary.txt"
grep -q "^VERIFY-TREE-CLEAN" "$W/logs/verify-snap0.txt" && grep -q "folders=3 files=2 ok=2 bad=0" "$W/logs/verify-snap0.txt" && ok "offline: a local copy of the whole tree verifies with the public key only (3 folders, 2 files)" || no "the honest tree does not verify offline"
T inspect "$W/snap0/seg1/.part-r-00000.attested" > "$W/logs/inspect-rec.txt" 2>&1; T inspect "$W/snap0/seg1/_attested-folder" > "$W/logs/inspect-id.txt" 2>&1; T inspect "$W/snap0/_attested-folder" > "$W/logs/inspect-top.txt" 2>&1
grep -q "ATTEST03.*name=part-r-00000" "$W/logs/inspect-rec.txt" && grep -q "name=seg1 .*parent=" "$W/logs/inspect-id.txt" && grep -q "top path=$TOP" "$W/logs/inspect-top.txt" && ok "the record is ATTEST03 and names its folder and file; seg1's identity names its parent; the top folder is bound to its full path ($D)" || no "the records or identities are not in the expected format"

say "== the honest operations"
"$HDFS" dfs -mv "$A" "$D/seg2/moved" && catw "$D/seg2/moved" "$W/m1.bin" "$W/logs/m1.err" && same "$W/m1.bin" "$W/honestA.bin" && ok "renaming a file into another folder works, and it reads" || no "the honest file rename failed (see $W/logs/m1.err)"
"$HDFS" dfs $PLAIN -get "$D/seg2/.moved.attested" "$W/moved.rec" 2>/dev/null; T inspect "$W/moved.rec" > "$W/logs/inspect-moved.txt" 2>&1
grep -q "name=moved" "$W/logs/inspect-moved.txt" && ok "its record was signed again for the new folder and name: $(cut -c1-110 "$W/logs/inspect-moved.txt")" || no "the record of the renamed file does not name the new name"
"$HDFS" dfs -mv "$D/seg2/moved" "$A" && catw "$A" "$W/m2.bin" "$W/logs/m2.err" && same "$W/m2.bin" "$W/honestA.bin" && ok "and back again: it reads" || no "the file could not be renamed back"
"$HDFS" dfs $PLAIN -cat "$D/seg2/.part-r-00000.attested" > "$W/recB-before.bin" 2>/dev/null; "$HDFS" dfs $PLAIN -get "$D/seg2/_attested-folder" "$W/idB-before.bin" 2>/dev/null
"$HDFS" dfs -mv "$D/seg2" "$D/seg2b" && catw "$D/seg2b/part-r-00000" "$W/m3.bin" "$W/logs/m3.err" && same "$W/m3.bin" "$W/honestB.bin" && ok "renaming a folder works, and the file inside reads" || no "the folder rename failed (see $W/logs/m3.err)"
"$HDFS" dfs $PLAIN -cat "$D/seg2b/.part-r-00000.attested" > "$W/recB-after.bin" 2>/dev/null; "$HDFS" dfs $PLAIN -get "$D/seg2b/_attested-folder" "$W/idB-after.bin" 2>/dev/null
same "$W/recB-before.bin" "$W/recB-after.bin" && ok "the record of the file inside the renamed folder is byte for byte unchanged (nothing below the folder was touched)" || no "the record inside the renamed folder changed"
T inspect "$W/idB-before.bin" > "$W/logs/idB-before.txt" 2>&1; T inspect "$W/idB-after.bin" > "$W/logs/idB-after.txt" 2>&1
idb="$(grep -o ' id=[0-9a-f]*' "$W/logs/idB-before.txt")"; ida="$(grep -o ' id=[0-9a-f]*' "$W/logs/idB-after.txt")"
[ -n "$idb" ] && [ "$idb" = "$ida" ] && grep -q "name=seg2b" "$W/logs/idB-after.txt" && ! same "$W/idB-before.bin" "$W/idB-after.bin" && ok "only the folder's own identity file was signed again: the same folder ID, the new name seg2b" || no "the identity of the renamed folder is not as expected (before: $(cat "$W/logs/idB-before.txt"); after: $(cat "$W/logs/idB-after.txt"))"
"$HDFS" dfs -mv "$D/seg2b" "$D/seg2" && catw "$B" "$W/m4.bin" "$W/logs/m4.err" && same "$W/m4.bin" "$W/honestB.bin" && ok "and back again: it reads" || no "the folder could not be renamed back"
snap snap1
T verify-tree "$W/public-key.txt" "$W/snap1" "$TOP" > "$W/logs/verify-snap1.txt" 2>&1; grep -q "^VERIFY-TREE-CLEAN" "$W/logs/verify-snap1.txt" && ok "after the renames the tree still verifies offline (this copy is what each attack is undone from)" || { cat "$W/logs/verify-snap1.txt" | head -5; stop "the tree does not verify after the honest renames"; }

put() { "$HDFS" dfs $PLAIN -put -f "$1" "$2" > /dev/null 2>&1; }
restore() {
  for x in seg1x seg1y seg1-copy other seg2/stolen seg1/copy-of-a seg1/extra seg1/laundered; do "$HDFS" dfs $PLAIN -rm -r -f -skipTrash "$D/$x" > /dev/null 2>&1; done
  "$HDFS" dfs $PLAIN -test -d "$D/seg1" || "$HDFS" dfs $PLAIN -mkdir -p "$D/seg1" > /dev/null 2>&1
  for s in seg1 seg2; do for f in part-r-00000 .part-r-00000.attested _attested-folder; do put "$W/snap1/$s/$f" "$D/$s/$f"; done; done
  put "$W/snap1/_attested-folder" "$D/_attested-folder"
}
failread() { # failread <number> <what> <hdfs path> <expected text>
  catw "$3" /dev/null "$W/logs/attack$1.err"; rc=$?
  msg="$(grep -m1 -o 'Attested verification failed.*' "$W/logs/attack$1.err" | cut -c1-175)"; [ -n "$msg" ] || msg="$(head -1 "$W/logs/attack$1.err" | cut -c1-175)"
  if [ $rc != 0 ] && grep -q "$4" "$W/logs/attack$1.err"; then ok "attack $2: the read FAILS: ${msg#*: }"; else no "attack $2: expected the read to fail with '$4'; exit code $rc, message: ${msg:-none}"; fi
}
failmv() { # failmv <number> <what> <from> <to>
  "$HDFS" dfs -mv "$3" "$4" > /dev/null 2> "$W/logs/attack$1.err"; rc=$?
  if [ $rc != 0 ] && grep -q "rename refused" "$W/logs/attack$1.err"; then ok "attack $2: the wrapper's rename is REFUSED: $(grep -m1 -o 'rename refused.*' "$W/logs/attack$1.err" | cut -c1-170)"; else no "attack $2: expected the rename to be refused; exit code $rc, message: $(head -1 "$W/logs/attack$1.err" | cut -c1-170)"; fi
}
honest_again() { catw "$A" "$W/h.bin" "$W/logs/h.err" && same "$W/h.bin" "$W/honestA.bin" && catw "$B" "$W/h.bin" "$W/logs/h.err" && same "$W/h.bin" "$W/honestB.bin"; }

say "== the attacker, with the plain client (behind the wrapper's back)"
put "$W/snap1/seg2/part-r-00000" "$A"; put "$W/snap1/seg2/.part-r-00000.attested" "$D/seg1/.part-r-00000.attested"; put "$W/snap1/seg1/part-r-00000" "$B"; put "$W/snap1/seg1/.part-r-00000.attested" "$D/seg2/.part-r-00000.attested"
failread 1a "1, two same-named files swapped between two folders (seg1's read)" "$A" "another folder"; failread 1b "1, the same swap (seg2's read)" "$B" "another folder"
restore; honest_again && ok "undone: both files read again" || no "the honest state could not be restored after attack 1"
put "$W/snap1/seg1/part-r-00000" "$D/seg1/copy-of-a"; put "$W/snap1/seg1/.part-r-00000.attested" "$D/seg1/.copy-of-a.attested"
failread 2 "2, a file and its record copied under another name in the same folder" "$D/seg1/copy-of-a" "is for a file named"
put "$W/snap1/seg1/part-r-00000" "$D/seg2/stolen"; put "$W/snap1/seg1/.part-r-00000.attested" "$D/seg2/.stolen.attested"
failread 3 "3, a file and its record moved into another folder" "$D/seg2/stolen" "another folder"
"$HDFS" dfs $PLAIN -cp "$D/seg1" "$D/seg1-copy" > /dev/null 2>&1
failread 4 "4, a whole folder copied elsewhere (the identity names another folder name)" "$D/seg1-copy/part-r-00000" "is for a folder named"
"$HDFS" dfs -mkdir -p "$D/other" > /dev/null 2>&1; "$HDFS" dfs $PLAIN -cp "$D/seg1" "$D/other/seg1" > /dev/null 2>&1
failread 4b "4b, a folder copied under another parent with the same name (the identity points to the old parent)" "$D/other/seg1/part-r-00000" "points to another parent"
restore
put "$W/snap1/seg2/_attested-folder" "$D/seg1/_attested-folder"
failread 5 "5, another folder's identity planted in seg1" "$A" "is for a folder named"
restore; "$HDFS" dfs $PLAIN -rm -skipTrash "$D/seg1/_attested-folder" > /dev/null 2>&1
failread 6 "6, the identity file deleted" "$A" "has no identity"
restore; T forge-identity "$W/snap1/seg1/_attested-folder" "$W/forged-id.bin" > "$W/logs/forge-id.txt" 2>&1 || { cat "$W/logs/forge-id.txt"; stop "cannot forge the identity"; }
put "$W/forged-id.bin" "$D/seg1/_attested-folder"
failread 7 "7, seg1's identity signed with the attacker's key under the real key id" "$A" "does not verify"
restore; "$HDFS" dfs $PLAIN -mv "$D/seg1" "$D/seg1x" > /dev/null 2>&1
failread 8a "8, a folder renamed behind the wrapper's back (its identity names the old name)" "$D/seg1x/part-r-00000" "is for a folder named"
failmv 8b "8, and the wrapper does not sign that folder again when asked to rename it" "$D/seg1x" "$D/seg1y"
"$HDFS" dfs $PLAIN -mv "$D/seg1x" "$D/seg1" > /dev/null 2>&1; restore
put "$W/evil.bin" "$D/seg1/extra"
failread 9 "9, an unsigned file added to a folder" "$D/seg1/extra" "no record"
restore; T forge-record "$W/evil.bin" "$W/snap1/seg1/.part-r-00000.attested" "$W/forged-rec.bin" > "$W/logs/forge-rec.txt" 2>&1 || { cat "$W/logs/forge-rec.txt"; stop "cannot forge the record"; }
put "$W/evil.bin" "$A"; put "$W/forged-rec.bin" "$D/seg1/.part-r-00000.attested"
failmv 10a "10, a forged record (right folder, right name, the attacker's signature): the wrapper must not sign it again" "$A" "$D/seg1/laundered"
failread 10b "10, the same forged record read through the wrapper" "$A" "does not verify"
restore; honest_again && ok "everything undone: both honest files read again" || no "the honest state could not be restored at the end"

say "== the audit log, the offline check of the end state, and the clean-up"
after_fail="$(cat "$AUDIT"/*.tsv 2>/dev/null | grep -c 'VERIFY-FAIL' || true)"
[ $((after_fail - before_fail)) -ge 14 ] && ok "the audit log has $((after_fail - before_fail)) new VERIFY-FAIL lines (every refused read and every refused rename)" || no "the audit log has only $((after_fail - before_fail)) new VERIFY-FAIL lines, expected at least 14"
cat "$AUDIT"/*.tsv 2>/dev/null | grep -F "$D/seg1/part-r-00000" | grep -F "OPEN" | grep -q "sig=ok-test bind=ok" && ok "the honest reads are logged as verify=ok sig=ok-test bind=ok" || no "no honest read is logged with bind=ok"
snap snap2; T verify-tree "$W/public-key.txt" "$W/snap2" "$TOP" > "$W/logs/verify-snap2.txt" 2>&1; grep -q "^VERIFY-TREE-CLEAN" "$W/logs/verify-snap2.txt" && ok "offline: the tree after all attacks and their undoing verifies again" || no "the final tree does not verify offline"
"$HDFS" dfs -rm -r -skipTrash "$D" > /dev/null 2>&1; "$HDFS" dfs $PLAIN -test -e "$D" && no "the demonstration folder is still there" || ok "the demonstration folder is removed ($D)"

cp "$W/summary.txt" "$W/evidence/"; cp "$W/logs/"* "$W/evidence/" 2>/dev/null; cp "$W/forged-id.bin" "$W/forged-rec.bin" "$W/moved.rec" "$W/evidence/" 2>/dev/null
if [ $bad -eq 0 ]; then say "M512-DEMO-OK (every attack was refused with the right reason, the honest renames work and sign only what they must, and the offline check agrees)"; else say "M512-DEMO-FAILED ($bad): see the FAIL lines above"; fi
cp "$W/summary.txt" "$W/evidence/"
( cd "$W/evidence" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
( cd "$W" && tar czf "$W/../evidence-m512-demo.tar.gz" evidence && sha256sum "$W/../evidence-m512-demo.tar.gz" | cut -c1-64 )
[ $bad -eq 0 ]
