#!/usr/bin/env python3
"""Dry run of a gate script (the PowerShell files that make the commits), without PowerShell: it reads the gate's own $zips and $table, resolves every source file
the way the gate does (stage\\<zip key>\\<src>, where the folder name is the 'kind' without its first 4 characters, 'zip:'), and compares its fingerprint with the one in the row.
It also checks the row format, the number of modified files that the gate announces, and that each row's base is '-' or a git blob id.
Usage: python3 gate_dryrun.py GATE.ps1 [FOLDER_WITH_THE_ZIPS]   (default folder: the folder of the gate)"""
import hashlib, os, re, shutil, sys, tempfile, zipfile
gate = sys.argv[1]; zdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(gate))
t = open(gate, encoding="utf-8").read()
def block(name):
    a = t.index("$%s = @(" % name); b = t.index("\n  )", a)
    return re.findall(r'"([^"]*\|[^"]*)"', t[a:b])
zips = [z.split("|") for z in block("zips")]; table = [r.split("|") for r in block("table")]
labels = re.search(r'foreach \(\$c in @\(([^)]*)\)\)', t).group(1).replace('"', "").split(",")
stage = tempfile.mkdtemp(); bad = []
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
for key, fn, want in zips:
    p = os.path.join(zdir, fn)
    if not os.path.exists(p): bad.append("zip %s is missing in %s" % (fn, zdir)); continue
    if sha(p) != want: bad.append("zip %s is not the fingerprint in the gate (%s)" % (fn, want[:8])); continue
    zipfile.ZipFile(p).extractall(os.path.join(stage, key))
keys = {z[0] for z in zips}
for r in table:
    if len(r) != 6: bad.append("row with %d fields: %s" % (len(r), r[:3])); continue
    label, kind, src, dst, want, base = r
    if not (base == "-" or re.fullmatch(r"[0-9a-f]{40}", base)): bad.append("%s %s: base is neither - nor a blob id" % (label, dst))
    if kind != "ev" and not kind.startswith("zip:"): bad.append("%s %s: kind '%s' does not start with zip: (the gate drops its first 4 characters)" % (label, dst, kind))
    folder = kind[4:]   # exactly the gate's $it.kind.Substring(4)
    if kind != "ev" and folder not in keys: bad.append("%s %s: the gate would look in the folder '%s', but the zips are unpacked as %s" % (label, dst, folder, sorted(keys)))
    path = os.path.join(stage, folder, *src.split("/"))
    if not os.path.exists(path): bad.append("%s %s: source %s does not exist" % (label, dst, os.path.join(folder, src))); continue
    if sha(path) != want: bad.append("%s %s: the source's fingerprint differs from the row" % (label, dst))
announced = re.search(r"the (\d+) modified files?", t)
mod = sum(1 for r in table if len(r) == 6 and r[5] != "-")
if announced and int(announced.group(1)) != mod: bad.append("the gate announces %s modified file(s) but its rows have %d" % (announced.group(1), mod))
unused = [l for l in labels if not any(r[0] == l for r in table)]
if unused: bad.append("labels without rows: %s" % unused)
shutil.rmtree(stage, ignore_errors=True)
print("%s: %d zip(s), %d row(s), commits %s, %d modified" % (os.path.basename(gate), len(zips), len(table), ",".join(labels), mod))
if bad:
    for b in bad: print("  PROBLEM:", b)
    print("GATE-DRYRUN: FAIL"); sys.exit(1)
print("GATE-DRYRUN: PASS (every source file exists where the gate looks for it and has the fingerprint of its row)")
