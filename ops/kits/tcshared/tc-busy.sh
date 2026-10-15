#!/usr/bin/env bash
# The reservation marker of the shared cluster (rule 4: nobody runs anything during someone else's measurement).
#   tc-busy.sh start "what you are about to do"   take the cluster; refuses if somebody else holds it
#   tc-busy.sh stop                               give it back (only the holder; the admin may use --force)
#   tc-busy.sh status                             who holds it, since when, for what
# It is an agreement between people, not a lock the system enforces: simple authentication lets anyone use any name.
set -uo pipefail
ROOT="${TC_SHARED:-/opt/tc-shared}"; M="$ROOT/state/BUSY"; ME="${TCS_USER:-$(id -un)}"
case "${1:-}" in
  start)
    WHAT="${2:?usage: tc-busy.sh start \"what you are about to do\"}"
    if [ -e "$M" ]; then
      IFS=$'\t' read -r who since what < "$M"
      if [ "$who" = "$ME" ]; then echo "TC-BUSY: you already hold the cluster (since $since: $what)"; exit 0; fi
      echo "TC-BUSY-REFUSED: $who holds the cluster since $since ($what). Do not start; ask them to stop first." >&2; exit 1
    fi
    set -o noclobber
    if printf '%s\t%s\t%s\n' "$ME" "$(date -u +%FT%TZ)" "$WHAT" > "$M" 2>/dev/null; then echo "TC-BUSY: the cluster is yours now ($WHAT). Run: tc-busy.sh stop when you are done"; else echo "TC-BUSY-REFUSED: somebody took it a moment ago" >&2; exit 1; fi
    ;;
  stop)
    [ -e "$M" ] || { echo "TC-BUSY: nobody holds the cluster"; exit 0; }
    IFS=$'\t' read -r who since what < "$M"
    if [ "$who" = "$ME" ] || [ "${2:-}" = "--force" ]; then rm -f "$M" && echo "TC-BUSY: released (held by $who since $since: $what)"; else echo "TC-BUSY-REFUSED: $who holds it, not you (use --force only as the admin)" >&2; exit 1; fi
    ;;
  status)
    if [ -e "$M" ]; then IFS=$'\t' read -r who since what < "$M"; echo "TC-BUSY: held by $who since $since: $what"; else echo "TC-BUSY: free"; fi
    ;;
  *) echo "usage: tc-busy.sh start \"what\" | stop [--force] | status" >&2; exit 2 ;;
esac
