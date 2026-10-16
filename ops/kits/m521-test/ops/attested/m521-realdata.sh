#!/usr/bin/env bash
# Step 5.2.1: the admission check against REAL data that already exists on the master: the two real bundles of run 15 (with their hardware quotes) and the plain copy of run 15's
# whole output. Nothing on the cluster is touched; it only reads files under ~/run15 and the scratch tree.
#   bash ops/attested/m521-realdata.sh [JAR] [RUN] [TREE]     defaults: the built jar of part 2 (~/m521b/attested-hdfs.jar), run15, ~/m521/tree
# Expected: both keys admitted by their quotes, the whole crawl output (55 folders, 60 files) verifies with ONLY admitted keys, and every decision flips with one edit.
set -uo pipefail
JAR="${1:-$HOME/m521b/attested-hdfs.jar}"; RUN="${2:-run15}"; TREE="${3:-$HOME/m521/tree}"
KIT="$(cd "$(dirname "$0")" && pwd)"; W="${M521R_WORK:-$HOME/m521r}"; HCP="$(hadoop classpath 2>/dev/null)"
bad=0; say() { echo "$*" | tee -a "$W/summary.txt"; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }
[ -e "$W" ] && { echo "M521R-STOP: $W exists already; remove it" >&2; exit 1; }
mkdir -p "$W/classes" "$W/out" || exit 1
R="$HOME/$RUN"; KL="$R/verify/keylist"; CRAWL="$R/verify/crawl-$RUN"; SEEDS="$R/verify/seeds-$RUN"; REF="$TREE/ops/attested/reference-measurements-m521.txt"
say "m521-realdata: $(date -u +%FT%TZ) on $(hostname)   jar=$(sha256sum "$JAR" | cut -c1-16)"
say "== the inputs (real data of $RUN)"
[ -f "$JAR" ] && ok "the jar of step 5.2.1 is there" || { say "M521R-STOP: no jar at $JAR"; exit 1; }
[ "$(ls "$KL"/TDX-*.attestkey 2>/dev/null | wc -l)" = 2 ] && ok "the key list of $RUN holds 2 TDX bundles ($(ls "$KL" | tr '\n' ' '))" || { say "M521R-STOP: no 2 bundles in $KL"; exit 1; }
[ -d "$CRAWL" ] && [ -d "$SEEDS" ] && ok "the plain copies of the crawl output ($(find "$CRAWL" -type f | wc -l) files) and of the seeds are there" || { say "M521R-STOP: no plain copy under $R/verify"; exit 1; }
[ -f "$REF" ] && ok "the reference measurements file: $(sha256sum "$REF" | cut -c1-16)..." || { say "M521R-STOP: no $REF"; exit 1; }
javac -source 11 -target 11 -Xlint:-options -nowarn -cp "$JAR:$HCP" -d "$W/classes" "$KIT/M521Tools.java" >"$W/out/javac.log" 2>&1 && ok "M521Tools compiles against the jar" || { say "M521R-STOP: M521Tools does not compile (see $W/out/javac.log)"; exit 1; }
T="java -cp $JAR:$W/classes:$HCP"
say "== 1. each real key is admitted by its quote (the Intel chain, the signatures, the reference)"
for b in "$KL"/TDX-*.attestkey; do
  if $T org.apache.nutch.attested.AttestedKeyTool bundle-admit "$b" "$REF" >"$W/out/admit-$(basename "$b").txt" 2>&1 && grep -q '^ADMIT' "$W/out/admit-$(basename "$b").txt"; then ok "$(grep -o 'ADMIT.*' "$W/out/admit-$(basename "$b").txt" | cut -c1-210)"; else no "$(basename "$b") is not admitted: $(tail -1 "$W/out/admit-$(basename "$b").txt")"; fi
done
say "== 2. the whole output of $RUN verifies with ONLY the keys that the quotes admit"
for X in "$SEEDS" "$CRAWL"; do
  n=$(basename "$X"); TOP="/user/$(whoami)/$n"
  $T org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$REF" "$X" "$TOP" >"$W/out/tree-$n.txt" 2>&1; rc=$?
  if [ $rc = 0 ] && grep -q '^VERIFY-TREE-CLEAN' "$W/out/tree-$n.txt" && grep -q '^KEYLIST 2 key(s) admitted' "$W/out/tree-$n.txt"; then ok "$n: $(grep -o 'folders=[0-9]* files=[0-9]*' "$W/out/tree-$n.txt") verify, both keys admitted by their quotes"; else no "$n does not verify with admitted keys (see $W/out/tree-$n.txt)"; grep -m4 'KEYLIST-REJECTED\|^BAD' "$W/out/tree-$n.txt" | sed 's/^/      /'; fi
