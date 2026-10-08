#!/usr/bin/env python3
"""Compare the NameNode's audit log with the wrapper's own audit log (Milestone 4, baby step 4.5.2).

Every request to HDFS passes through the NameNode, so its audit log shows what happened to a path
whoever did it. The wrapper's log shows only what went through the wrapper. A read of a data file, or
a change to any file, that the NameNode saw and the wrapper did not log was made behind the
wrapper's back: by a program that does not use the wrapper, or by a plain command.

The NameNode's lines carry the same user and address for every client on a machine, so the match is
by operation, path and time: a NameNode event is explained when the wrapper logged the same kind of
operation on the same path within --window-ms (default 3000 ms) of it, and each wrapper line explains
at most one NameNode event.

What is compared:
  open     of a data file (the wrapper's own reads of its record files are not logged and are skipped)
  create, append, truncate, concat, delete, rename, mkdirs, and the set... calls (SETATTR)
Everything else the NameNode logs (getfileinfo, listStatus, safemode_get, ...) is only counted.

Limits, stated plainly: a file larger than ten blocks makes the HDFS client ask the NameNode again
while it reads, and those later requests show as unexplained reads; and the clocks of the machines
must agree to within --window-ms, or a wrapper line and its NameNode event do not meet. A plain read
made right after a wrapped read of the same file is still found, because each wrapper line explains
one NameNode event only.

Usage:
  nn_audit_compare.py --nn NNLOG [--nn NNLOG ...] --wrapper DIR_OR_FILE [--wrapper ...]
      [--from 'YYYY-MM-DD HH:MM:SS'] [--to 'YYYY-MM-DD HH:MM:SS'] [--window-ms 3000]
      [--known LABEL:REGEX ...] [--tsv OUT.tsv] [--show 40]
Times are UTC (the NameNode's log is in the machine's time zone; the machines here run on UTC).
--known gives a label to unexplained events whose path matches a regular expression (for example
the NodeManager's reads of the job file until the wrapper is on Hadoop's classpath); they are listed
and counted separately and do not fail the comparison.
Exit code: 0 when nothing is unexplained, 1 when something is, 2 on bad input.
"""
import calendar
import glob
import os
import re
import sys
import time
from collections import Counter, defaultdict
from urllib.parse import urlparse

SET_CMDS = {"setPermission", "setOwner", "setReplication", "setTimes", "setStoragePolicy",
            "setXAttr", "removeXAttr", "setAcl", "removeAcl", "modifyAclEntries", "removeAclEntries",
            "removeDefaultAcl", "setQuota"}
WRAPPER_CATEGORY = {"OPEN": "open", "CREATE": "create", "COPYFROMLOCAL": "create", "APPEND": "append",
                    "TRUNCATE": "truncate", "CONCAT": "concat", "DELETE": "delete", "RENAME": "rename",
                    "MKDIRS": "mkdirs", "SETATTR": "setattr"}


def die(msg):
    sys.stderr.write("nn_audit_compare: %s\n" % msg)
    sys.exit(2)


def is_record(path):
    n = path.rsplit("/", 1)[-1]
    return len(n) > len(".attested") + 1 and n.startswith(".") and n.endswith(".attested")


def to_ms(stamp, ms):
    return calendar.timegm(time.strptime(stamp, "%Y-%m-%d %H:%M:%S")) * 1000 + int(ms)


def category(cmd):
    if cmd == "open":
        return "open"
    if cmd in ("create", "append", "truncate", "concat", "delete", "mkdirs"):
        return cmd
    if cmd.startswith("rename"):
        return "rename"
    if cmd in SET_CMDS:
        return "setattr"
    return None


