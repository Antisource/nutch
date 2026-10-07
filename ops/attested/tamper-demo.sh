#!/usr/bin/env bash
# The tamper test on the real cluster (stage B2). Run on the master, from the build folder,
# after a crawl that ran with the wrapper and its records.
#
#   1. control:  a reader job (nutch readdb -stats on the crawl database) runs through the
#                wrapper and must succeed;
#   2. tamper:   one byte of one data file is changed with the plain HDFS client (the wrapper
#                does not see this), keeping the length;
#   3. the same reader job must now FAIL (a map task fails);
#   4. restore:  the original bytes are put back, and the reader must succeed again.
# The original file is always put back on exit, even if a step fails.
#
# This script sees only what the client prints. A failed task's reason (the verification
# error) stays in the audit log and task log of the machine that ran the task, usually the
# worker. So this script proves the client side (control ok, tampered job fails, restored ok);
# the reason is then proved from the collected audit logs of both machines with
# tamper_verify.py, using the absolute path this script writes to OUTDIR/tampered-file-path.txt.
#
# Usage:  ops/attested/tamper-demo.sh CRAWL_DIR OUTDIR
#   CRAWL_DIR  the crawl folder in HDFS (for example crawl-run8)
#   OUTDIR     where the logs and the verdict are written
#
# Test hooks: ATTESTED_HDFS replaces the "hdfs" command, ATTESTED_READER the reader command.
set -uo pipefail
CRAWL="${1:?usage: tamper-demo.sh CRAWL_DIR OUTDIR}"
OUT="${2:?usage: tamper-demo.sh CRAWL_DIR OUTDIR}"
HDFS="${ATTESTED_HDFS:-hdfs}"
READER="${ATTESTED_READER:-runtime/deploy/bin/nutch readdb}"
FILE="$CRAWL/crawldb/current/part-r-00000/data"
mkdir -p "$OUT"
ORIG="$OUT/original.bin"; BAD="$OUT/changed.bin"
rm -f "$ORIG" "$BAD"
tampered=0; restored=0

restore() {
  if [ "$tampered" = 1 ] && [ "$restored" = 0 ]; then
    $HDFS dfs -put -f "$ORIG" "$FILE" && restored=1 && echo "restored the original bytes of $FILE"
  fi
}
trap restore EXIT

run_reader() {  # run_reader LABEL  -> prints the exit code
  $READER \
    -D fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem \
    -D fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs \
    -D attested.audit.dir=/tmp/attested-audit \
    -D mapreduce.map.maxattempts=1 -D mapreduce.reduce.maxattempts=1 \
    "$CRAWL/crawldb" -stats > "$OUT/$1.log" 2>&1
  echo $?
}
reader_ok() { [ "$1" = 0 ] && grep -q 'TOTAL urls' "$OUT/$2.log"; }

$HDFS dfs -get "$FILE" "$ORIG" || { echo "TAMPER-TEST: FAIL - cannot read $FILE"; exit 1; }
size=$(wc -c < "$ORIG")
[ "$size" -gt 100 ] || { echo "TAMPER-TEST: FAIL - $FILE is too small ($size bytes)"; exit 1; }
sha_orig=$(sha256sum "$ORIG" | cut -c1-16)
ABS=$($HDFS dfs -ls "$FILE" | awk 'NF>=8{print $NF}' | head -1)
echo "$ABS" > "$OUT/tampered-file-path.txt"
echo "file: $FILE  size: $size bytes  fingerprint: $sha_orig  absolute path: $ABS"

echo "== 1. control: the reader job through the wrapper"
rc1=$(run_reader control); reader_ok "$rc1" control && c1=ok || c1=FAILED
echo "   exit code $rc1, $c1"

echo "== 2. one byte is changed with the plain HDFS client"
python3 - "$ORIG" "$BAD" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
i = len(d) // 2
d[i] ^= 0x01
open(sys.argv[2], "wb").write(d)
print("   changed byte %d of %d" % (i, len(d)))
PY
tampered=1
$HDFS dfs -put -f "$BAD" "$FILE" || { echo "TAMPER-TEST: FAIL - could not write the changed file"; exit 1; }

echo "== 3. the same reader job must fail (a task fails; the reason is in the worker's logs)"
rc2=$(run_reader tampered)
jobid=$(grep -oE 'job_[0-9]+_[0-9]+' "$OUT/tampered.log" | head -1)
if [ "$rc2" != 0 ] && grep -qE 'failedMaps:[1-9]|failedReduces:[1-9]|Task failed' "$OUT/tampered.log"; then c2=ok; else c2=FAILED; fi
echo "   exit code $rc2, $c2 (job: ${jobid:-unknown}; failed tasks reported by the client: $(grep -cE 'failedMaps:[1-9]|failedReduces:[1-9]' "$OUT/tampered.log") line(s))"

echo "== 4. the original bytes are put back"
restore
sha_back=$($HDFS dfs -cat "$FILE" | sha256sum | cut -c1-16)
rc3=$(run_reader restored); reader_ok "$rc3" restored && c3=ok || c3=FAILED
echo "   fingerprint after restore: $sha_back, reader exit code $rc3, $c3"

{
  echo "file: $FILE ($size bytes, fingerprint $sha_orig)"
  echo "tampered job: ${jobid:-unknown}   absolute path: $ABS"
  echo "control (untouched): $c1   tampered must fail: $c2   restored: $c3   restored fingerprint equals original: $([ "$sha_back" = "$sha_orig" ] && echo yes || echo NO)"
} | tee "$OUT/verdict.txt"
if [ "$c1" = ok ] && [ "$c2" = ok ] && [ "$c3" = ok ] && [ "$sha_back" = "$sha_orig" ]; then
  echo "TAMPER-TEST (client side): PASS - now prove the reason from the collected audit logs with tamper_verify.py" | tee -a "$OUT/verdict.txt"
else
  echo "TAMPER-TEST (client side): FAIL" | tee -a "$OUT/verdict.txt"; exit 1
fi
