#!/usr/bin/env python3
"""Step 5.1.3: take a key bundle (*.attestkey) apart so that the existing quote tools can look at it.
Usage: m513_bundle_extract.py BUNDLE OUTDIR
Writes OUTDIR/statement.txt (the key statement that the quote vouches for) and OUTDIR/quote.bin (the TDX quote), and prints the key id, the REPORTDATA of the quote,
the SHA-512 of the statement (they must be equal: this is what attest/verify-binding.sh checks) and the measurement registers that the quote carries (information only)."""
import base64, hashlib, os, sys

REPORTDATA = 568          # 48-byte header + 520 bytes into the TD report body (the same offset as attest/verify-binding.sh)
FIELDS = [("MRTD", 184), ("RTMR0", 376), ("RTMR1", 424), ("RTMR2", 472), ("RTMR3", 520)]   # offsets of the 48-byte registers in a TDX quote v4


def main(argv):
    if len(argv) != 3:
        print("usage: m513_bundle_extract.py BUNDLE OUTDIR", file=sys.stderr)
        return 2
    lines = open(argv[1], encoding="ascii").read().split("\n")
    if len(lines) != 4 or lines[3] != "" or lines[0] != "ATTESTED-KEY-BUNDLE 1" or not lines[1].startswith("statement=") or not lines[2].startswith("quote="):
        print("EXTRACT-STOP: not a key bundle: " + argv[1], file=sys.stderr)
        return 1
    statement = base64.b64decode(lines[1][len("statement="):])
    q = lines[2][len("quote="):]
    key_id = next((l[len("key-id="):] for l in statement.decode("ascii").split("\n") if l.startswith("key-id=")), "?")
    os.makedirs(argv[2], exist_ok=True)
    open(os.path.join(argv[2], "statement.txt"), "wb").write(statement)
    print("key id    " + key_id)
    if q == "none":
        print("quote     none (a service key without a quote)")
        print("EXTRACT-NO-QUOTE")
        return 1
    quote = base64.b64decode(q)
    open(os.path.join(argv[2], "quote.bin"), "wb").write(quote)
    print("quote     %d bytes -> %s" % (len(quote), os.path.join(argv[2], "quote.bin")))
    if len(quote) < REPORTDATA + 64:
        print("EXTRACT-STOP: the quote is too short", file=sys.stderr)
        return 1
    embedded = quote[REPORTDATA:REPORTDATA + 64].hex()
    expected = hashlib.sha512(statement).hexdigest()
    print("REPORTDATA %s" % embedded)
    print("SHA-512 of the statement %s" % expected)
    for name, off in FIELDS:
        print("%-6s %s" % (name, quote[off:off + 48].hex()))
    if embedded == expected:
        print("EXTRACT-MATCH")
        return 0
    print("EXTRACT-MISMATCH")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
