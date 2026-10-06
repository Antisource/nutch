#!/usr/bin/env python3
"""Compare two Nutch job files entry by entry.

Used to show that the job built for run 6 differs from the job of run 5 only by the
wrapper's classes. Nested jars (the plugins) are compared by what is inside them, so
a jar rebuilt with new timestamps but the same content counts as the same.

Usage: job_compare.py OLD.job NEW.job
"""
import io
import sys
import zipfile

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)
old, new = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
o = {i.filename: i.CRC for i in old.infolist()}
n = {i.filename: i.CRC for i in new.infolist()}


def inner_differs(name):
    a = zipfile.ZipFile(io.BytesIO(old.read(name)))
    b = zipfile.ZipFile(io.BytesIO(new.read(name)))
    ca = {i.filename: i.CRC for i in a.infolist()}
    cb = {i.filename: i.CRC for i in b.infolist()}
    return ca != cb


only_old = sorted(set(o) - set(n))
only_new = sorted(set(n) - set(o))
different = []
for k in sorted(set(o) & set(n)):
    if k.endswith("/") or o[k] == n[k]:
        continue
    if k.endswith(".jar"):
        if inner_differs(k):
            different.append(k + "   (a different set or content inside)")
    else:
        different.append(k)
print("entries: old %d, new %d" % (len(o), len(n)))
print("only in the OLD job:          ", only_old or "none")
print("only in the NEW job:          ", only_new or "none")
print("same name, different content: ", different or "none")
