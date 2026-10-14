#!/usr/bin/env python3
# Milestone 4, baby step 4.8.3: a structural check of the teammate's receipt files of one run (read-only).
# Usage: m483_receipts_check.py EXPORT_DIR JOB_SHA256
#   EXPORT_DIR holds nonce, policy.json and one folder per segment with tc_receipts/ and warc/ (as exported from HDFS)
#   JOB_SHA256 is the full SHA-256 of the job file that ran (the receipts must name it as code_hash)
# It checks what can be checked WITHOUT her verifier: it is not a cryptographic check of the TLS evidence.
# Per receipt: the run's nonce, the policy hash, the format, TLS 1.3, an authenticated and valid chain, a matching hostname, the
# job's hash, the content hash equal to the SHA-256 of the page in the WARC (and its length), the document id equal to the WARC
# record id. Per outcome: ACCEPTED outcomes name exactly one receipt by its hash and document id; every other outcome has no receipt.
import glob, hashlib, json, os, sys, zlib

X, JOB = sys.argv[1], sys.argv[2].lower()
nonce = open(os.path.join(X, "nonce")).read().strip()
pol = "sha256:" + hashlib.sha256(open(os.path.join(X, "policy.json"), "rb").read()).hexdigest()
problems = []; tot = {}
def bump(k, n=1): tot[k] = tot.get(k, 0) + n
def bad(m): problems.append(m)

def warc_records(path):
    data = open(path, "rb").read(); pos = 0
    while pos < len(data):
        d = zlib.decompressobj(31); buf = d.decompress(data[pos:]); pos = len(data) - len(d.unused_data)
        i = buf.find(b"\r\n\r\n"); h = dict(l.split(": ", 1) for l in buf[:i].decode("utf-8", "replace").split("\r\n")[1:] if ": " in l)
        n = int(h.get("Content-Length", len(buf) - i - 4)); yield h, buf[i + 4:i + 4 + n]

for seg in sorted(d for d in glob.glob(os.path.join(X, "*")) if os.path.isdir(d)):
    rf = sorted(glob.glob(os.path.join(seg, "tc_receipts", "receipts-*.jsonl"))); of = sorted(glob.glob(os.path.join(seg, "tc_receipts", "outcomes-*.jsonl")))
    rlines = [l.rstrip("\n") for f in rf for l in open(f, encoding="utf-8") if l.strip()]
    outs = [json.loads(l) for f in of for l in open(f, encoding="utf-8") if l.strip()]
    resp = {}
    for f in sorted(glob.glob(os.path.join(seg, "warc", "*.warc.gz"))):
        try:
            for h, body in warc_records(f):
                if h.get("WARC-Type") == "response": resp[h.get("WARC-Target-URI")] = (h, body)
        except Exception as e: bad("%s: unreadable WARC %s (%s)" % (os.path.basename(seg), os.path.basename(f), e))
    st = {}
    for o in outs: st[o["status"]] = st.get(o["status"], 0) + 1
    print("== segment %s: receipts %d, outcomes %s, WARC pages %d" % (os.path.basename(seg), len(rlines), st, len(resp)))
    by_hash = {}
    for l in rlines:
        r = json.loads(l); u = r["source_url"]; h = "sha256:" + hashlib.sha256(l.encode()).hexdigest(); by_hash[h] = r; bump("receipts")
        if r.get("nonce") != nonce: bad("nonce differs: " + u)
        if r.get("collection_policy_hash") != pol: bad("policy hash differs: " + u)
        if r.get("version") != "tc-source-receipt/2": bad("format %s: %s" % (r.get("version"), u))
        if r.get("code_hash") != "sha256:" + JOB: bad("code_hash is not the job's hash: " + u)
        s = r.get("server", {}); v = s.get("validation", {})
        if s.get("protocol") != "TLSv1.3": bad("protocol %s: %s" % (s.get("protocol"), u))
        if not (v.get("authenticated") is True and s.get("chain_valid") is True and s.get("hostname_matches") is True): bad("chain or hostname not valid: " + u)
        if r.get("binding", {}).get("type") != "unattested": bad("binding type %s (expected unattested before step 5.1.3): %s" % (r.get("binding"), u))
        w = resp.get(u)
        if not w: bad("no WARC response record for " + u); continue
        hh, body = w; j = body.find(b"\r\n\r\n"); pl = body[j + 4:]
        if "sha256:" + hashlib.sha256(pl).hexdigest() != r["raw_content_hash"] or len(pl) != r["raw_content_length"]: bad("content hash or length differs from the WARC page: " + u)
        else: bump("content hash equals the WARC page")
        if "urn:uuid:" + hh.get("WARC-Record-ID", "").strip("<>").replace("urn:uuid:", "") != r["document_id"]: bad("document_id differs from the WARC record id: " + u)
        else: bump("document id equals the WARC record id")
    acc = 0
    for o in outs:
        if o.get("nonce") != nonce: bad("outcome nonce differs: " + str(o.get("source_url")))
        if o["status"] == "ACCEPTED":
            acc += 1; r = by_hash.get(o.get("receipt_sha256"))
            if r is None: bad("ACCEPTED outcome names no receipt line: " + str(o.get("source_url")))
            elif r["document_id"] != o.get("document_id") or r["source_url"] != o.get("source_url"): bad("ACCEPTED outcome and its receipt disagree: " + str(o.get("source_url")))
            else: bump("ACCEPTED outcomes tied to their receipt by hash")
        else:
            bump("non-ACCEPTED outcomes (%s)" % o["status"])
            if o.get("receipt_sha256"): bad("a %s outcome names a receipt: %s" % (o["status"], o.get("source_url")))
    if acc != len(rlines): bad("segment %s: %d ACCEPTED outcomes but %d receipts" % (os.path.basename(seg), acc, len(rlines)))
    bump("WARC pages without a receipt", len(set(resp) - {r["source_url"] for r in by_hash.values()}))
print(); [print("  %-58s %d" % (k, v)) for k, v in sorted(tot.items())]
print("\nPROBLEMS:", "none" if not problems else ""); [print("  - " + p) for p in problems[:20]]
print("RECEIPTS-CHECK-CLEAN" if not problems and tot.get("receipts") else "RECEIPTS-CHECK-FINDINGS (%d)" % len(problems))
