#!/usr/bin/env bash
# Milestone 5, baby step 5.1.2, part 1: build the wrapper with signed records bound to their folders in a SCRATCH clone and run all of its tests.
# Nothing on the cluster is touched: no daemon, no installed jar, no Hadoop setting, no HDFS path (the real-HDFS test of
# ops/attested/build-and-test.sh writes and removes its own scratch folder, as in every earlier step).
#
#   bash ops/attested/m512-test.sh COMMIT HER_PATCH HER_SHA256 OUR_PATCH OUR_SHA256 [WORKDIR]
#     COMMIT      the full commit id of branch feat/tee-hadoop-cluster to start from
#     HER_PATCH   the teammate's patch (Unix line endings) and its pinned SHA-256
#     OUR_PATCH   the wrapper patch of step 5.1.2 and its pinned SHA-256
#     WORKDIR     default ~/m512 (must not exist yet)
# Steps: check the tools and both patches; clone the branch at COMMIT; apply her patch, then ours; check that the files our
# patch changed are exactly the 9 expected ones; run ops/attested/build-and-test.sh (compile, the fake, MapReduce and hash tests, the
# Java/Python hash cross-check, the real-HDFS test); compile and run the signing core tests (SigCoreTest); write a summary and a bundle.
# Test hooks (used only to rehearse this script away from the cluster): M512_REPO, M512_BRANCH, M512_AUTH (default hadoop-master:9000,
# "none" skips the real-HDFS test), M512_BT (the test script to run instead of build-and-test.sh), M512_SKIP_JAVA=1,
# M512_SKIP_MR=1 (rehearsal only: the sandbox has no MapReduce), M512_EXPECT_FAKE (default 214), M512_EXPECT_SIGCORE (default 73), ATTESTED_HCP and ATTESTED_JAVAC (as in build-and-test.sh).
set -uo pipefail

