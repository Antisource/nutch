#!/usr/bin/env python3
"""Baby step 4.8.1: compare a Nutch job file built WITHOUT the teammate's source-receipt patch with one built WITH it.

The expected differences are read from the patch itself: every Java file it touches becomes a class (with its inner
classes), existing files are expected to CHANGE and files created by the patch are expected to be NEW. Every entry of the
job, and every file inside each nested jar, is compared by SHA-256; anything else that differs is reported as unexpected.
The check also fails if the patch is not in the job (an identical job proves nothing).
Container bytes of nested jars (timestamps, order) are not compared, only their contents.
Usage: m481_job_diff.py BASE.job PATCHED.job PATCH"""
import hashlib, io, re, sys, zipfile


def expected_from_patch(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    new, changed = [], []
    for i, l in enumerate(lines):
        m = re.match(r"^\+\+\+ b/(.*\.java)$", l)
        if not m:
            continue
        src = m.group(1)
        base = re.sub(r"^src/(?:java|plugin/[^/]+/src/java)/", "", src)[:-5]
        is_new = i > 0 and lines[i - 1].startswith("--- /dev/null")
        (new if is_new else changed).append(base)
    return new, changed


def digests(path):
    z = zipfile.ZipFile(path); out = {}
    for i in z.infolist():
        if i.is_dir():
            continue
        data = z.read(i.filename)
        if i.filename.endswith(".jar"):
            inner = zipfile.ZipFile(io.BytesIO(data))
            for j in inner.infolist():
                if not j.is_dir():
                    out[i.filename + "!" + j.filename] = hashlib.sha256(inner.read(j.filename)).hexdigest()
        else:
            out[i.filename] = hashlib.sha256(data).hexdigest()
    return out


def class_path(key):
    return key.split("!")[-1]


def belongs(key, bases):
    p = class_path(key)
    return any(re.fullmatch(re.escape(b) + r"(\$[^/]*)?\.class", p) for b in bases)


def main():
    if len(sys.argv) != 4:
        print(__doc__); return 2
    NEW, CHANGED = expected_from_patch(sys.argv[3])
    if not NEW and not CHANGED:
        print("JOB-DIFF-STOP: no Java file found in the patch"); return 2
    print("the patch names %d existing classes (expected to change) and %d new classes" % (len(CHANGED), len(NEW)))
    a, b = digests(sys.argv[1]), digests(sys.argv[2])
    only_a = sorted(set(a) - set(b)); only_b = sorted(set(b) - set(a))
    diff = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    print("entries (plain and inside nested jars): base %d, patched %d" % (len(a), len(b)))
    allowed = NEW + CHANGED
    unexpected = [("removed", k) for k in only_a] + [("changed", k) for k in diff if not belongs(k, allowed)] \
        + [("new", k) for k in only_b if not belongs(k, allowed)]
    print("changed: %d   new: %d   removed: %d   unexpected: %d" % (len(diff), len(only_b), len(only_a), len(unexpected)))
    for k in diff:
        print("   changed  " + k[:140])
    for k in only_b:
        print("   new      " + k[:140])
    for kind, k in unexpected:
        print("   UNEXPECTED (%s)  %s" % (kind, k[:140]))
    missing = [n for n in NEW if not any(class_path(k) == n + ".class" for k in only_b)]
    not_changed = [n for n in CHANGED if not any(class_path(k) == n + ".class" for k in diff)]
    for n in missing:
        print("   MISSING new class   " + n)
    for n in not_changed:
        print("   NOT CHANGED class   " + n)
    if unexpected:
        print("JOB-DIFF-UNEXPECTED (%d)" % len(unexpected)); return 1
    if missing or not_changed:
        print("JOB-DIFF-PATCH-NOT-IN-JOB (%d new classes missing, %d classes unchanged)" % (len(missing), len(not_changed))); return 1
    print("JOB-DIFF-ONLY-THE-PATCH (changed %d, new %d, removed 0, unexpected 0)" % (len(diff), len(only_b)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
