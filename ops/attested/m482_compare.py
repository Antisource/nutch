#!/usr/bin/env python3
# Compare the 4.8.2 event logs: old chain against new chain per node, and master against worker (read-only).
# Usage: m482_compare.py <extracted-dir> <bundle-dir>
#   extracted-dir holds evidence-m482-master/ and evidence-m482-worker/ (the post bundles, unpacked)
#   bundle-dir    holds old-chain-master/ and old-chain-worker/ (copied from the nodes)
import os, sys
X, B = sys.argv[1], sys.argv[2]

def read_log(p):
    rows = []
    for l in open(p):
        l = l.rstrip("\n")
        if l:
            n, d, b, a = l.split("\t"); rows.append((n, d))
    return rows

def read_manifest(p):
    m = {}
    for l in open(p):
        l = l.rstrip("\n")
        if l.startswith("F "):
            _, mode, h, path = l.split(" ", 3); m[path] = (mode, h[:12])
        elif l.startswith("L "):
            path, _, tgt = l[2:].partition(" -> "); m[path] = ("L", tgt)
    return m

def diff(a, b, la, lb, show=6):
    only_a = sorted(set(a) - set(b)); only_b = sorted(set(b) - set(a)); chg = sorted(p for p in set(a) & set(b) if a[p] != b[p])
    print("      files: %s %d, %s %d, in both %d (changed %d, only in %s %d, only in %s %d)" % (la, len(a), lb, len(b), len(set(a) & set(b)), len(chg), la, len(only_a), lb, len(only_b)))
    for tag, lst in (("changed", chg), ("only in " + la, only_a), ("only in " + lb, only_b)):
        for p in lst[:show]: print("        %-16s %s" % (tag, p))
        if len(lst) > show: print("        %-16s ... and %d more" % (tag, len(lst) - show))

new, old = {}, {}
for r in ("master", "worker"):
    new[r] = read_log(os.path.join(X, "evidence-m482-" + r, "rtmr3-events.tsv"))
    old[r] = read_log(os.path.join(B, "old-chain-" + r, "rtmr3-events.tsv"))

print("== 1. the new chain against the old chain (before the reboot), per node")
for r in ("master", "worker"):
    print(" %s: old %d events, new %d events" % (r, len(old[r]), len(new[r])))
    od, nd = dict(old[r]), dict(new[r])
    for n in [x for x, _ in new[r]] + [x for x in od if x not in nd]:
        st = "NEW" if n not in od else ("REMOVED" if n not in nd else ("SAME" if od[n] == nd[n] else "CHANGED"))
        print("   %-22s old %-12s new %-12s %s" % (n, od.get(n, "-")[:12], nd.get(n, "-")[:12], st))
        if st == "CHANGED":
            po = os.path.join(B, "old-chain-" + r, "measured", n + ".manifest"); pn = os.path.join(X, "evidence-m482-" + r, "measured", n + ".manifest")
            if os.path.exists(po) and os.path.exists(pn): diff(read_manifest(po), read_manifest(pn), "old", "new")

print("== 2. master against worker (new chain, components both measured)")
dm, dw = dict(new["master"]), dict(new["worker"])
for n, _ in new["worker"]:
    st = "equal" if dm.get(n) == dw[n] else "DIFFERENT"
    print("   %-22s master %-12s worker %-12s %s" % (n, dm.get(n, "-")[:12], dw[n][:12], st))
    if st == "DIFFERENT":
        pm = os.path.join(X, "evidence-m482-master", "measured", n + ".manifest"); pw = os.path.join(X, "evidence-m482-worker", "measured", n + ".manifest")
        if os.path.exists(pm) and os.path.exists(pw): diff(read_manifest(pm), read_manifest(pw), "master", "worker")
print("COMPARE-DONE")
