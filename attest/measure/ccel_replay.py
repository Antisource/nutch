#!/usr/bin/env python3
# Replay a TDX boot event log (CCEL) and compare with the registers in a quote.
# Usage: ccel_replay.py <ccel.bin> [<quote.bin>]
import hashlib, os, struct, sys

ALGS = {0x0004: 20, 0x000B: 32, 0x000C: 48, 0x000D: 64}
ccel = open(sys.argv[1], "rb").read()

# First event is in the old SHA-1 layout and carries the log header.
(size,) = struct.unpack_from("<I", ccel, 28)
off = 32 + size
regs, counts, n = {}, {}, 0
while off + 12 <= len(ccel):
    idx, etype, cnt = struct.unpack_from("<III", ccel, off)
    if idx == 0xFFFFFFFF or cnt == 0:
        tail = ccel[off:]
        fill = tail.count(0xFF) == len(tail) or tail.count(0) == len(tail)
        print("end of log at byte", off, "| rest of file is plain fill:", fill)
        break
    start = off
    off += 12
    d384 = None
    for _ in range(cnt):
        (alg,) = struct.unpack_from("<H", ccel, off)
        off += 2
        if alg not in ALGS:
            sys.exit("PARSE ERROR: unknown hash id %#x in event %d at byte %d" % (alg, n + 1, start))
        ln = ALGS[alg]
        if alg == 0x000C:
            d384 = ccel[off:off + ln]
        off += ln
    (esz,) = struct.unpack_from("<I", ccel, off)
    off += 4 + esz
    n += 1
    if etype == 3 or d384 is None:  # EV_NO_ACTION is not extended
        continue
    regs[idx] = hashlib.sha384(regs.get(idx, bytes(48)) + d384).digest()
    counts[idx] = counts.get(idx, 0) + 1

print("events read:", n)
for k in sorted(regs):
    print("replayed log index", k, " events:", counts[k], " value:", regs[k].hex()[:12])

if len(sys.argv) > 2:
    q = open(sys.argv[2], "rb").read()
    names = ["RTMR0", "RTMR1", "RTMR2", "RTMR3"]
    for i, name in enumerate(names):
        v = q[376 + 48 * i: 424 + 48 * i]
        hit = [k for k in regs if regs[k] == v]
        print(name, "in quote:", v.hex()[:12], "->",
              ("MATCHES replayed log index %s" % hit) if hit else "no replayed index matches")
    rd = sys.argv[2] + ".reportdata"
    if os.path.exists(rd):
        print("REPORTDATA offset check:", "OK" if q[568:632] == open(rd, "rb").read() else "WRONG")
