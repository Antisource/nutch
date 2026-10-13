#!/usr/bin/env bash
# The test suite on the master, with a pass table at the end: it shows that the cluster is back where we left off.
# Needs the job built by node-wrapper.sh. Writes everything to ~/suite-<time>/.   node-suite.sh [--no-contract]
set -uo pipefail
. "$(dirname "$0")/lib.sh"; hadoop_env
SRC="$HOME_DIR/nutch-build"; OUT="$HOME_DIR/suite-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
[ -d "$SRC/ops/attested" ] || die "no build in $SRC (run node-wrapper.sh build first)"
JOB="$(cat "$STATE/job.path" 2>/dev/null)"; [ -f "$JOB" ] || die "no job file"
cd "$SRC" || die "cannot enter $SRC"
say "smoke tests against the real HDFS"
ops/attested/build-and-test.sh hadoop-master:9000 > "$OUT/smoke.txt" 2>&1
S1=FAIL; grep -q "ATTESTED-BUILD-AND-TEST: ALL-PASS" "$OUT/smoke.txt" && S1=PASS
N=$(grep -c "^ALL-PASS" "$OUT/smoke.txt")
C1="skipped"
if [ "${1:-}" != "--no-contract" ]; then
  say "contract tests, plain HDFS against the wrapper"
  ATTESTED_JOB="$JOB" EXPECT_JOB="$(sha256sum "$JOB" | cut -c1-16)" ops/attested/contract-tests.sh "$OUT/contract" > "$OUT/contract.txt" 2>&1
  C1=$(grep -E "^CONTRACT-" "$OUT/contract.txt" | tail -1); [ -n "$C1" ] || C1="NO VERDICT (see $OUT/contract.txt)"
fi
echo
echo "================ SUITE RESULT ($(date -u +%FT%TZ)) ================"
printf '%-34s %s\n' "smoke tests (ALL-PASS modes: $N)" "$S1"
printf '%-34s %s\n' "contract tests" "$C1"
printf '%-34s %s\n' "job" "$(sha256sum "$JOB" | cut -c1-16)"
echo "files: $OUT"
[ "$S1" = PASS ] && echo "SUITE-OK" || { echo "SUITE-FAILED"; exit 1; }
