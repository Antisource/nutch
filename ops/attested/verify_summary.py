#!/usr/bin/env python3
"""Summarise how every read through the wrapper was verified (stage B2), from the audit logs.

Each OPEN line says how the file was checked: verify=ok (its record was found and agreed with
the file's length; every chunk read was then hashed and compared), verify=missing (no record;
the policy was "warn"), verify=skipped (no record; policy "allow"), verify=off (verification
switched off), verify=bypassed (a read path that is not verified yet). A VERIFY-FAIL line is a
read that was refused or stopped because the file or its record did not match.

Usage: verify_summary.py AUDIT_DIR [--allow-missing REGEX ...]
  --allow-missing  paths that may be read without a record (for example the seed file, which
                   the command-line client put there). Each use needs a stated reason.

Exit code 0 for VERIFY-CLEAN: no failures, and no unverified read outside the allowed paths.
"""
import glob
import os
import re
import sys
from collections import Counter, defaultdict


def main(argv):
    allow, pos, i = [], [], 1
    while i < len(argv):
        if argv[i] == "--allow-missing":
            allow.append(re.compile(argv[i + 1])); i += 2
        else:
            pos.append(argv[i]); i += 1
    if len(pos) != 1:
        print(__doc__); return 2
    opens, fails = Counter(), []
    unverified = defaultdict(Counter)
    for fn in sorted(glob.glob(os.path.join(pos[0], "**", "*.tsv"), recursive=True)):
        with open(fn, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) != 7:
                    raise SystemExit("bad line in %s: %r" % (fn, line[:80]))
                op, p1, extra = c[3], c[4], c[6]
                if op == "VERIFY-FAIL":
                    fails.append((p1, extra))
                elif op == "OPEN":
                    m = re.search(r"verify=(\w+)", extra)
                    how = m.group(1) if m else "none"
                    opens[how] += 1
                    if how in ("missing", "skipped", "bypassed", "none"):
                        unverified[how][p1] += 1
    print("opens in total: %d" % sum(opens.values()))
    for how in ("ok", "missing", "skipped", "off", "bypassed", "none"):
        if opens[how]:
            print("  verify=%-9s %d" % (how, opens[how]))
    print("verification failures: %d" % len(fails))
    for p, e in fails[:20]:
        print("  VERIFY-FAIL %s  %s" % (p, e))
    problems = []
    if fails:
        problems.append("%d read(s) failed verification" % len(fails))
    for how, paths in unverified.items():
        outside = [p for p in paths if not any(rx.search(p) for rx in allow)]
        allowed = [p for p in paths if p not in outside]
        print("read without verification, verify=%s: %d distinct paths (%d allowed)" % (how, len(paths), len(allowed)))
        for p in sorted(paths)[:30]:
            print("  %s %s  x%d" % ("allowed " if p in allowed else "OUTSIDE ", p, paths[p]))
        if outside:
            problems.append("%d path(s) read with verify=%s outside the allowed list" % (len(outside), how))
    if opens["ok"] == 0:
        problems.append("no read was verified at all (is the wrapper in use?)")
    print()
    if problems:
        for pr in problems:
            print("PROBLEM: " + pr)
        print("VERIFY-GAPS")
        return 1
    print("VERIFY-CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
