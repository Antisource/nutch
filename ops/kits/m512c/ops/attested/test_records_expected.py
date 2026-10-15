#!/usr/bin/env python3
"""Tests of records_expected.py: a folder identity file (_attested-folder, step 5.1.2) is a companion of the data, like a record file."""
import os, subprocess, sys, tempfile

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "records_expected.py")
results = []


def check(name, ok):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name)


def run(listing, records, audit_lines=()):
    with tempfile.TemporaryDirectory() as root:
        after = os.path.join(root, "after.tsv"); rdir = os.path.join(root, "rec"); adir = os.path.join(root, "aud"); os.makedirs(rdir); os.makedirs(adir)
        open(after, "w").write("".join("-\t%d\t0\t%s\n" % (size, p) for p, size in listing))
        open(os.path.join(rdir, "r.tsv"), "w").write("".join("\t".join(["1000", "h", "1", "J", "A", p, str(n), "root", "leaf", "chunk", "closed"]) + "\n" for p, n in records))
        open(os.path.join(adir, "a.tsv"), "w").write("".join(audit_lines))
        p = subprocess.run([sys.executable, TOOL, after, rdir, adir, "--cover", "^/c/crawl", "--require-sidecars", "--out", os.path.join(root, "e.tsv")], capture_output=True, text=True)
        return p.returncode, p.stdout


base = [("/c/crawl/a", 100), ("/c/crawl/.a.attested", 300)]
rc, out = run(base, [("/c/crawl/a", 100)])
check("control: a file with its record and its record file is complete", rc == 0 and "RECORDS-COMPLETE" in out and "files judged: 1" in out)
rc, out = run(base + [("/c/crawl/_attested-folder", 250)], [("/c/crawl/a", 100)])
check("a folder identity file in the listing is not judged as data (no record, no record file needed for it)", rc == 0 and "RECORDS-COMPLETE" in out and "files judged: 1" in out)
rc, out = run(base + [("/c/crawl/seg/_attested-folder", 250), ("/c/crawl/seg/.b.attested", 300), ("/c/crawl/seg/b", 50)], [("/c/crawl/a", 100), ("/c/crawl/seg/b", 50)])
check("identity files in several folders of the tree are all companions", rc == 0 and "RECORDS-COMPLETE" in out and "files judged: 2" in out)
rc, out = run(base + [("/c/crawl/other", 7)], [("/c/crawl/a", 100)])
check("negative control: a data file with no record is still found", rc == 1 and "NO-RECORD  /c/crawl/other" in out and "RECORDS-GAPS" in out)
rc, out = run(base + [("/c/crawl/x", 7), ("/c/crawl/.x.attested", 300)], [("/c/crawl/a", 100)])
check("negative control: a data file with a record file but no hashed record is still found", rc == 1 and "NO-RECORD  /c/crawl/x" in out)
rc, out = run([("/c/crawl/a", 100)], [("/c/crawl/a", 100)])
check("negative control: a data file with no record file next to it is still found", rc == 1 and "NO-SIDECAR /c/crawl/a" in out)
rc, out = run(base + [("/c/crawl/_attested-folder-copy", 250)], [("/c/crawl/a", 100)])
check("negative control: a file whose name only starts like the identity file is judged as data", rc == 1 and "NO-RECORD  /c/crawl/_attested-folder-copy" in out)
ok = sum(results)
print("%s (%d of %d checks passed)" % ("ALL-PASS" if ok == len(results) else "SOME-FAILED", ok, len(results)))
sys.exit(0 if ok == len(results) else 1)
