#!/usr/bin/env python3
"""Check that every status summary in the documents says what it must say (a sweep, not memory).

A status is stated in many places: the plan's summary row, the report's header and steps table, the docs index, the state page, the handoff's item. After a step closes, the expected-status
file is updated with what each place must now say, and this check is run before the documents are committed. It fails when a place still says the old thing.

Usage: python3 docs_status_check.py EXPECTED.tsv ROOT
The expected file has tab-separated lines (lines that start with # are comments):
  DOC  must     TEXT          the document contains TEXT
  DOC  mustnot  TEXT          the document does not contain TEXT (DOC may be * for every .md file under docs/)
  DOC  line     PREFIX  TEXT  a line that starts with PREFIX exists in the document and contains TEXT
"""
import glob, os, sys
if len(sys.argv) != 3:
    sys.exit(__doc__)
exp, root = sys.argv[1], sys.argv[2]
bad = 0
n = 0
def docs_of(d):
    if d == "*":
        return sorted(glob.glob(os.path.join(root, "docs", "*.md")))
    return [os.path.join(root, d)]
for raw in open(exp, encoding="utf-8").read().split("\n"):
    if not raw.strip() or raw.startswith("#"):
        continue
    f = raw.split("\t")
    if len(f) < 3:
        print("BAD-RULE  %s" % raw[:100]); bad += 1; continue
    d, kind = f[0], f[1]
    for path in docs_of(d):
        n += 1
        name = os.path.relpath(path, root)
        if not os.path.exists(path):
            print("FAIL  %s: the document is missing" % name); bad += 1; continue
        text = open(path, encoding="utf-8").read()
        if kind == "must":
            ok = f[2] in text; why = "does not say: %s" % f[2][:90]
        elif kind == "mustnot":
            ok = f[2] not in text; why = "still says: %s" % f[2][:90]
        elif kind == "line":
            lines = [l for l in text.split("\n") if l.startswith(f[2])]
            ok = bool(lines) and any(f[3] in l for l in lines) if len(f) > 3 else False
            why = ("no line starts with: %s" % f[2][:60]) if not lines else ("the line '%s...' does not contain: %s" % (f[2][:40], f[3][:70]))
        else:
            print("BAD-RULE  unknown kind %s" % kind); bad += 1; continue
        if ok:
            print("ok    %s: %s %s" % (name, kind, (f[2] if kind != "line" else f[2][:40] + " ... " + f[3])[:80]))
        else:
            print("FAIL  %s: %s" % (name, why)); bad += 1
print("%d rule(s) checked" % n)
print("DOCS-STATUS-OK" if bad == 0 else "DOCS-STATUS-FAILED (%d)" % bad)
sys.exit(0 if bad == 0 else 1)
