#!/usr/bin/env python3
"""Milestone 4, baby step 4.8.3: the numbers of the timing pair (ADR-028), read from a run's own files. Read-only.

Usage: m483_metrics.py RUNDIR [RUNDIR ...]
One RUNDIR (the folder that m481r-run.sh or m483-control.sh wrote, for example ~/run12) prints its numbers; several print a
table with one column per run and, for the wall time, the ratio of each run to the first.

What is read, and from where:
  wall time            summary.txt, the line "the crawl finished, exit code N, S s" (the crawl command only, as in every earlier run)
  jobs                 crawl.log, the count of "completed successfully" lines (Hadoop's own message at the end of each job)
  counters             crawl.log, Hadoop's job counters: "<SCHEME>: Number of bytes read=N" and "... written=N", summed over all jobs,
                       and the Nutch fetcher counter bytes_downloaded=N (if the job printed it)
  bytes stored         before.tsv and after.tsv (listings of all of HDFS made by audit.sh): the files that are new in after.tsv,
                       their count and total size; of these, the .warc.gz files; and, in a wrapped run, the record files
  A value that is not found is printed as "not found", never as 0.
"""
import os, re, sys

def read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return None

def listing(p):
    rows = {}
    t = read(p)
    if t is None:
        return None
    for l in t.splitlines():
        f = l.split("\t")
        if len(f) >= 4 and f[0] == "-" and f[1].isdigit():
            rows[f[3]] = int(f[1])
    return rows

def metrics(d):
    m = {}
    s = read(os.path.join(d, "summary.txt")) or ""
    mm = re.search(r"m4(?:81r-run|83-control): \S+ on (\S+)\s+run=(\S+) mode=(\S+)", s)
    m["run"], m["mode"] = (mm.group(2), mm.group(3)) if mm else (os.path.basename(d.rstrip("/")), "not found")
    w = re.search(r"the crawl finished, exit code 0, (\d+) s", s)
    m["wall_s"] = int(w.group(1)) if w else None
    m["kind"] = "unwrapped control" if "m483-control:" in s else ("wrapped" if "m481r-run:" in s else "not found")
    c = read(os.path.join(d, "crawl.log"))
    if c is None:
        m.update(jobs=None, counters={}, downloaded=None)
    else:
        m["jobs"] = len(re.findall(r"completed successfully", c))
        ctr = {}
        for sch, kind, n in re.findall(r"^\s*([A-Za-z][A-Za-z0-9_ ]*): Number of bytes (read|written)=(\d+)", c, re.M):
            ctr[(sch.strip(), kind)] = ctr.get((sch.strip(), kind), 0) + int(n)
        m["counters"] = ctr
        dl = re.findall(r"bytes[_ ]downloaded\s*=\s*(\d+)", c, re.I)
        m["downloaded"] = sum(int(x) for x in dl) if dl else None
    b, a = listing(os.path.join(d, "before.tsv")), listing(os.path.join(d, "after.tsv"))
    if b is None or a is None:
        m.update(new_files=None, new_bytes=None, warc_files=None, warc_bytes=None, rec_files=None, rec_bytes=None)
    else:
        new = {p: n for p, n in a.items() if p not in b}
        m["new_files"], m["new_bytes"] = len(new), sum(new.values())
        warc = {p: n for p, n in new.items() if p.endswith(".warc.gz")}
        m["warc_files"], m["warc_bytes"] = len(warc), sum(warc.values())
        rec = {p: n for p, n in new.items() if re.search(r"(^|/)\..+\.attested$", p)}   # the wrapper's record file: .NAME.attested next to each file
        m["rec_files"], m["rec_bytes"] = len(rec), sum(rec.values())
    return m

def fmt(v):
    return "not found" if v is None else str(v)

def main(dirs):
    ms = [metrics(d) for d in dirs]
    schemes = sorted({k for m in ms for k in m["counters"]})
    rows = [("run", [m["run"] for m in ms]), ("kind", [m["kind"] for m in ms]), ("receipts mode", [m["mode"] for m in ms]),
            ("wall time of the crawl (s)", [fmt(m["wall_s"]) for m in ms]), ("jobs completed", [fmt(m["jobs"]) for m in ms]),
            ("fetcher bytes_downloaded", [fmt(m["downloaded"]) for m in ms])]
    for k in schemes:
        rows.append(("%s bytes %s (job counters)" % k, [fmt(m["counters"].get(k)) for m in ms]))
    if not schemes:
        rows.append(("job counters (bytes read/written)", ["not found"] * len(ms)))
    rows += [("new files in HDFS", [fmt(m["new_files"]) for m in ms]), ("bytes stored (new files)", [fmt(m["new_bytes"]) for m in ms]),
             ("  of which WARC files", [fmt(m["warc_files"]) for m in ms]), ("  of which WARC bytes", [fmt(m["warc_bytes"]) for m in ms]),
             ("  of which record files", [fmt(m["rec_files"]) for m in ms]), ("  of which record bytes", [fmt(m["rec_bytes"]) for m in ms])]
    if len(ms) > 1 and ms[0]["wall_s"]:
        rows.append(("wall time relative to the first run", ["%.3f" % (m["wall_s"] / ms[0]["wall_s"]) if m["wall_s"] else "not found" for m in ms]))
    w = max(len(r[0]) for r in rows)
    for name, vals in rows:
        print("%-*s  %s" % (w, name, "  ".join("%-22s" % v for v in vals)))
    print("METRICS-DONE")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: m483_metrics.py RUNDIR [RUNDIR ...]")
    main(sys.argv[1:])
