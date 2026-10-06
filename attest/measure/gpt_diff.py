#!/usr/bin/env python3
# Compare the disk partition-table (GPT) event in two TDX boot event logs, field by field.
# Usage: gpt_diff.py <ccel-A.bin> <ccel-B.bin>
import struct, sys

ALGS = {0x0004: 20, 0x000B: 32, 0x000C: 48, 0x000D: 64}

def gpt_data(path):
    b = open(path, "rb").read()
    (size,) = struct.unpack_from("<I", b, 28)
    off = 32 + size
    while off + 12 <= len(b):
        idx, et, cnt = struct.unpack_from("<III", b, off)
        if idx == 0xFFFFFFFF or cnt == 0:
            break
        off += 12
        for _ in range(cnt):
            (alg,) = struct.unpack_from("<H", b, off)
            off += 2 + ALGS[alg]
        (esz,) = struct.unpack_from("<I", b, off)
        data = b[off + 4: off + 4 + esz]
        off += 4 + esz
        if et == 0x80000006:
            return data
    sys.exit("no GPT event found in " + path)

HDR = [("signature", 8), ("revision", 4), ("header_size", 4), ("header_crc32", 4), ("reserved", 4),
       ("my_lba", 8), ("alternate_lba", 8), ("first_usable_lba", 8), ("last_usable_lba", 8),
       ("disk_guid", 16), ("entries_lba", 8), ("num_entries", 4), ("entry_size", 4), ("entries_crc32", 4)]
ENT = [("type_guid", 16), ("unique_guid", 16), ("first_lba", 8), ("last_lba", 8), ("attributes", 8), ("name", 72)]

def fields(buf, spec, base=0):
    out, o = {}, base
    for name, n in spec:
        out[name] = buf[o:o + n]
        o += n
    return out

A, B = gpt_data(sys.argv[1]), gpt_data(sys.argv[2])
ha, hb = fields(A, HDR), fields(B, HDR)
print("GPT header fields:")
for k, _ in HDR:
    print("  %-17s %s" % (k, "same" if ha[k] == hb[k] else "DIFFERENT  A=%s  B=%s" % (ha[k].hex(), hb[k].hex())))
na, nb = struct.unpack_from("<Q", A, 92)[0], struct.unpack_from("<Q", B, 92)[0]
print("partitions in event: A=%d B=%d" % (na, nb))
for i in range(min(na, nb)):
    ea, eb = fields(A, ENT, 100 + i * 128), fields(B, ENT, 100 + i * 128)
    diff = [k for k, _ in ENT if ea[k] != eb[k]]
    print("  partition %d: %s" % (i + 1, "same" if not diff else "DIFFERENT in " + ", ".join(diff)))
