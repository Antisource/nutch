#!/usr/bin/env bash
# Milestone 5, baby step 5.1.1, part 2: build the job with signed records and the wrapper jar from the scratch tree of part 1.
# Nothing on the cluster is touched: no daemon, no installed jar, no setting, no HDFS path. The new jar stays in the work folder.
#
#   bash ops/attested/m511-build.sh TREE BASEJOB BASEJOB_SHA256 OUR_PATCH [WORKDIR]
#     TREE         the scratch tree of part 1 (default ~/m511/tree): the branch tip with her patch and ours applied
#     BASEJOB      the job that ran in 4.8.1 (the patched job with her receipts, ~/m481/patched/runtime/deploy/apache-nutch-1.22.job)
#     BASEJOB_SHA256  its pinned SHA-256
#     OUR_PATCH    the wrapper patch of step 5.1.1 (it names the classes that may differ)
#     WORKDIR      default ~/m511b (must not exist yet)
# Steps: check the tools, the tree (it is exactly base + her patch + ours) and the base job; build the job with ant; compare it
# with the base job entry by entry (only the classes of our patch may differ); build the wrapper jar from the job's classes and
# compare it class by class with the jar that is installed now (only our classes may differ); prove that the jar's key tool runs.
# Test hooks (used only to rehearse this script away from the cluster): M511B_ANT, M511B_INSTALLED, M511B_SKIP_JAVA=1.
set -uo pipefail

