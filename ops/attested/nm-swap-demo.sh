#!/usr/bin/env bash
# Milestone 4, baby step 4.6.3: the NodeManager reads through the wrapper and refuses a swapped file.
#
# A job can ask Hadoop to hand a file to its tasks (the "distributed cache"). The NodeManager on the worker
# fetches that file from HDFS itself, before the task starts, with its own settings and not the job's. Since
# step 4.6 those settings name the wrapper, so the NodeManager's read is checked against the file's record.
#
#   1. a small file is stored through the wrapper (its record is made);
#   2. control:  the Pi example with -files <that file> must succeed;
#   3. tamper:   one byte of the file is changed with the PLAIN client (behind the wrapper's back), keeping
#                the length, and the same job must now FAIL, because the NodeManager's read is refused;
#   4. restore:  the original bytes are put back, and the job must succeed again.
# The original bytes are always put back, and the demo's folder is always removed, even if a step fails.
#
# This script sees only what the client prints. The reason (a VERIFY-FAIL line in the wrapper's log of the
# NodeManager's process, on the worker) is proved afterwards from the collected logs; the path to look for is
# written to OUTDIR/tampered-file-path.txt.
#
# Usage:  ops/attested/nm-swap-demo.sh OUTDIR      (on the master, with the cluster in wrapped mode)
# Test hooks: ATTESTED_HDFS, ATTESTED_HADOOP, ATTESTED_EXAMPLES replace the commands and the examples jar;
#             NM_SWAP_TIMEOUT is the time limit of one job in seconds (default 420).
set -uo pipefail
OUT="${1:?usage: nm-swap-demo.sh OUTDIR}"
H="${HADOOP_HOME:-$HOME/hadoop}"
HDFS="${ATTESTED_HDFS:-$H/bin/hdfs}"; HADOOP="${ATTESTED_HADOOP:-$H/bin/hadoop}"
EXAMPLES="${ATTESTED_EXAMPLES:-$H/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.3.jar}"
# the demo's own file handling must not go through the wrapper (the tamper must be behind its back)
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
die() { echo "NM-SWAP-STOP: $*" >&2; exit 1; }

impl="$($HDFS getconf -confKey fs.hdfs.impl 2>/dev/null | tail -1)"
[ "$impl" = org.apache.nutch.attested.AttestedHdfsFileSystem ] || die "the cluster is not in wrapped mode (fs.hdfs.impl is '${impl:-unset}'); run cluster-mode.sh wrapped on both nodes"
FS="$($HDFS getconf -confKey fs.defaultFS 2>/dev/null | tail -1)"; [ -n "$FS" ] || die "cannot read fs.defaultFS"
[ ! -e "$OUT" ] || die "$OUT already exists; use a new folder"
mkdir -p "$OUT" || die "cannot create $OUT"
FOLDER="/user/$(id -un)/nm-swap-demo-$(date -u +%Y%m%dT%H%M%SZ)"; FILE="$FOLDER/dc-file"; URI="$FS$FILE"
ORIG="$OUT/original.bin"; BAD="$OUT/changed.bin"
tampered=0; restored=0; pi_noted=0
# The Pi example deletes its temporary folder (QuasiMonteCarlo_<time>_<number> in the user's home) only when it
# succeeds, so the tampered run leaves one behind. Note the ones that exist before the demo, and remove only the new ones.
pi_folders() { $HDFS dfs $PLAIN -ls "/user/$(id -un)" 2>/dev/null | awk '{print $NF}' | sed -n 's#.*/\(QuasiMonteCarlo_[0-9]*_[0-9]*\)$#\1#p' | sort -u; }
cleanup() {
  if [ "$tampered" = 1 ] && [ "$restored" = 0 ]; then $HDFS dfs $PLAIN -put -f "$ORIG" "$FILE" >/dev/null 2>&1 && restored=1 && echo "restored the original bytes of $FILE"; fi
  $HDFS dfs $PLAIN -rm -r -f "$FOLDER" >/dev/null 2>&1 && echo "removed $FOLDER"
  if [ "$pi_noted" = 1 ]; then
    for n in $(comm -13 <(printf '%s\n' "$PI_BEFORE") <(pi_folders)); do
      $HDFS dfs $PLAIN -rm -r -f "/user/$(id -un)/$n" >/dev/null 2>&1 && echo "removed $n (the temporary folder of a job that failed during the demo)"
    done
  fi
}
trap cleanup EXIT

