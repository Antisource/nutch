#!/usr/bin/env bash
# Rehearsal of m513c-run.sh on a fake cluster (fake hdfs, yarn, jps, audit and wrapper tools, and a fake crawl that records
# its arguments), using the REAL ops/run-crawl.sh, REAL signing services (with a stand-in quote command), the REAL key list and the REAL verification tool (M513Tools) on signed trees that the fake hdfs
# makes with the real wrapper classes and the keys of real services. Usage: bash m513c-run-rehearse.sh KITDIR REPO_CHECKOUT JARS WORKOUT TOOLSOUT
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
# hermetic: the script under rehearsal must see only the fake home, never the real installation of the machine it runs on (the master has HADOOP_HOME set;
# the first run of this rehearsal on the master stopped at "core-site.xml is not the wrapped version" because it read the real, plain core-site.xml)
unset HADOOP_HOME HADOOP_CONF_DIR HADOOP_COMMON_HOME HADOOP_HDFS_HOME HADOOP_MAPRED_HOME
KIT="$1"; REPO="$2"; JARS="$3"; WORKOUT="$4"; TOOLSOUT="$5"; R=$(mktemp -d); fail=0; CPJ="$(ls "$JARS"/*.jar | tr '\n' ':')"
printf '#!/bin/bash\nexec java -m jdk.compiler/com.sun.tools.javac.Main "$@"\n' > "$R/javac-standin"; chmod +x "$R/javac-standin"
cat > "$R/fake-quote.sh" <<'EOQ'
#!/usr/bin/env bash
python3 - "$1" "$2" <<'PY'
import hashlib, sys
st = open(sys.argv[1], 'rb').read()
q = bytearray(b'\x04\x00' + b'\x00' * 630)
q[568:632] = hashlib.sha512(st).digest()
open(sys.argv[2], 'wb').write(bytes(q))
PY
EOQ
chmod +x "$R/fake-quote.sh"
cat > "$R/signreq.py" <<'EOQ'
import base64, socket, sys
port, token, keyid, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
tag = b"ATTEST02-SIGNED\n"
kid = (keyid if mode == "good" else "TDX-0123456789abcdef").encode()
st = tag + bytes([len(kid)]) + kid + (16384).to_bytes(4, "big") + (50000).to_bytes(8, "big") + bytes(32)
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(("AUTH %s\nSIGN %s\n" % (token, base64.b64encode(st).decode())).encode())
s.settimeout(5); data = b""
while data.count(b"\n") < 2:
    c = s.recv(4096)
    if not c: break
    data += c
