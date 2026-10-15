#!/usr/bin/env bash
# Shared cluster setup (the teammate's request of 14 October, items 1 and 3, and the reservation marker of her rule 4).
# Run on the MASTER, as the user that runs the Hadoop daemons:    bash tcs-install.sh
#
# What it does, in this order, and stops at the first problem:
#   1. checks: this is the master, /opt/tc-shared does not exist yet, the kit's tools are there, the event log holds the three
#      digests it needs, the measured set is intact right now (check-unchanged), there is room on the disk
#   2. COPIES (never moves) the Hadoop client tree (without logs) and the measured job folder into /opt/tc-shared, copies
#      ops/run-crawl.sh, installs the kit's tools and the README, makes everything owned by root, and refuses if anything in
#      the copy could be changed by other people
#   3. PROVES the copy is the measured stack: the digests of hadoop-code, hadoop-conf and nutch-deploy recomputed on the copy equal
#      the ones in the event log of the 4.8.2 measurement, and the wrapper jar equals the installed one
#   4. makes the wrapper's two log folders in /tmp usable by every user (mode 1777, kept across reboots by a tmpfiles rule) and
#      the reservation folder /opt/tc-shared/state
#   5. checks the measured set again (the copy must not have disturbed it)
# It changes nothing in ~/hadoop, in the measured job folder or in HDFS. Undo: sudo rm -rf /opt/tc-shared
# and sudo rm /etc/tmpfiles.d/zz-tc-shared.conf.
# Test hooks (used only to rehearse this script away from the cluster): TCS_ROOT, TCS_HAD, TCS_NUTCH, TCS_EVENTS, TCS_CHECK,
# TCS_SUDO, TCS_TMPFILES, TCS_TMP, TCS_HOSTNAME, TCS_USER, TCS_OUT.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
ROOT="${TCS_ROOT:-/opt/tc-shared}"; HAD="${TCS_HAD:-$HOME/hadoop}"; NUTCH="${TCS_NUTCH:-$HOME/m481/patched}"
LOGF="${TCS_EVENTS:-$HOME/rtmr3-events.tsv}"; CHECK="${TCS_CHECK:-$HOME/m482kit/m482/check-unchanged-m482.sh}"
SUDO="${TCS_SUDO:-sudo}"; TMPF="${TCS_TMPFILES:-/etc/tmpfiles.d}"; TMPD="${TCS_TMP:-/tmp}"
HOST="${TCS_HOSTNAME:-$(hostname)}"; ME="${TCS_USER:-$(id -un)}"; OWN="$(id -un)"; MYG="$(id -gn)"; OUT="${TCS_OUT:-$HOME/tcshared}"
cd "$HOME" || { echo "TCS-INSTALL-STOP: cannot enter the home folder" >&2; exit 1; }
[ "$HOST" = "tdx-lab" ] || { echo "TCS-INSTALL-STOP: this is $HOST; the shared client belongs on the master (tdx-lab)" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "TCS-INSTALL-STOP: $OUT exists already (an earlier run); nothing was changed" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
say()  { echo "$*" | tee -a "$OUT/summary.txt"; }
ok()   { say "   ok:   $*"; }
stop() { say "TCS-INSTALL-STOP: $*"; exit 1; }
say "tcs-install: $(date -u +%FT%TZ) on $HOST   user=$ME   root=$ROOT"

say "== checks"
[ ! -e "$ROOT" ] || stop "$ROOT exists already; nothing was changed (to start again: sudo rm -rf $ROOT)"
for f in treehash.sh tc-env.sh tc-seed.sh tc-busy.sh tc-check.sh tc-user-add.sh README.txt; do [ -f "$KIT/$f" ] || stop "kit file missing: $KIT/$f"; done
[ -x "$KIT/treehash.sh" ] || stop "$KIT/treehash.sh is not executable (unpacking drops the flag); run: chmod +x $KIT/*.sh"
ok "the kit's files are present"
[ -f "$LOGF" ] || stop "no event log at $LOGF (the stack must have been measured in this boot)"
evd() { awk -F'\t' -v n="$1" '$1==n {print $2}' "$LOGF"; }
for n in hadoop-code hadoop-conf nutch-deploy; do d="$(evd $n)"; [ "$(printf '%s\n' "$d" | grep -c .)" = 1 ] && [ "${#d}" = 96 ] || stop "the event log does not hold exactly one 96-hex digest for $n"; done
ok "the event log holds the digests of hadoop-code, hadoop-conf and nutch-deploy"
[ -f "$HAD/share/hadoop/common/lib/attested-hdfs.jar" ] || stop "the wrapper jar is not installed in $HAD"
[ -f "$NUTCH/runtime/deploy/apache-nutch-1.22.job" ] && [ -f "$NUTCH/ops/run-crawl.sh" ] || stop "the measured job folder or ops/run-crawl.sh is missing in $NUTCH"
if NUTCH_DIR="$NUTCH" bash "$CHECK" > "$OUT/check-before.txt" 2>&1 && grep -q 'ALL-UNCHANGED' "$OUT/check-before.txt"; then ok "the measured set is intact right now ($(grep 'ALL-UNCHANGED' "$OUT/check-before.txt"))"
else tail -5 "$OUT/check-before.txt"; stop "the measured set is not intact; do not copy from a source that differs from the measurement"; fi
need=$(du -sk "$HAD" "$NUTCH/runtime/deploy" | awk '{s+=$1} END {print s*2}'); mkdir -p "$(dirname "$ROOT")" 2>/dev/null
avail=$(df -Pk "$(dirname "$ROOT")" | awk 'NR==2 {print $4}'); [ "${avail:-0}" -gt "$need" ] || stop "not enough room for the copy: need about $((need/1024)) MB, have $((avail/1024)) MB"
ok "room on the disk: $((avail/1024)) MB free, about $((need/2048)) MB to copy"

say "== copy (never move)"
$SUDO mkdir -p "$ROOT/hadoop" "$ROOT/nutch/runtime/deploy" "$ROOT/nutch/ops" "$ROOT/bin" "$ROOT/state" || stop "cannot create $ROOT"
( cd "$HAD" && tar cf - --exclude=./logs . ) | $SUDO tar xpf - -C "$ROOT/hadoop" || stop "copying the Hadoop tree failed (it is incomplete; remove $ROOT and try again)"
$SUDO mkdir -p "$ROOT/hadoop/logs"
( cd "$NUTCH/runtime/deploy" && tar cf - . ) | $SUDO tar xpf - -C "$ROOT/nutch/runtime/deploy" || stop "copying the job folder failed"
$SUDO cp -p "$NUTCH/ops/run-crawl.sh" "$ROOT/nutch/ops/run-crawl.sh" || stop "cannot copy run-crawl.sh"
for f in tc-env.sh tc-seed.sh tc-busy.sh tc-check.sh tc-user-add.sh; do $SUDO install -m 755 "$KIT/$f" "$ROOT/bin/$f" || stop "cannot install $f"; done
$SUDO install -m 644 "$KIT/README.txt" "$ROOT/README.txt" || stop "cannot install the README"
$SUDO chown -R root:root "$ROOT" || stop "cannot make $ROOT owned by root"
$SUDO chmod 1777 "$ROOT/state" || stop "cannot prepare $ROOT/state"
ok "copied: $(du -sm "$ROOT/hadoop" | cut -f1) MB of Hadoop, $(du -sm "$ROOT/nutch" | cut -f1) MB of job, 5 tools, the README; owned by root"
w="$(find "$ROOT" -perm -0002 ! -type l ! -path "$ROOT/state" 2>/dev/null | head -5)"
[ -z "$w" ] || stop "something in the copy could be changed by other people: $w"
ok "nothing in the copy (except the reservation folder) can be changed by other people"

say "== prove that the copy is the measured stack"
cmp_digest() { # cmp_digest <name> <digest-of-the-copy>
  [ "$2" = "$(evd "$1")" ] && ok "$1: the copy's digest equals the measurement (${2:0:16}...)" || stop "$1: the copy's digest ${2:0:16} differs from the measurement ${3:-$(evd "$1" | cut -c1-16)}"
}
cmp_digest hadoop-code "$("$KIT/treehash.sh" "$ROOT/hadoop" logs etc/hadoop | awk '{print $2}')"
cmp_digest hadoop-conf "$("$KIT/treehash.sh" "$ROOT/hadoop/etc/hadoop" | awk '{print $2}')"
cmp_digest nutch-deploy "$("$KIT/treehash.sh" "$ROOT/nutch/runtime/deploy" | awk '{print $2}')"
[ "$(sha256sum "$ROOT/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sha256sum "$HAD/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" ] && ok "the wrapper jar equals the installed one" || stop "the wrapper jar of the copy differs from the installed one"
cmp -s "$ROOT/nutch/ops/run-crawl.sh" "$NUTCH/ops/run-crawl.sh" && ok "ops/run-crawl.sh equals the one that ran" || stop "ops/run-crawl.sh differs from the original"

say "== the wrapper's log folders, and the reservation folder"
for d in attested-audit attested-records; do
  $SUDO mkdir -p "$TMPD/$d" && $SUDO chown "$OWN:$MYG" "$TMPD/$d" && $SUDO chmod 1777 "$TMPD/$d" || stop "cannot prepare $TMPD/$d"
done
$SUDO mkdir -p "$TMPF" && printf '%s\n' "# the wrapper's log folders are shared by every user of the cluster client (shared cluster setup, 14 October 2026)" \
  "d $TMPD/attested-audit 1777 $OWN $MYG -" "d $TMPD/attested-records 1777 $OWN $MYG -" | $SUDO tee "$TMPF/zz-tc-shared.conf" >/dev/null || stop "cannot write the tmpfiles rule"
ok "$TMPD/attested-audit and $TMPD/attested-records are writable for everybody (mode 1777, owner $OWN) and recreated at every boot by $TMPF/zz-tc-shared.conf"
ok "$ROOT/state is the reservation folder (mode 1777)"

say "== the measured set again"
if NUTCH_DIR="$NUTCH" bash "$CHECK" > "$OUT/check-after.txt" 2>&1 && grep -q 'ALL-UNCHANGED' "$OUT/check-after.txt"; then ok "the measured set is still intact ($(grep 'ALL-UNCHANGED' "$OUT/check-after.txt"))"
else tail -5 "$OUT/check-after.txt"; stop "the measured set changed during the copy"; fi
{ echo "installed $(date -u +%FT%TZ) by $ME on $HOST"; echo "hadoop-code $(evd hadoop-code)"; echo "hadoop-conf $(evd hadoop-conf)"; echo "nutch-deploy $(evd nutch-deploy)"; } | $SUDO tee "$ROOT/INSTALLED.txt" >/dev/null
say "TCS-INSTALL-OK: /opt/tc-shared is the measured stack (read-only, owned by root). Next: tc-user-add.sh <her Linux user>, then tc-check.sh as that user."
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
tar czf "$HOME/tcs-install-evidence.tar.gz" -C "$HOME" tcshared && sha256sum "$HOME/tcs-install-evidence.tar.gz" | cut -c1-64
