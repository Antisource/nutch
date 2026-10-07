#!/usr/bin/env python3
"""Check that the facts stated in the documents are confirmed by the evidence.

Each line of the facts file names a document, a piece of text that must appear in it, an evidence
source, and a piece of text (or a count) that the evidence must show. The check fails when the
document does not contain its text, or when the evidence contradicts it. When an evidence file is
missing the fact is reported as not confirmable, not as confirmed.

Usage: docs_facts_check.py DOCS_ROOT EVIDENCE_ROOT REPO FACTS.tsv [--docs-only]
  DOCS_ROOT      folder that holds docs/ (the documents to check)
  EVIDENCE_ROOT  folder with the unpacked evidence bundles, the .sha256 files and the zips
  REPO           a clone of the repository (for the commits and the source code)
  --docs-only    only check that each document contains its text

Facts file (tab separated; lines starting with # are ignored):  document, text in the document,
evidence source, evidence text. The evidence source is one of:
  FILE                      a file under EVIDENCE_ROOT; the evidence text must occur in it
                            ("re:" in front makes it a regular expression)
  lines:FILE                the number of lines of FILE must equal the evidence text
  files:DIR                 the number of *.tsv files under DIR must equal the evidence text
  dirhas:DIR                some *.tsv file under DIR must contain the evidence text
  zip-sha:ZIP#MEMBER        the SHA-256 of that member of the zip must start with the evidence text
  @repo:PATH                a file of the repository; the evidence text must occur in it
                            ("re:" in front makes it a regular expression here too)
  @git-log                  the evidence text must occur in the last commits (one line each)
  @git-files:COMMIT         the number of files changed by that commit must equal the evidence text

Exit code: 0 all confirmed, 1 a text missing or a contradiction, 3 only some evidence missing.
"""
import glob
import hashlib
import os
import re
import subprocess
import sys
import zipfile


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def matches(body, text):
    """A plain text must occur in the body; with "re:" in front it is a regular expression."""
    if text.startswith("re:"):
        return re.search(text[3:], body) is not None
    return text in body


def git(repo, args):
    return subprocess.run(["git", "-C", repo] + args, capture_output=True, text=True).stdout


def check_evidence(src, text, evid, repo):
    """Returns ('ok' | 'fail' | 'missing', detail)."""
    if src == "@git-log":
        return ("ok", "") if text in git(repo, ["log", "--oneline", "-30"]) else ("fail", "not in the last 30 commits")
    if src.startswith("@git-files:"):
        names = git(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", src.split(":", 1)[1]]).split()
        if not names:
            return ("missing", "commit not found in the clone")
        return ("ok", "") if str(len(names)) == text else ("fail", "the commit changed %d files" % len(names))
    if src.startswith("@repo:"):
        p = os.path.join(repo, src[6:])
        if not os.path.exists(p):
            return ("missing", "no such file in the clone: " + src[6:])
        return ("ok", "") if matches(read(p), text) else ("fail", "text not in " + src[6:])
    if src.startswith("lines:"):
        p = os.path.join(evid, src[6:])
        if not os.path.exists(p):
            return ("missing", "no such evidence file: " + src[6:])
        n = len(read(p).splitlines())
        return ("ok", "") if str(n) == text else ("fail", "the file has %d lines" % n)
    if src.startswith("files:"):
        d = os.path.join(evid, src[6:])
        if not os.path.isdir(d):
            return ("missing", "no such evidence folder: " + src[6:])
        n = len(glob.glob(os.path.join(d, "**", "*.tsv"), recursive=True))
        return ("ok", "") if str(n) == text else ("fail", "the folder has %d log files" % n)
    if src.startswith("dirhas:"):
        d = os.path.join(evid, src[7:])
        if not os.path.isdir(d):
            return ("missing", "no such evidence folder: " + src[7:])
        for fn in glob.glob(os.path.join(d, "**", "*.tsv"), recursive=True):
            if text in read(fn):
                return ("ok", "")
        return ("fail", "no log file in the folder contains the text")
    if src.startswith("zip-sha:"):
        zpath, _, member = src[8:].partition("#")
        zp = os.path.join(evid, zpath)
        if not os.path.exists(zp):
            return ("missing", "no such zip: " + zpath)
        with zipfile.ZipFile(zp) as z:
            if member not in z.namelist():
                return ("fail", "member not in the zip: " + member)
            digest = hashlib.sha256(z.read(member)).hexdigest()
        return ("ok", "") if digest.startswith(text) else ("fail", "the member's fingerprint is " + digest[:16])
    p = os.path.join(evid, src)
    if not os.path.exists(p):
        return ("missing", "no such evidence file: " + src)
    return ("ok", "") if matches(read(p), text) else ("fail", "text not found in " + src)


def main(argv):
    args = [a for a in argv[1:] if a != "--docs-only"]
    docs_only = "--docs-only" in argv
    if len(args) != 4:
        print(__doc__); return 2
    docs, evid, repo, facts = args
    total = good = missing = doc_bad = contradicted = 0
    details = []
    cache = {}
    for n, line in enumerate(open(facts, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            raise SystemExit("facts file line %d: expected 4 tab-separated fields" % n)
        doc, dtext, src, etext = parts
        total += 1
        dp = os.path.join(docs, doc)
        if dp not in cache:
            cache[dp] = read(dp) if os.path.exists(dp) else None
        if cache[dp] is None or dtext not in cache[dp]:
            doc_bad += 1
            details.append("DOC-TEXT-MISSING  line %d  %s: %r" % (n, doc, dtext[:90]))
            continue
        if docs_only:
            good += 1
            continue
        status, why = check_evidence(src, etext, evid, repo)
        if status == "ok":
            good += 1
        elif status == "missing":
            missing += 1
            details.append("EVIDENCE-MISSING line %d  %s: %s" % (n, doc, why))
        else:
            contradicted += 1
            details.append("CONTRADICTED     line %d  %s: %r  (%s)" % (n, doc, dtext[:80], why))
    for d in details:
        print(d)
    print("facts: %d   confirmed: %d   evidence missing: %d   text missing in the document: %d   contradicted by the evidence: %d"
          % (total, good, missing, doc_bad, contradicted))
    if doc_bad or contradicted:
        print("DOCS-FACTS-FAILED"); return 1
    if missing:
        print("DOCS-FACTS-PARTLY-CONFIRMED"); return 3
    print("DOCS-FACTS-CONFIRMED" if not docs_only else "DOCS-TEXT-PRESENT"); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
