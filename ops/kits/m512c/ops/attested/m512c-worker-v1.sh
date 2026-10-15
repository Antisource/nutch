#!/usr/bin/env bash
# Milestone 5, the combined crawl: the two small jobs of the WORKER node.
#   bash ops/attested/m512c-worker.sh prep          BEFORE the window is opened on the worker: move this node's old wrapper logs aside, so that the
#                                                   crawl starts clean. The window's open then restarts the daemons, so the NodeManager writes its
#                                                   logs into the fresh folder (a process that is running keeps writing into a file that was moved).
#   bash ops/attested/m512c-worker.sh pack RUN      AFTER the crawl, with the window still open: pack this node's wrapper logs as ~/RUN-worker.tar.gz.
# Test hooks (rehearsal only): M512C_HOME, M512C_HOST, M512C_ATT_TMP.
set -uo pipefail
ACTION="${1:?usage: $0 prep | pack RUN}"; HOME_="${M512C_HOME:-$HOME}"; HOST="${M512C_HOST:-$(hostname)}"; TMP="${M512C_ATT_TMP:-/tmp}"
KIT="$(cd "$(dirname "$0")" && pwd)"
[ "$HOST" = tdx-lab-worker ] || { echo "M512C-WORKER-STOP: this runs on the worker (tdx-lab-worker), not on $HOST" >&2; exit 1; }
WIN="$HOME_/m512w/window"
case "$ACTION" in
prep)
  [ ! -e "$WIN" ] || { echo "M512C-WORKER-STOP: the window is open already ($WIN): prep must come BEFORE the window's open, because the open restarts the NodeManager" >&2; exit 1; }
  out="$(ATTESTED_AUDIT_DIR="$TMP/attested-audit" bash "$KIT/audit.sh" rotate 2>&1)"; rc=$?
  echo "$out"
  [ $rc = 0 ] || { echo "M512C-WORKER-STOP: the log rotation failed" >&2; exit 1; }
  echo "M512C-WORKER-PREP-OK: the old wrapper logs of this node are moved aside. Now open the window on this node (m512-window.sh open worker ...)."
  ;;
pack)
  RUN="${2:?usage: $0 pack RUN}"; [[ "$RUN" =~ ^[a-z0-9]+$ ]] || { echo "M512C-WORKER-STOP: RUN must be letters and digits only" >&2; exit 1; }
  [ -d "$WIN/saved" ] || { echo "M512C-WORKER-STOP: the window is not open on this node ($WIN): the pack is taken during the window" >&2; exit 1; }
  [ ! -e "$HOME_/$RUN-worker.tar.gz" ] || { echo "M512C-WORKER-STOP: $HOME_/$RUN-worker.tar.gz exists already" >&2; exit 1; }
  [ -d "$TMP/attested-audit" ] && [ -d "$TMP/attested-records" ] || { echo "M512C-WORKER-STOP: no wrapper log folders in $TMP on this node" >&2; exit 1; }
  na="$(find "$TMP/attested-audit" -maxdepth 1 -name '*.tsv' | wc -l)"; nr="$(find "$TMP/attested-records" -maxdepth 1 -name '*.tsv' | wc -l)"
  [ "$na" -gt 0 ] || { echo "M512C-WORKER-STOP: there are no audit logs on this node: the NodeManager did not write any (was prep run before the window's open?)" >&2; exit 1; }
  ( cd "$TMP" && tar czf "$HOME_/$RUN-worker.tar.gz" attested-audit attested-records ) || { echo "M512C-WORKER-STOP: packing failed" >&2; exit 1; }
  echo "packed $na audit log file(s) and $nr record log file(s) into $HOME_/$RUN-worker.tar.gz"
  echo "sha256 $(sha256sum "$HOME_/$RUN-worker.tar.gz" | cut -c1-64)"
  echo "M512C-WORKER-PACK-OK ($RUN)"
  ;;
*) echo "usage: $0 prep | pack RUN" >&2; exit 2 ;;
esac
