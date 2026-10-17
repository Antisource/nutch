#!/usr/bin/env bash
# Rehearsal of node-attest.sh away from the cluster: the REAL script and the REAL verify-binding.sh; stand-ins only for the TDX guest (a quote command that writes a 632-byte quote with the right
# REPORTDATA, or a wrong one for the faults) and the WireGuard public key file. Usage: bash node-attest-rehearse.sh KITDIR
set -uo pipefail
KIT="$1"; A="$KIT/ops/attested"; PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; mkdir -p "$R/xbin"
if ! command -v xxd >/dev/null; then cat > "$R/xbin/xxd" <<'EOX'
#!/usr/bin/env python3
import sys
a = sys.argv[1:]; skip = int(a[a.index("-s") + 1]); length = int(a[a.index("-l") + 1]); data = open(a[-1], "rb").read()[skip:skip + length].hex()
for i in range(0, len(data), 60): print(data[i:i + 60])
EOX
chmod +x "$R/xbin/xxd"; export PATH="$R/xbin:$PATH"; fi
cat > "$R/good-quote.sh" <<'EOQ'
#!/usr/bin/env bash
python3 - "$1" "$2" <<'PY'
import hashlib, sys
st = open(sys.argv[1], 'rb').read(); q = bytearray(b'\x04\x00' + b'\x00' * 630); q[568:632] = hashlib.sha512(st).digest(); open(sys.argv[2], 'wb').write(bytes(q))
PY
EOQ
cat > "$R/wrong-quote.sh" <<'EOQ'
#!/usr/bin/env bash
python3 - "$1" "$2" <<'PY'
import hashlib, sys
q = bytearray(b'\x04\x00' + b'\x00' * 630); q[568:632] = hashlib.sha512(b'another statement').digest(); open(sys.argv[2], 'wb').write(bytes(q))
PY
EOQ
printf '#!/bin/bash\necho "no tsm here" >&2; exit 3\n' > "$R/broken-quote.sh"; chmod +x "$R"/*.sh
echo "jUiaEGwx5tJq7sO3jv1Hd0E2f4dZ4QZ8cSvJ9Lk1w2g=" > "$R/wg.pub"
printf '#!/bin/bash\necho "$*" >> "$R/sudo.log"\nexec "$@"\n' > "$R/fake-sudo.sh"; chmod +x "$R/fake-sudo.sh"; export R
run() { ( export NA_QUOTE="${NA_QUOTE:-$R/good-quote.sh}" NA_WGPUB="${NA_WGPUB:-$R/wg.pub}" NA_HOST="${NA_HOST:-tdx-lab}" NA_SUDO="${NA_SUDO-$R/fake-sudo.sh}" NA_WGSHOW="${NA_WGSHOW-cat $R/wg.pub}"; "$@" ) 2>&1; }
echo "=== 1. the happy path"
out="$(run bash "$A/node-attest.sh" "$R/b1.attestnode" 10.20.0.1)"; rc=$?; echo "$out" | cut -c1-170
chk "the key file is read through sudo (the folder /etc/wireguard is root only, mode 700) and the running interface agrees with the file" $(grep -q "^cat $R/wg.pub" "$R/sudo.log" && grep -q "the public key in .* is the key that the running wg0 uses" <<<"$out"; echo $?)
chk "exits 0 and says NODE-ATTEST-OK" $([ $rc = 0 ] && grep -q '^NODE-ATTEST-OK' <<<"$out"; echo $?)
chk "the bundle has the three lines of a bundle (tag, statement, quote)" $([ "$(grep -c '' "$R/b1.attestnode")" = 3 ] && [ "$(sed -n 1p "$R/b1.attestnode")" = "ATTESTED-NODE-BUNDLE 1" ] && sed -n 2p "$R/b1.attestnode" | grep -q '^statement=' && sed -n 3p "$R/b1.attestnode" | grep -q '^quote='; echo $?)
python3 - "$R/b1.attestnode" > "$R/decoded.txt" <<'PY'
import base64, hashlib, sys
l = open(sys.argv[1]).read().split("\n"); st = base64.b64decode(l[1][10:]); q = base64.b64decode(l[2][6:])
print(st.decode()); print("BINDING", q[568:632] == hashlib.sha512(st).digest())
PY
chk "the statement holds the tag, host, the WireGuard public key, the mesh address, a time and a 32-digit nonce" $(grep -q '^ATTESTED-NODE-STATEMENT 1$' "$R/decoded.txt" && grep -q '^host=tdx-lab$' "$R/decoded.txt" && grep -q '^mesh-public=jUiaEGwx5tJq7sO3jv1Hd0E2f4dZ4QZ8cSvJ9Lk1w2g=$' "$R/decoded.txt" && grep -q '^mesh-ip=10.20.0.1$' "$R/decoded.txt" && grep -Eq '^created=20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$R/decoded.txt" && grep -Eq '^nonce=[0-9a-f]{32}$' "$R/decoded.txt"; echo $?)
chk "the quote's REPORTDATA is the SHA-512 of the statement (checked here independently of verify-binding.sh)" $(grep -q '^BINDING True' "$R/decoded.txt"; echo $?)
out2="$(run bash "$A/node-attest.sh" "$R/b2.attestnode" 10.20.0.1)"; n1=$(sed -n 2p "$R/b1.attestnode" | cut -c1-30); 
chk "two runs make two different statements (the nonce differs)" $([ "$(python3 -c "import base64,sys; print(base64.b64decode(open('$R/b1.attestnode').read().split(chr(10))[1][10:]).decode()==base64.b64decode(open('$R/b2.attestnode').read().split(chr(10))[1][10:]).decode())")" = False ]; echo $?)
out3="$(python3 "$A/node_bundle_extract.py" "$R/b1.attestnode" "$R/x1" 2>&1)"; rc=$?
chk "the extractor takes the bundle apart and says EXTRACT-MATCH (and writes statement.txt and quote.bin)" $([ $rc = 0 ] && grep -q '^EXTRACT-MATCH' <<<"$out3" && [ -s "$R/x1/quote.bin" ] && [ -s "$R/x1/statement.txt" ]; echo $?)
python3 - "$R/b1.attestnode" "$R/b-tampered.attestnode" <<'PY'
import base64, sys
l = open(sys.argv[1]).read().split("\n"); st = bytearray(base64.b64decode(l[1][10:])); i = st.index(b"10.20.0.1"); st[i + 8] = ord("9")
open(sys.argv[2], "w").write(l[0] + "\nstatement=" + base64.b64encode(bytes(st)).decode() + "\n" + l[2] + "\n")
PY
out4="$(python3 "$A/node_bundle_extract.py" "$R/b-tampered.attestnode" "$R/x2" 2>&1)"; rc=$?
chk "a statement changed after the quote was made (the mesh address 10.20.0.1 became 10.20.0.9) is reported EXTRACT-MISMATCH (exit 2)" $([ $rc = 2 ] && grep -q '^EXTRACT-MISMATCH' <<<"$out4"; echo $?)
echo "=== 2. faults: it must stop, say why, and leave no bundle"
f() { rm -f "$R/bf.attestnode"; out="$(eval "$2")"; rc=$?; chk "fault: $1 -> stops ($3)" $([ $rc != 0 ] && grep -q "$3" <<<"$out" && [ ! -e "$R/bf.attestnode" ]; echo $?); }
echo "keep me" > "$R/bf.attestnode"; out="$(run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1)"; rc=$?; chk "fault: the output file exists already -> stops (exists already), and the file is not touched" $([ $rc != 0 ] && grep -q "exists already" <<<"$out" && [ "$(cat "$R/bf.attestnode")" = "keep me" ]; echo $?); rm -f "$R/bf.attestnode"
f "the WireGuard public key file cannot be read" 'NA_WGPUB="$R/none.pub" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "cannot be read"
f "sudo is not available (the folder is root only, so the key cannot be read)" 'NA_SUDO="$R/no-sudo.sh" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "cannot be read"
f "the key of the running wg0 is not the key in the file" 'NA_WGSHOW="echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "is not the key in"
f "the file is not a WireGuard public key" 'echo "not-a-key" > "$R/bad.pub"; NA_WGPUB="$R/bad.pub" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "does not hold a WireGuard public key"
f "the mesh address is not an address" 'run bash "$A/node-attest.sh" "$R/bf.attestnode" ten.twenty' "not an IPv4 address"
f "the quote command fails (no TDX guest)" 'NA_QUOTE="$R/broken-quote.sh" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "the quote could not be made"
f "the quote does not bind this statement (REPORTDATA is another hash)" 'NA_QUOTE="$R/wrong-quote.sh" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "not the SHA-512 of the statement"
f "the host name is unusable" 'NA_HOST="bad host!" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "the host name is not usable"
f "verify-binding.sh is missing" 'NA_VERIFY="$R/none.sh" run bash "$A/node-attest.sh" "$R/bf.attestnode" 10.20.0.1' "missing next to this script"
echo; echo "pass: $PASS   fail: $FAILN"; [ "$FAILN" = 0 ] && echo "REHEARSAL-PASS: the real script passes, and its 10 faults are all reported; $PASS checks" || echo "REHEARSAL-FAIL"
