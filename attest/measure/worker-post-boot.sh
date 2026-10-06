#!/usr/bin/env bash
# Run on the worker after the one-time boot into 6.17.
# Checks the kernel and register files, measures this node's stack into RTMR3,
# takes a quote, restarts this node's Hadoop daemons, and bundles the evidence.
# Needs rtmr3-extend.sh, treehash.sh and quote.sh in the same folder.
set -euo pipefail
NEW=6.17.0-1022-gcp
H="$(cd "$(dirname "$0")" && pwd)"
M="${TDX_MEAS:-/sys/devices/virtual/misc/tdx_guest/measurements}"
JDK="${JDK_DIR:-/usr/lib/jvm/java-11-openjdk-amd64}"
JETC="${JAVA_ETC:-/etc/java-11-openjdk}"
HAD="${HADOOP_DIR:-$HOME/hadoop}"
CCEL="${CCEL_FILE:-/sys/firmware/acpi/tables/data/CCEL}"
LOG="$HOME/rtmr3-events.tsv"
MEAS="$HOME/measured"
EV="$HOME/evidence-worker-m1"
fail() { echo "ABORT: $*" >&2; exit 1; }
say() { echo "== $*"; }

say "checks"
[ "$(uname -r)" = "$NEW" ] || fail "running $(uname -r), expected $NEW"
for f in mrtd rtmr0 rtmr1 rtmr2 rtmr3; do [ -e "$M/$f:sha384" ] || fail "missing $M/$f:sha384"; done
R3="$(sudo xxd -p "$M/rtmr3:sha384" | tr -d '\n')"
[ -z "$(printf '%s' "$R3" | tr -d 0)" ] || fail "RTMR3 is not zero (already measured on this boot?)"
[ ! -e "$LOG" ] || fail "an event log already exists: $LOG"
echo "kernel $NEW, measurement files present, RTMR3 is zero"

say "measure this node's stack into RTMR3"
mkdir -p "$MEAS"
export RTMR3_LOG="$LOG"
MANIFEST="$MEAS/jdk.manifest"           "$H/rtmr3-extend.sh" jdk "$JDK"
MANIFEST="$MEAS/java-settings.manifest" "$H/rtmr3-extend.sh" java-settings "$JETC"
keytool -list -cacerts -storepass changeit 2>/dev/null | grep 'Certificate fingerprint' | sort > "$MEAS/java-ca-fingerprints.txt"
"$H/rtmr3-extend.sh" java-ca-fingerprints "$MEAS/java-ca-fingerprints.txt"
MANIFEST="$MEAS/hadoop-code.manifest"   "$H/rtmr3-extend.sh" hadoop-code "$HAD" logs etc/hadoop
MANIFEST="$MEAS/hadoop-conf.manifest"   "$H/rtmr3-extend.sh" hadoop-conf "$HAD/etc/hadoop"

say "quote bound to the event log"
"$H/quote.sh" "$LOG" "$HOME/quote-worker-m1.bin"

say "restart this node's Hadoop daemons"
hdfs --daemon start datanode
yarn --daemon start nodemanager
sleep 20
jps

say "bundle the evidence"
rm -rf "$EV"; mkdir -p "$EV"
sudo cat "$CCEL" > "$EV/ccel-worker-617.bin"
{ hostname; uname -a; uptime -s; java -version 2>&1 | head -1; hadoop version | head -1
  dpkg -l | grep -E '^ii +linux-(image|modules)-[0-9]' | awk '{print $2, $3}' || true; sudo grub-editenv list || true; } > "$EV/worker-facts.txt"
cp "$LOG" "$HOME/quote-worker-m1.bin" "$HOME/quote-worker-m1.bin.reportdata" "$EV/"
cp -r "$MEAS" "$EV/measured"
cp "$H/rtmr3-extend.sh" "$H/treehash.sh" "$H/quote.sh" "$H/worker-post-boot.sh" "$EV/"
[ -f "$H/worker-kernel-prep.sh" ] && cp "$H/worker-kernel-prep.sh" "$EV/"
( cd "$EV" && find . -type f ! -name SHA256SUMS.txt | sort | xargs sha256sum > SHA256SUMS.txt
  echo "files verified: $(sha256sum -c SHA256SUMS.txt | grep -c ': OK') of $(wc -l < SHA256SUMS.txt)" )
cd "$HOME"
tar -czf evidence-worker-m1.tar.gz evidence-worker-m1
sha256sum evidence-worker-m1.tar.gz | tee evidence-worker-m1.tar.gz.sha256
echo "tar entries: $(tar -tzf evidence-worker-m1.tar.gz | wc -l)"
echo
echo "DONE. Next: fetch evidence-worker-m1.tar.gz from Cloud Shell."
