#!/usr/bin/env bash
# Rehearsal of m512c-run.sh on a fake cluster (fake hdfs, yarn, jps, audit and wrapper tools, and a fake crawl that records
# its arguments), using the REAL ops/run-crawl.sh, the REAL key tool and the REAL verification tool (M512Tools) on signed trees that the fake hdfs
# makes with the real wrapper classes. Usage: bash m512c-run-rehearse.sh KITDIR REPO_CHECKOUT JARS WORKOUT TOOLSOUT
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
# hermetic: the script under rehearsal must see only the fake home, never the real installation of the machine it runs on (the master has HADOOP_HOME set;
# the first run of this rehearsal on the master stopped at "core-site.xml is not the wrapped version" because it read the real, plain core-site.xml)
unset HADOOP_HOME HADOOP_CONF_DIR HADOOP_COMMON_HOME HADOOP_HDFS_HOME HADOOP_MAPRED_HOME
KIT="$1"; REPO="$2"; JARS="$3"; WORKOUT="$4"; TOOLSOUT="$5"; R=$(mktemp -d); fail=0; CPJ="$(ls "$JARS"/*.jar | tr '\n' ':')"
printf '#!/bin/bash\nexec java -m jdk.compiler/com.sun.tools.javac.Main "$@"\n' > "$R/javac-standin"; chmod +x "$R/javac-standin"
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -6; fail=1; fi; }
mkfake() {   # $1 = home folder
  local H="$1"; rm -rf "$H" "$R/hdfs" "$R/tmp"; mkdir -p "$H/m512/tree/runtime/deploy/bin" "$H/m512/tree/ops/attested" "$H/m512/tree/seeds" "$H/m512b/evidence" "$H/tc-policy" "$H/hadoop/etc/hadoop" "$H/hadoop/logs" "$R/hdfs" "$R/tmp/attested-audit" "$R/tmp/attested-records" "$R/bin"
  cp "$REPO/ops/run-crawl.sh" "$H/m512/tree/ops/"; cp "$REPO/seeds/seed.txt" "$H/m512/tree/seeds/"
  head -c 5000 /dev/urandom > "$H/m512/tree/runtime/deploy/apache-nutch-1.22.job"
  echo "new job    $(sha256sum "$H/m512/tree/runtime/deploy/apache-nutch-1.22.job" | cut -c1-64)  5000" > "$H/m512b/evidence/fingerprints.txt"
  mkdir -p "$H/tc-test-key" "$H/hadoop/share/hadoop/common/lib"; java -cp "$CPJ$WORKOUT" org.apache.nutch.attested.AttestedKeyTool generate "$H/tc-test-key/test-key.txt" >/dev/null
  python3 - "$H" "$WORKOUT" <<'PYJ'
import os, sys, zipfile
h, src = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(h + "/hadoop/share/hadoop/common/lib/attested-hdfs.jar", "w", zipfile.ZIP_DEFLATED)
for root, _, files in os.walk(os.path.join(src, "org/apache/nutch/attested")):
    for f in sorted(files):
        if f.startswith(("AttestedFsSmoke", "SigCoreTest", "M512", "FakeHdfsCli")): continue
        p = os.path.join(root, f); z.write(p, os.path.relpath(p, src))
z.close()
PYJ
  printf "%s\t2026-10-15T00:00:00Z\tcombined crawl\n" "$(whoami)" > "$R/BUSY"
  echo '{"policy":"fake"}' > "$H/tc-policy/policy.json"; sha256sum "$H/tc-policy/policy.json" | cut -c1-64 > "$H/tc-policy/policy.json.sha256"
  echo "<value>org.apache.nutch.attested.AttestedHdfsFileSystem</value>" > "$H/hadoop/etc/hadoop/core-site.xml"
  for i in 1 2 3; do echo "audit line $i" >> "$H/hadoop/logs/hdfs-audit.log"; done
  echo "wrapper log" > "$R/tmp/attested-audit/a.tsv"; echo "record" > "$R/tmp/attested-records/r.tsv"
  cat > "$H/m512/tree/runtime/deploy/bin/crawl" <<'EOC'
#!/bin/bash
printf '%s\n' "$@" > "$R/crawl-args.txt"
mkdir -p "$FAKEHDFS_ROOT/user/$(whoami)/crawl-x"; for i in 1 2 3 4; do echo "crawl event $i" >> "$FAKE_NN_LOG"; done
exit ${FAKE_CRAWL_RC:-0}
EOC
  cat > "$H/m512/tree/ops/attested/audit.sh" <<'EOC'
#!/bin/bash
if [ "$1" = rotate ]; then echo rotated; elif [ "$1" = snapshot ]; then (cd "$FAKEHDFS_ROOT" && find . -mindepth 1 | sed 's#^\./#/#' | awk '{print "d\t0\t0\t"$0}') > "$2"; else exit 2; fi
EOC
  cat > "$H/m512/tree/ops/attested/wrapper-jar.sh" <<'EOC'
#!/bin/bash
[ "${FAKE_WRAPPER_BAD:-0}" = 1 ] && { echo "CLASSES-DIFFER"; exit 1; }; echo "CLASSES-SAME (14 classes identical to the job file)"
EOC
  cat > "$R/bin/hdfs" <<'EOC'
#!/bin/bash
if [ "$1" = getconf ]; then [ "${FAKE_BIND_OFF:-0}" = 1 ] && [ "$3" = attested.folder.binding.enabled ] && exit 1; echo true; exit 0; fi
shift   # dfs
if [ "$1" = -D ]; then shift 2; fi
case "$1" in
  -test) [ -e "$FAKEHDFS_ROOT$3" ] ;;
  -mkdir) mkdir -p "$FAKEHDFS_ROOT$3" ;;
  -put) mkdir -p "$FAKEHDFS_ROOT$3" && cp "$2" "$FAKEHDFS_ROOT$3" ;;
  -get) [ "${FAKE_GET_FAIL:-0}" = 1 ] && { echo "get: simulated failure" >&2; exit 1; }
        java -cp "$FAKE_CP" org.apache.nutch.attested.M512TreeGen "$FAKE_KEY" "$3" "$2" ${FAKE_TREE_BAD:+bad} ;;
