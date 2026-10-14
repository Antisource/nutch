#!/usr/bin/env bash
# Milestone 4, baby step 4.8.2, part 2 (AFTER the reboot into 6.17). Run on one node, MASTER FIRST.
#
# Usage:  bash m482-post.sh <master|worker> <policy-sha256>
# Needs the other files of this kit in the same folder (rtmr3-extend.sh, treehash.sh, quote.sh, rtmr3_replay.py,
# mesh-hadoop-node.sh, check-unchanged-m482.sh) and the state saved by m482-pre.sh in ~/m482/pre-<role>/.
#
# What it does, in this order, and stops at the first problem (no daemon is started before the measurement is proven):
#   1. checks: right machine, kernel 6.17, RTMR3 is zero (a fresh boot), the saved state exists, the policy is the pinned one
#   2. moves the old event log and manifests aside (never deletes them)
#   3. applies the mesh firewall (the repository's own step, with a NEW backup name so that
#      /root/iptables-before-mesh is not overwritten), checks that it equals the firewall saved before the reboot, then keeps it
#   4. measures into RTMR3, one event per component: jdk, java-settings, java-ca-fingerprints, hadoop-code, hadoop-conf,
#      tc-policy (new), and on the master also nutch-deploy, driver, seeds from NUTCH_DIR (default ~/m481/patched)
#   5. takes a quote bound to the event log and replays the log against it
#   6. recomputes every measured digest and compares it with the log
#   7. starts this node's Hadoop daemons (master: NameNode, ResourceManager; worker: DataNode, NodeManager)
#   8. bundles the evidence in ~/evidence-m482-<role>.tar.gz
# Test hooks (used only to rehearse this script away from the cluster): M482_HOSTNAME, TDX_MEAS, RTMR3_PATH, M482_QUOTE,
# M482_FW_BACKUP, M482_OUT, M482_POLICY_DIR, M482_NUTCH_DIR, M482_CCEL, M482_ANCHORS, M482_SLEEP, JDK_DIR, JAVA_ETC, HADOOP_DIR.
set -uo pipefail

U="usage: $0 <master|worker> <policy-sha256>"
ROLE="${1:?$U}"; POLICY_SHA="${2:?$U}"
NEW=6.17.0-1022-gcp
HOST="${M482_HOSTNAME:-$(hostname)}"
H="$(cd "$(dirname "$0")" && pwd)"
MS="${TDX_MEAS:-/sys/devices/virtual/misc/tdx_guest/measurements}"
JDK="${JDK_DIR:-/usr/lib/jvm/java-11-openjdk-amd64}"; JETC="${JAVA_ETC:-/etc/java-11-openjdk}"; HAD="${HADOOP_DIR:-$HOME/hadoop}"
N="${M482_NUTCH_DIR:-$HOME/m481/patched}"; POL="${M482_POLICY_DIR:-$HOME/tc-policy}"
OUT="${M482_OUT:-$HOME/m482}"; PRE="$OUT/pre-$ROLE"; D="$OUT/post-$ROLE"; OLD="$OUT/old-chain-$ROLE"
LOG="$HOME/rtmr3-events.tsv"; MEAS="$HOME/measured"; QUOTE="$HOME/quote-$ROLE-m482.bin"
CCEL="${M482_CCEL:-/sys/firmware/acpi/tables/data/CCEL}"; ANCHORS="${M482_ANCHORS:-121}"
FWB="${M482_FW_BACKUP:-/root/iptables-after-reboot-m482}"; KEEP="/tmp/fw-keep"
EV="$HOME/evidence-m482-$ROLE"
export HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop}" JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
cd "$HOME" || { echo "M482-POST-STOP: cannot enter the home folder" >&2; exit 1; }

case "$ROLE" in
  master) WANT_HOST=tdx-lab ;;
  worker) WANT_HOST=tdx-lab-worker ;;
  *) echo "M482-POST-STOP: the role must be master or worker" >&2; exit 1 ;;
esac
[ "$HOST" = "$WANT_HOST" ] || { echo "M482-POST-STOP: this machine is $HOST, but the role $ROLE belongs to $WANT_HOST" >&2; exit 1; }
[ -f "$PRE/iptables-S.txt" ] || { echo "M482-POST-STOP: the state saved before the reboot is missing: $PRE" >&2; exit 1; }
[ ! -e "$D" ] || { echo "M482-POST-STOP: $D exists already (an earlier run); nothing was changed" >&2; exit 1; }
[ ! -e "$OLD" ] || { echo "M482-POST-STOP: $OLD exists already; nothing was changed" >&2; exit 1; }
mkdir -p "$D" || exit 1
say()  { echo "$*" | tee -a "$D/summary.txt"; }
ok()   { say "   ok:   $*"; }
stop() { say "M482-POST-STOP: $*"; exit 1; }
fp()   { sha256sum "$1" | cut -c1-64; }
say "m482-post: $(date -u +%FT%TZ) on $HOST   role=$ROLE   kit folder=$H"

