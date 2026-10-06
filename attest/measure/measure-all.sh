#!/usr/bin/env bash
# Measure the whole crawl stack into RTMR3, one event per component, in a fixed order.
# Needs rtmr3-extend.sh and treehash.sh next to this script.
# Saves a manifest (file list with hashes) per folder in ~/measured/.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
N="${NUTCH_DIR:-$HOME/ccbot-work/nutch-cc}"
JDK="${JDK_DIR:-/usr/lib/jvm/java-11-openjdk-amd64}"
JETC="${JAVA_ETC:-/etc/java-11-openjdk}"
HAD="${HADOOP_DIR:-$HOME/hadoop}"
LOG="${RTMR3_LOG:-$HOME/rtmr3-events.tsv}"
MEAS="$HOME/measured"
export RTMR3_LOG="$LOG"

if grep -q -P '^jdk\t' "$LOG" 2>/dev/null; then
  echo "the stack is already measured in this log; reboot before measuring again" >&2
  exit 1
fi
mkdir -p "$MEAS"

MANIFEST="$MEAS/jdk.manifest"            "$H/rtmr3-extend.sh" jdk "$JDK"
MANIFEST="$MEAS/java-settings.manifest"  "$H/rtmr3-extend.sh" java-settings "$JETC"
keytool -list -cacerts -storepass changeit 2>/dev/null | grep 'Certificate fingerprint' | sort > "$MEAS/java-ca-fingerprints.txt"
"$H/rtmr3-extend.sh" java-ca-fingerprints "$MEAS/java-ca-fingerprints.txt"
MANIFEST="$MEAS/hadoop-code.manifest"    "$H/rtmr3-extend.sh" hadoop-code "$HAD" logs etc/hadoop
MANIFEST="$MEAS/hadoop-conf.manifest"    "$H/rtmr3-extend.sh" hadoop-conf "$HAD/etc/hadoop"
MANIFEST="$MEAS/nutch-deploy.manifest"   "$H/rtmr3-extend.sh" nutch-deploy "$N/runtime/deploy"
MANIFEST="$MEAS/driver.manifest"         "$H/rtmr3-extend.sh" driver "$N/ops"
MANIFEST="$MEAS/seeds.manifest"          "$H/rtmr3-extend.sh" seeds "$N/seeds"
echo "measured components: $(wc -l < "$LOG") events in $LOG"