python3 - "$ORIG" <<'PY'
import sys
open(sys.argv[1], "wb").write("".join("line %04d of the file the NodeManager will fetch\n" % i for i in range(80)).encode())
PY
size=$(wc -c < "$ORIG"); sha_orig=$(sha256sum "$ORIG" | cut -c1-16)
PI_BEFORE="$(pi_folders)"; pi_noted=1
# stored through the wrapper (the cluster's default): its record is made
$HDFS dfs -mkdir -p "$FOLDER" && $HDFS dfs -put "$ORIG" "$FILE" || die "cannot store the demo file"
n=$($HDFS dfs $PLAIN -ls "$FOLDER" | grep -c '\.dc-file\.attested')
[ "$n" = 1 ] || die "no record was made next to the demo file (found $n); the wrapper is not in use"
echo "file: $FILE  size: $size bytes  fingerprint: $sha_orig  its record exists"
echo "$FILE" > "$OUT/tampered-file-path.txt"

run_job() {  # run_job LABEL -> prints the exit code
  timeout "${NM_SWAP_TIMEOUT:-420}" "$HADOOP" jar "$EXAMPLES" pi -files "$URI" \
    -D mapreduce.am.max-attempts=1 -D mapreduce.map.maxattempts=1 -D mapreduce.reduce.maxattempts=1 \
    2 10 > "$OUT/$1.log" 2>&1
  echo $?
}
job_ok() { [ "$1" = 0 ] && grep -q 'Estimated value of Pi' "$OUT/$2.log"; }

echo "== 1. control: the job fetches the file through the NodeManager, which checks it"
rc1=$(run_job control); job_ok "$rc1" control && c1=ok || c1=FAILED
echo "   exit code $rc1, $c1"

echo "== 2. one byte is changed with the plain HDFS client (behind the wrapper's back)"
python3 - "$ORIG" "$BAD" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read()); i = len(d) // 2; d[i] ^= 0x01
open(sys.argv[2], "wb").write(d); print("   changed byte %d of %d" % (i, len(d)))
PY
tampered=1
$HDFS dfs $PLAIN -put -f "$BAD" "$FILE" || die "could not write the changed file"

echo "== 3. the same job must fail (the NodeManager's read is refused; the reason is in the worker's logs)"
rc2=$(run_job tampered); jobid=$(grep -oE 'job_[0-9]+_[0-9]+|application_[0-9]+_[0-9]+' "$OUT/tampered.log" | head -1)
if [ "$rc2" != 0 ] && ! grep -q 'Estimated value of Pi' "$OUT/tampered.log"; then c2=ok; else c2=FAILED; fi
echo "   exit code $rc2, $c2 (${jobid:-no job id printed})"

echo "== 4. the original bytes are put back"
$HDFS dfs $PLAIN -put -f "$ORIG" "$FILE" && restored=1
sha_back=$($HDFS dfs $PLAIN -cat "$FILE" | sha256sum | cut -c1-16)
rc3=$(run_job restored); job_ok "$rc3" restored && c3=ok || c3=FAILED
echo "   fingerprint after restore: $sha_back, exit code $rc3, $c3"

{
  echo "file: $FILE ($size bytes, fingerprint $sha_orig)   job of the tampered run: ${jobid:-unknown}"
  echo "control: $c1   tampered must fail: $c2   restored: $c3   restored fingerprint equals original: $([ "$sha_back" = "$sha_orig" ] && echo yes || echo NO)"
} | tee "$OUT/verdict.txt"
if [ "$c1" = ok ] && [ "$c2" = ok ] && [ "$c3" = ok ] && [ "$sha_back" = "$sha_orig" ]; then
  echo "NM-SWAP-DEMO (client side): PASS - now prove the reason from the worker's wrapper log (a VERIFY-FAIL line from the NodeManager's process)" | tee -a "$OUT/verdict.txt"
else
  echo "NM-SWAP-DEMO (client side): FAIL" | tee -a "$OUT/verdict.txt"; exit 1
fi