print(data.decode().split("\n")[1][:40])
EOQ
trap 'kill $(cat "$R/svc.pid" "$R/svc2.pid" 2>/dev/null) 2>/dev/null' EXIT
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -6; fail=1; fi; }
mkfake() {   # $1 = home folder
  local H="$1"; rm -rf "$H" "$R/hdfs" "$R/tmp"; mkdir -p "$H/m513/tree/runtime/deploy/bin" "$H/m513/tree/ops/attested" "$H/m513/tree/seeds" "$H/m513b/evidence" "$H/tc-policy" "$H/hadoop/etc/hadoop" "$H/hadoop/logs" "$R/hdfs" "$R/tmp/attested-audit" "$R/tmp/attested-records" "$R/bin"
  cp "$REPO/ops/run-crawl.sh" "$H/m513/tree/ops/"; cp "$REPO/seeds/seed.txt" "$H/m513/tree/seeds/"
  head -c 5000 /dev/urandom > "$H/m513/tree/runtime/deploy/apache-nutch-1.22.job"
  echo "new job    $(sha256sum "$H/m513/tree/runtime/deploy/apache-nutch-1.22.job" | cut -c1-64)  5000" > "$H/m513b/evidence/fingerprints.txt"
  mkdir -p "$H/hadoop/share/hadoop/common/lib"
  python3 - "$H" "$WORKOUT" <<'PYJ'
import os, sys, zipfile
h, src = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(h + "/hadoop/share/hadoop/common/lib/attested-hdfs.jar", "w", zipfile.ZIP_DEFLATED)
for root, _, files in os.walk(os.path.join(src, "org/apache/nutch/attested")):
    for f in sorted(files):
        if f.startswith(("AttestedFsSmoke", "SigCoreTest", "KeyCoreTest", "M512", "M513", "FakeHdfsCli")): continue
        p = os.path.join(root, f); z.write(p, os.path.relpath(p, src))
z.close()
PYJ
  [ -f "$R/svc.pid" ] && kill $(cat "$R/svc.pid") 2>/dev/null; sleep 0.3
  mkdir -p "$H/tc-keys/list"
  ( nohup java -cp "$CPJ$WORKOUT" org.apache.nutch.attested.KeyService --dir "$H/tc-keyservice" --port 17461 --list-dir "$H/tc-keys/list" --quote-cmd "$R/fake-quote.sh" --host rehearsal-master >"$R/svc.out" 2>&1 & echo $! > "$R/svc.pid" )
  for i in $(seq 1 60); do [ -f "$H/tc-keyservice/port" ] && break; sleep 0.5; done
  [ -f "$R/svc2.pid" ] && kill $(cat "$R/svc2.pid") 2>/dev/null; rm -rf "$R/worker-svc"
  ( nohup java -cp "$CPJ$WORKOUT" org.apache.nutch.attested.KeyService --dir "$R/worker-svc" --port 17462 --list-dir "$H/tc-keys/list" --quote-cmd "$R/fake-quote.sh" --host rehearsal-worker >"$R/svc2.out" 2>&1 & echo $! > "$R/svc2.pid" )
  for i in $(seq 1 60); do [ "$(ls "$H/tc-keys/list"/TDX-*.attestkey 2>/dev/null | wc -l)" -ge 2 ] && break; sleep 0.5; done
  SKID="$(basename "$(ls "$H/tc-keyservice"/TDX-*.attestkey | head -1)" .attestkey)"; TOK="$(cat "$H/tc-keyservice/token")"
  python3 "$R/signreq.py" 17461 "$TOK" "$SKID" good >/dev/null 2>&1
  [ "${FAKE_REFUSAL:-0}" = 1 ] && python3 "$R/signreq.py" 17461 "$TOK" "$SKID" other >/dev/null 2>&1
  printf "%s\t2026-10-15T00:00:00Z\tcombined crawl\n" "$(whoami)" > "$R/BUSY"
  echo '{"policy":"fake"}' > "$H/tc-policy/policy.json"; sha256sum "$H/tc-policy/policy.json" | cut -c1-64 > "$H/tc-policy/policy.json.sha256"
  echo "<value>org.apache.nutch.attested.AttestedHdfsFileSystem</value>" > "$H/hadoop/etc/hadoop/core-site.xml"
  for i in 1 2 3; do echo "audit line $i" >> "$H/hadoop/logs/hdfs-audit.log"; done
  echo "wrapper log" > "$R/tmp/attested-audit/a.tsv"; echo "record" > "$R/tmp/attested-records/r.tsv"
  cat > "$H/m513/tree/runtime/deploy/bin/crawl" <<'EOC'
#!/bin/bash
printf '%s\n' "$@" > "$R/crawl-args.txt"
mkdir -p "$FAKEHDFS_ROOT/user/$(whoami)/crawl-x"; for i in 1 2 3 4; do echo "crawl event $i" >> "$FAKE_NN_LOG"; done
exit ${FAKE_CRAWL_RC:-0}
EOC
  cat > "$H/m513/tree/ops/attested/audit.sh" <<'EOC'
#!/bin/bash
if [ "$1" = rotate ]; then echo rotated; elif [ "$1" = snapshot ]; then (cd "$FAKEHDFS_ROOT" && find . -mindepth 1 | sed 's#^\./#/#' | awk '{print "d\t0\t0\t"$0}') > "$2"; else exit 2; fi
EOC
  cat > "$H/m513/tree/ops/attested/wrapper-jar.sh" <<'EOC'
#!/bin/bash
[ "${FAKE_WRAPPER_BAD:-0}" = 1 ] && { echo "CLASSES-DIFFER"; exit 1; }; echo "CLASSES-SAME (14 classes identical to the job file)"
EOC
  cat > "$R/bin/hdfs" <<'EOC'
#!/bin/bash
if [ "$1" = getconf ]; then [ "${FAKE_BIND_OFF:-0}" = 1 ] && [ "$3" = attested.folder.binding.enabled ] && exit 1; [ "$3" = attested.keys.provider ] && { echo "${FAKE_PROVIDER:-service}"; exit 0; }; [ "$3" = attested.signature.allow.test.keys ] && { echo "${FAKE_ALLOW_TEST:-false}"; exit 0; }; echo true; exit 0; fi
shift   # dfs
if [ "$1" = -D ]; then shift 2; fi
case "$1" in
  -test) [ -e "$FAKEHDFS_ROOT$3" ] ;;
  -mkdir) mkdir -p "$FAKEHDFS_ROOT$3" ;;
  -put) mkdir -p "$FAKEHDFS_ROOT$3" && cp "$2" "$FAKEHDFS_ROOT$3" ;;
  -get) [ "${FAKE_GET_FAIL:-0}" = 1 ] && { echo "get: simulated failure" >&2; exit 1; }
        if [ "${FAKE_TREE_UNLISTED:-0}" = 1 ]; then java -cp "$FAKE_CP" org.apache.nutch.attested.M513TreeGen "$R/gen-$$-$RANDOM" "$R/unlisted-list" "$3" "$2" "$R/fake-quote.sh" ${FAKE_TREE_BAD:+bad}
        else java -cp "$FAKE_CP" org.apache.nutch.attested.M513TreeGen two 17461 "$FAKE_HOME/tc-keyservice/token" 17462 "$R/worker-svc/token" "$FAKE_LIST" "$3" "$2" ${FAKE_TREE_BAD:+bad}; fi ;;
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
  chmod +x "$H/m513/tree/runtime/deploy/bin/crawl" "$H/m513/tree/ops/attested/"*.sh "$R/bin/"*
}
export R FAKEHDFS_ROOT="$R/hdfs" FAKE_CP="$CPJ$WORKOUT:$TOOLSOUT"; export M513C_JAVAC="$R/javac-standin" M513C_BUSY="$R/BUSY"; export M513C_HDFS="$R/bin/hdfs" M513C_YARN="$R/bin/yarn" M513C_JPS="$R/bin/jps" M513C_ATT_TMP="$R/tmp"
run() { ( cd "$KIT" && HOME="$R/home" HADOOP_HOME="$R/home/hadoop" HADOOP_CONF_DIR="$R/home/hadoop/etc/hadoop" FAKE_HOME="$R/home" FAKE_LIST="$R/home/tc-keys/list" M513C_PORT=17461 FAKE_NN_LOG="$R/home/hadoop/logs/hdfs-audit.log" bash ops/attested/m513c-run.sh "$@" ) >"$R/out.txt" 2>&1; }
mkfake "$R/home"; run run11 on; res "T1 receipts ON (exact invocation: relative script path, from the kit folder)" "M513C-RUN-DONE (run11, mode on"
ARGS_ON=$(cat "$R/crawl-args.txt"); N=$(cat "$R/home/run11/nonce")
echo "$ARGS_ON" | grep -qx -- "tc.receipts.enabled=true" && echo "$ARGS_ON" | grep -qx -- "tc.nonce=$N" && echo "$ARGS_ON" | grep -qx -- "tc.policy.file=$R/home/tc-policy/policy.json" && echo "CAUGHT/OK  T1b the crawl received exactly the three receipt settings (nonce $N)" || { echo "NOT AS EXPECTED  T1b the three settings"; fail=1; }
[ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 3 ] && echo "CAUGHT/OK  T1c no other receipt setting reached the crawl" || { echo "NOT AS EXPECTED  T1c"; fail=1; }
[ "$(grep -c . "$R/home/run11/nn-window.log")" = 4 ] && echo "CAUGHT/OK  T1d the NameNode window has exactly the 4 events of the crawl" || { echo "NOT AS EXPECTED  T1d window"; fail=1; }
tar tzf "$R/home/run11/master-logs.tar.gz" > "$R/tarlist.txt"; grep -q "attested-audit/a.tsv" "$R/tarlist.txt" && echo "CAUGHT/OK  T1e the master logs are packed" || { echo "NOT AS EXPECTED  T1e pack"; fail=1; }
mkfake "$R/home"; run run12 off; res "T2 receipts OFF" "M513C-RUN-DONE (run12, mode off"
OFF=$(cat "$R/crawl-args.txt"); [ "$(grep -c '^tc\.' "$R/crawl-args.txt")" = 0 ] && echo "CAUGHT/OK  T2b no receipt setting in the 'off' crawl" || { echo "NOT AS EXPECTED  T2b"; fail=1; }
mkfake "$R/home"; run run12 on >/dev/null; diff <(tr '\n' ' ' < "$R/crawl-args.txt" | sed -E 's/-D tc\.[^ ]+ //g') <(echo "$OFF" | tr '\n' ' ') >/dev/null && echo "CAUGHT/OK  T2c on and off crawls differ only by the three settings" || { echo "NOT AS EXPECTED  T2c"; fail=1; }
mkfake "$R/home"; echo x >> "$R/home/m513/tree/runtime/deploy/apache-nutch-1.22.job"; run run13 on; res "T3 the job is not the job of step 5.1.3 that the build proved" "M513C-RUN-STOP: the job file is not the job of step 5.1.3"
mkfake "$R/home"; echo changed >> "$R/home/tc-policy/policy.json"; run run13 on; res "T4 the policy file differs from its recorded fingerprint" "M513C-RUN-STOP: the policy file"
mkfake "$R/home"; echo "<value>plain</value>" > "$R/home/hadoop/etc/hadoop/core-site.xml"; run run13 on; res "T5 the cluster is not in wrapped mode" "M513C-RUN-STOP: core-site.xml is not the wrapped"
mkfake "$R/home"; FAKE_YARN_APPS=1 run run13 on; res "T6 a YARN application is running" "M513C-RUN-STOP: 1 YARN application"
mkfake "$R/home"; mkdir -p "$R/hdfs/user/$(whoami)/seeds-run13"; run run13 on; res "T7 the seeds folder exists already in HDFS" "M513C-RUN-STOP: /user/.*/seeds-run13 exists already"
mkfake "$R/home"; FAKE_CRAWL_RC=3 run run14 on; res "T8 the crawl fails (exit 3)" "M513C-RUN-FAILED"
[ -f "$R/home/run14/after.tsv" ] && echo "CAUGHT/OK  T8b the after listing and logs are still taken after a failed crawl" || { echo "NOT AS EXPECTED  T8b"; fail=1; }
mkfake "$R/home"; FAKE_WRAPPER_BAD=1 run run13 on; res "T9 the installed wrapper jar differs from the job" "M513C-RUN-STOP: the installed wrapper jar differs"
mkfake "$R/home"; sed -i 's/--time-limit-fetch 10/--time-limit-fetch 11/' "$R/home/m513/tree/ops/run-crawl.sh"; run run13 on; res "T10 ops/run-crawl.sh changed shape (no single place for the settings)" "M513C-RUN-STOP: ops/run-crawl.sh does not have the expected"
mkfake "$R/home"; mkdir -p "$R/home/run13"; run run13 on; res "T11 the run name exists already" "M513C-RUN-STOP: .*run13 exists already"
mkfake "$R/home"; FAKE_JPS_MISSING=ResourceManager run run13 on; res "T12 the ResourceManager is not running" "M513C-RUN-STOP: ResourceManager is not running"
mkfake "$R/home"; FAKE_YARN_NODES=0 run run13 on; res "T14 the worker's NodeManager has not registered again" "M513C-RUN-STOP: no YARN node is RUNNING"
mkfake "$R/home"; FAKE_JPS_MISSING=NameNode FAKE_JPS_SECONDARY=1 run run13 on; res "T15 only a SecondaryNameNode runs (it must not pass for the NameNode)" "M513C-RUN-STOP: NameNode is not running"
mkfake "$R/home"; run RUN-13 on; res "T13 a bad run name" "M513C-RUN-STOP: RUN must be letters and digits"
mkfake "$R/home"; run run15 on; res "T16 the offline verification of the seeds folder passes" "offline: every folder and every file of /user/.*/seeds-run15 verifies"; res "T16b ... and of the crawl folder" "offline: every folder and every file of /user/.*/crawl-run15 verifies"
res "T16c ... with the counts of folders and files" "folders=3 files=3"
res "T16e the tree was signed by keys that are all in the key list" "the tree was signed by [0-9] key(s), all of them in the key list"
res "T16f negative control: a partial key list refuses the other machine's files" "negative control: with only this node's bundle in the list"
res "T16g the signing service of this node signed statements and refused none" "signed [0-9]* statements and refused none"
res "T16h the key list at that moment is kept" "the key list at this moment is kept"
[ -f "$R/home/run15/verify-results.tar.gz" ] && grep -q verify-results "$R/home/run15/fingerprints.txt" && echo "CAUGHT/OK  T16d the verification results are packed and fingerprinted" || { echo "NOT AS EXPECTED  T16d"; fail=1; }
mkfake "$R/home"; FAKE_TREE_BAD=1 run run16 on; res "T17 a file of the output was changed (the offline verification finds it)" "M513C-RUN-FAILED"; res "T17b ... and says why" "the file's bytes do not match its record"
mkfake "$R/home"; FAKE_GET_FAIL=1 run run16 on; res "T18 the copy of the output cannot be made" "could not get a copy of"
mkfake "$R/home"; FAKE_BIND_OFF=1 run run16 on; res "T19 folder binding is not on (the window is not open)" "M513C-RUN-STOP: attested.folder.binding.enabled is not true on this node"
mkfake "$R/home"; rm -f "$R/BUSY"; run run16 on; res "T20 the cluster is not reserved" "M513C-RUN-STOP: the cluster is not reserved by you"
mkfake "$R/home"; printf "somebody\t2026\tcrawl\n" > "$R/BUSY"; run run16 on; res "T21 the cluster is reserved by somebody else" "M513C-RUN-STOP: the cluster is not reserved by you"
mkfake "$R/home"; rm -f "$R/home/tc-keyservice"/TDX-*.attestkey; run run16 on; res "T22 no key bundle in the service folder (the service is not running here)" "M513C-RUN-STOP: no TDX- key bundle in"
mkfake "$R/home"; kill $(cat "$R/svc.pid"); sleep 0.5; run run16 on; res "T25 the signing service does not answer" "M513C-RUN-STOP: the signing service does not answer on port 17461"
mkfake "$R/home"; ls "$R/home/tc-keys/list"/TDX-*.attestkey | head -1 | xargs rm -f; run run16 on; res "T26 the key list holds only one bundle (the exchange was not done)" "run m513-keylist-sync.sh in Cloud Shell first"
mkfake "$R/home"; FAKE_PROVIDER=test run run16 on; res "T27 the keys do not come from the signing service" "M513C-RUN-STOP: the keys do not come from the signing service"
mkfake "$R/home"; FAKE_ALLOW_TEST=true run run16 on; res "T28 test keys are still allowed" "M513C-RUN-STOP: the keys do not come from the signing service, or test keys are still allowed"
FAKE_REFUSAL=1 mkfake "$R/home"; run run16 on; res "T29 the service refused a request during the run (a statement for another key id)" "M513C-RUN-FAILED"; res "T29b ... and the audit log is blamed" "the service audit log says"
mkfake "$R/home"; mkdir -p "$R/unlisted-list"; FAKE_TREE_UNLISTED=1 run run16 on; res "T31 the output was signed by a key that is not in the key list" "M513C-RUN-FAILED"; res "T31b ... and the offline verification says not trusted here" "not trusted here"
mkfake "$R/home"; rm -f "$R/home/m513b/evidence/fingerprints.txt"; run run16 on; res "T23 the build evidence with the job's fingerprint is missing" "M513C-RUN-STOP: no recorded fingerprint of the job of step 5.1.3"
mkfake "$R/home"; run run16 on; [ "$(grep -c 'M513C-RUN-DONE' "$R/out.txt")" = 1 ] && echo "CAUGHT/OK  T24 after all the faults, a clean run still passes" || { echo "NOT AS EXPECTED  T24"; fail=1; }
[ $fail -eq 0 ] && echo "REHEARSAL-PASS: on and off pass, the offline verification of the whole output passes, and all 26 faults are caught" || echo "REHEARSAL-FAIL"
