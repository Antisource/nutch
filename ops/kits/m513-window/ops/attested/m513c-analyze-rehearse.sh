#!/usr/bin/env bash
# Rehearsal of m513c-analyze.sh with stand-in tools (they print the real verdict lines and check their arguments) and fetched-file fixtures: audit logs with real-signature reads (sig=ok),
# the run's verification results with key ids and the negative control, and the audit logs of the two signing services.
# Usage: bash m513c-analyze-rehearse.sh KITDIR
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
KIT="$1"; R=$(mktemp -d); fail=0
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -6; fail=1; fi; }
TL="$R/tools/ops/attested"; mkdir -p "$TL"
cat > "$TL/audit_compare.py" <<'PY'
import os, sys
a = sys.argv[1:]; assert len(a) >= 3 and a[3] == "--require-hosts" and a[4] == "tdx-lab,tdx-lab-worker", a
print("explained by the log: added 3, removed 0, changed 1")
print("AUDIT-GAPS" if os.environ.get("FAKE_AUDIT") == "gaps" else "AUDIT-CLEAN")
PY
cat > "$TL/verify_summary.py" <<'PY'
import os, sys
print("265 opens, all verify=ok"); print("VERIFY-NOT-CLEAN" if os.environ.get("FAKE_VERIFY") == "fail" else "VERIFY-CLEAN")
PY
cat > "$TL/records_expected.py" <<'PY'
import os, sys
a = sys.argv[1:]; cover = a[a.index("--cover") + 1]; out = a[a.index("--out") + 1]
ok = cover == "^/user/rishabsdp17/(crawl|seeds)-run11(/|$)" and "--require-sidecars" in a and os.environ.get("FAKE_RECORDS") != "gaps"
open(out, "w").write("expected\n"); print("55 files judged, 55 with a matching record" if ok else "gaps: cover=%r" % cover); print("RECORDS-COMPLETE" if ok else "RECORDS-GAPS")
PY
cat > "$TL/nn_audit_compare.py" <<'PY'
import os, sys
a = sys.argv[1:]; w = a[a.index("--wrapper") + 1]; n = len([f for f in os.listdir(w) if f.endswith(".tsv")])
print("   of them, folders made with their identity file (a mkdirs next to the creation of the folder's identity): 4") if "--strict" not in a else None
if "--strict" in a: print("NN-AUDIT-COMPARE-FINDINGS (26)")
elif os.environ.get("FAKE_NN") == "findings": print("NN-AUDIT-COMPARE-FINDINGS (3)")
elif os.environ.get("FAKE_NN_BLIND") == "1": print("NN-AUDIT-COMPARE-CLEAN")
elif not os.path.exists(os.path.join(w, "tdx-lab-worker-28-1.tsv")): print("NN-AUDIT-COMPARE-FINDINGS (108)")   # the biggest log is missing
else: print("NN-AUDIT-COMPARE-CLEAN")
PY
mkfx() {   # $1 = fixture folder
  rm -rf "$1"; mkdir -p "$1/run11" "$R/pk/m/attested-audit" "$R/pk/m/attested-records" "$R/pk/w/attested-audit" "$R/pk/w/attested-records" "$R/pk/w/userlogs/application_1/container_1"
  python3 - "$1" "$R/pk" <<'PY'
import hashlib, os, sys, tarfile
fx, pk = sys.argv[1], sys.argv[2]; d = os.path.join(fx, "run11")
open(os.path.join(d, "before.tsv"), "w").write("d\t0\t1\t/user\n")
base = "/user/rishabsdp17/crawl-run11/segments/20261014113000"
rows = ["-\t300\t1\t/user/rishabsdp17/crawl-run11/_attested-folder", "-\t100\t1\t%s/tc_receipts/receipts-attempt_1_0001_m_000000_0.jsonl" % base, "-\t40\t1\t%s/tc_receipts/outcomes-attempt_1_0001_m_000000_0.jsonl" % base,
        "-\t60\t1\t%s/tc_receipts/handshakes-attempt_1_0001_m_000000_0.jsonl" % base, "-\t5000\t1\t%s/warc/NUTCH-CRAWL-1-00000.warc.gz" % base, "-\t9\t1\t/user/rishabsdp17/seeds-run11/seed.txt"]
open(os.path.join(d, "after.tsv"), "w").write("\n".join(rows) + "\n")
open(os.path.join(d, "nn-window.log"), "w").write("event\n"); open(os.path.join(d, "crawl.log"), "w").write("crawl\n")
open(os.path.join(d, "nonce"), "w").write("41e3f6cc93792ade699c7588db08834c\n"); open(os.path.join(d, "policy.json"), "w").write("{}\n"); open(os.path.join(d, "crawl-command.sh"), "w").write("x\n")
open(os.path.join(d, "summary.txt"), "w").write("M513C-RUN-DONE (run11, mode on, 770 s)\n")
for n, big in (("m", 3), ("w", 9)):
    for i in range(big if n == "w" else 1):
        open(os.path.join(pk, n, "attested-audit", ("tdx-lab-worker-2%d-1.tsv" if n == "w" else "tdx-lab-1%d-1.tsv") % i), "w").write(("1\th\tj\tOPEN\tp\t\tverify=ok sig=ok bind=ok\n" * (3 + 3 * i)) + "x" * (100 * (i + 1)))
    open(os.path.join(pk, n, "attested-records", ("tdx-lab-worker-2-1.tsv" if n == "w" else "tdx-lab-1-1.tsv")), "w").write("r\n")
open(os.path.join(pk, "w", "userlogs", "application_1", "container_1", "syslog"), "w").write("log\n")
for n, name in (("m", os.path.join(d, "master-logs.tar.gz")), ("w", os.path.join(fx, "run11-worker.tar.gz"))):
    t = tarfile.open(name, "w:gz"); [t.add(os.path.join(pk, n, x), arcname=x) for x in sorted(os.listdir(os.path.join(pk, n)))]; t.close()
import io
os.makedirs(os.path.join(pk, "vr", "verify"), exist_ok=True)
def okl(path, key): return "OK   %s  folder=aaaaaaaa key=%s\n" % (path, key)
M, W = "TDX-1111111111111111", "TDX-2222222222222222"
open(os.path.join(pk, "vr", "verify", "tree-seeds-run11.txt"), "w").write("KEYLIST 2 key(s) trusted\n" + okl("/user/rishabsdp17/seeds-run11/seed.txt", M) + "VERIFY-TREE folders=1 files=1 ok=1 bad=0\nVERIFY-TREE-CLEAN\n")
open(os.path.join(pk, "vr", "verify", "tree-crawl-run11.txt"), "w").write("KEYLIST 2 key(s) trusted\n" + okl("/user/rishabsdp17/crawl-run11/_SUCCESS", M) + okl("/user/rishabsdp17/crawl-run11/segments/x/part-r-00000", W) + "VERIFY-TREE folders=3 files=41 ok=41 bad=0\nVERIFY-TREE-CLEAN\n")
open(os.path.join(pk, "vr", "verify", "negative-this-node-only-list.txt"), "w").write("KEYLIST 1 key(s) trusted\nBAD  /user/rishabsdp17/crawl-run11/segments/x/part-r-00000  the record is signed by a key that is not trusted here (" + W + ")\nVERIFY-TREE folders=3 files=41 ok=1 bad=40\nVERIFY-TREE-FINDINGS (40)\n")
for r_, k_ in (("master", M), ("worker", W)):
    open(os.path.join(fx, "service-audit-%s-closed.log" % r_), "w").write("2026-10-16T08:00:00Z START key=%s quote=yes port=7461\n" % k_ + "2026-10-16T08:10:00Z SIGNED peer=1 tag=ATTEST03-SIGNED statement=abcdef0123456789\n" * 5 + "2026-10-16T09:00:00Z STOP signed=5 refused=0\n")
t = tarfile.open(os.path.join(d, "verify-results.tar.gz"), "w:gz"); t.add(os.path.join(pk, "vr", "verify"), arcname="verify"); t.close()
open(os.path.join(fx, "run11-console.txt"), "w").write("console\n")
with open(os.path.join(d, "fingerprints.txt"), "w") as o:
    for f in ["before.tsv", "after.tsv", "nn-window.log", "master-logs.tar.gz", "crawl.log", "nonce", "policy.json", "crawl-command.sh", "verify-results.tar.gz"]:
        o.write("%s  %s\n" % (hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest(), f))
PY
}
run() { ( cd "$KIT" && M513C_FETCH_DIR="$R/fx" M513C_TOOLS="$R/tools" bash ops/attested/m513c-analyze.sh run11 "$R/w$1" ) >"$R/out.txt" 2>&1; }
mkfx "$R/fx"; run 1; res "T1 happy path (relative script path, from the kit folder)" "M513C-ANALYSIS-CLEAN (run11)"
res "T1b the receipts look is printed" "tc_receipts files in the crawl folder: 3  {'receipts': 1, 'outcomes': 1, 'handshakes': 1}"
res "T1c the negative control is caught" "negative control: with the biggest wrapper log removed"
res "T1d the tools of the committed head include the updated ones" "include the updated nn_audit_compare.py"
res "T1e the folders made with their identity file are reported" "folders made with their identity file"
res "T1f the run's own offline verification is read: two trees clean" "the run's offline verification: 2 trees, all VERIFY-TREE-CLEAN"
res "T1g every read had a binding and a signature" "every verified read was bound to its folder"; res "T1h ... with a REAL signature (sig=ok, never a test key)" "every verified read had a REAL signature"
res "T1j the master's signing service: key, hardware quote, signatures, no refusal" "the master's signing service (TDX-1111111111111111, with a hardware quote) signed 5 statements and refused none"
res "T1k ... and the worker's" "the worker's signing service (TDX-2222222222222222, with a hardware quote) signed 5 statements and refused none"
res "T1l every file of the verified trees was signed by one of the two services' keys" "every file of the verified trees was signed by one of the two services' keys"
res "T1m the run's negative control (a partial key list) refused the other machine's files" "negative control of the run: with only one node's bundle in the key list"
res "T1i the folders have identity files" "the folders of the run have identity files"
FAKE_AUDIT=gaps run 2; res "T2 audit gaps" "M513C-ANALYSIS-FINDINGS"; res "T2b ... and says which check" "audit_compare: AUDIT-GAPS"
FAKE_RECORDS=gaps run 3; res "T3 records gaps" "records_expected: RECORDS-GAPS"
FAKE_VERIFY=fail run 4; res "T4 verification not clean" "verify_summary: VERIFY-NOT-CLEAN"
FAKE_NN=findings run 5; res "T5 NameNode comparison has findings" "nn_audit_compare: NN-AUDIT-COMPARE-FINDINGS"
FAKE_NN_BLIND=1 run 6; res "T6 the negative control is NOT caught (a blind comparison)" "negative control NOT caught"
echo "tampered" >> "$R/fx/run11/crawl.log"; run 7; res "T7 a fetched file differs from the master's fingerprint" "M513C-STOP: a fetched file differs"
mkfx "$R/fx"; rm "$R/fx/run11-worker.tar.gz"; run 8; res "T8 the worker's pack is missing" "M513C-STOP: the worker's pack is missing"
mkfx "$R/fx"; rm "$R/pk/w/attested-audit/"*.tsv; python3 - "$R" <<'PY'
import os, sys, tarfile
R = sys.argv[1]; t = tarfile.open(R + "/fx/run11-worker.tar.gz", "w:gz")
for x in sorted(os.listdir(R + "/pk/w")): t.add(R + "/pk/w/" + x, arcname=x)
t.close()
PY
run 9; res "T9 no audit logs from the worker" "audit logs missing"
mkfx "$R/fx"; mkdir -p "$R/w10"; run 10; res "T10 the work folder exists already" "M513C-STOP: .*w10 exists already"
mkfx "$R/fx"; echo "M513C-RUN-FAILED (1): run11" > "$R/fx/run11/summary.txt"
run 11; res "T11 the master's summary does not say the run is done" "does not say M513C-RUN-DONE"
mkfx "$R/fx"; python3 - "$R" <<'PY'
import os, sys, tarfile, io
R = sys.argv[1]; d = R + "/fx/run11"
for f in os.listdir(R + "/pk/vr/verify"):
    if f == "tree-crawl-run11.txt": open(R + "/pk/vr/verify/" + f, "w").write("VERIFY-TREE folders=3 files=41 ok=40 bad=1\nBAD  /user/x/crawl-run11/a/f  the file's bytes do not match its record\nVERIFY-TREE-FINDINGS (1)\n")
