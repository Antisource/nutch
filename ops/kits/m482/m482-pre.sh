#!/usr/bin/env bash
# Milestone 4, baby step 4.8.2, part 1 (BEFORE the reboot). Run on one node.
#
# Usage:  bash m482-pre.sh <master|worker> <policy-sha256> [<patched-job-sha256>]
#   policy-sha256       the full SHA-256 of ~/tc-policy/policy.json (the policy built and verified in 4.8.1)
#   patched-job-sha256  the full SHA-256 of the patched job (required on the master)
#
# What it does, in this order, and stops at the first problem:
#   1. checks the node (right machine, boot pin, 6.17 menu entry, nothing pending, no running application,
#      the policy and (master) the patched build are the pinned versions, the firewall is the mesh firewall)
#   2. saves the state in ~/m482/pre-<role>/ (firewall rules, boot variables, hosts, daemons, sessions, tmux, wrapper logs)
#   3. asks GRUB for ONE boot into the 6.17 kernel (the pin on 6.8 stays; a reset returns to 6.8)
#   4. stops this node's Hadoop daemons
# It does NOT reboot. Reboot yourself when it prints M482-PRE-OK.
# Test hooks (used only to rehearse this script away from the cluster): M482_HOSTNAME, M482_GRUB_CFG,
# M482_POLICY_DIR, M482_NUTCH_DIR, M482_OUT, M482_SLEEP.
set -uo pipefail

U="usage: $0 <master|worker> <policy-sha256> [<patched-job-sha256>]"
ROLE="${1:?$U}"; POLICY_SHA="${2:?$U}"; JOB_SHA="${3:-}"
NEW=6.17.0-1022-gcp
HOST="${M482_HOSTNAME:-$(hostname)}"
CFG="${M482_GRUB_CFG:-/boot/grub/grub.cfg}"
POL="${M482_POLICY_DIR:-$HOME/tc-policy}"
NUTCH="${M482_NUTCH_DIR:-$HOME/m481/patched}"
OUT="${M482_OUT:-$HOME/m482}"
D="$OUT/pre-$ROLE"
ENTRY="Advanced options for Ubuntu>Ubuntu, with Linux $NEW"
export HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop}" JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
cd "$HOME" || { echo "M482-PRE-STOP: cannot enter the home folder" >&2; exit 1; }

case "$ROLE" in
  master) WANT_HOST=tdx-lab ;;
  worker) WANT_HOST=tdx-lab-worker ;;
  *) echo "M482-PRE-STOP: the role must be master or worker" >&2; exit 1 ;;
esac
[ "$HOST" = "$WANT_HOST" ] || { echo "M482-PRE-STOP: this machine is $HOST, but the role $ROLE belongs to $WANT_HOST" >&2; exit 1; }
[ ! -e "$D" ] || { echo "M482-PRE-STOP: $D exists already (an earlier run); move it away first, nothing was changed" >&2; exit 1; }
mkdir -p "$D" || exit 1
say()  { echo "$*" | tee -a "$D/summary.txt"; }
ok()   { say "   ok:   $*"; }
stop() { say "M482-PRE-STOP: $*"; exit 1; }
fp()   { sha256sum "$1" | cut -c1-64; }
say "m482-pre: $(date -u +%FT%TZ) on $HOST   role=$ROLE"

say "== checks"
ok "machine $HOST, role $ROLE"
say "   running kernel: $(uname -r)"
ENVTXT="$(sudo grub-editenv list 2>&1)"
grep -q '^saved_entry=.*6\.8\.0-' <<<"$ENVTXT" || stop "the boot pin is not on a 6.8 kernel: $(grep '^saved_entry' <<<"$ENVTXT")"
ok "the boot pin is on the old kernel ($(grep '^saved_entry' <<<"$ENVTXT" | sed 's/.*Linux //'))"
if grep -q '^next_entry=.\+' <<<"$ENVTXT"; then stop "a one-time boot is already pending: $(grep '^next_entry' <<<"$ENVTXT")"; fi
ok "no one-time boot is pending"
n="$(sudo grep -c "menuentry 'Ubuntu, with Linux $NEW' " "$CFG" 2>/dev/null || true)"
[ "$n" = 1 ] || stop "the boot menu has $n entries for $NEW, expected 1"
ok "the boot menu has the entry for $NEW"
ip link show wg0 >/dev/null 2>&1 || stop "wg0 is not up"
ok "wg0 is up"
if [ "$ROLE" = master ]; then
  n="$(yarn application -list -appStates RUNNING 2>/dev/null | grep -c 'application_[0-9]' || true)"
  [ "$n" = 0 ] || stop "$n Hadoop applications are running"
  ok "no Hadoop application is running"
