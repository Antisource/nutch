#!/usr/bin/env bash
# Rehearsal of m512c-analyze.sh with stand-in tools (they print the real verdict lines and check their arguments), stand-ins for the two updated tools
# in an overlay folder (they print a marker, so that the replacement can be seen), and fetched-file fixtures with signed-read lines in the audit logs.
# Usage: bash m512c-analyze-rehearse.sh KITDIR
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
print("RECORDS-GAPS")
PY
cat > "$TL/nn_audit_compare.py" <<'PY'
print("NN-AUDIT-COMPARE-FINDINGS (999)")
PY
OVL="$R/overlay"; mkdir -p "$OVL"
cat > "$OVL/records_expected.py" <<'PY'
import os, sys
a = sys.argv[1:]; cover = a[a.index("--cover") + 1]; out = a[a.index("--out") + 1]
ok = cover == "^/user/rishabsdp17/(crawl|seeds)-run11(/|$)" and "--require-sidecars" in a and os.environ.get("FAKE_RECORDS") != "gaps"
open(out, "w").write("expected\n"); print("55 files judged, 55 with a matching record" if ok else "gaps: cover=%r" % cover); print("RECORDS-COMPLETE" if ok else "RECORDS-GAPS")
PY
cat > "$OVL/nn_audit_compare.py" <<'PY'
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
open(os.path.join(d, "summary.txt"), "w").write("M512C-RUN-DONE (run11, mode on, 693 s)\n")
for n, big in (("m", 3), ("w", 9)):
    for i in range(big if n == "w" else 1):
        open(os.path.join(pk, n, "attested-audit", ("tdx-lab-worker-2%d-1.tsv" if n == "w" else "tdx-lab-1%d-1.tsv") % i), "w").write(("1\th\tj\tOPEN\tp\t\tverify=ok sig=ok-test bind=ok\n" * (3 + 3 * i)) + "x" * (100 * (i + 1)))
    open(os.path.join(pk, n, "attested-records", ("tdx-lab-worker-2-1.tsv" if n == "w" else "tdx-lab-1-1.tsv")), "w").write("r\n")
open(os.path.join(pk, "w", "userlogs", "application_1", "container_1", "syslog"), "w").write("log\n")
for n, name in (("m", os.path.join(d, "master-logs.tar.gz")), ("w", os.path.join(fx, "run11-worker.tar.gz"))):
    t = tarfile.open(name, "w:gz"); [t.add(os.path.join(pk, n, x), arcname=x) for x in sorted(os.listdir(os.path.join(pk, n)))]; t.close()
import io
os.makedirs(os.path.join(pk, "vr", "verify"), exist_ok=True)
for nm_, files_ in (("seeds-run11", 1), ("crawl-run11", 41)):
    open(os.path.join(pk, "vr", "verify", "tree-%s.txt" % nm_), "w").write("VERIFY-TREE folders=3 files=%d ok=%d bad=0\nVERIFY-TREE-CLEAN\n" % (files_, files_))
t = tarfile.open(os.path.join(d, "verify-results.tar.gz"), "w:gz"); t.add(os.path.join(pk, "vr", "verify"), arcname="verify"); t.close()
open(os.path.join(fx, "run11-console.txt"), "w").write("console\n")
with open(os.path.join(d, "fingerprints.txt"), "w") as o:
    for f in ["before.tsv", "after.tsv", "nn-window.log", "master-logs.tar.gz", "crawl.log", "nonce", "policy.json", "crawl-command.sh", "verify-results.tar.gz"]:
        o.write("%s  %s\n" % (hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest(), f))