def parse_nn(path, counts):
    """Yield one dict per well-formed audit line of the NameNode's log."""
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        die("cannot read %s: %s" % (path, e))
    with f:
        for line in f:
            line = line.rstrip("\n")
            parts = line.split("\t")
            m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3}) \w+ [\w.$]+: allowed=(\w+)$", parts[0])
            if not m:
                counts["nn lines skipped (not an audit line)"] += 1
                continue
            kv = {}
            for p in parts[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = v
            if "cmd" not in kv:
                counts["nn lines skipped (no cmd)"] += 1
                continue
            yield {"t": to_ms(m.group(1), m.group(2)), "allowed": m.group(3) == "true",
                   "ugi": kv.get("ugi", ""), "ip": kv.get("ip", ""), "cmd": kv["cmd"],
                   "src": kv.get("src", "null"), "dst": kv.get("dst", "null")}


def wpath(p):
    if p.startswith("hdfs://") or p.startswith("file:"):
        return urlparse(p).path
    return p


def parse_wrapper(arg, counts):
    files = sorted(glob.glob(os.path.join(arg, "*.tsv"))) if os.path.isdir(arg) else [arg]
    if not files:
        die("no .tsv audit files in %s" % arg)
    for fn in files:
        try:
            f = open(fn, encoding="utf-8", errors="replace")
        except OSError as e:
            die("cannot read %s: %s" % (fn, e))
        with f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) != 7 or not c[0].isdigit():
                    counts["wrapper lines skipped (not 7 columns)"] += 1
                    continue
                cat = WRAPPER_CATEGORY.get(c[3])
                if cat is None:
                    counts["wrapper lines ignored (%s)" % c[3]] += 1
                    continue
                yield {"t": int(c[0]), "host": c[1], "op": c[3], "cat": cat, "p1": wpath(c[4]),
                       "p2": wpath(c[5]) if c[5] else "", "used": False}


def key_of_nn(e, cat):
    if cat == "rename":
        return (cat, e["src"], e["dst"])
    if cat == "concat":
        return (cat, e["dst"], "")
    return (cat, e["src"], "")


def key_of_wrapper(w):
    if w["cat"] == "rename":
        return (w["cat"], w["p1"], w["p2"])
    return (w["cat"], w["p1"], "")


def stamp_ms(s):
    try:
        return to_ms(s, "000")
    except ValueError:
        die("bad time '%s' (use YYYY-MM-DD HH:MM:SS, UTC)" % s)