U="usage: $0 TREE BASEJOB BASEJOB_SHA256 OUR_PATCH [WORKDIR]"
TREE="${1:?$U}"; BASEJOB="${2:?$U}"; BASE_SHA="${3:?$U}"; OUR="${4:?$U}"; W="${5:-$HOME/m511b}"
ANT="${M511B_ANT:-ant}"; INSTALLED="${M511B_INSTALLED:-$HOME/hadoop/share/hadoop/common/lib/attested-hdfs.jar}"
for v in TREE BASEJOB OUR W; do case "${!v}" in /*) ;; *) printf -v "$v" '%s' "$PWD/${!v}" ;; esac; done

bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M511B-BUILD-STOP: $*"; exit 1; }
fp()   { sha256sum "$1" | cut -c1-64; }

[ -e "$W" ] && { echo "M511B-BUILD-STOP: $W exists already; remove it or give another folder" >&2; exit 1; }
mkdir -p "$W/logs" "$W/evidence" || exit 1
say "m511-build: $(date -u +%FT%TZ) on $(hostname)   tree=$TREE"
avail=$(df -Pk "$W" | awk 'NR==2{print $4}'); [ "${avail:-0}" -ge 3000000 ] && ok "free disk space: $((avail/1024)) MB" || stop "less than 3 GB free in $W"
say "== tools"
command -v git >/dev/null && ok "git" || stop "git is missing"
command -v python3 >/dev/null && ok "python3" || stop "python3 is missing"
"$ANT" -version >"$W/logs/ant-version.txt" 2>&1 && ok "ant: $(head -1 "$W/logs/ant-version.txt")" || stop "ant is missing"
if [ "${M511B_SKIP_JAVA:-0}" = 1 ]; then ok "java check skipped (rehearsal)"; else
  java -version >"$W/logs/java-version.txt" 2>&1; grep -q 'version "11\.' "$W/logs/java-version.txt" && ok "java: $(head -1 "$W/logs/java-version.txt")" || stop "java 11 is required: $(head -1 "$W/logs/java-version.txt")"; fi

say "== the inputs"
[ -f "$OUR" ] || stop "patch file not found: $OUR"
[ -d "$TREE/.git" ] || stop "the tree of part 1 is not there: $TREE"
[ -f "$BASEJOB" ] || stop "base job not found: $BASEJOB"
[ "$(fp "$BASEJOB")" = "$BASE_SHA" ] && ok "the base job is the pinned one (${BASE_SHA:0:16}..., $(stat -c %s "$BASEJOB") bytes)" || stop "the base job SHA-256 is $(fp "$BASEJOB" | cut -c1-16), the pinned one is ${BASE_SHA:0:16}"
git -C "$TREE" apply -R --check "$OUR" >"$W/logs/tree-check.log" 2>&1 && ok "the tree holds exactly the changes of our patch (it reverses cleanly)" || stop "the tree does not hold our patch (see $W/logs/tree-check.log)"
n=$(git -C "$TREE" status --porcelain | grep -v __pycache__ | wc -l); [ "$n" = 20 ] && ok "the tree has 20 changed or new files (her patch 11, ours 9)" || stop "the tree has $n changed or new files, expected 20"
ok "tree commit: $(git -C "$TREE" rev-parse HEAD)"
[ ! -e "$TREE/runtime/deploy/apache-nutch-1.22.job" ] && ok "the tree has not been built yet" || say "   note: the tree has a job file from an earlier build; ant will replace it"

say "== build the job (this takes minutes)"
s=$(date +%s); ( cd "$TREE" && "$ANT" runtime ) >"$W/logs/ant.log" 2>&1; rc=$?; e=$(date +%s)
NEW="$TREE/runtime/deploy/apache-nutch-1.22.job"
if [ $rc -eq 0 ] && grep -q "BUILD SUCCESSFUL" "$W/logs/ant.log" && [ -f "$NEW" ]; then ok "BUILD SUCCESSFUL in $((e-s)) s"; else tail -12 "$W/logs/ant.log" | sed 's/^/   | /'; stop "the build failed (see $W/logs/ant.log)"; fi
say "   new job:  $(fp "$NEW" | cut -c1-16)...  $(stat -c %s "$NEW") bytes"
say "   base job: ${BASE_SHA:0:16}...  $(stat -c %s "$BASEJOB") bytes"

say "== what does our patch change in the job?"
python3 - "$OUR" "$W/job-patch.txt" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.split(r"(?m)^(?=diff --git )", text)
keep = [b for b in blocks if b.startswith("diff --git a/src/java/")]
open(sys.argv[2], "w", encoding="utf-8").write("".join(keep))
print("%d of %d files of the patch are in the job (the others are tests)" % (len(keep), len([b for b in blocks if b.startswith("diff --git")])))
PY
python3 "$TREE/ops/kits/m481-build/ops/attested/m481_job_diff.py" "$BASEJOB" "$NEW" "$W/job-patch.txt" >"$W/logs/job-diff.log" 2>&1; rc=$?
grep -E "^(the patch names|entries|changed:)|^JOB-DIFF" "$W/logs/job-diff.log" | sed "s/^/      /" | tee -a "$W/summary.txt"
grep -E "UNEXPECTED|MISSING|NOT CHANGED" "$W/logs/job-diff.log" | head -12 | tee -a "$W/summary.txt"
[ $rc -eq 0 ] && ok "only the classes of the patch differ from the job of 4.8.1, and all of them are there" || no "the new job is not 'the 4.8.1 job plus exactly our patch' (see $W/logs/job-diff.log)"

say "== the wrapper jar"
bash "$TREE/ops/attested/wrapper-jar.sh" build "$NEW" "$W/attested-hdfs.jar" >"$W/logs/wrapper-build.log" 2>&1 && ok "built from the job's classes: $(grep 'classes written' "$W/logs/wrapper-build.log"); sha256 $(fp "$W/attested-hdfs.jar" | cut -c1-16)..." || { tail -3 "$W/logs/wrapper-build.log"; stop "the wrapper jar could not be built (see $W/logs/wrapper-build.log)"; }
grep -q "CLASSES-SAME" "$W/logs/wrapper-build.log" && ok "$(grep CLASSES-SAME "$W/logs/wrapper-build.log")" || no "the new jar does not equal the job's wrapper classes"
if [ -f "$INSTALLED" ]; then
  python3 - "$INSTALLED" "$W/attested-hdfs.jar" <<'PY' >"$W/logs/jar-compare.log"; rc=$?
import hashlib, re, sys, zipfile
def d(p):
    z = zipfile.ZipFile(p); return {n: hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist() if n.endswith(".class")}
a, b = d(sys.argv[1]), d(sys.argv[2])
changed = sorted(n for n in set(a) & set(b) if a[n] != b[n]); new = sorted(set(b) - set(a)); removed = sorted(set(a) - set(b))
print("installed jar: %d classes, new jar: %d classes" % (len(a), len(b)))
print("changed: %d   new: %d   removed: %d" % (len(changed), len(new), len(removed)))
for n in changed: print("   changed  " + n)
for n in new: print("   new      " + n)
for n in removed: print("   REMOVED  " + n)
allowed = re.compile(r"org/apache/nutch/attested/(AttestedHdfsFileSystem(\$.*)?|AttestedSidecar(\$.*)?|AttestedKeys|AttestedRecordCodec(\$.*)?|AttestedSignatures|TestKeys|AttestedKeyTool)\.class")
odd = [n for n in changed + new if not allowed.fullmatch(n)]
for n in odd: print("   UNEXPECTED  " + n)
need = ["AttestedKeys", "AttestedRecordCodec", "AttestedSignatures", "TestKeys", "AttestedKeyTool"]
miss = [x for x in need if "org/apache/nutch/attested/%s.class" % x not in b]
for x in miss: print("   MISSING  " + x)
ok = not removed and not odd and not miss and "org/apache/nutch/attested/AttestedHdfsFileSystem.class" in changed and "org/apache/nutch/attested/AttestedSidecar.class" in changed
print("JAR-COMPARE-ONLY-OUR-CLASSES" if ok else "JAR-COMPARE-UNEXPECTED"); sys.exit(0 if ok else 1)
PY
  grep -E "^(installed|changed)" "$W/logs/jar-compare.log" | sed "s/^/      /" | tee -a "$W/summary.txt"
  [ $rc -eq 0 ] && ok "against the installed jar only our classes differ (the wrapper's other classes are unchanged)" || { grep -E "UNEXPECTED|MISSING|REMOVED" "$W/logs/jar-compare.log" | head -8 | tee -a "$W/summary.txt"; no "the new jar differs from the installed one in more than our classes (see $W/logs/jar-compare.log)"; }
else
  no "no installed jar at $INSTALLED to compare with"
fi
java -cp "$W/attested-hdfs.jar" org.apache.nutch.attested.AttestedKeyTool generate "$W/sanity-key.txt" >"$W/logs/keytool.log" 2>&1 && java -cp "$W/attested-hdfs.jar" org.apache.nutch.attested.AttestedKeyTool info "$W/sanity-key.txt" >>"$W/logs/keytool.log" 2>&1 \
  && grep -q "can sign: true" "$W/logs/keytool.log" && ok "the jar's key tool runs: $(grep -o 'key id TEST-[0-9a-f]*' "$W/logs/keytool.log" | head -1) (a throw-away key, deleted below)" || no "the jar's key tool does not run (see $W/logs/keytool.log)"
rm -f "$W/sanity-key.txt"

cp "$OUR" "$W/job-patch.txt" "$W/evidence/" 2>/dev/null
{ echo "tree commit $(git -C "$TREE" rev-parse HEAD)"; echo "base job   $(fp "$BASEJOB")  $(stat -c %s "$BASEJOB")"; echo "new job    $(fp "$NEW")  $(stat -c %s "$NEW")"; echo "new jar    $(fp "$W/attested-hdfs.jar")  $(stat -c %s "$W/attested-hdfs.jar")"; [ -f "$INSTALLED" ] && echo "installed  $(fp "$INSTALLED")  $(stat -c %s "$INSTALLED")"; echo "patch      $(fp "$OUR")"; } > "$W/evidence/fingerprints.txt"
cp "$NEW" "$W/new-apache-nutch-1.22.job"
if [ $bad -eq 0 ]; then say "M511B-BUILD-OK (the job and the wrapper jar are built and are the 4.8.1 stack plus exactly our patch; nothing on the cluster was touched)"; else say "M511B-BUILD-FAILED ($bad): see the FAIL lines above"; fi
cp "$W/summary.txt" "$W/logs/"*.log "$W/evidence/" 2>/dev/null
( cd "$W/evidence" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
( cd "$W" && tar czf "$W/../evidence-m511b-build.tar.gz" evidence && sha256sum "$W/../evidence-m511b-build.tar.gz" | cut -c1-64 )
[ $bad -eq 0 ]