PY
}
run() { ( cd "$KIT" && M512C_FETCH_DIR="$R/fx" M512C_TOOLS="$R/tools" M512C_OVERLAY="${OVERLAY_DIR:-$R/overlay}" bash ops/attested/m512c-analyze.sh run11 "$R/w$1" ) >"$R/out.txt" 2>&1; }
mkfx "$R/fx"; run 1; res "T1 happy path (relative script path, from the kit folder)" "M512C-ANALYSIS-CLEAN (run11)"
res "T1b the receipts look is printed" "tc_receipts files in the crawl folder: 3  {'receipts': 1, 'outcomes': 1, 'handshakes': 1}"
res "T1c the negative control is caught" "negative control: with the biggest wrapper log removed"
res "T1d the two updated tools replace the committed ones (the committed stand-ins would say RECORDS-GAPS and FINDINGS (999))" "nn_audit_compare.py (.*) and records_expected.py (.*) are the updated ones"
res "T1e the folders made with their identity file are reported" "folders made with their identity file"
res "T1f the run's own offline verification is read: two trees clean" "the run's offline verification: 2 trees, all VERIFY-TREE-CLEAN"
res "T1g every read had a binding and a signature" "every verified read was bound to its folder"; res "T1h ... with a signature" "every verified read had a signature"
res "T1i the folders have identity files" "the folders of the run have identity files"
FAKE_AUDIT=gaps run 2; res "T2 audit gaps" "M512C-ANALYSIS-FINDINGS"; res "T2b ... and says which check" "audit_compare: AUDIT-GAPS"
FAKE_RECORDS=gaps run 3; res "T3 records gaps" "records_expected: RECORDS-GAPS"
FAKE_VERIFY=fail run 4; res "T4 verification not clean" "verify_summary: VERIFY-NOT-CLEAN"
FAKE_NN=findings run 5; res "T5 NameNode comparison has findings" "nn_audit_compare: NN-AUDIT-COMPARE-FINDINGS"
FAKE_NN_BLIND=1 run 6; res "T6 the negative control is NOT caught (a blind comparison)" "negative control NOT caught"
echo "tampered" >> "$R/fx/run11/crawl.log"; run 7; res "T7 a fetched file differs from the master's fingerprint" "M512C-STOP: a fetched file differs"
mkfx "$R/fx"; rm "$R/fx/run11-worker.tar.gz"; run 8; res "T8 the worker's pack is missing" "M512C-STOP: the worker's pack is missing"
mkfx "$R/fx"; rm "$R/pk/w/attested-audit/"*.tsv; python3 - "$R" <<'PY'
import os, sys, tarfile
R = sys.argv[1]; t = tarfile.open(R + "/fx/run11-worker.tar.gz", "w:gz")
for x in sorted(os.listdir(R + "/pk/w")): t.add(R + "/pk/w/" + x, arcname=x)
t.close()
PY
run 9; res "T9 no audit logs from the worker" "audit logs missing"
mkfx "$R/fx"; mkdir -p "$R/w10"; run 10; res "T10 the work folder exists already" "M512C-STOP: .*w10 exists already"
mkfx "$R/fx"; echo "M512C-RUN-FAILED (1): run11" > "$R/fx/run11/summary.txt"
run 11; res "T11 the master's summary does not say the run is done" "does not say M512C-RUN-DONE"
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
run 12; res "T12 the run's own offline verification found a bad file" "M512C-ANALYSIS-FINDINGS"; res "T12b ... and says so" "the run's offline verification found problems in 1 of 2 trees"
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
mkfx "$R/fx"; mkdir -p "$R/empty-overlay"; OVERLAY_DIR="$R/empty-overlay" run 16; res "T16 the updated tools are not in the kit folder" "M512C-STOP: the updated tool nn_audit_compare.py is not in"
mkfx "$R/fx"; sed -i '\#/_attested-folder#d' "$R/fx/run11/after.tsv"; python3 - "$R" <<'PY'
import hashlib, sys
d = sys.argv[1] + "/fx/run11"; lines = [l for l in open(d + "/fingerprints.txt") if not l.rstrip().endswith("after.tsv")]
lines.append("%s  after.tsv\n" % hashlib.sha256(open(d + "/after.tsv", "rb").read()).hexdigest()); open(d + "/fingerprints.txt", "w").writelines(lines)
PY
run 17; res "T17 no identity file in the after listing" "no identity file in the after listing"
mkfx "$R/fx"; run 18; res "T18 after all the faults, a clean run still passes" "M512C-ANALYSIS-CLEAN (run11)"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: the happy path passes, the two updated tools replace the committed ones, and all 17 faults are caught" || echo "REHEARSAL-FAIL"
