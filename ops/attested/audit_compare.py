#!/usr/bin/env python3
"""Compare a listing of all HDFS before and after a crawl with the wrapper's logs.

With the wrapper behind hdfs:// the paths no longer show whether it was used, so
this audit is the proof. Every change that appears in storage between the two
listings (a path added, a path removed, a file whose size or modification time
changed) must be explained by a line in the wrapper's logs. A change with no
matching log line was made by something that did not go through the wrapper.

Usage:
  audit_compare.py BEFORE.tsv AFTER.tsv LOGDIR [--allow REGEX ...] [--require-hosts H1,H2]

BEFORE.tsv / AFTER.tsv  one line per path: type (d or -), size, modified, path
LOGDIR                  folder with the *.tsv logs of all JVMs, from all machines
--allow REGEX           paths of known actors that do not use the wrapper (for
                        example the history server). They are still listed, but
                        do not fail the audit. Use sparingly and say why.
--require-hosts         host names (the exact name, or the name followed by a dot,
                        so "tdx-lab" does not match "tdx-lab-worker") that must each
                        have written an INIT line, to show the wrapper ran on every
                        machine

Exit code 0 for AUDIT-CLEAN, 1 for AUDIT-GAPS.
Limits: reads are not audited (they change nothing); a change that leaves size
and modification time unchanged is not seen.
"""
import glob
import os
import re
import sys
from collections import Counter