def main(argv):
    nn_files, wr_args, known, tsv = [], [], [], None
    t_from = t_to = None
    window, show = 3000, 40
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        if i + 1 >= len(argv):
            die("%s needs a value" % a)
        v = argv[i + 1]
        if a == "--nn":
            nn_files.append(v)
        elif a == "--wrapper":
            wr_args.append(v)
        elif a == "--from":
            t_from = stamp_ms(v)
        elif a == "--to":
            t_to = stamp_ms(v) + 999
        elif a == "--window-ms":
            window = int(v)
        elif a == "--known":
            if ":" not in v:
                die("--known needs LABEL:REGEX")
            label, rx = v.split(":", 1)
            known.append((label, re.compile(rx)))
        elif a == "--tsv":
            tsv = v
        elif a == "--show":
            show = int(v)
        else:
            die("unknown option %s" % a)
        i += 2
    if not nn_files or not wr_args:
        die("give at least one --nn and one --wrapper (see --help)")
    counts = Counter()
    wrapper = []
    for a in wr_args:
        wrapper.extend(parse_wrapper(a, counts))
    by_key = defaultdict(list)
    for w in wrapper:
        by_key[key_of_wrapper(w)].append(w)
    events = []
    for fn in nn_files:
        events.extend(parse_nn(fn, counts))
    events.sort(key=lambda e: e["t"])
    if t_from is not None or t_to is not None:
        events = [e for e in events if (t_from is None or e["t"] >= t_from) and (t_to is None or e["t"] <= t_to)]
        wrapper_in = [w for w in wrapper if (t_from is None or w["t"] >= t_from - window) and (t_to is None or w["t"] <= t_to + window)]
    else:
        wrapper_in = wrapper
    seen = Counter(); watched = explained = 0
    unexplained, known_hits, denied = [], defaultdict(list), []
    for e in events:
        cat = category(e["cmd"])
        seen[e["cmd"]] += 1
        if not e["allowed"]:
            denied.append(e)
        if cat is None:
            continue
        if cat == "open" and is_record(e["src"]):
            continue                      # the wrapper reads its own records; it does not log those opens
        watched += 1
        cands = [w for w in by_key.get(key_of_nn(e, cat), []) if not w["used"] and abs(w["t"] - e["t"]) <= window]
        if cands:
            best = min(cands, key=lambda w: abs(w["t"] - e["t"]))
            best["used"] = True
            explained += 1
            continue
        label = None
        for lab, rx in known:
            if rx.search(e["src"]) or (e["dst"] != "null" and rx.search(e["dst"])):
                label = lab
                break
        if label:
            known_hits[label].append(e)
        else:
            unexplained.append(e)
    wrapper_only = [w for w in wrapper_in if not w["used"]]

    def fmt(e):
        ts = time.strftime("%H:%M:%S", time.gmtime(e["t"] / 1000.0)) + ".%03d" % (e["t"] % 1000)
        path = e["src"] if e["dst"] in ("null", "") else "%s -> %s" % (e["src"], e["dst"])
        return "%s  %-9s %s   [%s %s]" % (ts, e["cmd"].split(" ")[0], path, e["ugi"].split(" ")[0], e["ip"])

    print("NN-AUDIT-COMPARE")
    print("NameNode lines read: %d   wrapper lines read: %d   window for a match: %d ms" % (sum(seen.values()), len(wrapper), window))
    for k, v in sorted(counts.items()):
        print("  %s: %d" % (k, v))
    print("NameNode events compared (open of data files and changes): %d" % watched)
    print("  explained by the wrapper's log: %d" % explained)
    print("  known, not counted: %d" % sum(len(v) for v in known_hits.values()))
    print("  UNEXPLAINED (made behind the wrapper's back): %d" % len(unexplained))
    print("other NameNode commands, counted only: " + (", ".join("%s %d" % (c, n) for c, n in sorted(seen.items()) if category(c) is None) or "none"))
    if denied:
        print("requests the NameNode DENIED: %d" % len(denied))
        for e in denied[:show]:
            print("  " + fmt(e))
    for lab, evs in sorted(known_hits.items()):
        print("known (%s): %d" % (lab, len(evs)))
        for e in evs[:min(show, 5)]:
            print("  " + fmt(e))
    if unexplained:
        print("UNEXPLAINED events:")
        for e in unexplained[:show]:
            print("  " + fmt(e))
        if len(unexplained) > show:
            print("  ... and %d more (use --show or --tsv)" % (len(unexplained) - show))
    if wrapper_only:
        print("wrapper lines the NameNode log does not show (a short or rotated log, or clocks out of step): %d" % len(wrapper_only))
        for w in wrapper_only[:min(show, 10)]:
            print("  %s %s %s" % (w["op"], w["p1"], w["p2"]))
    if tsv:
        with open(tsv, "w", encoding="utf-8") as out:
            out.write("verdict\ttime_ms\tcmd\tsrc\tdst\tugi\tip\n")
            for e in unexplained:
                out.write("unexplained\t%d\t%s\t%s\t%s\t%s\t%s\n" % (e["t"], e["cmd"], e["src"], e["dst"], e["ugi"], e["ip"]))
            for lab, evs in known_hits.items():
                for e in evs:
                    out.write("known:%s\t%d\t%s\t%s\t%s\t%s\t%s\n" % (lab, e["t"], e["cmd"], e["src"], e["dst"], e["ugi"], e["ip"]))
    if unexplained:
        print("NN-AUDIT-COMPARE-FINDINGS (%d)" % len(unexplained))
        return 1
    print("NN-AUDIT-COMPARE-CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
