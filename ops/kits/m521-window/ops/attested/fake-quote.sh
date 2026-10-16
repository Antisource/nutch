#!/usr/bin/env bash
# A FAKE quote command, used only to play a rogue key in the live check: it writes a 632-byte "quote" whose REPORTDATA is the SHA-512 of the statement, so the old
# binding check passes, but it has no Intel certificate chain, so the admission must refuse it. Usage: fake-quote.sh STATEMENT_FILE QUOTE_OUT
python3 - "$1" "$2" <<'PY'
import hashlib, sys
st = open(sys.argv[1], 'rb').read()
q = bytearray(b'\x04\x00' + b'\x00' * 630)
q[568:632] = hashlib.sha512(st).digest()
open(sys.argv[2], 'wb').write(bytes(q))
PY
