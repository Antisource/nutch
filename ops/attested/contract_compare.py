#!/usr/bin/env python3
"""Compare Hadoop's contract tests run against plain HDFS and through the wrapper.

The same tests ran twice on the same cluster (ContractRunner writes one line per test:
mode, class, method, outcome, message). A test that passes on plain HDFS and fails through the
wrapper is a real difference. A test that fails on plain HDFS too is explained by the cluster
or the options, not by the wrapper.

A difference can be listed in advance, with its reason, in contract/expected-differences.tsv (next to this
script): class, method, a phrase that must appear in the wrapper's failure message, and why. Such a difference is
reported as EXPECTED-DIFFERENCE and does not fail the comparison. If the failure message does not contain the
phrase, it is a different failure and counts as a real difference.

Usage: contract_compare.py RESULTS-PLAIN.tsv RESULTS-WRAPPED.tsv [EXPECTED.tsv | --no-expected]
Exit code 0 when no test passes on plain HDFS and fails or goes missing through the wrapper, apart from the
expected differences.
"""
import os
import sys
from collections import OrderedDict, defaultdict


def load(path):
    res = OrderedDict()
    with open(path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 4:
                raise SystemExit("bad line in %s: %r" % (path, line[:80]))
            res[(c[1], c[2])] = (c[3], c[4] if len(c) > 4 else "")
    return res


def load_expected(path):
    exp = {}
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                c = line.rstrip("\n").split("\t")
                if len(c) < 4:
                    raise SystemExit("bad line in %s: %r" % (path, line[:80]))
                exp[(c[0], c[1])] = (c[2], c[3])
    return exp


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__); return 2
    plain, wrapped = load(argv[1]), load(argv[2])
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "contract", "expected-differences.tsv")
    expected = {} if (len(argv) == 4 and argv[3] == "--no-expected") else load_expected(argv[3] if len(argv) == 4 else default)
    keys = list(OrderedDict.fromkeys(list(plain) + list(wrapped)))
    per = defaultdict(lambda: [0, 0, 0, 0, 0, 0])   # plain pass/fail/skip, wrapped pass/fail/skip
    diffs, both_fail, better, missing, explained = [], [], [], [], []
    for k in keys:
        p, w = plain.get(k), wrapped.get(k)
        row = per[k[0]]
        for off, v in ((0, p), (3, w)):
            if v is None:
                continue
            o = v[0]
            row[off + (0 if o == "PASS" else 1 if o == "FAIL" else 2)] += 1
        if p is None or w is None:
            missing.append((k, "plain" if p is None else "wrapped"))
        elif p[0] == "PASS" and w[0] == "FAIL":
            if k in expected and expected[k][0] in w[1]:
                explained.append((k, expected[k][1]))
            else:
                diffs.append((k, w[1]))
        elif p[0] == "FAIL" and w[0] == "FAIL":
            both_fail.append((k, p[1], w[1]))
        elif p[0] == "FAIL" and w[0] == "PASS":
            better.append((k, p[1]))
        elif p[0] == "PASS" and w[0] in ("SKIP", "IGNORED"):
            diffs.append((k, "skipped through the wrapper: " + w[1]))
    print("%-34s %22s %22s" % ("test class", "plain pass/fail/skip", "wrapped pass/fail/skip"))
    for cls, r in per.items():
        print("%-34s %22s %22s" % (cls, "%d / %d / %d" % tuple(r[:3]), "%d / %d / %d" % tuple(r[3:])))
    tot = [sum(r[i] for r in per.values()) for i in range(6)]
    print("%-34s %22s %22s" % ("TOTAL", "%d / %d / %d" % tuple(tot[:3]), "%d / %d / %d" % tuple(tot[3:])))
    print()
    print("tests that pass on plain HDFS but fail (or are skipped) through the wrapper: %d" % len(diffs))
    for (c, m), why in diffs:
        print("  WRAPPER-DIFFERENCE  %s.%s  %s" % (c, m, why))
    print("expected differences (listed in advance, with the reason): %d" % len(explained))
    for (c, m), why in explained:
        print("  EXPECTED-DIFFERENCE  %s.%s  %s" % (c, m, why))
    seen = set(k for k, _ in explained)
    for k in expected:
        if k not in seen:
            print("  EXPECTED-DIFFERENCE-NOT-SEEN  %s.%s  (it did not fail through the wrapper this time; check the list)" % k)
    print("tests that fail on plain HDFS and through the wrapper (explained by the cluster or the options): %d" % len(both_fail))
    for (c, m), pw, ww in both_fail:
        print("  FAILS-ON-PLAIN-TOO  %s.%s  plain: %s" % (c, m, pw[:140]))
    print("tests that fail on plain HDFS but pass through the wrapper: %d" % len(better))
    for (c, m), pw in better:
        print("  PASSES-ONLY-WRAPPED %s.%s  plain: %s" % (c, m, pw[:140]))
    print("tests missing from one of the runs: %d" % len(missing))
    for (c, m), where in missing:
        print("  MISSING-IN-%s  %s.%s" % (where.upper(), c, m))
    print()
    ok = not diffs and not missing
    if ok:
        print("CONTRACT-SAME-AS-HDFS" + (" (%d explained difference%s)" % (len(explained), "" if len(explained) == 1 else "s") if explained else ""))
    else:
        print("CONTRACT-DIFFERENCES (%d)" % (len(diffs) + len(missing)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
