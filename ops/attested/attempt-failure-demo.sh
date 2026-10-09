#!/usr/bin/env bash
# Milestone 4, step 4.7 recon: what the wrapper logs when a task attempt fails and the task runs again.
#
# The recon of run 9 showed no retry and no speculative copy, so the failure paths have never appeared in the
# wrapper's logs. This script provokes one on purpose, with Hadoop's own TeraGen example (one map task that
# writes one big file through the output committer):
#   1. start TeraGen with one map and at most 3 attempts;
#   2. find the first attempt while it runs, give it 3 seconds to start writing;
#   3. fail that attempt with 'mapred job -fail-task' (this must succeed: the job must still be running);
#   4. the task runs again as attempt number 1 and the job must succeed, with the file in its final folder.
# The demo's folder is always removed at the end. This script sees only what the client prints; what the wrapper
# logged is read afterwards from the logs of both nodes with attempt_timeline.py.
#
# Usage:  ops/attested/attempt-failure-demo.sh OUTDIR [ROWS]
#   run on the master with the cluster in wrapped mode and nothing else running; ROWS defaults to 15000000
#   (100 bytes each, 1.5 GB: about 25 seconds of writing, long enough to be caught while it writes; at its peak
#   the demo needs about 2 GB of HDFS space, the failed attempt's partial file plus the retry's full file).
# The MapReduce client cannot ask about a finished job here (no job history server runs), so the attempt has to be
# failed while the job runs; a first version of this script, which checked that the client program was alive
# and not that the job was running, failed the attempt after the job had finished.
# Test hooks: ATTESTED_HADOOP, ATTESTED_MAPRED, ATTESTED_HDFS, ATTESTED_YARN, ATTESTED_EXAMPLES.
set -uo pipefail
OUT="${1:?usage: attempt-failure-demo.sh OUTDIR [ROWS]}"; ROWS="${2:-15000000}"
H="${HADOOP_HOME:-$HOME/hadoop}"
HADOOP="${ATTESTED_HADOOP:-$H/bin/hadoop}"; MAPRED="${ATTESTED_MAPRED:-$H/bin/mapred}"; HDFS="${ATTESTED_HDFS:-$H/bin/hdfs}"; YARN="${ATTESTED_YARN:-$H/bin/yarn}"
EXAMPLES="${ATTESTED_EXAMPLES:-$H/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.3.jar}"
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
die() { echo "ATTEMPT-DEMO-STOP: $*" >&2; exit 1; }

impl="$($HDFS getconf -confKey fs.hdfs.impl 2>/dev/null | tail -1)"
[ "$impl" = org.apache.nutch.attested.AttestedHdfsFileSystem ] || die "the cluster is not in wrapped mode (fs.hdfs.impl is '${impl:-unset}')"
napps="$($YARN application -list -appStates RUNNING 2>/dev/null | grep -c '^application_')"; [ "$napps" = 0 ] || die "$napps YARN application(s) are running; wait until none is"
[ ! -e "$OUT" ] || die "$OUT already exists; use a new folder"
mkdir -p "$OUT" || die "cannot create $OUT"
DIR="/user/$(id -un)/attempt-failure-demo-$(date -u +%Y%m%dT%H%M%SZ)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done; kill "$pid" 2>/dev/null; fi   # let a running job end before its folder goes
  $HDFS dfs $PLAIN -rm -r -f "$DIR" >/dev/null 2>&1 && echo "removed $DIR"
}
trap cleanup EXIT

echo "== 1. TeraGen: one map task, $ROWS rows ($((ROWS * 100 / 1000000)) MB), at most 3 attempts, output in $DIR/out"
date -u +"   started %T UTC" | tee "$OUT/times.txt"
$HADOOP jar "$EXAMPLES" teragen -D mapreduce.job.maps=1 -D mapreduce.map.maxattempts=3 "$ROWS" "$DIR/out" > "$OUT/job.log" 2>&1 &
pid=$!
JOB=""; for i in $(seq 1 60); do JOB="$(grep -oE 'job_[0-9]+_[0-9]+' "$OUT/job.log" | head -1)"; [ -n "$JOB" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 1; done
[ -n "$JOB" ] || die "no job id after 60 s (see $OUT/job.log)"
echo "   job: $JOB"
ATT=""; for i in $(seq 1 90); do ATT="$($MAPRED job -list-attempt-ids "$JOB" MAP running 2>/dev/null | grep -oE 'attempt_[0-9_]+_m_[0-9]+_0' | head -1)"; [ -n "$ATT" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 1; done
[ -n "$ATT" ] || die "no running first attempt was found in 90 s: the job ended or never started a map (see $OUT/job.log)"
echo "   first attempt: $ATT"
sleep 3
echo "== 2. failing it now (it should be writing its output)"
date -u +"   failing it at %T UTC" | tee -a "$OUT/times.txt"
$MAPRED job -fail-task "$ATT" > "$OUT/fail-task.log" 2>&1; frc=$?
echo "   mapred job -fail-task exit code $frc"
[ "$frc" = 0 ] || die "mapred job -fail-task failed (exit code $frc); if $OUT/fail-task.log says the application is completed, the job had already finished: use more rows"
echo "== 3. waiting for the job (the task runs again as attempt number 1)"
wait "$pid"; rc=$?; pid=""
date -u +"   ended %T UTC" | tee -a "$OUT/times.txt"
echo "   job exit code $rc"
ok_job=0; [ "$rc" = 0 ] && grep -q "completed successfully" "$OUT/job.log" && ok_job=1
failed_seen=0; grep -qE "Task Id : ${ATT}, Status : FAILED" "$OUT/job.log" && failed_seen=1
size="$($HDFS dfs $PLAIN -ls "$DIR/out/part-m-00000" 2>/dev/null | awk 'NF>=8{print $5}' | head -1)"
want=$((ROWS * 100)); ok_size=0; [ "${size:-0}" = "$want" ] && ok_size=1
{
  echo "job: $JOB   first attempt (failed on purpose): $ATT   the task's second attempt: ${ATT%_0}_1"
  echo "client log: first attempt reported FAILED: $([ $failed_seen = 1 ] && echo yes || echo NO)   job completed: $([ $ok_job = 1 ] && echo yes || echo NO)   final file $DIR/out/part-m-00000: ${size:-missing} bytes (expected $want)"
} | tee "$OUT/verdict.txt"
echo "$JOB" > "$OUT/job-id.txt"; echo "$ATT" > "$OUT/first-attempt.txt"
if [ "$ok_job" = 1 ] && [ "$failed_seen" = 1 ] && [ "$ok_size" = 1 ]; then
  echo "ATTEMPT-FAILURE-DEMO (client side): PASS - now read what the wrapper logged with attempt_timeline.py" | tee -a "$OUT/verdict.txt"
else
  echo "ATTEMPT-FAILURE-DEMO (client side): FAIL" | tee -a "$OUT/verdict.txt"; exit 1
fi
