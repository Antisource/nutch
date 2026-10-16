#!/usr/bin/env bash
# Rehearsal of m521-test.sh away from the cluster. The REAL script runs, with the REAL tests (the fake, hash and signing core tests):
# only the Hadoop jars (a pack taken from the master), the Java compiler command, and a copy of build-and-test.sh without the MapReduce
# mode (the sandbox has no MapReduce jars) are stand-ins. Usage: bash m521-test-rehearse.sh KITDIR REPO HADOOP_PACK_JARS STUBS OUR_PATCH HER_PATCH
set -uo pipefail
KIT="$1"; REPO="$2"; JARS="$3"; STUBS="$4"; OURP="$5"; HERP="$6"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; COMMIT="$(git -C "$REPO" rev-parse HEAD)"
printf '#!/bin/bash\nexec java -m jdk.compiler/com.sun.tools.javac.Main "$@"\n' > "$R/javac-standin"; chmod +x "$R/javac-standin"
sed '/^run mr-fake mr-fake$/d;/^run mr-bound mr-bound$/d' "$REPO/ops/attested/build-and-test.sh" > "$R/bt.sh"
export ATTESTED_JAVAC="$R/javac-standin" ATTESTED_HCP="$(ls "$JARS"/*.jar | tr '\n' ':')$STUBS" M521_REPO="$REPO" M521_AUTH=none M521_BT="$R/bt.sh" M521_SKIP_JAVA=1 M521_SKIP_MR=1
BR="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"; export M521_BRANCH="$BR"
HER_SHA="$(sha256sum "$HERP" | cut -c1-64)"; OUR_SHA="$(sha256sum "$OURP" | cut -c1-64)"
run() { # run <workdir-name> <commit> <her-patch> <her-sha> <our-patch> <our-sha>
  ( cd "$KIT" && bash ops/attested/m521-test.sh "$2" "$3" "$4" "$5" "$6" "$R/$1" ) > "$R/$1.out" 2>&1; echo $?; }
has() { grep -q -- "$2" "$R/$1.out"; echo $?; }

echo "=== 1. the happy path: the real script, the real tests"
rc=$(run happy "$COMMIT" "$HERP" "$HER_SHA" "$OURP" "$OUR_SHA"); tail -14 "$R/happy.out" | cut -c1-175
chk "the script exits 0 and says M521-TEST-OK" $([ "$rc" = 0 ] && [ "$(has happy M521-TEST-OK)" = 0 ]; echo $?)
chk "it checked that our patch changes exactly the 12 expected files" $(has happy "exactly the 12 expected files")
chk "both patches applied, the tree has her 11 files and our 12" $(has happy "the tree has 23 changed or new files")
chk "the fake-mode smoke test passed 239 of 239" $(has happy "passes 239 of 239")
chk "the signing core passed 73 of 73" $(has happy "passes 73 of 73")
chk "the key core passed 68 of 68" $(has happy "the key core passes 68 of 68")
chk "the admission core passed 73 of 73" $(has happy "the admission core passes 73 of 73")
chk "the evidence bundle was packed after the final line" $(tar -xzOf "$R/evidence-m521-test.tar.gz" summary.txt 2>/dev/null | grep -q "M521-TEST-OK"; echo $?)
chk "the bundle lists its own files with fingerprints" $(tar -xzOf "$R/evidence-m521-test.tar.gz" evidence/SHA256SUMS 2>/dev/null | grep -q "summary.txt"; echo $?)

echo "=== 2. faults: the script must stop, or report FAILED, with the reason"
f() { rc=$(run "$1" "$2" "$3" "$4" "$5" "$6"); chk "fault: $7 -> $8" $([ "$rc" != 0 ] && [ "$(has "$1" "$8")" = 0 ]; echo $?); }
f f1 "$COMMIT" "$HERP" "$(printf '%064d' 1)" "$OURP" "$OUR_SHA" "her patch has another fingerprint" "her patch SHA-256 is"
f f2 "$COMMIT" "$HERP" "$HER_SHA" "$OURP" "$(printf '%064d' 2)" "our patch has another fingerprint" "our patch SHA-256 is"
f f3 "deadbeef00000000000000000000000000000000" "$HERP" "$HER_SHA" "$OURP" "$OUR_SHA" "the commit does not exist" "not found in the clone"
python3 - "$OURP" "$R/broken-context.patch" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n"); inhunk = False
for i, l in enumerate(lines):
    if l.startswith("@@"): inhunk = True
    elif inhunk and l.startswith(" ") and len(l) > 12:
        lines[i] = l[:6] + "#" + l[7:]; break
open(sys.argv[2], "w").write("\n".join(lines))
PY
f f4 "$COMMIT" "$HERP" "$HER_SHA" "$R/broken-context.patch" "$(sha256sum "$R/broken-context.patch" | cut -c1-64)" "our patch does not apply (a context line differs)" "does not apply"
cp "$OURP" "$R/extra.patch"; printf 'diff --git a/EXTRA.txt b/EXTRA.txt\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/EXTRA.txt\n@@ -0,0 +1 @@\n+x\n' >> "$R/extra.patch"
f f5 "$COMMIT" "$HERP" "$HER_SHA" "$R/extra.patch" "$(sha256sum "$R/extra.patch" | cut -c1-64)" "our patch touches a file that is not expected" "other files than expected"
# a patch that breaks the signature check: the tests must fail and the script must say so
rm -rf "$R/mut" && git clone -q "$REPO" "$R/mut" 2>/dev/null && ( cd "$R/mut" && git checkout -q "$COMMIT" && git apply "$OURP" && python3 - <<'PY'
p = "src/java/org/apache/nutch/attested/QuoteVerifier.java"; s = open(p).read()
a = "  static void verify(Quote q, Set<String> pinnedRoots, boolean checkDates, Instant now) throws IOException {\n"; assert a in s
open(p, "w").write(s.replace(a, a + "    if (true) { return; }\n"))
PY
git add -N src ops && git diff --binary > "$R/mutated.patch" )
f f6 "$COMMIT" "$HERP" "$HER_SHA" "$R/mutated.patch" "$(sha256sum "$R/mutated.patch" | cut -c1-64)" "a mutated patch skips the quote verification: the tests fail and the script says FAILED" "M521-TEST-FAILED"
chk "   and the failing run names the failing checks" $(grep -q "FAIL" "$R/f6.out" && echo 0 || echo 1)
mkdir -p "$R/exists"; rc=$( cd "$KIT" && bash ops/attested/m521-test.sh "$COMMIT" "$HERP" "$HER_SHA" "$OURP" "$OUR_SHA" "$R/exists" >"$R/f7.out" 2>&1; echo $? ); chk "fault: the work folder exists already -> stops, changes nothing" $([ "$rc" != 0 ] && grep -q "exists already" "$R/f7.out" && [ -z "$(ls -A "$R/exists")" ]; echo $?)
rc=$( cd "$KIT" && M521_EXPECT_FAKE=999 bash ops/attested/m521-test.sh "$COMMIT" "$HERP" "$HER_SHA" "$OURP" "$OUR_SHA" "$R/f8" >"$R/f8.out" 2>&1; echo $? ); chk "fault: a wrong expected count of the fake tests is reported, not ignored" $([ "$rc" != 0 ] && grep -q "expected ALL-PASS (999 of 999" "$R/f8.out"; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the real script runs the real tests and passes; its 7 faults are all reported; $PASS checks"; else echo "REHEARSAL-FAIL"; exit 1; fi
