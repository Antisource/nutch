#!/usr/bin/env bash
# Compile the hdfs:// wrapper (with its hashing) and run its smoke tests against the Hadoop installed on
# this machine. Nothing in the repository is changed: the classes go to a scratch
# folder (default /tmp/attested-build).
#
# Usage, from the repo root (or any folder with the same src/ and ops/ layout):
#   ops/attested/build-and-test.sh [HOST:PORT]     default hadoop-master:9000
#   ops/attested/build-and-test.sh none            skip the real-HDFS test
# The hash cross-check needs python3 and ops/attested/merkle_root.py.
#
# Test hooks (used only to test this script away from the cluster):
#   ATTESTED_HCP    use this classpath instead of "$(hadoop classpath)"
#   ATTESTED_JAVAC  use this compiler command instead of "javac"
set -uo pipefail

AUTH="${1:-hadoop-master:9000}"
OUT="${ATTESTED_BUILD_DIR:-/tmp/attested-build}"
JAVAC="${ATTESTED_JAVAC:-javac}"
HCP="${ATTESTED_HCP:-$(hadoop classpath)}"

SRC=src/java/org/apache/nutch/attested
TST=ops/attested/AttestedFsSmoke.java
for f in "$SRC/AttestedAudit.java" "$SRC/AttestedHdfsFileSystem.java" "$SRC/AttestedHdfs.java" "$TST"; do
  [ -f "$f" ] || { echo "ABORT: $f not found (run from the repo root)" >&2; exit 2; }
done

rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/logs"
echo "== compile"
$JAVAC -source 11 -target 11 -Xlint:all,-serial,-options -d "$OUT/classes" -cp "$HCP" "$SRC"/*.java "$TST" 2>&1 \
  | grep -v '^Note:' | grep -v 'bad path element' | head -30
if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "COMPILE-FAILED"; exit 1; fi
echo "compiled into $OUT/classes"

fail=0
run() {  # run <label> <mode> [args]
  local label="$1"; shift
  echo "== $label"
  java -cp "$OUT/classes:$HCP" org.apache.nutch.attested.AttestedFsSmoke "$@" \
    > "$OUT/logs/$label.log" 2>&1
  grep -E '^(PASS|FAIL)|ALL-PASS|SOME-FAILED' "$OUT/logs/$label.log"
  if ! grep -q '^ALL-PASS' "$OUT/logs/$label.log"; then
    fail=1
    echo "   first error lines:"; grep -m5 -E 'Exception|Caused by' "$OUT/logs/$label.log" | cut -c1-200
  fi
}

run fake fake
run mr-fake mr-fake
run hash hash

echo "== hash cross-check: the wrapper's roots against merkle_root.py, on the same files"
java -Dsmoke.keep=1 -cp "$OUT/classes:$HCP" org.apache.nutch.attested.AttestedFsSmoke hash \
  > "$OUT/logs/hash-keep.log" 2>&1
KEPT="$(grep '^KEPT ' "$OUT/logs/hash-keep.log" | cut -d' ' -f2)"
xbad=0; xn=0
while read -r _tag size chunk root; do
  py="$(python3 ops/attested/merkle_root.py "$chunk" "$KEPT/work/f$size" | cut -d' ' -f1)"
  xn=$((xn + 1))
  [ "$py" = "$root" ] || { xbad=1; echo "DIFFER size $size: wrapper $root, python $py"; }
done < <(grep '^ROOTLINE ' "$OUT/logs/hash-keep.log")
[ -n "$KEPT" ] && rm -rf "$KEPT"
if [ "$xbad" -eq 0 ] && [ "$xn" -gt 0 ]; then
  echo "JAVA-AND-PYTHON-AGREE ($xn sizes)"
else
  echo "CROSS-CHECK-FAILED"; fail=1
fi

if [ "$AUTH" != "none" ]; then run "hdfs" hdfs "$AUTH"; fi

echo
if [ "$fail" -eq 0 ]; then echo "ATTESTED-BUILD-AND-TEST: ALL-PASS"; else echo "ATTESTED-BUILD-AND-TEST: SOME-FAILED (logs in $OUT/logs)"; fi
exit "$fail"
