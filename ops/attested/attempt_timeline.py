#!/usr/bin/env python3
"""Show what the wrapper logged for one job, in time order, with the task attempts named.
Usage: attempt_timeline.py AUDIT_DIR JOB_ID      (AUDIT_DIR: the wrapper's *.tsv logs of all nodes; JOB_ID: job_<time>_<number>)"""
import collections, glob, os, re, sys
from urllib.parse import urlparse
def wp(p): return urlparse(p).path if p.startswith(("hdfs://", "file:")) else p
if len(sys.argv) != 3:
    print(__doc__); sys.exit(2)
audit, job = sys.argv[1], sys.argv[2]
num = job.replace("job_", "")
rows = []
for fn in sorted(glob.glob(os.path.join(audit, "*.tsv"))):
    for line in open(fn, encoding="utf-8", errors="replace"):
        c = line.rstrip("\n").split("\t")
        if len(c) == 7 and c[0].isdigit() and c[3] != "INIT" and (num in c[4] or num in c[5]):
            rows.append((int(c[0]), c[1].replace("tdx-lab-worker", "worker").replace("tdx-lab", "master"), c[2], c[3], wp(c[4]), wp(c[5]) if c[5] else ""))
rows.sort()
A = re.compile(r"attempt_\d+_\d+_([mr])_(\d+)_(\d+)")
def short(p):
    p = A.sub(lambda m: "<%s%s.a%s>" % (m.group(1), int(m.group(2)), m.group(3)), p)
    p = re.sub(r"/user/[^/]+/", "~/", p); p = re.sub(r"/tmp/hadoop-yarn/staging/[^/]+/\.staging/job_\d+_\d+/", "<staging>/", p)
    return p if len(p) < 105 else "..." + p[-102:]
print("wrapper lines for %s: %d" % (job, len(rows)))
t0 = rows[0][0] if rows else 0
for t, host, pid, op, p1, p2 in rows[:140]:
    print("%7.1fs %-6s %-6s %-13s %s%s" % ((t - t0) / 1000.0, host, pid, op, short(p1), ("  ->  " + short(p2)) if p2 else ""))
by = collections.defaultdict(lambda: collections.Counter())
for t, host, pid, op, p1, p2 in rows:
    for p in (p1, p2):
        m = A.search(p)
        if m: by[(m.group(1) + str(int(m.group(2))), int(m.group(3)))][op] += 1; break
print("\nper attempt (task, attempt number): operations on paths that carry the attempt id")
for k in sorted(by): print("  %s attempt %d: %s" % (k[0], k[1], dict(by[k])))
atts = collections.defaultdict(set); renamed = collections.defaultdict(set); deleted = collections.defaultdict(set)
for t, host, pid, op, p1, p2 in rows:
    m = A.search(p1)
    if not m: continue
    key = (m.group(1) + str(int(m.group(2)))); n = int(m.group(3)); atts[key].add(n)
    if op == "RENAME" and not A.search(p2): renamed[key].add(n)
    if op == "DELETE" and A.search(p1) and re.search(r"attempt_\d+_\d+_[mr]_\d+_\d+/?$", p1): deleted[key].add(n)
print("per task: attempts seen; the attempt whose files were renamed to the final folder; attempts whose folder was deleted")
for k in sorted(atts): print("  %s: attempts %s; committed by %s; folder deleted for %s" % (k, sorted(atts[k]), sorted(renamed[k]) or "none", sorted(deleted[k]) or "none"))
