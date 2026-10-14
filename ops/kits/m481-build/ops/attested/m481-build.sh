#!/usr/bin/env bash
# Milestone 4, baby step 4.8.1 (part 1): build the job with the teammate's source-receipt patch in a scratch folder
# and prove exactly what the patch changed. Nothing on the cluster is touched: no daemon, no Hadoop file, no HDFS path.
#
# Usage (on the master; needs git, ant, Java 11, python3, and this folder's ops/attested files):
#   bash ops/attested/m481-build.sh PATCH PATCH_SHA256 COMMIT [WORKDIR]
#     PATCH         the patch file with Unix line endings
#     PATCH_SHA256  the full SHA-256 the patch must have (the pinned version); optional M481_PATCH_BLOB also pins its git blob id
#     COMMIT   the full commit id of branch feat/tee-hadoop-cluster to build (checked after the clone)
#     WORKDIR  default ~/m481 (must not exist yet)
# Steps: check the tools and the patch; clone the branch twice (base, patched); apply the patch to one; build both with
# "ant runtime"; compare the base job with the job that ran in run 10 (the build must reproduce it); compare the
# patched job with the base job (only the patch's classes may differ); check that the installed wrapper jar still equals
# the wrapper classes of the patched job; write a summary and an evidence bundle.
# The files the patch must touch, and which are new, are read from the patch itself (nothing is written into this script).
# Test hooks (used only to rehearse this script away from the cluster): M481_REPO, M481_BRANCH, M481_ANT,
# M481_RUN10_JOB, M481_SKIP_JAVA=1, M481_SKIP_WRAPPER=1.
set -uo pipefail