esac
EOC
  cat > "$R/bin/yarn" <<'EOC'
#!/bin/bash
if [ "$1" = node ]; then   # the layout of Hadoop's NodeCLI: right-justified columns separated by TAB characters
  echo "Total Nodes:${FAKE_YARN_NODES:-1}"; printf '%16s\t%15s\t%17s\t%28s\n' Node-Id Node-State Node-Http-Address Number-of-Running-Containers
  for i in $(seq 1 ${FAKE_YARN_NODES:-1}); do printf '%16s\t%15s\t%17s\t%28s\n' "hadoop-worker:3504$i" RUNNING "hadoop-worker:8042" 0; done; exit 0; fi
echo "Total number of applications (application-types: [], states: [RUNNING] and tags: []):${FAKE_YARN_APPS:-0}"
printf '%30s\t%20s\t%20s\n' Application-Id Application-Name State
for i in $(seq 1 ${FAKE_YARN_APPS:-0}); do printf '%35s\t%20s\t%20s\n' "application_1791873617149_0${i}999" "nutch fetch" RUNNING; done   # padded with leading spaces, as Hadoop does
EOC
  cat > "$R/bin/jps" <<'EOC'
#!/bin/bash
for d in NameNode ResourceManager; do [ "$d" = "${FAKE_JPS_MISSING:-}" ] || echo "100 $d"; done
[ -n "${FAKE_JPS_SECONDARY:-}" ] && echo "200 SecondaryNameNode"; exit 0
EOC
  chmod +x "$H/m512/tree/runtime/deploy/bin/crawl" "$H/m512/tree/ops/attested/"*.sh "$R/bin/"*
}
export R FAKEHDFS_ROOT="$R/hdfs" FAKE_CP="$CPJ$WORKOUT:$TOOLSOUT"; export M512C_JAVAC="$R/javac-standin" M512C_BUSY="$R/BUSY"; export M512C_HDFS="$R/bin/hdfs" M512C_YARN="$R/bin/yarn" M512C_JPS="$R/bin/jps" M512C_ATT_TMP="$R/tmp"
run() { ( cd "$KIT" && HOME="$R/home" HADOOP_HOME="$R/home/hadoop" HADOOP_CONF_DIR="$R/home/hadoop/etc/hadoop" FAKE_KEY="$R/home/tc-test-key/test-key.txt" FAKE_NN_LOG="$R/home/hadoop/logs/hdfs-audit.log" bash ops/attested/m512c-run.sh "$@" ) >"$R/out.txt" 2>&1; }
mkfake "$R/home"; run run11 on; res "T1 receipts ON (exact invocation: relative script path, from the kit folder)" "M512C-RUN-DONE (run11, mode on"
ARGS_ON=$(cat "$R/crawl-args.txt"); N=$(cat "$R/home/run11/nonce")
echo "$ARGS_ON" | grep -qx -- "tc.receipts.enabled=true" && echo "$ARGS_ON" | grep -qx -- "tc.nonce=$N" && echo "$ARGS_ON" | grep -qx -- "tc.policy.file=$R/home/tc-policy/policy.json" && echo "CAUGHT/OK  T1b the crawl received exactly the three receipt settings (nonce $N)" || { echo "NOT AS EXPECTED  T1b the three settings"; fail=1; }
[ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 3 ] && echo "CAUGHT/OK  T1c no other receipt setting reached the crawl" || { echo "NOT AS EXPECTED  T1c"; fail=1; }
[ "$(grep -c . "$R/home/run11/nn-window.log")" = 4 ] && echo "CAUGHT/OK  T1d the NameNode window has exactly the 4 events of the crawl" || { echo "NOT AS EXPECTED  T1d window"; fail=1; }
tar tzf "$R/home/run11/master-logs.tar.gz" > "$R/tarlist.txt"; grep -q "attested-audit/a.tsv" "$R/tarlist.txt" && echo "CAUGHT/OK  T1e the master logs are packed" || { echo "NOT AS EXPECTED  T1e pack"; fail=1; }
mkfake "$R/home"; run run12 off; res "T2 receipts OFF" "M512C-RUN-DONE (run12, mode off"
OFF=$(cat "$R/crawl-args.txt"); [ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 0 ] && echo "CAUGHT/OK  T2b no receipt setting in the 'off' crawl" || { echo "NOT AS EXPECTED  T2b"; fail=1; }
mkfake "$R/home"; run run12 on >/dev/null; diff <(tr '\n' ' ' < "$R/crawl-args.txt" | sed -E 's/-D tc\.[^ ]+ //g') <(echo "$OFF" | tr '\n' ' ') >/dev/null && echo "CAUGHT/OK  T2c on and off crawls differ only by the three settings" || { echo "NOT AS EXPECTED  T2c"; fail=1; }
mkfake "$R/home"; echo x >> "$R/home/m512/tree/runtime/deploy/apache-nutch-1.22.job"; run run13 on; res "T3 the job is not the job of step 5.1.2 that the build proved" "M512C-RUN-STOP: the job file is not the job of step 5.1.2"
mkfake "$R/home"; echo changed >> "$R/home/tc-policy/policy.json"; run run13 on; res "T4 the policy file differs from its recorded fingerprint" "M512C-RUN-STOP: the policy file"
mkfake "$R/home"; echo "<value>plain</value>" > "$R/home/hadoop/etc/hadoop/core-site.xml"; run run13 on; res "T5 the cluster is not in wrapped mode" "M512C-RUN-STOP: core-site.xml is not the wrapped"
mkfake "$R/home"; FAKE_YARN_APPS=1 run run13 on; res "T6 a YARN application is running" "M512C-RUN-STOP: 1 YARN application"
mkfake "$R/home"; mkdir -p "$R/hdfs/user/$(whoami)/seeds-run13"; run run13 on; res "T7 the seeds folder exists already in HDFS" "M512C-RUN-STOP: /user/.*/seeds-run13 exists already"
mkfake "$R/home"; FAKE_CRAWL_RC=3 run run14 on; res "T8 the crawl fails (exit 3)" "M512C-RUN-FAILED"
[ -f "$R/home/run14/after.tsv" ] && echo "CAUGHT/OK  T8b the after listing and logs are still taken after a failed crawl" || { echo "NOT AS EXPECTED  T8b"; fail=1; }
mkfake "$R/home"; FAKE_WRAPPER_BAD=1 run run13 on; res "T9 the installed wrapper jar differs from the job" "M512C-RUN-STOP: the installed wrapper jar differs"
mkfake "$R/home"; sed -i 's/--time-limit-fetch 10/--time-limit-fetch 11/' "$R/home/m512/tree/ops/run-crawl.sh"; run run13 on; res "T10 ops/run-crawl.sh changed shape (no single place for the settings)" "M512C-RUN-STOP: ops/run-crawl.sh does not have the expected"
mkfake "$R/home"; mkdir -p "$R/home/run13"; run run13 on; res "T11 the run name exists already" "M512C-RUN-STOP: .*run13 exists already"
mkfake "$R/home"; FAKE_JPS_MISSING=ResourceManager run run13 on; res "T12 the ResourceManager is not running" "M512C-RUN-STOP: ResourceManager is not running"
mkfake "$R/home"; FAKE_YARN_NODES=0 run run13 on; res "T14 the worker's NodeManager has not registered again" "M512C-RUN-STOP: no YARN node is RUNNING"
mkfake "$R/home"; FAKE_JPS_MISSING=NameNode FAKE_JPS_SECONDARY=1 run run13 on; res "T15 only a SecondaryNameNode runs (it must not pass for the NameNode)" "M512C-RUN-STOP: NameNode is not running"
mkfake "$R/home"; run RUN-13 on; res "T13 a bad run name" "M512C-RUN-STOP: RUN must be letters and digits"
mkfake "$R/home"; run run15 on; res "T16 the offline verification of the seeds folder passes" "offline: every folder and every file of /user/.*/seeds-run15 verifies"; res "T16b ... and of the crawl folder" "offline: every folder and every file of /user/.*/crawl-run15 verifies"
res "T16c ... with the counts of folders and files" "folders=3 files=3"
[ -f "$R/home/run15/verify-results.tar.gz" ] && grep -q verify-results "$R/home/run15/fingerprints.txt" && echo "CAUGHT/OK  T16d the verification results are packed and fingerprinted" || { echo "NOT AS EXPECTED  T16d"; fail=1; }
mkfake "$R/home"; FAKE_TREE_BAD=1 run run16 on; res "T17 a file of the output was changed (the offline verification finds it)" "M512C-RUN-FAILED"; res "T17b ... and says why" "the file's bytes do not match its record"
mkfake "$R/home"; FAKE_GET_FAIL=1 run run16 on; res "T18 the copy of the output cannot be made" "could not get a copy of"
mkfake "$R/home"; FAKE_BIND_OFF=1 run run16 on; res "T19 folder binding is not on (the window is not open)" "M512C-RUN-STOP: attested.folder.binding.enabled is not true on this node"
mkfake "$R/home"; rm -f "$R/BUSY"; run run16 on; res "T20 the cluster is not reserved" "M512C-RUN-STOP: the cluster is not reserved by you"
mkfake "$R/home"; printf "somebody\t2026\tcrawl\n" > "$R/BUSY"; run run16 on; res "T21 the cluster is reserved by somebody else" "M512C-RUN-STOP: the cluster is not reserved by you"
mkfake "$R/home"; rm -f "$R/home/tc-test-key/test-key.txt"; run run16 on; res "T22 no test key file" "M512C-RUN-STOP: no test key file"
mkfake "$R/home"; rm -f "$R/home/m512b/evidence/fingerprints.txt"; run run16 on; res "T23 the build evidence with the job's fingerprint is missing" "M512C-RUN-STOP: no recorded fingerprint of the job of step 5.1.2"
mkfake "$R/home"; run run16 on; [ "$(grep -c 'M512C-RUN-DONE' "$R/out.txt")" = 1 ] && echo "CAUGHT/OK  T24 after all the faults, a clean run still passes" || { echo "NOT AS EXPECTED  T24"; fail=1; }
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: on and off pass, the offline verification of the whole output passes, and all 21 faults are caught" || echo "REHEARSAL-FAIL"
