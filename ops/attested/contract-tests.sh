#!/usr/bin/env bash
# Hadoop's file-system contract tests against the wrapper, with plain HDFS as the control
# (Milestone 4, step 4.4). Run on the master, from any folder.
#
# The same tests run twice on the real cluster: once through the plain HDFS client (the control)
# and once through the wrapper, whose classes are taken from the job file that ran the crawl.
# contract_compare.py then shows which tests behave differently through the wrapper.
#
# SAFETY: Hadoop's contract tests delete their test folder after every test. The folder is
# /user/<you>/contract-tests-m44 by default; the script refuses to start if it already exists or
# if its name is not dedicated, and the contract class refuses it again. The root-directory tests
# are not part of the suite.
#
# Usage: ops/attested/contract-tests.sh OUTDIR
# Settings (environment): ATTESTED_CONTRACT_URI (default hdfs://hadoop-master:9000),
#   ATTESTED_CONTRACT_DIR, ATTESTED_JOB (default ~/m3-build/runtime/deploy/apache-nutch-1.22.job),
#   EXPECT_JOB (a job fingerprint prefix; the run stops if the job differs), HADOOP_HOME (default ~/hadoop),
#   EXPECT_FILES (a list of 'sha256  path' lines, paths relative to the folder that holds ops/; the run stops
#   unless every file matches).
set -uo pipefail
OUT="${1:?usage: contract-tests.sh OUTDIR}"
H="${HADOOP_HOME:-$HOME/hadoop}"
URI="${ATTESTED_CONTRACT_URI:-hdfs://hadoop-master:9000}"
DIR="${ATTESTED_CONTRACT_DIR:-/user/$(id -un)/contract-tests-m44}"
JOB="${ATTESTED_JOB:-$HOME/m3-build/runtime/deploy/apache-nutch-1.22.job}"
SRC="$(cd "$(dirname "$0")" && pwd)/contract"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIBS="$HOME/contract-libs"; BUILD="$HOME/contract-build"
ASSERTJ=assertj-core-3.12.2.jar
ASSERTJ_URL=https://repo1.maven.org/maven2/org/assertj/assertj-core/3.12.2

die() { echo "STOP: $*" >&2; exit 1; }

dedicated() {  # an absolute path of at least three parts whose last part contains "contract-tests"
  case "$1" in /*) ;; *) return 1 ;; esac
  local p="${1#/}"; local n; n=$(awk -F/ '{print NF}' <<< "$p")
  [ "$n" -ge 3 ] && [[ "${p##*/}" == *contract-tests* ]]
}
dedicated "$DIR" || die "the test folder '$DIR' is not dedicated (needs three parts and 'contract-tests' in the last one)"
[ -x "$H/bin/hadoop" ] || die "no Hadoop in $H"
[ -f "$JOB" ] || die "no job file at $JOB"
JOBFP=$(sha256sum "$JOB" | cut -c1-16)
if [ -n "${EXPECT_FILES:-}" ]; then
  [ -f "$EXPECT_FILES" ] || die "no list of file fingerprints at $EXPECT_FILES"
  want=$(grep -c . "$EXPECT_FILES"); ok=$(cd "$ROOT" && sha256sum -c "$EXPECT_FILES" 2>&1 | grep -c ': OK$')
  [ "$ok" = "$want" ] && [ "$want" -gt 0 ] || die "only $ok of $want files match the list $EXPECT_FILES; nothing was run"
  echo "== files: $ok of $want identical to the list"
fi
[ -z "${EXPECT_JOB:-}" ] || [[ "$JOBFP" == "$EXPECT_JOB"* ]] || die "the job file is $JOBFP, expected $EXPECT_JOB"
if "$H/bin/hdfs" dfs -test -e "$DIR"; then die "the test folder $DIR already exists; the tests would delete it. Remove it yourself if it is yours, or choose another with ATTESTED_CONTRACT_DIR"; fi
[ ! -e "$OUT/results-plain.tsv" ] && [ ! -e "$OUT/results-wrapped.tsv" ] || die "$OUT already holds results; use a new folder"
mkdir -p "$OUT" "$LIBS" "$BUILD/classes"
echo "== contract tests: uri $URI  test folder $DIR  job $JOBFP"

