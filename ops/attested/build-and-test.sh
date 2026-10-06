#!/usr/bin/env bash
# Compile the hdfs:// wrapper and run its smoke tests against the Hadoop installed on
# this machine. Nothing in the repository is changed: the classes go to a scratch
# folder (default /tmp/attested-build).
#
# Usage, from the repo root (or any folder with the same src/ and ops/ layout):
#   ops/attested/build-and-test.sh [HOST:PORT]     default hadoop-master:9000
#   ops/attested/build-and-test.sh none            skip the real-HDFS test
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
if [ "$AUTH" != "none" ]; then run "hdfs" hdfs "$AUTH"; fi

echo
if [ "$fail" -eq 0 ]; then echo "ATTESTED-BUILD-AND-TEST: ALL-PASS"; else echo "ATTESTED-BUILD-AND-TEST: SOME-FAILED (logs in $OUT/logs)"; fi
exit "$fail"
