#!/usr/bin/env python3
# Milestone 4, baby step 4.8.3: bytes fetched and pages fetched, read from the WARC files of two runs (read-only).
# Usage: m483_warcstats.py DIR_A DIR_B     each folder holds the .warc.gz files of one run (copied out of HDFS)
# For each run: the number of files, the number of "response" records (pages), the payload bytes (the HTTP body after the
# headers, summed over the response records), the distinct URLs. Then: are the URL sets the same, and for the URLs in both,
# how many payloads are byte-identical (SHA-256). A WARC file that cannot be read is reported, never skipped silently.
import glob, hashlib, os, sys, zlib

def records(path):
    data = open(path, "rb").read(); pos = 0
    while pos < len(data):
        d = zlib.decompressobj(31); buf = d.decompress(data[pos:]); pos = len(data) - len(d.unused_data)
        i = buf.find(b"\r\n\r\n")
        if i < 0: raise ValueError("no header end in a record")
        h = dict(l.split(": ", 1) for l in buf[:i].decode("utf-8", "replace").split("\r\n")[1:] if ": " in l)
        n = int(h.get("Content-Length", len(buf) - i - 4)); yield h, buf[i + 4:i + 4 + n]

def run(d):
    files = sorted(glob.glob(os.path.join(d, "*.warc.gz"))); pages = {}; bad = []; types = {}
    for f in files:
        try:
            for h, body in records(f):
                t = h.get("WARC-Type"); types[t] = types.get(t, 0) + 1
                if t == "response":
                    j = body.find(b"\r\n\r\n"); payload = body[j + 4:] if j >= 0 else b""
                    pages.setdefault(h.get("WARC-Target-URI"), []).append((len(payload), hashlib.sha256(payload).hexdigest()))
        except Exception as e:
            bad.append("%s: %s" % (os.path.basename(f), e))
    return files, types, pages, bad

res = [run(d) for d in sys.argv[1:3]]
for d, (files, types, pages, bad) in zip(sys.argv[1:3], res):
    n = sum(len(v) for v in pages.values()); b = sum(x[0] for v in pages.values() for x in v)
    print("%-28s WARC files %d, records %s" % (os.path.basename(d.rstrip("/")), len(files), dict(sorted((k or "?", v) for k, v in types.items()))))
    print("%-28s response records (pages) %d, distinct URLs %d, payload bytes %d" % ("", n, len(pages), b))
    for x in bad: print("   UNREADABLE: " + x)
a, b = res[0][2], res[1][2]
print("same URL set: %s   (only in the first run: %d, only in the second: %d)" % ("YES" if set(a) == set(b) else "NO", len(set(a) - set(b)), len(set(b) - set(a))))
for u in sorted(set(a) - set(b))[:8]: print("   only in the first:  " + str(u))
for u in sorted(set(b) - set(a))[:8]: print("   only in the second: " + str(u))
both = sorted(set(a) & set(b)); same = [u for u in both if sorted(set(x[1] for x in a[u])) == sorted(set(x[1] for x in b[u]))]
print("URLs in both runs: %d, byte-identical payloads: %d" % (len(both), len(same)))
for u in [u for u in both if u not in same][:8]: print("   payload differs: %s  (%s vs %s bytes)" % (u, [x[0] for x in a[u]], [x[0] for x in b[u]]))
print("WARCSTATS-DONE" if not any(r[3] for r in res) else "WARCSTATS-DONE-WITH-UNREADABLE-FILES")
