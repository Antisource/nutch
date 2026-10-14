#!/usr/bin/env bash
# Rehearsal of m481r-run.sh on a fake cluster (fake hdfs, yarn, jps, audit and wrapper tools, and a fake crawl that records
# its arguments), using the REAL ops/run-crawl.sh. Usage: bash m481r-run-rehearse.sh KITDIR REPO_CHECKOUT
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
KIT="$1"; REPO="$2"; R=$(mktemp -d); fail=0
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -6; fail=1; fi; }
mkfake() {   # $1 = home folder
  local H="$1"; rm -rf "$H" "$R/hdfs" "$R/tmp"; mkdir -p "$H/m481/patched/runtime/deploy/bin" "$H/m481/patched/ops/attested" "$H/m481/patched/seeds" "$H/m481/evidence" "$H/tc-policy" "$H/hadoop/etc/hadoop" "$H/hadoop/logs" "$R/hdfs" "$R/tmp/attested-audit" "$R/tmp/attested-records" "$R/bin"
  cp "$REPO/ops/run-crawl.sh" "$H/m481/patched/ops/"; cp "$REPO/seeds/seed.txt" "$H/m481/patched/seeds/"
  head -c 5000 /dev/urandom > "$H/m481/patched/runtime/deploy/apache-nutch-1.22.job"
  echo "patched job $(sha256sum "$H/m481/patched/runtime/deploy/apache-nutch-1.22.job" | cut -c1-64)  5000" > "$H/m481/evidence/fingerprints.txt"
  echo '{"policy":"fake"}' > "$H/tc-policy/policy.json"; sha256sum "$H/tc-policy/policy.json" | cut -c1-64 > "$H/tc-policy/policy.json.sha256"
  echo "<value>org.apache.nutch.attested.AttestedHdfsFileSystem</value>" > "$H/hadoop/etc/hadoop/core-site.xml"
  for i in 1 2 3; do echo "audit line $i" >> "$H/hadoop/logs/hdfs-audit.log"; done
  echo "wrapper log" > "$R/tmp/attested-audit/a.tsv"; echo "record" > "$R/tmp/attested-records/r.tsv"
  cat > "$H/m481/patched/runtime/deploy/bin/crawl" <<'EOC'
#!/bin/bash
printf '%s\n' "$@" > "$R/crawl-args.txt"
mkdir -p "$FAKEHDFS_ROOT/user/$(whoami)/crawl-x"; for i in 1 2 3 4; do echo "crawl event $i" >> "$FAKE_NN_LOG"; done
exit ${FAKE_CRAWL_RC:-0}
EOC
  cat > "$H/m481/patched/ops/attested/audit.sh" <<'EOC'
#!/bin/bash
if [ "$1" = rotate ]; then echo rotated; elif [ "$1" = snapshot ]; then (cd "$FAKEHDFS_ROOT" && find . -mindepth 1 | sed 's#^\./#/#' | awk '{print "d\t0\t0\t"$0}') > "$2"; else exit 2; fi
EOC
  cat > "$H/m481/patched/ops/attested/wrapper-jar.sh" <<'EOC'
#!/bin/bash
[ "${FAKE_WRAPPER_BAD:-0}" = 1 ] && { echo "CLASSES-DIFFER"; exit 1; }; echo "CLASSES-SAME (14 classes identical to the job file)"
EOC
  cat > "$R/bin/hdfs" <<'EOC'
#!/bin/bash
shift   # dfs
case "$1" in
  -test) [ -e "$FAKEHDFS_ROOT$3" ] ;;
  -mkdir) mkdir -p "$FAKEHDFS_ROOT$3" ;;
  -put) mkdir -p "$FAKEHDFS_ROOT$3" && cp "$2" "$FAKEHDFS_ROOT$3" ;;
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
  chmod +x "$H/m481/patched/runtime/deploy/bin/crawl" "$H/m481/patched/ops/attested/"*.sh "$R/bin/"*
}
export R FAKEHDFS_ROOT="$R/hdfs"; export M481R_HDFS="$R/bin/hdfs" M481R_YARN="$R/bin/yarn" M481R_JPS="$R/bin/jps" M481R_ATT_TMP="$R/tmp"
run() { ( cd "$KIT" && HOME="$R/home" FAKE_NN_LOG="$R/home/hadoop/logs/hdfs-audit.log" bash ops/attested/m481r-run.sh "$@" ) >"$R/out.txt" 2>&1; }
mkfake "$R/home"; run run11 on; res "T1 receipts ON (exact invocation: relative script path, from the kit folder)" "M481R-RUN-DONE (run11, mode on"
ARGS_ON=$(cat "$R/crawl-args.txt"); N=$(cat "$R/home/run11/nonce")
echo "$ARGS_ON" | grep -qx -- "tc.receipts.enabled=true" && echo "$ARGS_ON" | grep -qx -- "tc.nonce=$N" && echo "$ARGS_ON" | grep -qx -- "tc.policy.file=$R/home/tc-policy/policy.json" && echo "CAUGHT/OK  T1b the crawl received exactly the three receipt settings (nonce $N)" || { echo "NOT AS EXPECTED  T1b the three settings"; fail=1; }
[ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 3 ] && echo "CAUGHT/OK  T1c no other receipt setting reached the crawl" || { echo "NOT AS EXPECTED  T1c"; fail=1; }
[ "$(grep -c . "$R/home/run11/nn-window.log")" = 4 ] && echo "CAUGHT/OK  T1d the NameNode window has exactly the 4 events of the crawl" || { echo "NOT AS EXPECTED  T1d window"; fail=1; }
tar tzf "$R/home/run11/master-logs.tar.gz" > "$R/tarlist.txt"; grep -q "attested-audit/a.tsv" "$R/tarlist.txt" && echo "CAUGHT/OK  T1e the master logs are packed" || { echo "NOT AS EXPECTED  T1e pack"; fail=1; }
mkfake "$R/home"; run run12 off; res "T2 receipts OFF" "M481R-RUN-DONE (run12, mode off"
OFF=$(cat "$R/crawl-args.txt"); [ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 0 ] && echo "CAUGHT/OK  T2b no receipt setting in the 'off' crawl" || { echo "NOT AS EXPECTED  T2b"; fail=1; }
mkfake "$R/home"; run run12 on >/dev/null; diff <(tr '\n' ' ' < "$R/crawl-args.txt" | sed -E 's/-D tc\.[^ ]+ //g') <(echo "$OFF" | tr '\n' ' ') >/dev/null && echo "CAUGHT/OK  T2c on and off crawls differ only by the three settings" || { echo "NOT AS EXPECTED  T2c"; fail=1; }
mkfake "$R/home"; echo x >> "$R/home/m481/patched/runtime/deploy/apache-nutch-1.22.job"; run run13 on; res "T3 the job is not the patched job of the build" "M481R-RUN-STOP: the job file is not the patched job"
mkfake "$R/home"; echo changed >> "$R/home/tc-policy/policy.json"; run run13 on; res "T4 the policy file differs from its recorded fingerprint" "M481R-RUN-STOP: the policy file"
mkfake "$R/home"; echo "<value>plain</value>" > "$R/home/hadoop/etc/hadoop/core-site.xml"; run run13 on; res "T5 the cluster is not in wrapped mode" "M481R-RUN-STOP: core-site.xml is not the wrapped"
mkfake "$R/home"; FAKE_YARN_APPS=1 run run13 on; res "T6 a YARN application is running" "M481R-RUN-STOP: 1 YARN application"
mkfake "$R/home"; mkdir -p "$R/hdfs/user/$(whoami)/seeds-run13"; run run13 on; res "T7 the seeds folder exists already in HDFS" "M481R-RUN-STOP: /user/.*/seeds-run13 exists already"
mkfake "$R/home"; FAKE_CRAWL_RC=3 run run14 on; res "T8 the crawl fails (exit 3)" "M481R-RUN-FAILED"
[ -f "$R/home/run14/after.tsv" ] && echo "CAUGHT/OK  T8b the after listing and logs are still taken after a failed crawl" || { echo "NOT AS EXPECTED  T8b"; fail=1; }
mkfake "$R/home"; FAKE_WRAPPER_BAD=1 run run13 on; res "T9 the installed wrapper jar differs from the job" "M481R-RUN-STOP: the installed wrapper jar differs"
mkfake "$R/home"; sed -i 's/--time-limit-fetch 10/--time-limit-fetch 11/' "$R/home/m481/patched/ops/run-crawl.sh"; run run13 on; res "T10 ops/run-crawl.sh changed shape (no single place for the settings)" "M481R-RUN-STOP: ops/run-crawl.sh does not have the expected"
mkfake "$R/home"; mkdir -p "$R/home/run13"; run run13 on; res "T11 the run name exists already" "M481R-RUN-STOP: .*run13 exists already"
mkfake "$R/home"; FAKE_JPS_MISSING=ResourceManager run run13 on; res "T12 the ResourceManager is not running" "M481R-RUN-STOP: ResourceManager is not running"
mkfake "$R/home"; FAKE_YARN_NODES=0 run run13 on; res "T14 the worker's NodeManager has not registered again" "M481R-RUN-STOP: no YARN node is RUNNING"
mkfake "$R/home"; FAKE_JPS_MISSING=NameNode FAKE_JPS_SECONDARY=1 run run13 on; res "T15 only a SecondaryNameNode runs (it must not pass for the NameNode)" "M481R-RUN-STOP: NameNode is not running"
mkfake "$R/home"; run RUN-13 on; res "T13 a bad run name" "M481R-RUN-STOP: RUN must be letters and digits"
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: on and off pass, and all 13 faults are caught" || echo "REHEARSAL-FAIL"
