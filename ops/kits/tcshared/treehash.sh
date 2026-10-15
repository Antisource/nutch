#!/usr/bin/env bash
# Fingerprint a folder: SHA-384 over a sorted list of (type, mode, file hash, path).
# Usage: treehash.sh <dir> [path-to-skip-relative-to-dir ...]
# Writes the list to $MANIFEST if that variable is set.
set -euo pipefail
DIR="$1"; shift
cd "$DIR"
skip=()
for e in "$@"; do skip+=( -not -path "./$e" -not -path "./$e/*" ); done
list() {
  find . \( -type f -o -type l \) "${skip[@]}" -print0 | LC_ALL=C sort -z |
  while IFS= read -r -d '' p; do
    if [ -L "$p" ]; then
      printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
    else
      printf 'F %s %s %s\n' "$(stat -c %a "$p")" "$(sha384sum < "$p" | cut -d' ' -f1)" "$p"
    fi
  done
}
if [ -n "${MANIFEST:-}" ]; then list > "$MANIFEST"; src="$MANIFEST"; else src=$(mktemp); list > "$src"; fi
echo "TREE-DIGEST $(sha384sum < "$src" | cut -d' ' -f1) files=$(wc -l < "$src") dir=$DIR"
