#!/usr/bin/env python3
"""Compare two Nutch job files by the SHA-256 of every entry and of every file inside the nested jars.

CRC-32 (what job_compare.py uses) catches accidental differences, not a deliberate change. This reads every
entry, and every entry inside each nested .jar, and compares SHA-256 digests. A rebuilt jar with the same
content but different container bytes (timestamps, ordering) is reported separately, not as a difference.
Usage: job_sha_compare.py OLD.job NEW.job"""
import hashlib, io, sys, zipfile

def digests(path):
    z = zipfile.ZipFile(path); plain, inner, outer = {}, {}, {}
    for i in z.infolist():
        if i.is_dir():
            continue
        data = z.read(i.filename); h = hashlib.sha256(data).hexdigest()
        if i.filename.endswith(".jar"):
            outer[i.filename] = h
            zz = zipfile.ZipFile(io.BytesIO(data))
            for j in zz.infolist():
                if not j.is_dir():
                    inner[i.filename + "!" + j.filename] = hashlib.sha256(zz.read(j.filename)).hexdigest()
        else:
            plain[i.filename] = h
    return plain, inner, outer

def main():
    if len(sys.argv) != 3:
        print(__doc__); return 2
    (pa, ia, oa), (pb, ib, ob) = digests(sys.argv[1]), digests(sys.argv[2])
    print("plain entries: old %d, new %d   files inside nested jars: old %d, new %d   nested jars: old %d, new %d" % (len(pa), len(pb), len(ia), len(ib), len(oa), len(ob)))
    bad = 0
    for label, a, b in (("plain entries", pa, pb), ("files inside nested jars", ia, ib), ("nested jars (names only)", dict.fromkeys(oa), dict.fromkeys(ob))):
        only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
        diff = sorted(k for k in set(a) & set(b) if a[k] != b[k])
        print("%-26s only in old: %d, only in new: %d, different SHA-256: %d" % (label, len(only_a), len(only_b), len(diff)))
        for k in (only_a + only_b + diff)[:8]:
            print("    " + k[:150])
        bad += len(only_a) + len(only_b) + len(diff)
    container = sorted(k for k in set(oa) & set(ob) if oa[k] != ob[k])
    print("nested jars whose container bytes differ but whose contents are identical: %d" % len(container))
    print("job files: old %s, new %s" % (hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()[:16], hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()[:16]))
    print("JOBS-SAME-BY-SHA256" if bad == 0 else "JOBS-DIFFER-BY-SHA256 (%d)" % bad)
    return 0 if bad == 0 else 1

sys.exit(main())
