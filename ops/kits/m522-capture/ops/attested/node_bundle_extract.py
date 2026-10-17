#!/usr/bin/env python3
"""Take an ATTESTED-NODE-BUNDLE apart: write statement.txt and quote.bin into OUTDIR, print the statement's fields, and say EXTRACT-MATCH when the quote's REPORTDATA (offset 568, 64 bytes)
equals the SHA-512 of the statement, EXTRACT-MISMATCH (exit 2) when it does not. It does NOT verify the quote's signature chain (go-tdx-guest's check on the laptop, or the admission step, does).
Usage: python3 node_bundle_extract.py BUNDLE OUTDIR"""
import base64, hashlib, os, sys
if len(sys.argv) != 3: sys.exit("usage: node_bundle_extract.py BUNDLE OUTDIR")
lines = open(sys.argv[1]).read().split("\n")
if len(lines) < 3 or lines[0] != "ATTESTED-NODE-BUNDLE 1" or not lines[1].startswith("statement=") or not lines[2].startswith("quote="): sys.exit("not an ATTESTED-NODE-BUNDLE 1 file")
st = base64.b64decode(lines[1][len("statement="):]); q = base64.b64decode(lines[2][len("quote="):])
os.makedirs(sys.argv[2], exist_ok=True); open(os.path.join(sys.argv[2], "statement.txt"), "wb").write(st); open(os.path.join(sys.argv[2], "quote.bin"), "wb").write(q)
for l in st.decode().split("\n"):
    if "=" in l: k, v = l.split("=", 1); print("  %-12s %s" % (k, v))
print("  quote        %d bytes" % len(q))
if len(q) >= 632 and q[568:632] == hashlib.sha512(st).digest(): print("EXTRACT-MATCH: the quote's REPORTDATA equals the SHA-512 of the statement")
else: print("EXTRACT-MISMATCH"); sys.exit(2)