U="usage: $0 COMMIT HER_PATCH HER_SHA256 OUR_PATCH OUR_SHA256 [WORKDIR]"
COMMIT="${1:?$U}"; HER="${2:?$U}"; HER_SHA="${3:?$U}"; OUR="${4:?$U}"; OUR_SHA="${5:?$U}"; W="${6:-$HOME/m512}"
REPO="${M512_REPO:-https://github.com/Antisource/nutch.git}"; BRANCH="${M512_BRANCH:-feat/tee-hadoop-cluster}"
AUTH="${M512_AUTH:-hadoop-master:9000}"; BT="${M512_BT:-ops/attested/build-and-test.sh}"
EXPECT_FAKE="${M512_EXPECT_FAKE:-214}"; EXPECT_SIGCORE="${M512_EXPECT_SIGCORE:-73}"
JAVAC="${ATTESTED_JAVAC:-javac}"
# full paths: the script changes folders, so relative names would not be found
case "$HER" in /*) ;; *) HER="$PWD/$HER" ;; esac
case "$OUR" in /*) ;; *) OUR="$PWD/$OUR" ;; esac
case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
EXPECTED_FILES="ops/attested/AttestedFsSmoke.java
ops/attested/build-and-test.sh
ops/attested/SigCoreTest.java
src/java/org/apache/nutch/attested/AttestedFolderCodec.java
src/java/org/apache/nutch/attested/AttestedFolders.java
src/java/org/apache/nutch/attested/AttestedHdfsFileSystem.java
src/java/org/apache/nutch/attested/AttestedRecordCodec.java
src/java/org/apache/nutch/attested/AttestedSidecar.java
src/java/org/apache/nutch/attested/AttestedSignatures.java"

bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M512-TEST-STOP: $*"; exit 1; }
fp()   { sha256sum "$1" | cut -c1-64; }

[ -e "$W" ] && { echo "M512-TEST-STOP: $W exists already; remove it or give another folder" >&2; exit 1; }
mkdir -p "$W/logs" "$W/evidence" || exit 1
say "m512-test: $(date -u +%FT%TZ) on $(hostname)   commit=$COMMIT"

avail=$(df -Pk "$W" | awk 'NR==2{print $4}'); [ "${avail:-0}" -ge 2000000 ] && ok "free disk space: $((avail/1024)) MB" || stop "less than 2 GB free in $W"
say "== tools"
command -v git >/dev/null && ok "git" || stop "git is missing"
command -v python3 >/dev/null && ok "python3" || stop "python3 is missing"
command -v "$JAVAC" >/dev/null && ok "javac: $(command -v "$JAVAC")" || stop "javac is missing"
if [ -z "${ATTESTED_HCP:-}" ]; then command -v hadoop >/dev/null && ok "hadoop: $(hadoop version 2>/dev/null | head -1)" || stop "hadoop is missing"; else ok "classpath given by ATTESTED_HCP (rehearsal)"; fi
if [ "${M512_SKIP_JAVA:-0}" = 1 ]; then ok "java check skipped (rehearsal)"; else
  java -version >"$W/logs/java-version.txt" 2>&1; grep -q 'version "11\.' "$W/logs/java-version.txt" && ok "java: $(head -1 "$W/logs/java-version.txt")" || stop "java 11 is required: $(head -1 "$W/logs/java-version.txt")"; fi

say "== the two patches"
for p in "$HER" "$OUR"; do [ -f "$p" ] || stop "patch file not found: $p"; done
[ "$(fp "$HER")" = "$HER_SHA" ] && ok "her patch is the pinned one (${HER_SHA:0:16}...)" || stop "her patch SHA-256 is $(fp "$HER" | cut -c1-16), the pinned one is ${HER_SHA:0:16}"
[ "$(fp "$OUR")" = "$OUR_SHA" ] && ok "our patch is the pinned one (${OUR_SHA:0:16}...)" || stop "our patch SHA-256 is $(fp "$OUR" | cut -c1-16), the pinned one is ${OUR_SHA:0:16}"
python3 - "$HER" "$OUR" <<'PY' && ok "Unix line endings in both patches (no carriage return)" || stop "a patch has carriage returns"
import sys
sys.exit(1 if any(b"\r" in open(p, "rb").read() for p in sys.argv[1:]) else 0)
PY
got="$(grep '^+++ b/' "$OUR" | sed 's#^+++ b/##' | sort)"; want="$(printf '%s\n' "$EXPECTED_FILES" | sort)"
[ "$got" = "$want" ] && ok "our patch changes exactly the 9 expected files" || stop "our patch changes other files than expected: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ')"

say "== clone the branch, apply her patch, then ours"
git clone -q --branch "$BRANCH" "$REPO" "$W/tree" >"$W/logs/clone.log" 2>&1 || stop "clone failed (see $W/logs/clone.log)"
git -C "$W/tree" checkout -q "$COMMIT" >>"$W/logs/clone.log" 2>&1 || stop "commit $COMMIT not found in the clone"
[ "$(git -C "$W/tree" rev-parse HEAD)" = "$COMMIT" ] && ok "the tree is at $COMMIT" || stop "the tree is not at $COMMIT"
git -C "$W/tree" apply --check "$HER" >"$W/logs/apply-her.log" 2>&1 && git -C "$W/tree" apply "$HER" >>"$W/logs/apply-her.log" 2>&1 && ok "her patch applies" || stop "her patch does not apply to $COMMIT (see $W/logs/apply-her.log)"
git -C "$W/tree" apply --check "$OUR" >"$W/logs/apply-our.log" 2>&1 && git -C "$W/tree" apply "$OUR" >>"$W/logs/apply-our.log" 2>&1 && ok "our patch applies on top of hers" || stop "our patch does not apply on top of hers (see $W/logs/apply-our.log)"
n=$(git -C "$W/tree" status --porcelain | wc -l); ok "the tree has $n changed or new files (her patch and ours)"

say "== the wrapper's tests (ops/attested/build-and-test.sh: compile, fake, MapReduce, hash, cross-check, real HDFS)"
export ATTESTED_BUILD_DIR="$W/build"
( cd "$W/tree" && bash "$BT" "$AUTH" ) >"$W/logs/build-and-test.log" 2>&1; RC=$?
grep -E '^(==|PASS|FAIL|ALL-PASS|SOME-FAILED|JAVA-AND-PYTHON|COMPILE-FAILED|CROSS-CHECK|ATTESTED-BUILD)' "$W/logs/build-and-test.log" | grep -v '^PASS' | sed 's/^/      /' | head -40 | tee -a "$W/summary.txt" >/dev/null
[ "$RC" = 0 ] && grep -q 'ATTESTED-BUILD-AND-TEST: ALL-PASS' "$W/logs/build-and-test.log" && ok "build-and-test.sh: ALL-PASS" || no "build-and-test.sh did not pass (see $W/logs/build-and-test.log)"
f="$(grep -o 'ALL-PASS ([0-9]* of [0-9]*' "$W/build/logs/fake.log" 2>/dev/null | head -1)"
[ "$f" = "ALL-PASS ($EXPECT_FAKE of $EXPECT_FAKE" ] && ok "the fake-mode smoke test passes $EXPECT_FAKE of $EXPECT_FAKE checks (167 of step 5.1.1 plus 47 for folder binding)" || no "the fake-mode smoke test says '${f:-nothing}', expected ALL-PASS ($EXPECT_FAKE of $EXPECT_FAKE"
if [ "${M512_SKIP_MR:-0}" = 1 ]; then ok "mode mr-bound skipped (rehearsal: no MapReduce in the sandbox)"; else
  grep -q '^ALL-PASS' "$W/build/logs/mr-bound.log" 2>/dev/null && ok "mode mr-bound (Hadoop's real output committer, signing and folder binding on): $(grep -o 'ALL-PASS ([0-9]* of [0-9]*' "$W/build/logs/mr-bound.log" | head -1)" || no "mode mr-bound did not pass (see $W/build/logs/mr-bound.log)"; fi
for m in hash; do grep -q '^ALL-PASS' "$W/build/logs/$m.log" 2>/dev/null && ok "mode $m: $(grep -o 'ALL-PASS ([0-9]* of [0-9]*' "$W/build/logs/$m.log" | head -1)" || no "mode $m did not pass"; done
if [ "$AUTH" != none ]; then grep -q '^ALL-PASS' "$W/build/logs/hdfs.log" 2>/dev/null && ok "mode hdfs (the real HDFS): $(grep -o 'ALL-PASS ([0-9]* of [0-9]*' "$W/build/logs/hdfs.log" | head -1)" || no "mode hdfs did not pass"; fi

say "== the signing core tests (no Hadoop in them: the record bytes, the keys, the rewrite attacks, the key tool)"
HCP="${ATTESTED_HCP:-$(hadoop classpath)}"
$JAVAC -source 11 -target 11 -Xlint:-options -nowarn -d "$W/build/classes" -cp "$W/build/classes:$HCP" "$W/tree/ops/attested/SigCoreTest.java" >"$W/logs/sigcore-compile.log" 2>&1 && ok "SigCoreTest compiles" || { no "SigCoreTest does not compile (see $W/logs/sigcore-compile.log)"; }
java -cp "$W/build/classes:$HCP" org.apache.nutch.attested.SigCoreTest >"$W/logs/sigcore.log" 2>&1
if grep -q '^SIGCORE-PASS' "$W/logs/sigcore.log" && grep -q "^pass: $EXPECT_SIGCORE   fail: 0" "$W/logs/sigcore.log"; then ok "the signing core passes $EXPECT_SIGCORE of $EXPECT_SIGCORE checks"; else no "the signing core tests did not pass as expected (see $W/logs/sigcore.log): $(grep -E '^pass:|FAIL' "$W/logs/sigcore.log" | head -3 | tr '\n' ' ')"; fi

cp "$HER" "$OUR" "$W/evidence/"
{ echo "tree commit $COMMIT"; echo "her patch  $(fp "$HER")  $(basename "$HER")"; echo "our patch  $(fp "$OUR")  $(basename "$OUR")"; hadoop version 2>/dev/null | head -1; java -version 2>&1 | head -1; } > "$W/evidence/fingerprints.txt" 2>&1
if [ $bad -eq 0 ]; then say "M512-TEST-OK (the wrapper with folder binding builds and passes every test; nothing on the cluster was touched)"; else say "M512-TEST-FAILED ($bad): see the FAIL lines above"; fi
( cd "$W" && find summary.txt evidence logs build/logs -type f ! -name SHA256SUMS | sort | xargs sha256sum > evidence/SHA256SUMS )
tar czf "$W/../evidence-m512-test.tar.gz" -C "$W" summary.txt evidence logs build/logs 2>/dev/null && sha256sum "$W/../evidence-m512-test.tar.gz" | cut -c1-64
[ $bad -eq 0 ]
