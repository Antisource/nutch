#!/usr/bin/env bash
# Request an Intel TDX quote whose REPORTDATA field holds the SHA-512 of a file.
#
# Usage: attest/quote.sh <input-file> <output-quote-file>
#
# Needs a TDX guest (kernel configfs-tsm interface), sudo, sha512sum and xxd.
# A SHA-512 digest is exactly 64 bytes, the size of the REPORTDATA field.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <input-file> <output-quote-file>" >&2
  exit 1
fi
IN="$1"
OUT="$2"
TSM=/sys/kernel/config/tsm/report

[ -f "$IN" ] || { echo "input file not found: $IN" >&2; exit 1; }
[ -d "$TSM" ] || { echo "configfs-tsm not found at $TSM; is this a TDX guest?" >&2; exit 1; }

REPORTDATA="${OUT}.reportdata"
sha512sum "$IN" | cut -d' ' -f1 | xxd -r -p > "$REPORTDATA"
if [ "$(stat -c%s "$REPORTDATA")" -ne 64 ]; then
  echo "REPORTDATA must be exactly 64 bytes" >&2
  exit 1
fi

# Use our own uniquely named request folder; never touch folders made by others.
REQ="$TSM/req-$$-$(date +%s)"
sudo mkdir "$REQ"
trap 'sudo rmdir "$REQ" 2>/dev/null || true' EXIT

sudo cp "$REPORTDATA" "$REQ/inblob"
sudo cat "$REQ/outblob" > "$OUT"

echo "quote written: $OUT ($(stat -c%s "$OUT") bytes)"