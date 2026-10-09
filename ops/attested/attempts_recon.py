#!/usr/bin/env python3
"""Read-only recon for step 4.7: how task attempts appear in the wrapper's logs.
Usage: attempts_recon.py AUDIT_DIR      (a folder with the wrapper's *.tsv logs, columns: ms, host, pid, op, path, path2, detail)"""
import collections, glob, os, re, sys
from urllib.parse import urlparse
def wp(p): return urlparse(p).path if p.startswith(("hdfs://", "file:")) else p
rows = []
for fn in sorted(glob.glob(os.path.join(sys.argv[1], "*.tsv"))):
    for line in open(fn, encoding="utf-8", errors="replace"):
        c = line.rstrip("\n").split("\t")
        if len(c) == 7 and c[0].isdigit(): rows.append((int(c[0]), c[1], c[2], c[3], wp(c[4]), wp(c[5]) if c[5] else ""))
A = re.compile(r"attempt_(\d+_\d+)_([mr])_(\d+)_(\d+)")
ops = collections.Counter(r[3] for r in rows); print("wrapper lines: %d  operations: %s" % (len(rows), dict(ops)))
ren = [r for r in rows if r[3] == "RENAME"]
src_attempt = [r for r in ren if A.search(r[4])]
src_temp = [r for r in ren if "/_temporary/" in r[4] or r[4].endswith("/_temporary")]
print("RENAME lines: %d; with an attempt id in the source: %d; with _temporary in the source: %d" % (len(ren), len(src_attempt), len(src_temp)))
shape = collections.Counter(re.sub(r"\d{5,}", "N", re.sub(r"attempt_[0-9_]+[mr]_[0-9_]+", "attempt_X", r[4])) + "  ->  " + re.sub(r"\d{5,}", "N", re.sub(r"attempt_[0-9_]+[mr]_[0-9_]+", "attempt_X", r[5])) for r in src_attempt)
print("the rename shapes with an attempt source (count, shape):")
for s, n in shape.most_common(5): print("  %4d  %s" % (n, s[:170]))
cr = [r for r in rows if r[3] == "CREATE" and A.search(r[4])]
print("CREATE lines inside an attempt's folder: %d" % len(cr))
atts = collections.defaultdict(set)
for r in rows:
    for p in (r[4], r[5]):
        m = A.search(p)
        if m: atts[(m.group(1), m.group(2), m.group(3))].add(int(m.group(4)))
nums = collections.Counter(max(v) for v in atts.values())
print("tasks seen: %d; highest attempt number per task (number, tasks): %s" % (len(atts), dict(sorted(nums.items()))))
multi = [k for k, v in atts.items() if len(v) > 1]
print("tasks with more than one attempt (retry or speculative copy): %d" % len(multi))
succ = [r for r in rows if r[3] == "CREATE" and r[4].endswith("/_SUCCESS")]
print("_SUCCESS files created: %d" % len(succ))
dels = [r for r in rows if r[3] == "DELETE" and r[4].endswith("/_temporary")]
print("_temporary folders deleted: %d" % len(dels))
