#!/usr/bin/env bash
# Rehearsal of m481-build.sh away from the cluster, with a stand-in for "ant" (it builds a job whose class bytes are the hash of
# the source files), a local copy of the repository, and deliberate faults. Every fault must be caught.
# Usage: bash m481-rehearse.sh KITDIR PATCH_LF PATCH_CRLF OLD_PATCH_LF COMMIT LOCAL_CLONE_OF_THE_REPO
set -uo pipefail
KIT="$1"; PATCH="$2"; PATCHCRLF="$3"; OLDPATCH="$4"; COMMIT="$5"; SRC="$6"; R=$(mktemp -d); cd "$R"
SHA=$(sha256sum "$PATCH" | cut -c1-64); BLOB=$(git hash-object "$PATCH")
git clone -q --bare "$SRC" origin.git && git --git-dir=origin.git branch -f feat/tee-hadoop-cluster "$COMMIT"
cat > fake-ant <<'EOA'
#!/bin/bash
if [ "$1" = "-version" ]; then echo "Apache Ant(TM) version 1.10.12 (stand-in)"; exit 0; fi
python3 - <<'PY'
import hashlib, io, os, zipfile
root = os.getcwd(); out = os.path.join(root, "runtime", "deploy"); os.makedirs(out, exist_ok=True)
def jar(files):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            zi = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED; z.writestr(zi, data)
    return b.getvalue()
def classes(base):
    d = {}
    for dp, _, fs in os.walk(base):
        for f in fs:
            if f.endswith(".java"):
                d[os.path.relpath(os.path.join(dp, f), base)[:-5] + ".class"] = hashlib.sha256(open(os.path.join(dp, f), "rb").read()).hexdigest().encode()
    return d
entries = {"lib/apache-nutch-1.22.jar": jar(classes(os.path.join(root, "src/java")))}
pl = os.path.join(root, "src/plugin")
for p in sorted(os.listdir(pl)):
    sj = os.path.join(pl, p, "src/java")
    if os.path.isdir(sj): entries["classes/plugins/%s/%s.jar" % (p, p)] = jar(classes(sj))
with zipfile.ZipFile(os.path.join(out, "apache-nutch-1.22.job"), "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in sorted(entries.items()):
        zi = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED; z.writestr(zi, data)
PY
echo "BUILD SUCCESSFUL"
EOA
chmod +x fake-ant; export M481_REPO="$R/origin.git" M481_ANT="$R/fake-ant" M481_SKIP_JAVA=1 M481_SKIP_WRAPPER=1
mk() { git clone -q --branch feat/tee-hadoop-cluster origin.git "$1" && (cd "$1" && git checkout -q "$COMMIT"); }
mk ref && (cd ref && "$R/fake-ant" runtime >/dev/null); cp ref/runtime/deploy/apache-nutch-1.22.job run10.job
mk x2 && (cd x2 && echo "// changed" >> src/java/org/apache/nutch/crawl/Generator.java && "$R/fake-ant" runtime >/dev/null); cp x2/runtime/deploy/apache-nutch-1.22.job run10-changed.job
res() { if grep -q "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted $2)"; fail=1; fi; }
fail=0
B() { M481_RUN10_JOB="$R/run10.job" bash "$KIT/ops/attested/m481-build.sh" "$@"; }
B "$PATCH" "$SHA" "$COMMIT" "$R/w1" >"$R/out.txt" 2>&1; res "T1 happy path" "M481-BUILD-OK"
M481_PATCH_BLOB="$BLOB" B "$PATCH" "$SHA" "$COMMIT" "$R/w1b" >"$R/out.txt" 2>&1; res "T1b happy path with the git blob id pinned too" "git blob id equals the committed one"
M481_RUN10_JOB="$R/run10-changed.job" bash "$KIT/ops/attested/m481-build.sh" "$PATCH" "$SHA" "$COMMIT" "$R/w2" >"$R/out.txt" 2>&1; res "T2 the run-10 job differs from a clean build" "M481-BUILD-FAILED"
B "$PATCHCRLF" "$SHA" "$COMMIT" "$R/w3" >"$R/out.txt" 2>&1; res "T3 patch with Windows line endings" "M481-BUILD-STOP: patch SHA-256 is"
cp "$PATCH" p4.patch && sed -i '0,/CustodyReceipt/s//CustodyReceipu/' p4.patch
B p4.patch "$SHA" "$COMMIT" "$R/w4" >"$R/out.txt" 2>&1; res "T4 patch changed by one character" "M481-BUILD-STOP: patch SHA-256 is"
B "$PATCH" "$SHA" 0123456789abcdef0123456789abcdef01234567 "$R/w5" >"$R/out.txt" 2>&1; res "T5 commit not in the branch" "M481-BUILD-STOP: commit 0123456789abcdef0123456789abcdef01234567 not found"
mk x6 && (cd x6 && git apply "$PATCH" && echo "// sneaked in" >> src/java/org/apache/nutch/crawl/Generator.java && "$R/fake-ant" runtime >/dev/null)
python3 "$KIT/ops/attested/m481_job_diff.py" run10.job x6/runtime/deploy/apache-nutch-1.22.job "$PATCH" >"$R/out.txt" 2>&1; res "T6 an unrelated change in the patched build" "JOB-DIFF-UNEXPECTED"
python3 "$KIT/ops/attested/m481_job_diff.py" run10.job run10.job "$PATCH" >"$R/out.txt" 2>&1; res "T7 the patch is not in the job" "JOB-DIFF-PATCH-NOT-IN-JOB"
mk x8 && (cd x8 && git apply "$PATCH" && rm src/java/org/commoncrawl/util/TcCanonical.java && "$R/fake-ant" runtime >/dev/null)
python3 "$KIT/ops/attested/m481_job_diff.py" run10.job x8/runtime/deploy/apache-nutch-1.22.job "$PATCH" >"$R/out.txt" 2>&1; res "T8 one new class missing" "MISSING new class"
( cd "$KIT" && M481_RUN10_JOB="$R/run10.job" bash ops/attested/m481-build.sh patch/source-receipt-841c1d3.lf.patch "$SHA" "$COMMIT" "$R/w12" ) >"$R/out.txt" 2>&1; res "T12 the exact command used on the master: a RELATIVE patch path from the kit folder" "M481-BUILD-OK"
( cd "$R" && M481_RUN10_JOB="$R/run10.job" bash "$KIT/ops/attested/m481-build.sh" "$PATCH" "$SHA" "$COMMIT" w13 ) >"$R/out.txt" 2>&1; res "T13 a RELATIVE work folder" "M481-BUILD-OK"
B "$OLDPATCH" "$SHA" "$COMMIT" "$R/w9" >"$R/out.txt" 2>&1; res "T9 the OLD key-free patch offered against the new pinned fingerprint" "M481-BUILD-STOP: patch SHA-256 is"
M481_PATCH_BLOB=0000000000000000000000000000000000000000 B "$PATCH" "$SHA" "$COMMIT" "$R/w10" >"$R/out.txt" 2>&1; res "T10 a wrong git blob id" "M481-BUILD-STOP: git blob id of the patch is"
python3 "$KIT/ops/attested/m481_job_diff.py" run10.job "$R/w1/patched/runtime/deploy/apache-nutch-1.22.job" "$PATCH" >"$R/out.txt" 2>&1; res "T11 the happy-path job: 9 changed, 2 new" "JOB-DIFF-ONLY-THE-PATCH (changed 9, new 2, removed 0, unexpected 0)"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: the happy path passes, all 9 faults are caught, and both relative-path runs pass" || echo "REHEARSAL-FAIL"