say "== checks"
[ "$(uname -r)" = "$NEW" ] || stop "running kernel $(uname -r), expected $NEW (the one-time boot did not happen: nothing was measured)"
for f in mrtd rtmr0 rtmr1 rtmr2 rtmr3; do [ -e "$MS/$f:sha384" ] || stop "missing $MS/$f:sha384"; done
R3="$(sudo xxd -p "$MS/rtmr3:sha384" | tr -d '\n')"
[ -z "$(printf '%s' "$R3" | tr -d 0)" ] || stop "RTMR3 is not zero (this boot was measured already)"
ok "kernel $NEW, the measurement files exist, RTMR3 is zero"
[ -f "$POL/policy.json" ] && [ "$(fp "$POL/policy.json")" = "$POLICY_SHA" ] || stop "policy.json is not the pinned one (${POLICY_SHA:0:16})"
ok "policy.json is the pinned one (${POLICY_SHA:0:16}...)"
if [ "$ROLE" = master ]; then
  [ -d "$N/runtime/deploy/bin" ] && [ -d "$N/ops" ] && [ -d "$N/seeds" ] || stop "$N lacks runtime/deploy/bin, ops or seeds"
  ok "NUTCH_DIR $N has deploy, ops and seeds"
fi
for f in rtmr3-extend.sh treehash.sh quote.sh rtmr3_replay.py mesh-hadoop-node.sh check-unchanged-m482.sh; do [ -f "$H/$f" ] || stop "kit file missing: $H/$f"; done
ok "the kit files are present"
for f in rtmr3-extend.sh treehash.sh quote.sh mesh-hadoop-node.sh; do [ -x "$H/$f" ] || stop "$H/$f is not executable (unpacking drops the flag); run: chmod +x $H/*.sh"; done
ok "the helper tools are executable"
if sudo test -e "$FWB"; then stop "$FWB exists already; it must not be overwritten"; fi

say "== move the old event log and manifests aside"
mkdir -p "$OLD" || stop "cannot create $OLD"
[ ! -e "$LOG" ] || mv "$LOG" "$OLD/rtmr3-events.tsv" || stop "cannot move the old log"
[ ! -d "$MEAS" ] || mv "$MEAS" "$OLD/measured" || stop "cannot move the old manifests"
ok "the old chain is in $OLD (nothing deleted)"

say "== firewall: the mesh rules, then a comparison with the rules saved before the reboot"
rm -f "$KEEP"
FW_BACKUP="$FWB" FW_KEEP_FILE="$KEEP" bash "$H/mesh-hadoop-node.sh" fw "$ROLE" > "$D/fw.txt" 2>&1 || { cat "$D/fw.txt"; stop "the firewall step failed (it undoes itself in 150 seconds)"; }
sudo iptables -S > "$D/iptables-S.after.txt" 2>&1
if cmp -s "$PRE/iptables-S.txt" "$D/iptables-S.after.txt"; then
  ok "the firewall equals the one saved before the reboot ($(wc -l < "$D/iptables-S.after.txt") rule lines)"
else
  diff "$PRE/iptables-S.txt" "$D/iptables-S.after.txt" | head -20
  stop "the firewall differs from the one saved before the reboot; it was NOT kept and undoes itself in 150 seconds"
fi
FW_KEEP_FILE="$KEEP" bash "$H/mesh-hadoop-node.sh" keep "$ROLE" > "$D/fw-keep.txt" 2>&1 || stop "could not keep the firewall"
ok "firewall kept; the backup of the state before this step is $FWB"

