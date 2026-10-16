#!/usr/bin/env bash
# Milestone 5, the combined crawl: the small jobs of the WORKER node.
#   bash ops/attested/m513c-worker.sh prep          BEFORE the window is opened on the worker: move this node's old wrapper logs aside, so that the
#                                                   crawl starts clean. The window's open then restarts the daemons, so the NodeManager writes its
#                                                   logs into the fresh folder (a process that is running keeps writing into a file that was moved).
#   bash ops/attested/m513c-worker.sh pack RUN      AFTER the crawl, with the window still open: pack this node's wrapper logs AND the YARN task logs
#                                                   (the userlogs of the crawl's containers) as ~/RUN-worker.tar.gz.
#   bash ops/attested/m513c-worker.sh repack RUN FROM TO     AFTER the window, for a pack that was made without the task logs (version 1 of this script did that
#                                                   for run14): moves ~/RUN-worker.tar.gz to ~/RUN-worker-logs-only.tar.gz and makes ~/RUN-worker.tar.gz again from it
#                                                   plus the userlogs of the applications that were started between FROM and TO (UTC, "YYYY-MM-DD HH:MM:SS", the
#                                                   window's open and close times). The wrapper logs in it are the ones of the original pack, unchanged.
# Test hooks (rehearsal only): M513C_HOME, M513C_HOST, M513C_ATT_TMP, M513C_HH.
set -uo pipefail
ACTION="${1:?usage: $0 prep | pack RUN | repack RUN FROM TO}"; HOME_="${M513C_HOME:-$HOME}"; HOST="${M513C_HOST:-$(hostname)}"; TMP="${M513C_ATT_TMP:-/tmp}"
HH="${M513C_HH:-$HOME_/hadoop}"; UL="$HH/logs/userlogs"
KIT="$(cd "$(dirname "$0")" && pwd)"
stop() { echo "M513C-WORKER-STOP: $*" >&2; exit 1; }
[ "$HOST" = tdx-lab-worker ] || stop "this runs on the worker (tdx-lab-worker), not on $HOST"
WIN="$HOME_/m513w/window"
runname() { [[ "${1:-}" =~ ^[a-z0-9]+$ ]] || stop "RUN must be letters and digits only"; }
case "$ACTION" in
prep)
  [ ! -e "$WIN" ] || stop "the window is open already ($WIN): prep must come BEFORE the window's open, because the open restarts the NodeManager"
  out="$(ATTESTED_AUDIT_DIR="$TMP/attested-audit" bash "$KIT/audit.sh" rotate 2>&1)"; rc=$?
  echo "$out"
  [ $rc = 0 ] || stop "the log rotation failed"
  echo "M513C-WORKER-PREP-OK: the old wrapper logs of this node are moved aside. Now open the window on this node (m513-window.sh open worker ...)."
  ;;
pack)
  RUN="${2:-}"; runname "$RUN"
  [ -d "$WIN/saved" ] || stop "the window is not open on this node ($WIN): the pack is taken during the window"
  [ ! -e "$HOME_/$RUN-worker.tar.gz" ] || stop "$HOME_/$RUN-worker.tar.gz exists already"
  [ -d "$TMP/attested-audit" ] && [ -d "$TMP/attested-records" ] || stop "no wrapper log folders in $TMP on this node"
  [ -d "$UL" ] && [ -n "$(ls -A "$UL" 2>/dev/null)" ] || stop "no YARN task logs in $UL: the pack would have no userlogs (the analysis needs them)"
  na="$(find "$TMP/attested-audit" -maxdepth 1 -name '*.tsv' | wc -l)"; nr="$(find "$TMP/attested-records" -maxdepth 1 -name '*.tsv' | wc -l)"
  [ "$na" -gt 0 ] || stop "there are no audit logs on this node: the NodeManager did not write any (was prep run before the window's open?)"
  nu="$(find "$UL" -mindepth 1 -maxdepth 1 -name 'application_*' | wc -l)"
  ( tar czf "$HOME_/$RUN-worker.tar.gz" -C "$TMP" attested-audit attested-records -C "$HH/logs" userlogs ) || stop "packing failed"
  tar tzf "$HOME_/$RUN-worker.tar.gz" | grep -q '^userlogs/' || stop "the pack has no userlogs"
  echo "packed $na audit log file(s), $nr record log file(s) and the task logs of $nu application(s) into $HOME_/$RUN-worker.tar.gz"
  echo "sha256 $(sha256sum "$HOME_/$RUN-worker.tar.gz" | cut -c1-64)"
  echo "M513C-WORKER-PACK-OK ($RUN)"
  ;;
repack)
  RUN="${2:-}"; runname "$RUN"; FROM="${3:-}"; TO="${4:-}"
  [ -n "$FROM" ] && [ -n "$TO" ] || stop "give FROM and TO (UTC, \"YYYY-MM-DD HH:MM:SS\")"
  tf="$(date -u -d "$FROM" +%s 2>/dev/null)" && tt="$(date -u -d "$TO" +%s 2>/dev/null)" || stop "FROM or TO is not a time"
  [ "$tf" -lt "$tt" ] || stop "FROM must be before TO"
  P="$HOME_/$RUN-worker.tar.gz"; O="$HOME_/$RUN-worker-logs-only.tar.gz"
  [ -f "$P" ] || stop "there is no $P to complete"
  [ ! -e "$O" ] || stop "$O exists already: this pack was completed before"
  tar tzf "$P" | grep -q '^userlogs/' && stop "$P has userlogs already: nothing to complete"
  [ -d "$UL" ] || stop "no YARN task logs folder at $UL"
  apps=""; for d in "$UL"/application_*; do [ -d "$d" ] || continue; m="$(stat -c %Y "$d")"; [ "$m" -ge "$tf" ] && [ "$m" -le "$tt" ] && apps="$apps $(basename "$d")"; done
  [ -n "$apps" ] || stop "no application's task logs were written between $FROM and $TO in $UL"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  tar xzf "$P" -C "$T" || stop "cannot unpack $P"
  mkdir -p "$T/userlogs"; for a in $apps; do cp -a "$UL/$a" "$T/userlogs/$a" || stop "cannot copy the task logs of $a"; done
  cp -p "$P" "$O" || stop "cannot keep the original pack"
  ( cd "$T" && tar czf "$P.new" attested-audit attested-records userlogs ) || stop "packing failed"
  mv -f "$P.new" "$P"
  echo "the original pack is kept as $O (sha256 $(sha256sum "$O" | cut -c1-64))"
  echo "task logs added for $(echo $apps | wc -w) application(s):$apps"
  echo "the completed pack $P: sha256 $(sha256sum "$P" | cut -c1-64), $(tar tzf "$P" | grep -c '^userlogs/.*[^/]$') task log files"
  echo "M513C-WORKER-REPACK-OK ($RUN)"
  ;;
*) echo "usage: $0 prep | pack RUN | repack RUN FROM TO" >&2; exit 2 ;;
esac
