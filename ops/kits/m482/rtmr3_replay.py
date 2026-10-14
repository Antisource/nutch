#!/usr/bin/env python3
# Replay our RTMR3 event log from zeros and compare with a quote.
# Usage: rtmr3_replay.py <events.tsv> [<quote.bin>]
import hashlib, sys

reg = bytes(48)
ok = True
n = 0
for line in open(sys.argv[1]):
    name, digest, before, after = line.rstrip("\n").split("\t")
    n += 1
    if bytes.fromhex(before) != reg:
        print("event", n, name, ": 'before' does not follow the previous event")
        ok = False
    reg = hashlib.sha384(reg + bytes.fromhex(digest)).digest()
    if reg.hex() != after:
        print("event", n, name, ": recorded 'after' does not match the replay")
        ok = False
    print("event", n, name, "->", reg.hex()[:12])
print("events:", n, "| chain consistent:", ok)
print("replayed RTMR3:", reg.hex()[:12])
if len(sys.argv) > 2:
    q = open(sys.argv[2], "rb").read()
    v = q[520:568]
    print("RTMR3 in quote:", v.hex()[:12], "->", "MATCH" if v == reg else "NO MATCH")
    log = open(sys.argv[1], "rb").read()
    rd = hashlib.sha512(log).digest()
    print("REPORTDATA = SHA-512 of this log:", "YES" if q[568:632] == rd else "NO")
