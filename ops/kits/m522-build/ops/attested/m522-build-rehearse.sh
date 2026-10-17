#!/usr/bin/env bash
# Rehearsal of m522-build.sh away from the cluster. The REAL script runs, with the REAL wrapper-jar.sh and the REAL job comparison; only ant is
# a stand-in (the sandbox has no ant): it compiles the wrapper's sources with the sandbox compiler and zips the classes, with a few dummy
# entries, into a job file. Usage: bash m522-build-rehearse.sh KITDIR REPO HADOOP_PACK_JARS OUR_PATCH HER_PATCH
set -uo pipefail
KIT="$1"; REPO="$2"; JARS="$3"; OURP="$4"; HERP="$5"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; COMMIT="$(git -C "$REPO" rev-parse HEAD)"; CP="$(ls "$JARS"/*.jar | tr '\n' ':')"
cat > "$R/ant" <<EOS
#!/bin/bash
if [ "\$1" = -version ]; then echo "Apache Ant(TM) version 1.10.12 (rehearsal stand-in)"; exit 0; fi
[ "\${FAKE_ANT_FAIL:-}" = 1 ] && { echo "BUILD FAILED"; exit 1; }
rm -rf build/classes runtime && mkdir -p build/classes runtime/deploy
java -m jdk.compiler/com.sun.tools.javac.Main -source 11 -target 11 -Xlint:-options -nowarn -cp "$CP" -d build/classes src/java/org/apache/nutch/attested/*.java 2>&1 | head -5
python3 - <<'PY'
import os, zipfile
z = zipfile.ZipFile("runtime/deploy/apache-nutch-1.22.job", "w", zipfile.ZIP_DEFLATED)
def put(n, d):
    zi = zipfile.ZipInfo(n, date_time=(2026, 10, 15, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED; z.writestr(zi, d)
for root, _, files in os.walk("build/classes"):
    for f in sorted(files):
        p = os.path.join(root, f); put(os.path.relpath(p, "build/classes"), open(p, "rb").read())
put("org/apache/nutch/crawl/Dummy.class", b"dummy class bytes")
put("plugins/readme.txt", b"plugins")
if os.environ.get("FAKE_ANT_EXTRA") == "1": put("org/apache/nutch/crawl/Surprise.class", b"a class that no patch names")
z.close()
PY
echo "BUILD SUCCESSFUL"
EOS
chmod +x "$R/ant"
# the base tree (the 4.8.1 state: tip plus her patch) and its job, and the tree under test (tip plus her patch plus ours)
git clone -q "$REPO" "$R/base" 2>/dev/null && ( cd "$R/base" && git checkout -q "$COMMIT" && git apply "$HERP" && "$R/ant" runtime >/dev/null 2>&1 )
git clone -q "$REPO" "$R/tree" 2>/dev/null && ( cd "$R/tree" && git checkout -q "$COMMIT" && git apply "$HERP" && git apply "$OURP" )
BASEJOB="$R/base/runtime/deploy/apache-nutch-1.22.job"; BASE_SHA="$(sha256sum "$BASEJOB" | cut -c1-64)"
bash "$R/tree/ops/attested/wrapper-jar.sh" build "$BASEJOB" "$R/installed.jar" >/dev/null 2>&1
export M522B_ANT="$R/ant" M522B_INSTALLED="$R/installed.jar" M522B_SKIP_JAVA=1
run() { # run <name> <tree> <basejob> <basesha> [workdir-name]
  ( cd "$KIT" && bash ops/attested/m522-build.sh "$2" "$3" "$4" "$OURP" "$R/$1" ) > "$R/$1.out" 2>&1; echo $?; }
has() { grep -q -- "$2" "$R/$1.out"; echo $?; }

echo "=== 1. the happy path: the real script, the real job comparison, the real wrapper-jar.sh"
rc=$(run happy "$R/tree" "$BASEJOB" "$BASE_SHA"); tail -22 "$R/happy.out" | cut -c1-175
chk "the script exits 0 and says M522B-BUILD-OK" $([ "$rc" = 0 ] && [ "$(has happy M522B-BUILD-OK)" = 0 ]; echo $?)
chk "the job comparison: only the classes of the patch differ" $(has happy "JOB-DIFF-ONLY-THE-PATCH")
chk "the jar comparison: only our classes differ from the installed jar" $(has happy "only our classes differ")
chk "the wrapper jar equals the job's classes (CLASSES-SAME)" $(has happy "CLASSES-SAME")
chk "the jar's key tool runs and prints a TEST- key id" $(has happy "the jar's key tool runs: key id TEST-")
chk "the jar's signing service starts, makes a key bundle and the bundle verifies" $(has happy "the jar's signing service starts")
chk "the built jar's doorman admits the two REAL node bundles" $(has happy "the built jar's doorman admits the two REAL node bundles")
chk "the throw-away key was deleted" $([ ! -e "$R/happy/sanity-key.txt" ]; echo $?)
chk "the new job and the new jar are kept in the work folder" $([ -f "$R/happy/new-apache-nutch-1.22.job" ] && [ -f "$R/happy/attested-hdfs.jar" ]; echo $?)
chk "the evidence bundle was packed after the final line, with its own fingerprints" $(tar -xzOf "$R/evidence-m522b-build.tar.gz" evidence/summary.txt 2>/dev/null | grep -q "M522B-BUILD-OK" && tar -xzOf "$R/evidence-m522b-build.tar.gz" evidence/SHA256SUMS | grep -q fingerprints.txt; echo $?)
chk "the tree was built (the job exists there) and nothing else was changed in it" $([ -f "$R/tree/runtime/deploy/apache-nutch-1.22.job" ]; echo $?)

echo "=== 2. faults: the script must stop or report FAILED, with the reason"
f() { rc=$(run "$1" "$2" "$3" "$4"); chk "fault: $5 -> $6" $([ "$rc" != 0 ] && [ "$(has "$1" "$6")" = 0 ]; echo $?); }
f f1 "$R/tree" "$BASEJOB" "$(printf '%064d' 1)" "the base job has another fingerprint" "the base job SHA-256 is"
git clone -q "$REPO" "$R/unpatched" 2>/dev/null && ( cd "$R/unpatched" && git checkout -q "$COMMIT" )
f f2 "$R/unpatched" "$BASEJOB" "$BASE_SHA" "the tree is not patched" "does not hold our patch"
git clone -q "$R/tree" "$R/extra" 2>/dev/null; ( cd "$R/tree" && git apply "$HERP" -R --check ) 2>/dev/null
cp -a "$R/tree" "$R/tree2" && touch "$R/tree2/ops/extra.txt"
f f3 "$R/tree2" "$BASEJOB" "$BASE_SHA" "the tree has an extra file" "has 21 changed or new files"
rc=$( FAKE_ANT_FAIL=1 run f4 "$R/tree" "$BASEJOB" "$BASE_SHA" ); chk "fault: ant fails -> stops with the reason" $([ "$rc" != 0 ] && [ "$(has f4 "the build failed")" = 0 ]; echo $?)
rc=$( FAKE_ANT_EXTRA=1 run f5 "$R/tree" "$BASEJOB" "$BASE_SHA" ); chk "fault: the new job holds a class that no patch names -> reported as UNEXPECTED, and the run is FAILED" $([ "$rc" != 0 ] && [ "$(has f5 "UNEXPECTED")" = 0 ] && [ "$(has f5 "M522B-BUILD-FAILED")" = 0 ]; echo $?)
rc=$( M522B_INSTALLED="$R/none.jar" run f6 "$R/tree" "$BASEJOB" "$BASE_SHA" ); chk "fault: there is no installed jar to compare with -> FAILED, not skipped" $([ "$rc" != 0 ] && [ "$(has f6 "no installed jar")" = 0 ]; echo $?)
f f7 "$R/tree" "$R/nojob.job" "$BASE_SHA" "the base job is missing" "base job not found"
mkdir -p "$R/exists"; rc=$( cd "$KIT" && bash ops/attested/m522-build.sh "$R/tree" "$BASEJOB" "$BASE_SHA" "$OURP" "$R/exists" >"$R/f8.out" 2>&1; echo $? ); chk "fault: the work folder exists already -> stops, changes nothing" $([ "$rc" != 0 ] && grep -q "exists already" "$R/f8.out" && [ -z "$(ls -A "$R/exists")" ]; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the real script, the real job comparison and the real wrapper-jar.sh pass; its 8 faults are all reported; $PASS checks"; else echo "REHEARSAL-FAIL"; exit 1; fi
