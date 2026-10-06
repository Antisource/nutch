#!/usr/bin/env bash
# Recompute the fingerprint of each measured component and compare it with the event log.
# Read-only: no register is touched. Usage: check-unchanged.sh [component-name ...]
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
N="${NUTCH_DIR:-$HOME/ccbot-work/nutch-cc}"
JDK="${JDK_DIR:-/usr/lib/jvm/java-11-openjdk-amd64}"
JETC="${JAVA_ETC:-/etc/java-11-openjdk}"
HAD="${HADOOP_DIR:-$HOME/hadoop}"
LOG="${RTMR3_LOG:-$HOME/rtmr3-events.tsv}"
MARK="${MARKER_FILE:-$HOME/m1-test-marker.txt}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

digest_of() {
  case "$1" in
    test-marker) sha384sum "$MARK" | cut -d' ' -f1 ;;
    nutch-job) sha384sum "$N/runtime/deploy/apache-nutch-1.22.job" | cut -d' ' -f1 ;;
    jdk) "$H/treehash.sh" "$JDK" | awk '{print $2}' ;;
    java-settings) "$H/treehash.sh" "$JETC" | awk '{print $2}' ;;
    java-ca-fingerprints)
      keytool -list -cacerts -storepass changeit 2>/dev/null | grep 'Certificate fingerprint' | sort > "$TMP/ca.txt"
      sha384sum "$TMP/ca.txt" | cut -d' ' -f1 ;;
    hadoop-code) "$H/treehash.sh" "$HAD" logs etc/hadoop | awk '{print $2}' ;;
    hadoop-conf) "$H/treehash.sh" "$HAD/etc/hadoop" | awk '{print $2}' ;;
    nutch-deploy) "$H/treehash.sh" "$N/runtime/deploy" | awk '{print $2}' ;;
    driver) "$H/treehash.sh" "$N/ops" | awk '{print $2}' ;;
    seeds) "$H/treehash.sh" "$N/seeds" | awk '{print $2}' ;;
    *) echo "unknown component $1" >&2; return 1 ;;
  esac
}

bad=0; n=0
while IFS=$'\t' read -r name logged _; do
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
  now="$(digest_of "$name" </dev/null)"
  n=$((n+1))
  if [ "$now" = "$logged" ]; then echo "$name SAME"; else echo "$name CHANGED"; bad=1; fi
done < "$LOG"
if [ "$bad" -eq 0 ]; then echo "ALL-UNCHANGED ($n components checked)"; else echo "SOMETHING-CHANGED"; exit 1; fi