U="usage: $0 PATCH PATCH_SHA256 COMMIT [WORKDIR]"; PATCH="${1:?$U}"; EXPECT_SHA="${2:?$U}"; COMMIT="${3:?$U}"; W="${4:-$HOME/m481}"
REPO="${M481_REPO:-https://github.com/Antisource/nutch.git}"; BRANCH="${M481_BRANCH:-feat/tee-hadoop-cluster}"
ANT="${M481_ANT:-ant}"; RUN10="${M481_RUN10_JOB:-$HOME/a14-work/runtime/deploy/apache-nutch-1.22.job}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# full paths: the script changes folders (git -C ...), so a relative patch or work folder would not be found
case "$PATCH" in /*) ;; *) PATCH="$PWD/$PATCH" ;; esac
case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
RUN10_IN="$RUN10"; case "$RUN10" in /*) ;; *) RUN10="$PWD/$RUN10" ;; esac

bad=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
ok()   { say "   ok:   $*"; }
no()   { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M481-BUILD-STOP: $*"; exit 1; }
fp()   { sha256sum "$1" | cut -c1-64; }

[ -e "$W" ] && { echo "M481-BUILD-STOP: $W exists already; remove it or give another folder" >&2; exit 1; }
mkdir -p "$W/logs" "$W/evidence" || exit 1
say "m481-build: $(date -u +%FT%TZ) on $(hostname)   patch=$PATCH   commit=$COMMIT"

avail=$(df -Pk "$W" | awk 'NR==2{print $4}'); [ "${avail:-0}" -ge 3000000 ] && ok "free disk space: $((avail/1024)) MB" || stop "less than 3 GB free in $W (two clones and two builds need about 3 GB)"
say "== tools"
command -v git >/dev/null && ok "git" || stop "git is missing"
command -v python3 >/dev/null && ok "python3" || stop "python3 is missing"
"$ANT" -version >"$W/logs/ant-version.txt" 2>&1 && ok "ant: $(head -1 "$W/logs/ant-version.txt")" || stop "ant is missing"
if [ "${M481_SKIP_JAVA:-0}" = 1 ]; then ok "java check skipped (rehearsal)"; else
  java -version >"$W/logs/java-version.txt" 2>&1; grep -q 'version "11\.' "$W/logs/java-version.txt" && ok "java: $(head -1 "$W/logs/java-version.txt")" || stop "java 11 is required: $(head -1 "$W/logs/java-version.txt")"; fi

say "== the patch"
[ -f "$PATCH" ] || stop "patch file not found: $PATCH"
[ "$(fp "$PATCH")" = "$EXPECT_SHA" ] && ok "SHA-256 is the pinned one (${EXPECT_SHA:0:16}...)" || stop "patch SHA-256 is $(fp "$PATCH" | cut -c1-16), the pinned one is ${EXPECT_SHA:0:16} (a different version, or Windows line endings: use the Unix-endings copy)"
if [ -n "${M481_PATCH_BLOB:-}" ]; then [ "$(git hash-object "$PATCH")" = "$M481_PATCH_BLOB" ] && ok "git blob id equals the committed one (${M481_PATCH_BLOB:0:12}...)" || stop "git blob id of the patch is $(git hash-object "$PATCH"), expected $M481_PATCH_BLOB"; fi
python3 - "$PATCH" <<'PY' && ok "Unix line endings (no carriage return)" || stop "the patch has carriage returns"
import sys; b = open(sys.argv[1], "rb").read(); sys.exit(1 if b"\r" in b else 0)
PY
n=$(grep -c '^+++ b/' "$PATCH"); nn=$(grep -c '^--- /dev/null' "$PATCH"); [ "$n" -ge 1 ] && ok "the patch touches $n files ($nn new, $((n-nn)) existing)" || stop "no file found in the patch"

say "== clone the branch twice (base and patched)"
git clone -q --branch "$BRANCH" "$REPO" "$W/base" >"$W/logs/clone.log" 2>&1 || stop "clone failed (see $W/logs/clone.log)"
git -C "$W/base" checkout -q "$COMMIT" >>"$W/logs/clone.log" 2>&1 || stop "commit $COMMIT not found in the clone"
[ "$(git -C "$W/base" rev-parse HEAD)" = "$COMMIT" ] && ok "base is at $COMMIT" || stop "base is not at $COMMIT"
cp -a "$W/base" "$W/patched" && ok "patched is a copy of base"

say "== apply the patch to the copy"
git -C "$W/patched" apply --check "$PATCH" >"$W/logs/apply.log" 2>&1 && ok "git apply --check passes" || { head -6 "$W/logs/apply.log" | sed 's/^/   | /'; stop "the patch does not apply (see $W/logs/apply.log)"; }
git -C "$W/patched" apply "$PATCH" >>"$W/logs/apply.log" 2>&1 || stop "git apply failed"
got=$(git -C "$W/patched" status --porcelain | sed -E 's/^.. //' | sort | tr '\n' ' '); want=$(grep '^+++ b/' "$PATCH" | sed 's#^+++ b/##' | sort | tr '\n' ' ')
[ "$got" = "$want" ] && ok "exactly the $n files named in the patch changed ($nn new)" || no "the changed files are not the files named in the patch: $got"
[ -z "$(git -C "$W/base" status --porcelain)" ] && ok "base is untouched" || no "base has local changes"

say "== build both (this takes minutes)"
for v in base patched; do
  s=$(date +%s); ( cd "$W/$v" && "$ANT" runtime ) >"$W/logs/ant-$v.log" 2>&1; rc=$?; e=$(date +%s)
  if [ $rc -eq 0 ] && grep -q "BUILD SUCCESSFUL" "$W/logs/ant-$v.log" && [ -f "$W/$v/runtime/deploy/apache-nutch-1.22.job" ]; then ok "$v: BUILD SUCCESSFUL in $((e-s)) s"; else stop "$v: the build failed (see $W/logs/ant-$v.log)"; fi
done
BJ="$W/base/runtime/deploy/apache-nutch-1.22.job"; PJ="$W/patched/runtime/deploy/apache-nutch-1.22.job"
say "   base job:    $(fp "$BJ" | cut -c1-16)...  $(stat -c %s "$BJ") bytes"
say "   patched job: $(fp "$PJ" | cut -c1-16)...  $(stat -c %s "$PJ") bytes"

say "== does a clean build of the base reproduce the job of run 10?"
if [ -f "$RUN10" ]; then
  say "   run 10 job:  $(fp "$RUN10" | cut -c1-16)...  $(stat -c %s "$RUN10") bytes"
  python3 "$W/base/ops/attested/job_sha_compare.py" "$RUN10" "$BJ" >"$W/logs/compare-base-run10.log" 2>&1; tail -1 "$W/logs/compare-base-run10.log" | tee -a "$W/summary.txt" >/dev/null
  tail -1 "$W/logs/compare-base-run10.log" | grep -q "^JOBS-SAME-BY-SHA256" && ok "the base build equals the job of run 10 entry by entry" || no "the base build differs from the job of run 10 (see $W/logs/compare-base-run10.log)"
else
  say "   SKIPPED: the job of run 10 was not found at $RUN10 (the reproducibility of the build is then not shown)"; bad=$((bad+1))
fi

say "== what does the patch change in the job?"
python3 "$HERE/m481_job_diff.py" "$BJ" "$PJ" "$PATCH" >"$W/logs/compare-patched-base.log" 2>&1; rc=$?
grep -E "^(the patch names|entries|changed:)|^JOB-DIFF" "$W/logs/compare-patched-base.log" | tee -a "$W/summary.txt" >/dev/null
grep -E "UNEXPECTED|MISSING|NOT CHANGED" "$W/logs/compare-patched-base.log" | head -12 | tee -a "$W/summary.txt"
[ $rc -eq 0 ] && ok "only the classes of the patch differ, and all of them are there" || no "the patched job is not 'base plus exactly the patch' (see $W/logs/compare-patched-base.log)"

say "== is the installed wrapper jar still the wrapper of the patched job?"
if [ "${M481_SKIP_WRAPPER:-0}" = 1 ]; then ok "skipped (rehearsal)"; else
  bash "$W/patched/ops/attested/wrapper-jar.sh" verify "$PJ" >"$W/logs/wrapper-verify.log" 2>&1; cat "$W/logs/wrapper-verify.log" | tail -6 | tee -a "$W/summary.txt" >/dev/null
  grep -q "CLASSES-SAME" "$W/logs/wrapper-verify.log" && ok "CLASSES-SAME: the wrapper classes of the patched job equal the installed jar" || no "the installed wrapper jar differs from the patched job's wrapper classes"
fi

say "== evidence bundle"
cp "$PATCH" "$W/evidence/"; cp "$W/summary.txt" "$W/logs/"*.log "$W/logs/"*.txt "$W/evidence/" 2>/dev/null
{ echo "base job    $(fp "$BJ")  $(stat -c %s "$BJ")"; echo "patched job $(fp "$PJ")  $(stat -c %s "$PJ")"; echo "patch       $(fp "$PATCH")"; echo "commit      $COMMIT"; } >"$W/evidence/fingerprints.txt"
( cd "$W/evidence" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum >SHA256SUMS )
( cd "$W" && tar czf evidence-m481-build.tar.gz evidence && sha256sum evidence-m481-build.tar.gz | tee evidence-m481-build.sha256 )
say "   files in the bundle: $(grep -c . "$W/evidence/SHA256SUMS")"
if [ $bad -eq 0 ]; then say "M481-BUILD-OK"; exit 0; else say "M481-BUILD-FAILED ($bad)"; exit 1; fi
