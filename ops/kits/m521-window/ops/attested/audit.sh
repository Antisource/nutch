#!/usr/bin/env bash
# Helpers for the storage audit. Run on a node.
#   audit.sh rotate            move this node's old wrapper logs aside, so the next crawl starts clean
#   audit.sh snapshot FILE     (master only) list all of HDFS into FILE: type, size, modified, path
#
# Test hooks: ATTESTED_HDFS replaces the "hdfs" command; ATTESTED_AUDIT_DIR the log folder.
set -euo pipefail
HDFS="${ATTESTED_HDFS:-hdfs}"
# Since step 4.6 the wrapper is the cluster's default file system, so a plain "hdfs dfs" goes through it.
# The listing must show the record files and must not depend on the wrapper, so it asks for the plain client.
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
DIR="${ATTESTED_AUDIT_DIR:-/tmp/attested-audit}"
case "${1:-}" in
rotate)
  mkdir -p "$DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  list="$(find "$DIR" -maxdepth 1 -name '*.tsv')"
  n="$(find "$DIR" -maxdepth 1 -name '*.tsv' | wc -l)"
  if [ "$n" -gt 0 ]; then
    mkdir -p "$DIR-old/$stamp"
    find "$DIR" -maxdepth 1 -name '*.tsv' -exec mv {} "$DIR-old/$stamp/" \;
  fi
  if [ "$n" -gt 0 ]; then echo "rotated $n log file(s) on $(hostname) to $DIR-old/$stamp"; else echo "no old log files to rotate on $(hostname)"; fi
  # A process that is still running keeps writing into the file it has open, wherever that file is now. The
  # file names are <host>-<pid>-<time>.tsv, so the processes that still run are easy to find (found on the
  # cluster on 8 October 2026: the NodeManager's reads went on into a rotated file). This only warns; a pid
  # that was reused by another program gives a false warning, never a missed one.
  if [ "$n" -gt 0 ]; then
    live=""
    for f in $list; do   # only the files moved by this call
      pid="$(basename "$f" | sed -nE 's/^.*-([0-9]+)-[0-9]+\.tsv$/\1/p')"
      [ -n "$pid" ] || continue
      cmd="$(ps -p "$pid" -o args= 2>/dev/null | cut -c1-90 || true)"
      [ -z "$cmd" ] || live="$live  pid $pid: $cmd"$'\n'
    done
    if [ -n "$live" ]; then
      echo "WARNING: these processes wrote files that were just moved, and are still running; their next lines go to the moved file, not to $DIR:"
      printf '%s' "$live"
      echo "         restart them before the crawl (on the worker: cluster-mode.sh wrapped --restart-yarn), or collect from $DIR-old/$stamp too."
    fi
  fi
  ;;
snapshot)
  OUT="${2:?usage: audit.sh snapshot FILE}"
  tmp="$(mktemp)"
  $HDFS dfs $PLAIN -ls -R / > "$tmp"
  awk '$1 != "Found" && NF >= 8 { p=$8; for (i=9; i<=NF; i++) p = p " " $i; print substr($1,1,1) "\t" $5 "\t" $6 " " $7 "\t" p }' "$tmp" \
    | LC_ALL=C sort -t "$(printf '\t')" -k4,4 > "$OUT"
  rm -f "$tmp"
  echo "listed $(wc -l < "$OUT") paths into $OUT"
  ;;
*)
  echo "usage: audit.sh rotate | snapshot FILE" >&2; exit 2 ;;
esac