t = tarfile.open(d + "/verify-results.tar.gz", "w:gz"); t.add(R + "/pk/vr/verify", arcname="verify"); t.close()
import hashlib
lines = [l for l in open(d + "/fingerprints.txt") if not l.rstrip().endswith("verify-results.tar.gz")]
lines.append("%s  verify-results.tar.gz\n" % hashlib.sha256(open(d + "/verify-results.tar.gz", "rb").read()).hexdigest()); open(d + "/fingerprints.txt", "w").writelines(lines)
PY
run 12; res "T12 the run's own offline verification found a bad file" "M513C-ANALYSIS-FINDINGS"; res "T12b ... and says so" "the run's offline verification found problems in 1 of 2 trees"
mkfx "$R/fx"; rm "$R/fx/run11/verify-results.tar.gz"; sed -i '/verify-results.tar.gz/d' "$R/fx/run11/fingerprints.txt"; run 13; res "T13 the run's verification results are missing" "the run's offline verification results are missing or incomplete"
mkfx "$R/fx"; python3 - "$R" <<'PY'
import os, sys, tarfile
R = sys.argv[1]; p = R + "/pk/w/attested-audit/tdx-lab-worker-28-1.tsv"; open(p, "a").write("1\th\tj\tOPEN\tp\t\tverify=ok sig=ok-test bind=none\n")
t = tarfile.open(R + "/fx/run11-worker.tar.gz", "w:gz")
for x in sorted(os.listdir(R + "/pk/w")): t.add(R + "/pk/w/" + x, arcname=x)
t.close()
PY
run 14; res "T14 a read with bind=none (folder binding was required)" "reads and their folder binding: .* with bind=none"
mkfx "$R/fx"; python3 - "$R" <<'PY'
import os, sys, tarfile
R = sys.argv[1]; p = R + "/pk/w/attested-audit/tdx-lab-worker-28-1.tsv"; open(p, "a").write("1\th\tj\tVERIFY-FAIL\tp\t\tx\n")
t = tarfile.open(R + "/fx/run11-worker.tar.gz", "w:gz")
for x in sorted(os.listdir(R + "/pk/w")): t.add(R + "/pk/w/" + x, arcname=x)
t.close()
PY
run 15; res "T15 a VERIFY-FAIL line in a log" "1 VERIFY-FAIL lines in the audit logs"
mkfx "$R/fx"; sed -i 's/ SIGNED / REFUSED /' "$R/fx/service-audit-worker-closed.log"; run 16; res "T16 the worker's service refused requests and signed none" "M513C-ANALYSIS-FINDINGS"; res "T16b ... and says which log" "the worker's service audit log"
mkfx "$R/fx"; python3 - "$R" <<'PY'
import os, sys, tarfile
R = sys.argv[1]; p = R + "/pk/w/attested-audit/tdx-lab-worker-28-1.tsv"; open(p, "a").write("1\th\tj\tOPEN\tp\t\tverify=ok sig=ok-test bind=ok\n")
t = tarfile.open(R + "/fx/run11-worker.tar.gz", "w:gz")
for x in sorted(os.listdir(R + "/pk/w")): t.add(R + "/pk/w/" + x, arcname=x)
t.close()
PY
run 19; res "T19 a read verified with a TEST key in this run" "reads and their signature: .* sig=ok-test"
mkfx "$R/fx"; rm "$R/fx/service-audit-worker-closed.log"; python3 - "$R" <<'PY'
PY
run 20; res "T20 no audit log of the worker's signing service" "no service audit log of the worker"
mkfx "$R/fx"; sed -i 's/quote=yes/quote=none/' "$R/fx/service-audit-master-closed.log"; run 21; res "T21 the master's service had no hardware quote" "the master's service audit log"
mkfx "$R/fx"; python3 - "$R" <<'PY'
import os, sys, tarfile, hashlib
R = sys.argv[1]; d = R + "/fx/run11"; v = R + "/pk/vr/verify/"
p = v + "tree-crawl-run11.txt"; s = open(p).read().replace("TDX-2222222222222222", "TDX-9999999999999999"); open(p, "w").write(s)
t = tarfile.open(d + "/verify-results.tar.gz", "w:gz"); t.add(R + "/pk/vr/verify", arcname="verify"); t.close()
lines = [l for l in open(d + "/fingerprints.txt") if not l.rstrip().endswith("verify-results.tar.gz")]
lines.append("%s  verify-results.tar.gz\n" % hashlib.sha256(open(d + "/verify-results.tar.gz", "rb").read()).hexdigest()); open(d + "/fingerprints.txt", "w").writelines(lines)
PY
run 22; res "T22 a file was signed by a key that is not one of the two services' keys" "the trees were signed by keys that are not the two services' keys"
mkfx "$R/fx"; rm "$R/pk/vr/verify/negative-this-node-only-list.txt"; python3 - "$R" <<'PY'
import os, sys, tarfile, hashlib
R = sys.argv[1]; d = R + "/fx/run11"
t = tarfile.open(d + "/verify-results.tar.gz", "w:gz"); t.add(R + "/pk/vr/verify", arcname="verify"); t.close()
lines = [l for l in open(d + "/fingerprints.txt") if not l.rstrip().endswith("verify-results.tar.gz")]
lines.append("%s  verify-results.tar.gz\n" % hashlib.sha256(open(d + "/verify-results.tar.gz", "rb").read()).hexdigest()); open(d + "/fingerprints.txt", "w").writelines(lines)
PY
run 23; res "T23 the run's negative control is missing" "the run's negative control (a partial key list) is missing or did not refuse anything"
mkfx "$R/fx"; sed -i '\#/_attested-folder#d' "$R/fx/run11/after.tsv"; python3 - "$R" <<'PY'
import hashlib, sys
d = sys.argv[1] + "/fx/run11"; lines = [l for l in open(d + "/fingerprints.txt") if not l.rstrip().endswith("after.tsv")]
lines.append("%s  after.tsv\n" % hashlib.sha256(open(d + "/after.tsv", "rb").read()).hexdigest()); open(d + "/fingerprints.txt", "w").writelines(lines)
PY
run 17; res "T17 no identity file in the after listing" "no identity file in the after listing"
mkfx "$R/fx"; run 18; res "T18 after all the faults, a clean run still passes" "M513C-ANALYSIS-CLEAN (run11)"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: the happy path passes, the real-key checks pass, and all 22 faults are caught" || echo "REHEARSAL-FAIL"
