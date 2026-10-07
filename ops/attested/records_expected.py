#!/usr/bin/env python3
"""From the wrapper's records and audit logs, work out which hashed file should sit at which path.

Replays the records (one line per file, written when the file is closed) together with
the renames and deletes from the audit logs, in time order, and compares the result with
a listing of storage taken afterwards. It reports files with no record, files whose length
differs from their record, files that were appended to (not hashed), and records for paths
that are no longer in storage. It writes expected.tsv for records_verify.sh, which
re-hashes the real bytes independently.

Usage: records_expected.py AFTER.tsv RECORDS_DIR AUDIT_DIR [--cover REGEX] [--out FILE] [--require-sidecars]
  AFTER.tsv     listing of storage (type, size, modified, path), as made by audit.sh snapshot
  RECORDS_DIR   folder with the *.tsv record logs of all JVMs (searched recursively)
  AUDIT_DIR     folder with the *.tsv audit logs of all JVMs (searched recursively)
  --cover       only paths matching this regular expression are judged (default: all)
  --out         where to write expected.tsv (default: expected.tsv)
  --require-sidecars  (stage B2) every judged file must also have its record file
                next to it (.NAME.attested); the records themselves are not judged as files
Exit code 0 when every judged file has a matching record, 1 otherwise.
"""
import glob
import os
import re
import sys


def load_tsv(folder, ncols):
    rows = []
    for fn in sorted(glob.glob(os.path.join(folder, "**", "*.tsv"), recursive=True)):
        with open(fn, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) != ncols:
                    raise SystemExit("bad line in %s: %r" % (fn, line[:80]))
                rows.append(c)
    return rows


def main(argv):
    cover, out, pos, need_sidecars = ".", "expected.tsv", [], False
    i = 1
    while i < len(argv):
        if argv[i] == "--require-sidecars":
            need_sidecars = True; i += 1
        elif argv[i] == "--cover":
            cover = argv[i + 1]; i += 2
        elif argv[i] == "--out":
            out = argv[i + 1]; i += 2
        else:
            pos.append(argv[i]); i += 1
    if len(pos) != 3:
        print(__doc__); return 2
    cover_rx = re.compile(cover)
    listing = {}
    with open(pos[0], encoding="utf-8") as f:
        for line in f:
            t, size, _m, p = line.rstrip("\n").split("\t", 3)
            if t == "-":
                listing[p] = int(size)
    events = []
    for c in load_tsv(pos[1], 11):
        events.append((int(c[0]), 0, "rec", c))
    for c in load_tsv(pos[2], 7):
        if c[3] in ("RENAME", "DELETE"):
            events.append((int(c[0]), 1, c[3].lower(), c))
    events.sort(key=lambda e: (e[0], e[1]))

    state = {}          # path -> record fields
    appended = set()
    for _ts, _o, kind, c in events:
        if kind == "rec":
            path, flag = c[5], c[10]
            if flag == "closed":
                state[path] = c
                appended.discard(path)
            elif flag == "append-unhashed":
                appended.add(path)
        elif kind == "rename":
            src, dst = c[4], c[5]
            for k in [k for k in state if k == src or k.startswith(src + "/")]:
                state[dst + k[len(src):]] = state.pop(k)
            for k in [k for k in appended if k == src or k.startswith(src + "/")]:
                appended.discard(k); appended.add(dst + k[len(src):])
        elif kind == "delete":
            p = c[4]
            for k in [k for k in state if k == p or k.startswith(p + "/")]:
                del state[k]
            for k in [k for k in appended if k == p or k.startswith(p + "/")]:
                appended.discard(k)

    sidecar_rx = re.compile(r"(^|/)\..+\.attested$")
    judged = sorted(p for p in listing if cover_rx.search(p) and not sidecar_rx.search(p))
    missing, mismatch, appended_live, good = [], [], [], []
    for p in judged:
        if p in appended:
            appended_live.append(p)
        elif p not in state:
            missing.append(p)
        elif int(state[p][6]) != listing[p]:
            mismatch.append((p, state[p][6], listing[p]))
        else:
            good.append(p)
    stale = sorted(p for p in state if cover_rx.search(p) and p not in listing)
    no_sidecar = []
    if need_sidecars:
        for p in judged:
            d, _, n = p.rpartition("/")
            if (d + "/." + n + ".attested") not in listing:
                no_sidecar.append(p)
    with open(out, "w", encoding="utf-8") as f:
        for p in good:
            r = state[p]
            f.write("\t".join([p, r[6], r[7], r[8], r[9]]) + "\n")

    print("files judged: %d   with a matching record: %d" % (len(judged), len(good)))
    print("no record: %d   length differs from the record: %d   appended to (not hashed): %d   records for paths no longer in storage: %d"
          % (len(missing), len(mismatch), len(appended_live), len(stale)))
    if need_sidecars:
        print("files with no record file next to them: %d" % len(no_sidecar))
        for p in no_sidecar[:25]:
            print("  NO-SIDECAR " + p)
    for p in missing[:25]:
        print("  NO-RECORD  " + p)
    for p, rl, sl in mismatch[:25]:
        print("  LENGTH     %s  record %s, storage %s" % (p, rl, sl))
    for p in appended_live[:25]:
        print("  APPENDED   " + p)
    for p in stale[:25]:
        print("  STALE      " + p)
    print("expected.tsv: %d lines written to %s" % (len(good), out))
    ok = not (missing or mismatch or appended_live or stale or no_sidecar)
    print("RECORDS-COMPLETE" if ok else "RECORDS-GAPS")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
