#!/usr/bin/env python3
# Compare two TDX boot event logs (CCEL) event by event.
# Usage: ccel_diff.py <ccel-A.bin> <ccel-B.bin>
import struct, sys

ALGS = {0x0004: 20, 0x000B: 32, 0x000C: 48, 0x000D: 64}
TYPES = {0x0: "PREBOOT_CERT", 0x1: "POST_CODE", 0x4: "SEPARATOR", 0x5: "ACTION",
         0x7: "S_CRTM_CONTENTS", 0x8: "S_CRTM_VERSION", 0xA: "PLATFORM_CONFIG_FLAGS",
         0xD: "IPL", 0x80000001: "EFI_VARIABLE_DRIVER_CONFIG", 0x80000002: "EFI_VARIABLE_BOOT",
         0x80000003: "EFI_BOOT_SERVICES_APPLICATION", 0x80000004: "EFI_BOOT_SERVICES_DRIVER",
         0x80000006: "EFI_GPT_EVENT", 0x80000007: "EFI_ACTION",
         0x80000008: "EFI_PLATFORM_FIRMWARE_BLOB", 0x80000009: "EFI_HANDOFF_TABLES",
         0x800000E0: "EFI_VARIABLE_AUTHORITY"}

def events(path):
    b = open(path, "rb").read()
    (size,) = struct.unpack_from("<I", b, 28)
    off, out = 32 + size, []
    while off + 12 <= len(b):
        idx, et, cnt = struct.unpack_from("<III", b, off)
        if idx == 0xFFFFFFFF or cnt == 0:
            break
        off += 12
        d = None
        for _ in range(cnt):
            (alg,) = struct.unpack_from("<H", b, off)
            off += 2
            if alg == 0x000C:
                d = b[off:off + 48]
            off += ALGS[alg]
        (esz,) = struct.unpack_from("<I", b, off)
        data = b[off + 4: off + 4 + esz]
        off += 4 + esz
        out.append((idx, et, d, data))
    return out

def text(data):
    t = data[:160]
    s = t.decode("utf-16-le", "ignore") if t[1:2] == b"\0" else t.decode("latin-1")
    s = "".join(c if 32 <= ord(c) < 127 else "." for c in s)
    return s[:70]

A, B = events(sys.argv[1]), events(sys.argv[2])
print("events:", len(A), "vs", len(B))
diff = 0
for i in range(min(len(A), len(B))):
    a, b = A[i], B[i]
    if a[0] != b[0] or a[1] != b[1] or a[2] != b[2]:
        diff += 1
        print("#%d log index %d type %s" % (i + 1, a[0], TYPES.get(a[1], hex(a[1]))))
        print("   A", a[2].hex()[:12] if a[2] else None, text(a[3]))
        print("   B", b[2].hex()[:12] if b[2] else None, text(b[3]))
print("differing events:", diff)