fi
[ -f "$POL/policy.json" ] || stop "$POL/policy.json not found"
[ "$(fp "$POL/policy.json")" = "$POLICY_SHA" ] || stop "policy.json is $(fp "$POL/policy.json" | cut -c1-16), the pinned one is ${POLICY_SHA:0:16}"
ok "policy.json is the pinned one (${POLICY_SHA:0:16}...); the folder holds $(ls "$POL" | wc -l) files"
if [ "$ROLE" = master ]; then
  [ -n "$JOB_SHA" ] || stop "the master needs the patched job's SHA-256 as third argument"
  J="$NUTCH/runtime/deploy/apache-nutch-1.22.job"
  [ -f "$J" ] || stop "patched job not found: $J"
  [ "$(fp "$J")" = "$JOB_SHA" ] || stop "the job is $(fp "$J" | cut -c1-16), the pinned one is ${JOB_SHA:0:16}"
  [ -d "$NUTCH/runtime/deploy/bin" ] && [ -d "$NUTCH/ops" ] && [ -d "$NUTCH/seeds" ] || stop "$NUTCH lacks runtime/deploy/bin, ops or seeds"
  ok "the patched build is the pinned one (${JOB_SHA:0:16}...) and has deploy, ops and seeds"
fi
sudo iptables -S > "$D/iptables-S.txt" 2>&1 || stop "cannot read the firewall rules"
grep -q -- '-P INPUT DROP' "$D/iptables-S.txt" && grep -q 'multiport' "$D/iptables-S.txt" || stop "the firewall is not the mesh firewall (see $D/iptables-S.txt)"
ok "the firewall is the mesh firewall ($(wc -l < "$D/iptables-S.txt") rule lines)"
avail=$(df -Pk "$HOME" | awk 'NR==2{print $4}'); [ "${avail:-0}" -ge 1000000 ] || stop "less than 1 GB free"
ok "free disk space: $((avail/1024)) MB"

say "== save the state in $D"
sudo iptables-save > "$D/iptables-save.txt" 2>&1 || stop "iptables-save failed"
printf '%s\n' "$ENVTXT" > "$D/grub-editenv-before.txt"
cp /etc/hosts "$D/hosts.txt" 2>/dev/null || stop "cannot copy /etc/hosts"
{ jps 2>&1; } > "$D/jps.txt"
{ uname -a; uptime -s 2>&1; } > "$D/uname.txt"
{ who -u 2>&1; } > "$D/who.txt"
{ sudo wg show wg0 2>&1; } > "$D/wg.txt"
{ command -v tmux >/dev/null 2>&1 && { tmux ls 2>&1; tmux list-panes -a -F 'session=#{session_name} pane=#{pane_id} command=#{pane_current_command}' 2>&1; } || echo "tmux: not installed"; } > "$D/tmux.txt"
say "   tmux (ends at the reboot): $(tr '\n' ';' < "$D/tmux.txt" | cut -c1-200)"
[ ! -e "$HOME/rtmr3-events.tsv" ] || cp "$HOME/rtmr3-events.tsv" "$D/rtmr3-events.before.tsv"
[ ! -d "$HOME/measured" ] || ls -l "$HOME/measured" > "$D/measured-listing.txt"
if ls -d /tmp/attested-audit* >/dev/null 2>&1; then
  tar czf "$D/tmp-attested-audit.tar.gz" /tmp/attested-audit* 2>/dev/null || true
  say "   the wrapper's logs in /tmp (cleared by a reboot) are saved: $(stat -c %s "$D/tmp-attested-audit.tar.gz") bytes"
fi
ok "state saved"

say "== ask GRUB for ONE boot into $NEW"
sudo grub-reboot "$ENTRY" || stop "grub-reboot failed"
ENV2="$(sudo grub-editenv list 2>&1)"; printf '%s\n' "$ENV2" > "$D/grub-editenv-armed.txt"
grep -qxF "next_entry=$ENTRY" <<<"$ENV2" || stop "next_entry was not recorded (see $D/grub-editenv-armed.txt)"
[ "$(grep '^saved_entry' <<<"$ENV2")" = "$(grep '^saved_entry' <<<"$ENVTXT")" ] || stop "the pin changed"
ok "one-time boot recorded; the pin on 6.8 is unchanged"

say "== stop this node's Hadoop daemons"
if [ "$ROLE" = master ]; then yarn --daemon stop resourcemanager || true; hdfs --daemon stop namenode || true
else yarn --daemon stop nodemanager || true; hdfs --daemon stop datanode || true; fi
sleep "${M482_SLEEP:-5}"
left="$(jps 2>/dev/null | grep -c -E 'NameNode|ResourceManager|DataNode|NodeManager' || true)"
[ "$left" = 0 ] || stop "$left Hadoop daemons are still running. The one-time boot IS armed; to cancel it run: sudo grub-editenv /boot/grub/grubenv unset next_entry"
ok "no Hadoop daemon is running"

say "M482-PRE-OK $ROLE: one boot into $NEW is armed, the daemons are stopped, the state is in $D. Now reboot this node: sudo reboot"
( cd "$D" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
tar czf "$OUT/evidence-m482-pre-$ROLE.tar.gz" -C "$OUT" "pre-$ROLE" && sha256sum "$OUT/evidence-m482-pre-$ROLE.tar.gz" | cut -c1-64