done
say "== 3. one edit flips each decision (the decisions are changeable without any code)"
cp "$REF" "$W/ref-wrong-mrtd.txt"; python3 - "$W/ref-wrong-mrtd.txt" <<'PY'
import sys, re
s = open(sys.argv[1]).read(); m = re.search(r"^MRTD ([0-9a-f]{96}) ", s, re.M); open(sys.argv[1], "w").write(s.replace(m.group(1), "ab" * 48, 1))
PY
$T org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$W/ref-wrong-mrtd.txt" "$CRAWL" "/user/$(whoami)/crawl-$RUN" >"$W/out/flip-mrtd.txt" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'MRTD of tdx-lab' "$W/out/flip-mrtd.txt" && grep -q 'KEYLIST 0 key(s)' "$W/out/flip-mrtd.txt" && ok "EDIT 1: one changed MRTD in the reference: no key is admitted, the whole tree is refused ($(grep -c '^BAD' "$W/out/flip-mrtd.txt") findings), and the reason names MRTD" || no "EDIT 1 did not refuse the tree (see $W/out/flip-mrtd.txt)"
$T org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$W/ref-wrong-mrtd.txt" "$CRAWL" "/user/$(whoami)/crawl-$RUN" --enforce rtmr0,rtmr1,rtmr2 >"$W/out/flip-enforce.txt" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^VERIFY-TREE-CLEAN' "$W/out/flip-enforce.txt" && ok "EDIT 2: take mrtd out of the enforce list (the same wrong reference): the tree verifies again" || no "EDIT 2 did not flip (see $W/out/flip-enforce.txt)"
$T org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$REF" "$CRAWL" "/user/$(whoami)/crawl-$RUN" --root "$(printf '11%.0s' $(seq 32))" >"$W/out/flip-root.txt" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'not one of the trusted roots' "$W/out/flip-root.txt" && ok "EDIT 3: pin another root certificate: no key is admitted (not one of the trusted roots)" || no "EDIT 3 did not refuse (see $W/out/flip-root.txt)"
$T org.apache.nutch.attested.M521Tools verify-tree-admit "$KL" "$REF" "$CRAWL" "/user/$(whoami)/crawl-$RUN" --enforce mrtd,rtmr3 >"$W/out/flip-rtmr3.txt" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'the reference has no value for RTMR3, which is enforced' "$W/out/flip-rtmr3.txt" && ok "EDIT 4: enforce rtmr3 (the reference has no RTMR3 lines): refused, fail closed, with the reason" || no "EDIT 4 did not refuse (see $W/out/flip-rtmr3.txt)"
say "== 4. a quote that was changed after it was signed"
python3 - "$KL" "$W" <<'PY'
import base64, glob, sys, os
kl, w = sys.argv[1], sys.argv[2]; d = w + "/tampered-list"; os.makedirs(d, exist_ok=True)
for f in sorted(glob.glob(kl + "/TDX-*.attestkey")):
    l = open(f).read().split("\n"); q = bytearray(base64.b64decode(l[2][6:])); q[184] ^= 1   # one bit of MRTD
    open(d + "/" + os.path.basename(f), "w").write(l[0] + "\n" + l[1] + "\nquote=" + base64.b64encode(bytes(q)).decode() + "\n")
PY
$T org.apache.nutch.attested.M521Tools verify-tree-admit "$W/tampered-list" "$REF" "$CRAWL" "/user/$(whoami)/crawl-$RUN" >"$W/out/tampered.txt" 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'signature of the quote does not verify' "$W/out/tampered.txt" && ok "one flipped bit in MRTD of both quotes: no key is admitted (the signature of the quote does not verify) and the tree is refused" || no "the tampered quotes were not refused (see $W/out/tampered.txt)"
tar czf "$W/m521-realdata-results.tar.gz" -C "$W" out summary.txt && ok "the results are packed: $W/m521-realdata-results.tar.gz"
if [ $bad -eq 0 ]; then say "M521R-OK (the real quotes of $RUN are admitted offline in Java, the whole output verifies with only admitted keys, and each decision flips with one edit)"; else say "M521R-FAILED ($bad)"; fi
[ $bad -eq 0 ]
