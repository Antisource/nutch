#!/usr/bin/env bash
# Extend RTMR3 with the SHA-384 of a file (or of a folder, via treehash.sh)
# and keep our own event log.
# Usage: rtmr3-extend.sh <name> <path> [skip-path-inside-folder ...]
# Log ($RTMR3_LOG, default ~/rtmr3-events.tsv), one line per extension:
#   name <TAB> digest <TAB> rtmr3-before <TAB> rtmr3-after
set -euo pipefail
RT="${RTMR3_PATH:-/sys/devices/virtual/misc/tdx_guest/measurements/rtmr3:sha384}"
LOG="${RTMR3_LOG:-$HOME/rtmr3-events.tsv}"
NAME="$1"; TARGET="$2"; shift 2
read_rt() { sudo xxd -p "$RT" | tr -d '\n'; }

if [ -d "$TARGET" ]; then
  DIGEST=$("$(dirname "$0")/treehash.sh" "$TARGET" "$@" | awk '{print $2}')
else
  DIGEST=$(sha384sum "$TARGET" | cut -d' ' -f1)
fi
[ "${#DIGEST}" -eq 96 ] || { echo "digest is not 96 hex characters: $DIGEST" >&2; exit 1; }

BEFORE=$(read_rt)
printf '%s' "$DIGEST" | xxd -r -p | sudo dd of="$RT" bs=48 count=1 iflag=fullblock conv=notrunc status=none
AFTER=$(read_rt)
WANT=$(python3 -c "import hashlib,sys; print(hashlib.sha384(bytes.fromhex(sys.argv[1])+bytes.fromhex(sys.argv[2])).hexdigest())" "$BEFORE" "$DIGEST")
printf '%s\t%s\t%s\t%s\n' "$NAME" "$DIGEST" "$BEFORE" "$AFTER" >> "$LOG"
if [ "$AFTER" = "$WANT" ]; then
  echo "EXTENDED $NAME: register equals SHA-384(before + digest)"
  echo "digest $DIGEST"
else
  echo "MISMATCH after extending $NAME" >&2
  exit 1
fi