echo "== libraries"
if [ ! -f "$LIBS/$ASSERTJ" ]; then
  curl -fsS -m 180 -o "$LIBS/$ASSERTJ" "$ASSERTJ_URL/$ASSERTJ" && curl -fsS -m 60 -o "$LIBS/$ASSERTJ.sha1" "$ASSERTJ_URL/$ASSERTJ.sha1" || die "could not download $ASSERTJ"
fi
[ "$(cut -d' ' -f1 "$LIBS/$ASSERTJ.sha1")" = "$(sha1sum "$LIBS/$ASSERTJ" | cut -d' ' -f1)" ] || die "$ASSERTJ does not match the sha1 published next to it"
CT="$H/share/hadoop/common/hadoop-common-3.4.3-tests.jar"
JUNIT="$H/share/hadoop/tools/lib/junit-4.13.2.jar"; HAM="$H/share/hadoop/tools/lib/hamcrest-core-1.3.jar"
for f in "$CT" "$JUNIT" "$HAM"; do [ -f "$f" ] || die "missing $f"; done
{ echo "date: $(date -u +%FT%TZ)"; echo "java: $(java -version 2>&1 | head -1)"
  for f in "$JOB" "$CT" "$JUNIT" "$HAM" "$LIBS/$ASSERTJ"; do echo "$(sha256sum "$f" | cut -c1-64)  $f"; done; } | tee "$OUT/libs.txt"

HCP="$("$H/bin/hadoop" classpath)"
CP="$BUILD/classes:$CT:$JOB:$HCP:$JUNIT:$HAM:$LIBS/$ASSERTJ"

echo "== compile"
rm -rf "$BUILD/classes" && mkdir -p "$BUILD/classes/contract"
javac -nowarn -source 11 -target 11 -d "$BUILD/classes" -cp "$CP" "$SRC"/*.java > "$OUT/compile.txt" 2>&1 || { cat "$OUT/compile.txt"; die "compilation failed (output above and in $OUT/compile.txt)"; }
cp "$SRC/resources/contract/attested-hdfs.xml" "$BUILD/classes/contract/"
CLASSES=$(cd "$SRC" && ls Test*.java | sed 's/\.java$//; s/^/org.apache.nutch.attested.contracttest./' | tr '\n' ' ')
echo "compiled; test classes: $(echo $CLASSES | wc -w)"

run_mode() {  # run_mode MODE WRAPPER(true|false)
  echo "== run: $1"
  timeout 2400 java -cp "$CP" -Dattested.contract.uri="$URI" -Dattested.contract.dir="$DIR" \
    -Dattested.contract.wrapper="$2" -Dattested.contract.audit.dir="$OUT/audit-$1" -Dattested.contract.records.dir="$OUT/records-$1" \
    org.apache.nutch.attested.contracttest.ContractRunner "$OUT/results-$1.tsv" $CLASSES > "$OUT/console-$1.txt" 2>&1
  echo "   exit code $?  $(grep -E '^RUN-DONE' "$OUT/console-$1.txt" | tail -1)"
  if "$H/bin/hdfs" dfs -test -e "$DIR"; then echo "   the test folder was left behind; removing it"; "$H/bin/hdfs" dfs -rm -r -f "$DIR" > /dev/null; fi
}
run_mode plain false
run_mode wrapped true

echo "== comparison"
python3 "$(dirname "$0")/contract_compare.py" "$OUT/results-plain.tsv" "$OUT/results-wrapped.tsv" | tee "$OUT/comparison.txt"
echo "wrapper log files written during the tests: $(ls "$OUT/audit-wrapped" 2>/dev/null | wc -l) audit, $(ls "$OUT/records-wrapped" 2>/dev/null | wc -l) records"