def parse_listing(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            kind, size, mtime, p = line.split("\t", 3)
            out[p] = (kind, int(size), mtime)
    return out


def parse_logs(folder):
    events, files = [], []
    for fn in sorted(glob.glob(os.path.join(folder, "**", "*.tsv"), recursive=True)):
        files.append(fn)
        with open(fn, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) != 7:
                    raise SystemExit("bad log line in %s: %r" % (fn, line[:80]))
                events.append(dict(ts=int(c[0]), host=c[1], pid=c[2], op=c[3],
                                   p1=c[4], p2=c[5], extra=c[6], file=fn))
    return events, files


def ancestors(p):
    parts = p.strip("/").split("/")
    return ["/" + "/".join(parts[:i]) for i in range(1, len(parts))]


def under(p, prefix):
    return p == prefix or p.startswith(prefix.rstrip("/") + "/")


def build_rules(events):
    created, setattr_, dir_parents = set(), set(), set()
    rename_dst, rename_src, deleted, concat_src = [], [], [], set()
    renames = sorted((e["ts"], e["p1"], e["p2"]) for e in events if e["op"] == "RENAME")
    for e in events:
        op, p1, p2 = e["op"], e["p1"], e["p2"]
        if op in ("CREATE", "APPEND", "TRUNCATE", "COPYFROMLOCAL", "CONCAT", "MKDIRS"):
            created.add(p1)
            dir_parents.update(ancestors(p1))
            if op == "CONCAT" and e["extra"].startswith("srcs="):
                concat_src.update(x for x in e["extra"][5:].split(",") if x)
        elif op == "RENAME":
            rename_src.append(p1)
            rename_dst.append(p2)
            created.add(p2)
            dir_parents.update(ancestors(p2))
        elif op == "DELETE":
            deleted.append((p1, "recursive=true" in e["extra"]))
        elif op == "SETATTR":
            setattr_.add(p1)
    return dict(created=created, setattr=setattr_, dir_parents=dir_parents,
                rename_dst=rename_dst, rename_src=rename_src, deleted=deleted,
                concat_src=concat_src, renames=renames)


def forward(p, r):
    """The names a path had after each rename in the log, in time order."""
    hops = [p]
    for _ts, src, dst in r["renames"]:
        if under(hops[-1], src):
            hops.append(dst + hops[-1][len(src):])
    return hops


def backward(p, r):
    """The names a path had before each rename in the log, latest rename first."""
    hops = [p]
    for _ts, src, dst in reversed(r["renames"]):
        if under(hops[-1], dst):
            hops.append(src + hops[-1][len(dst):])
    return hops


def explained_added(p, kind, size, r, before):
    """Returns (explained, note)."""
    if p in r["created"] or (kind == "d" and p in r["dir_parents"]):
        return True, ""
    note = ""
    for h in backward(p, r)[1:]:
        if h in r["created"] or (kind == "d" and h in r["dir_parents"]):
            return True, ""          # created in this window, then moved
        b = before.get(h)
        if b is not None and b[0] == kind:
            if kind == "d" or b[1] == size:
                return True, ""      # an existing path, moved with the same size
            note = " (moved from %s but its size changed %d -> %d)" % (h, b[1], size)
    return False, note


def explained_removed(p, r, after):
    if p in r["concat_src"]:
        return True
    for h in forward(p, r):
        if h in after:               # it was moved, and it is still there
            return True
        if any(h == d or (rec and under(h, d)) for d, rec in r["deleted"]):
            return True
    return False


def explained_changed(p, r):
    return p in r["created"] or p in r["setattr"]


def main(argv):
    allow, require_hosts, pos = [], [], []
    i = 1
    while i < len(argv):
        if argv[i] == "--allow":
            allow.append(re.compile(argv[i + 1])); i += 2
        elif argv[i] == "--require-hosts":
            require_hosts = [h for h in argv[i + 1].split(",") if h]; i += 2
        else:
            pos.append(argv[i]); i += 1
    if len(pos) != 3:
        print(__doc__); return 2
    before, after = parse_listing(pos[0]), parse_listing(pos[1])
    events, files = parse_logs(pos[2])
    rules = build_rules(events)

    added = sorted(p for p in after if p not in before)
    removed = sorted(p for p in before if p not in after)
    changed = sorted(p for p in after if p in before and after[p][0] == "-"
                     and before[p][0] == "-" and (after[p][1] != before[p][1] or after[p][2] != before[p][2]))

    unexplained = []
    n_expl = Counter()
    for p in added:
        ok, note = explained_added(p, after[p][0], after[p][1], rules, before)
        if ok: n_expl["added"] += 1
        else: unexplained.append(("added", p + note))
    for p in removed:
        if explained_removed(p, rules, after): n_expl["removed"] += 1
        else: unexplained.append(("removed", p))
    for p in changed:
        if explained_changed(p, rules): n_expl["changed"] += 1
        else: unexplained.append(("changed", p))

    allowed = [(k, p) for k, p in unexplained if any(rx.search(p) for rx in allow)]
    gaps = [(k, p) for k, p in unexplained if (k, p) not in allowed]

    inits = [e for e in events if e["op"] == "INIT"]
    hosts = sorted({e["host"] for e in inits})
    ops = Counter(e["op"] for e in events)
    print("== the wrapper's logs")
    print("log files (one per JVM): %d   lines: %d   INIT lines: %d" % (len(files), len(events), len(inits)))
    print("hosts that reported the wrapper: %s" % (", ".join(hosts) or "none"))
    print("operations: " + ", ".join("%s=%d" % kv for kv in sorted(ops.items())))
    print("== storage before and after")
    print("paths before: %d   after: %d" % (len(before), len(after)))
    print("changes: added %d, removed %d, changed %d" % (len(added), len(removed), len(changed)))
    print("explained by the log: added %d, removed %d, changed %d" % (n_expl["added"], n_expl["removed"], n_expl["changed"]))
    if allowed:
        print("== allow-listed (not through the wrapper, accepted): %d" % len(allowed))
        for k, p in allowed[:40]: print("  %-8s %s" % (k, p))
    problems = []
    if not inits:
        problems.append("no JVM reported using the wrapper (no INIT line in any log)")
    for h in require_hosts:
        if not any(x == h or x.startswith(h + ".") for x in hosts):
            problems.append("no INIT line from host %s" % h)
    if gaps:
        problems.append("%d change(s) in storage have no matching log line" % len(gaps))
        print("== UNEXPLAINED changes (made without the wrapper, or the log has a gap): %d" % len(gaps))
        for k, p in gaps[:60]: print("  %-8s %s" % (k, p))
        if len(gaps) > 60: print("  ... and %d more" % (len(gaps) - 60))
    print()
    if problems:
        for pr in problems: print("PROBLEM: " + pr)
        print("AUDIT-GAPS")
        return 1
    print("AUDIT-CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
