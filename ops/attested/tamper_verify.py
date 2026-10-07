#!/usr/bin/env python3
"""Prove from the audit logs that the wrapper itself caught the change (stage B2 tamper demo).

The tamper demo changes one byte of one stored file with the plain HDFS client and runs a
reader job through the wrapper. The job's failure shows on the client; the reason is written by
the wrapper, on the machine that ran the failing task. This tool reads the audit logs of all
machines for the demo (collected into one folder) and checks:
  1. at least one VERIFY-FAIL line for the tampered file, naming a chunk and a hash mismatch;
  2. no VERIFY-FAIL line for any other path (nothing else was refused);
  3. at least two OPEN lines of the tampered file with verify=ok (the control read and the
     read after the original bytes were put back).

Usage: tamper_verify.py AUDIT_DIR ABSOLUTE_PATH_OF_THE_TAMPERED_FILE
Exit code 0 for TAMPER-PROVEN.
"""
import glob
import os
import sys


def main(argv):
    if len(argv) != 3:
        print(__doc__); return 2
    folder, target = argv[1], argv[2]
    fails, ok_opens, files = [], 0, 0
    for fn in sorted(glob.glob(os.path.join(folder, "**", "*.tsv"), recursive=True)):
        files += 1
        with open(fn, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) != 7:
                    raise SystemExit("bad line in %s: %r" % (fn, line[:80]))
                host, op, p1, extra = c[1], c[3], c[4], c[6]
                if op == "VERIFY-FAIL":
                    fails.append((host, p1, extra))
                elif op == "OPEN" and p1 == target and "verify=ok" in extra:
                    ok_opens += 1
    on_target = [x for x in fails if x[1] == target]
    elsewhere = [x for x in fails if x[1] != target]
    named = [x for x in on_target if "chunk=" in x[2] and "does not match" in x[2]]
    print("audit log files read: %d" % files)
    print("tampered file: %s" % target)
    print("VERIFY-FAIL lines for it: %d (naming a chunk and a hash mismatch: %d)" % (len(on_target), len(named)))
    for h, p, e in on_target[:5]:
        print("  %s  %s" % (h, e))
    print("VERIFY-FAIL lines for any other path: %d" % len(elsewhere))
    for h, p, e in elsewhere[:5]:
        print("  %s  %s  %s" % (h, p, e))
    print("verified opens of the tampered file (control and restored read): %d" % ok_opens)
    problems = []
    if not named:
        problems.append("no VERIFY-FAIL for the tampered file with a chunk and a hash mismatch")
    if elsewhere:
        problems.append("a verification failure for another path")
    if ok_opens < 2:
        problems.append("fewer than two verified opens of the tampered file")
    print()
    if problems:
        for pr in problems:
            print("PROBLEM: " + pr)
        print("TAMPER-NOT-PROVEN")
        return 1
    print("TAMPER-PROVEN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
