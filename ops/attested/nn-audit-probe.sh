#!/usr/bin/env bash
# Milestone 4, baby step 4.5.2: a small, known workload against HDFS, to test the comparison of the
# NameNode's audit log with the wrapper's own log.
#
# Some operations go through the wrapper (so the wrapper's log has them) and some go straight
# through the plain HDFS client (so only the NameNode's log has them). The comparison tool must
# find exactly the plain ones. The workload works in one folder, /user/<you>/nn-audit-probe-<time>,
# which the script removes at the end. Run it on the master.
#
# Usage: ATTESTED_JOB=<job file with the wrapper's classes> nn-audit-probe.sh OUTDIR
# Writes to OUTDIR: ground-truth.tsv (what was done and by which route), wrapper-audit/ (the
# wrapper's log), nn-audit-window.log (the NameNode's lines of the time window), probe.log.
set -uo pipefail
OUT="${1:?usage: nn-audit-probe.sh OUTDIR}"
H="${HADOOP_HOME:-$HOME/hadoop}"
JOB="${ATTESTED_JOB:?set ATTESTED_JOB to the job file that holds the wrapper classes}"
NNLOG="${NN_AUDIT_LOG:-$H/logs/hdfs-audit.log}"
die() { echo "NN-PROBE-STOP: $*" >&2; exit 1; }

[ -f "$JOB" ] || die "no job file at $JOB"
[ -f "$NNLOG" ] || die "no NameNode audit log at $NNLOG (turn it on with nn-audit.sh on)"
[ ! -e "$OUT" ] || die "$OUT already exists; use a new folder"
DIR="/user/$(id -un)/nn-audit-probe-$(date -u +%Y%m%dT%H%M%SZ)"
case "$DIR" in *nn-audit-probe-*) ;; *) die "bad probe folder $DIR" ;; esac
"$H/bin/hdfs" dfs -test -e "$DIR" && die "$DIR already exists"
mkdir -p "$OUT/wrapper-audit" "$OUT/wrapper-records" "$OUT/local" || die "cannot create $OUT"
for n in a b c d e; do printf 'probe file %s\n' "$n" > "$OUT/local/$n.txt"; done

LOG="$OUT/probe.log"; GT="$OUT/ground-truth.tsv"; : > "$GT"; : > "$LOG"; fails=0
# through the wrapper: its classes come from the job file, and its logs go to OUTDIR
W() { HADOOP_CLASSPATH="$JOB" "$H/bin/hadoop" fs \
        -D fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem \
        -D fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs \
        -D attested.audit.dir="$OUT/wrapper-audit" -D attested.records.dir="$OUT/wrapper-records" "$@"; }
# straight through the plain client
P() { "$H/bin/hdfs" dfs "$@"; }
# do ROUTE OPERATION PATH -- COMMAND...   (writes the ground truth, runs the command, counts failures)
do_() { local route="$1" op="$2" path="$3"; shift 4
  printf '%s\t%s\t%s\n' "$route" "$op" "$path" >> "$GT"
  if ! "$@" >> "$LOG" 2>&1; then echo "FAILED: $route $op $path" | tee -a "$LOG"; fails=$((fails + 1)); fi; }

START="$(date -u +'%Y-%m-%d %H:%M:%S')"; echo "start $START (UTC), folder $DIR"
sleep 2
# ---- through the wrapper
do_ wrapper mkdir  "$DIR"               -- W -mkdir -p "$DIR"
do_ wrapper create "$DIR/w-read"        -- W -put "$OUT/local/a.txt" "$DIR/w-read"
do_ wrapper open   "$DIR/w-read"        -- W -cat "$DIR/w-read"
do_ wrapper create "$DIR/w-renamed-src" -- W -put "$OUT/local/b.txt" "$DIR/w-renamed-src"
do_ wrapper rename "$DIR/w-renamed-src" -- W -mv "$DIR/w-renamed-src" "$DIR/w-renamed-dst"
do_ wrapper create "$DIR/w-deleted"     -- W -put "$OUT/local/c.txt" "$DIR/w-deleted"
do_ wrapper delete "$DIR/w-deleted"     -- W -rm "$DIR/w-deleted"
do_ wrapper list   "$DIR"               -- W -ls "$DIR"
# ---- straight through the plain client, behind the wrapper's back
do_ plain open     "$DIR/w-read"        -- P -cat "$DIR/w-read"
do_ plain create   "$DIR/p-new"         -- P -put "$OUT/local/d.txt" "$DIR/p-new"
do_ plain create   "$DIR/p-gone"        -- P -put "$OUT/local/e.txt" "$DIR/p-gone"
do_ plain delete   "$DIR/p-gone"        -- P -rm "$DIR/p-gone"
do_ plain rename   "$DIR/w-renamed-dst" -- P -mv "$DIR/w-renamed-dst" "$DIR/p-moved"
sleep 2
END="$(date -u +'%Y-%m-%d %H:%M:%S')"; echo "end   $END (UTC)"
# the NameNode's lines of the window (the timestamp is the first 19 characters of a line)
awk -v s="$START" -v e="$END" 'substr($0,1,19) >= s && substr($0,1,19) <= e' "$NNLOG" > "$OUT/nn-audit-window.log"
printf 'start\t%s\nend\t%s\nfolder\t%s\n' "$START" "$END" "$DIR" > "$OUT/window.txt"
# remove the probe folder, with the plain client (after the window, so these lines are not in it)
P -rm -r "$DIR" >> "$LOG" 2>&1
echo "operations: $(wc -l < "$GT") ($(grep -c '^wrapper' "$GT") through the wrapper, $(grep -c '^plain' "$GT") through the plain client); failures: $fails"
echo "NameNode lines in the window: $(wc -l < "$OUT/nn-audit-window.log"); wrapper audit lines: $(cat "$OUT/wrapper-audit"/*.tsv 2>/dev/null | wc -l)"
[ "$fails" = 0 ] && echo "NN-PROBE-DONE: results are in $OUT" || { echo "NN-PROBE-FAILURES: see $LOG" >&2; exit 1; }