say "== measure into RTMR3"
mkdir -p "$MEAS"; export RTMR3_LOG="$LOG"
ext() { # ext <name> <path> [skip...]  (the manifest goes to ~/measured/<name>.manifest)
  local name="$1"; shift
  MANIFEST="$MEAS/$name.manifest" "$H/rtmr3-extend.sh" "$name" "$@" > "$D/extend-$name.txt" 2>&1 || { cat "$D/extend-$name.txt"; stop "measuring $name failed"; }
  ok "$name: $(sed -n 's/^digest //p' "$D/extend-$name.txt" | cut -c1-16)..."
}
ext jdk "$JDK"
ext java-settings "$JETC"
keytool -list -cacerts -storepass changeit 2>/dev/null | grep 'Certificate fingerprint' | sort > "$MEAS/java-ca-fingerprints.txt"
[ "$(wc -l < "$MEAS/java-ca-fingerprints.txt")" -eq "$ANCHORS" ] || stop "the CA store lists $(wc -l < "$MEAS/java-ca-fingerprints.txt") certificates, the policy expects $ANCHORS"
ext java-ca-fingerprints "$MEAS/java-ca-fingerprints.txt"
ext hadoop-code "$HAD" logs etc/hadoop
ext hadoop-conf "$HAD/etc/hadoop"
ext tc-policy "$POL"
if [ "$ROLE" = master ]; then
  ext nutch-deploy "$N/runtime/deploy"
  ext driver "$N/ops"
  ext seeds "$N/seeds"
fi
say "   events measured: $(wc -l < "$LOG") (expected $([ "$ROLE" = master ] && echo 9 || echo 6))"
[ "$(wc -l < "$LOG")" -eq "$([ "$ROLE" = master ] && echo 9 || echo 6)" ] || stop "unexpected number of events"

say "== quote bound to the event log, and the replay"
[ ! -e "$QUOTE" ] || stop "$QUOTE exists already"
"${M482_QUOTE:-$H/quote.sh}" "$LOG" "$QUOTE" > "$D/quote.txt" 2>&1 || { cat "$D/quote.txt"; stop "the quote failed"; }
python3 "$H/rtmr3_replay.py" "$LOG" "$QUOTE" > "$D/replay.txt" 2>&1; cat "$D/replay.txt"
grep -q 'chain consistent: True' "$D/replay.txt" && grep -q -- '-> MATCH$' "$D/replay.txt" && grep -q 'SHA-512 of this log: YES' "$D/replay.txt" || stop "the replay does not match the quote"
ok "the replay equals the quote's RTMR3 and its REPORTDATA binds the log"

say "== recompute every measured digest"
if NUTCH_DIR="$N" POLICY_DIR="$POL" RTMR3_LOG="$LOG" bash "$H/check-unchanged-m482.sh" > "$D/check-unchanged.txt" 2>&1; then cat "$D/check-unchanged.txt"; ok "nothing changed since the measurement"
else cat "$D/check-unchanged.txt"; stop "something changed since the measurement"; fi

say "== start this node's Hadoop daemons"
bash "$H/mesh-hadoop-node.sh" start "$ROLE" > "$D/start.txt" 2>&1 || { cat "$D/start.txt"; stop "starting the daemons failed"; }
cat "$D/start.txt"
left="$(jps 2>/dev/null | grep -c -E 'NameNode|ResourceManager|DataNode|NodeManager' || true)"
[ "$left" = 2 ] || stop "$left Hadoop daemons are running, expected 2"
ok "2 Hadoop daemons are running"

say "M482-POST-OK $ROLE: measured $(wc -l < "$LOG") components, the quote matches, nothing changed, the firewall is kept, the daemons are running"
rm -rf "$EV"; mkdir -p "$EV/post" "$EV/pre-state" "$EV/kit"
cp "$LOG" "$QUOTE" "$QUOTE.reportdata" "$EV/"
cp -r "$MEAS" "$EV/measured"
cp "$PRE"/* "$EV/pre-state/"
cp "$D"/* "$EV/post/"
cp "$OLD/rtmr3-events.tsv" "$EV/old-chain-rtmr3-events.tsv" 2>/dev/null || true
sudo cat "$CCEL" > "$EV/ccel.bin" 2>/dev/null || echo "CCEL not readable" > "$EV/ccel.bin.missing"
{ hostname; uname -a; uptime -s; java -version 2>&1 | head -1; hadoop version 2>&1 | head -1; sudo grub-editenv list 2>&1; jps 2>&1; } > "$EV/facts.txt"
cp "$H"/m482-pre.sh "$H"/m482-post.sh "$H"/rtmr3-extend.sh "$H"/treehash.sh "$H"/quote.sh "$H"/rtmr3_replay.py "$H"/mesh-hadoop-node.sh "$H"/check-unchanged-m482.sh "$EV/kit/"
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS && echo "files listed: $(grep -c . SHA256SUMS)   verified: $(sha256sum -c SHA256SUMS | grep -c ': OK$')" )
tar czf "$EV.tar.gz" -C "$HOME" "evidence-m482-$ROLE" && sha256sum "$EV.tar.gz" | tee "$EV.tar.gz.sha256" | cut -c1-64
echo "bundle: $EV.tar.gz   $(stat -c %s "$EV.tar.gz") bytes   entries: $(tar -tzf "$EV.tar.gz" | wc -l)"
