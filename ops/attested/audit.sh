#!/usr/bin/env bash
# Helpers for the storage audit. Run on a node.
#   audit.sh rotate            move this node's old wrapper logs aside, so the next crawl starts clean
#   audit.sh snapshot FILE     (master only) list all of HDFS into FILE: type, size, modified, path
#
# Test hooks: ATTESTED_HDFS replaces the "hdfs" command; ATTESTED_AUDIT_DIR the log folder.
set -euo pipefail
HDFS="${ATTESTED_HDFS:-hdfs}"
DIR="${ATTESTED_AUDIT_DIR:-/tmp/attested-audit}"
case "${1:-}" in
rotate)
  mkdir -p "$DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  n="$(find "$DIR" -maxdepth 1 -name '*.tsv' | wc -l)"
  if [ "$n" -gt 0 ]; then
    mkdir -p "$DIR-old/$stamp"
    find "$DIR" -maxdepth 1 -name '*.tsv' -exec mv {} "$DIR-old/$stamp/" \;
  fi
  if [ "$n" -gt 0 ]; then echo "rotated $n log file(s) on $(hostname) to $DIR-old/$stamp"; else echo "no old log files to rotate on $(hostname)"; fi
  ;;
snapshot)
  OUT="${2:?usage: audit.sh snapshot FILE}"
  tmp="$(mktemp)"
  $HDFS dfs -ls -R / > "$tmp"
  awk '$1 != "Found" && NF >= 8 { p=$8; for (i=9; i<=NF; i++) p = p " " $i; print substr($1,1,1) "\t" $5 "\t" $6 " " $7 "\t" p }' "$tmp" \
    | LC_ALL=C sort -t "$(printf '\t')" -k4,4 > "$OUT"
  rm -f "$tmp"
  echo "listed $(wc -l < "$OUT") paths into $OUT"
  ;;
*)
  echo "usage: audit.sh rotate | snapshot FILE" >&2; exit 2 ;;
esac
