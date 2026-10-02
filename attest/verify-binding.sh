#!/usr/bin/env bash
# Check that a TDX quote's REPORTDATA equals the SHA-512 of a file.
#
# Usage: attest/verify-binding.sh <input-file> <quote-file>
#
# Prints MATCH (exit 0) or MISMATCH (exit 2).
# This does NOT verify the quote's signature; use go-tdx-guest's "check" tool for that.
# In the quotes we produced, REPORTDATA starts at byte offset 568
# (48-byte header + 520 bytes into the TD report body).
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <input-file> <quote-file>" >&2
  exit 1
fi
IN="$1"
QUOTE="$2"
[ -f "$IN" ] || { echo "input file not found: $IN" >&2; exit 1; }
[ -f "$QUOTE" ] || { echo "quote file not found: $QUOTE" >&2; exit 1; }

EMBEDDED="$(xxd -s 568 -l 64 -p "$QUOTE" | tr -d '\n')"
EXPECTED="$(sha512sum "$IN" | cut -d' ' -f1)"

if [ "$EMBEDDED" = "$EXPECTED" ]; then
  echo MATCH
else
  echo MISMATCH
  exit 2
fi