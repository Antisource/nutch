#!/usr/bin/env bash
# Rehearsal of m512-window.sh and m512-demo.sh away from the cluster. The REAL scripts run with the REAL wrapper code, the REAL key tool, the REAL
# wrapper-jar.sh and the REAL demonstration tools, over a local folder that plays HDFS (a command-line stand-in for hdfs, FakeHdfsCli.java).
# Stand-ins: hdfs/yarn/hadoop (the CLI), cluster-mode.sh (it swaps core-site.xml from the mode folder and records the call), the measured-set
# check (it compares the installed jar and core-site.xml with what they were at the start), and the compiler command.
# Usage: bash m512-window-rehearse.sh KITDIR REPO JARS STUBS WORKOUT BASEOUT TOOLSOUT WORKSRC
set -uo pipefail
KIT="$1"; REPO="$2"; JARS="$3"; STUBS="$4"; WORKOUT="$5"; BASEOUT="$6"; TOOLSOUT="$7"; WORKSRC="$8"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; CP="$(ls "$JARS"/*.jar | tr '\n' ':')"
printf '#!/bin/bash\nexec java -m jdk.compiler/com.sun.tools.javac.Main "$@"\n' > "$R/javac-standin"; chmod +x "$R/javac-standin"
cp "$REPO/ops/attested/wrapper-jar.sh" "$R/wrapper-jar.sh"; chmod +x "$R/wrapper-jar.sh"
# jobs: the measured job (old classes) and the new job (new classes): top-level classes plus a dummy entry, as in a real job file
mkjob() { python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED)
for root, _, files in os.walk(os.path.join(src, "org/apache/nutch/attested")):
    for f in sorted(files):
        if f.startswith(("AttestedFsSmoke", "SigCoreTest", "M512", "FakeHdfsCli")): continue
        p = os.path.join(root, f); zi = zipfile.ZipInfo(os.path.relpath(p, src), date_time=(2026, 10, 15, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED; z.writestr(zi, open(p, "rb").read())
zi = zipfile.ZipInfo("org/apache/nutch/crawl/Dummy.class", date_time=(2026, 10, 15, 0, 0, 0)); z.writestr(zi, b"dummy"); z.close()
PY
}
mkjob "$BASEOUT" "$R/measured.job"; mkjob "$WORKOUT" "$R/new.job"
bash "$R/wrapper-jar.sh" build "$R/measured.job" "$R/measured.jar" >/dev/null 2>&1; bash "$R/wrapper-jar.sh" build "$R/new.job" "$R/new.jar" >/dev/null 2>&1
JP="$(sha256sum "$R/new.jar" | cut -c1-20)"; OP="$(sha256sum "$R/new.job" | cut -c1-20)"
FAKE_CP="$CP$WORKOUT:$STUBS:$TOOLSOUT"
cat > "$R/cluster-mode.sh" <<'EOS'
#!/bin/bash
# stand-in: wrapped|plain --restart: put the file of that name from CLUSTER_MODE_DIR in place and record the call
[ "${FAKE_MODE_FAIL:-}" = 1 ] && { echo "CLUSTER-MODE-STOP: the daemons did not come back (rehearsal)"; exit 1; }
CONF="${HADOOP_HOME}/etc/hadoop/core-site.xml"; cp "$CLUSTER_MODE_DIR/core-site.xml.$1" "$CONF" && echo "$(basename "$HADOOP_HOME") $1 $2 dir=$(basename "$(dirname "$CLUSTER_MODE_DIR")")/$(basename "$CLUSTER_MODE_DIR")" >> "$FAKE_CALLS"; echo "CLUSTER-MODE-OK: $1; the daemons of this node are back and have joined the cluster"
EOS
chmod +x "$R/cluster-mode.sh"
# one node: a home folder with a Hadoop tree, the measured jar and the measured core-site.xml, and the node's hdfs/yarn/hadoop stand-ins
mknode() { # mknode <name>
  local N="$R/$1"; rm -rf "$N"; mkdir -p "$N/home/hadoop/bin" "$N/home/hadoop/etc/hadoop" "$N/home/hadoop/share/hadoop/common/lib" "$N/fake-root" "$N/state" "$N/home/m481/patched" "$N/fake-root/user/rishabsdp17"   # the cluster's home folder of the user exists before the wrapper makes anything in it
  cp "$R/measured.jar" "$N/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar"
  cat > "$N/home/hadoop/etc/hadoop/core-site.xml" <<'XML'
<?xml version="1.0"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://hadoop-master:9000</value>
  </property>
  <property>
    <name>fs.hdfs.impl</name>
    <value>org.apache.nutch.attested.AttestedHdfsFileSystem</value>
    <final>true</final>
  </property>
</configuration>
XML
  printf '#!/bin/bash\nexec java -Duser.home="$HOME" -cp "$FAKE_CP" org.apache.nutch.attested.FakeHdfsCli "$@"\n' > "$N/home/hadoop/bin/hdfs"
  printf '#!/bin/bash\n[ "$1" = application ] && { echo "Total number of applications:${FAKE_APPS:-0}"; [ "${FAKE_APPS:-0}" != 0 ] && echo "application_1791873617149_0042   crawl   MAPREDUCE"; exit 0; }\n' > "$N/home/hadoop/bin/yarn"
  printf '#!/bin/bash\n[ "$1" = classpath ] && echo "%s/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar:/x/other.jar"\n' "$N" > "$N/home/hadoop/bin/hadoop"
  chmod +x "$N/home/hadoop/bin/"*
  { sha256sum "$N/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64; sha256sum "$N/home/hadoop/etc/hadoop/core-site.xml" | cut -c1-64; } > "$N/measured-fps.txt"
  cat > "$N/check.sh" <<EOS
#!/bin/bash
j=\$(sha256sum "$N/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64); c=\$(sha256sum "$N/home/hadoop/etc/hadoop/core-site.xml" | cut -c1-64)
if [ "\$j" = "\$(sed -n 1p "$N/measured-fps.txt")" ] && [ "\$c" = "\$(sed -n 2p "$N/measured-fps.txt")" ]; then echo "ALL-UNCHANGED (stand-in: the jar and core-site.xml are the measured ones)"; else echo "hadoop-code CHANGED"; exit 1; fi
EOS
  chmod +x "$N/check.sh"; printf 'rishabsdp17\t2026-10-15T08:00:00Z\tsigned wrapper test\n' > "$N/BUSY"
}
nodeenv() { # nodeenv <name> <role>: the environment the scripts see on that node
  N="$R/$1"; export M512W_HOME="$N/home" HOME="$N/home" HADOOP_HOME="$N/home/hadoop" HADOOP_CONF_DIR="$N/home/hadoop/etc/hadoop" M512W_TOOLS="$R" M512W_MODE="$R/cluster-mode.sh" M512W_CHECK="$N/check.sh" \
    M512W_BUSY="$N/BUSY" M512W_USER=rishabsdp17 M512W_NUTCH_DIR="$N/home/m481/patched" FAKE_ROOT="$N/fake-root" FAKE_STATE="$N/state" FAKE_CALLS="$N/mode-calls.txt" FAKE_CP="$FAKE_CP" \
    M512D_TOPPREFIX="$N/fake-root" M512D_USER=rishabsdp17 M512D_BUSY="$N/BUSY" M512D_AUDIT="$N/state/audit" M512D_JAVAC="$R/javac-standin"
  [ "$2" = master ] && export M512W_HOST=tdx-lab M512D_HOST=tdx-lab || export M512W_HOST=tdx-lab-worker M512D_HOST=tdx-lab-worker
  unset FAKE_APPS FAKE_MODE_FAIL; cd "$N/home"
}
win() { ( cd "$KIT" && bash ops/attested/m512-window.sh "$@" ) 2>&1; }
demo() { ( cd "$KIT" && bash ops/attested/m512-demo.sh "$@" ) 2>&1; }

echo "=== 1. the master: open the window, run the demonstration, close the window"
mknode m; nodeenv m master
out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; rc=$?; echo "$out" | tail -14 | cut -c1-185
KEYID="$(echo "$out" | grep -o 'TEST-[0-9a-f]*' | head -1)"
chk "open exits 0 and says M512W-OPEN-OK" $([ $rc = 0 ] && grep -q "M512W-OPEN-OK master" <<<"$out"; echo $?)
chk "the installed jar is the new one, and the measured jar was saved" $([ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sha256sum "$R/new.jar" | cut -c1-64)" ] && [ "$(sha256sum "$R/m/home/m512w/window/saved/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
chk "the signed core-site.xml has the five new settings, all final, and keeps the measured ones" $(python3 - "$R/m/home/hadoop/etc/hadoop/core-site.xml" <<'PY'; echo $?
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot(); d = {p.findtext("name"): (p.findtext("value"), p.findtext("final")) for p in r.findall("property")}
ok = all(d.get("attested.signature." + k) == ("true", "true") for k in ("enabled", "required", "allow.test.keys")) and all(d.get("attested.folder.binding." + k) == ("true", "true") for k in ("enabled", "required")) and "fs.hdfs.impl" in d and "fs.defaultFS" in d
sys.exit(0 if ok else 1)
PY
)
chk "the mode script was called with the mode folder of the window and --restart" $(grep -q "wrapped --restart dir=window/modes" "$R/m/mode-calls.txt"; echo $?)
chk "the test key was made, mode 600, and its id was printed for the worker" $([ "$(stat -c %a "$R/m/home/tc-test-key/test-key.txt")" = 600 ] && [ -n "$KEYID" ]; echo $?)
chk "the configuration says signing on and required" $([ "$("$R/m/home/hadoop/bin/hdfs" getconf -confKey attested.signature.required)" = true ]; echo $?)
out="$(demo "$R/new.jar" "$R/m/home/m512w/demo")"; rc=$?; echo "$out" | tail -22 | cut -c1-190
chk "the demonstration exits 0 and says M512-DEMO-OK" $([ $rc = 0 ] && grep -q "M512-DEMO-OK" <<<"$out"; echo $?)
chk "twelve reads failed and two renames were refused, each with its reason" $([ "$(grep -c 'the read FAILS' <<<"$out")" = 12 ] && [ "$(grep -c 'rename is REFUSED' <<<"$out")" = 2 ]; echo $?)
chk "the offline check passes on the honest tree, after the renames, and after all attacks were undone" $(grep -q "offline: a local copy of the whole tree verifies" <<<"$out" && grep -q "after the renames the tree still verifies offline" <<<"$out" && grep -q "after all attacks and their undoing verifies again" <<<"$out"; echo $?)
chk "the honest renames sign only what they must (a record for a file, only the identity for a folder)" $(grep -q "only the folder.s own identity file was signed again" <<<"$out" && grep -q "byte for byte unchanged" <<<"$out" && grep -q "signed again for the new folder and name" <<<"$out"; echo $?)
chk "the demonstration folder was removed and the evidence bundle was made after the final line" $([ -z "$(ls "$R/m/fake-root/user/rishabsdp17" 2>/dev/null)" ] && tar -xzOf "$R/m/home/m512w/evidence-m512-demo.tar.gz" evidence/summary.txt | grep -q M512-DEMO-OK; echo $?)
out="$(win close master)"; rc=$?; echo "$out" | tail -10 | cut -c1-185
chk "close exits 0 and says M512W-CLOSE-OK" $([ $rc = 0 ] && grep -q "M512W-CLOSE-OK master" <<<"$out"; echo $?)
chk "the jar and core-site.xml are byte for byte the measured ones again" $([ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ] && [ "$(sha256sum "$R/m/home/hadoop/etc/hadoop/core-site.xml" | cut -c1-64)" = "$(sed -n 2p "$R/m/measured-fps.txt")" ]; echo $?)
chk "the window state was moved aside, not deleted" $([ ! -d "$R/m/home/m512w/window" ] && ls -d "$R/m/home/m512w/window-closed-master-"* >/dev/null 2>&1; echo $?)

echo "=== 2. the worker: it needs the master's key file and its id"
mknode w; nodeenv w worker
out="$(win open worker "$R/new.jar" "$JP" "$R/new.job" "$OP" "$KEYID")"; chk "worker open without the key file -> stops" $([ $? != 0 ] && grep -q "test key file is not here" <<<"$out"; echo $?)
mkdir -p "$R/w/home/tc-test-key"; cp "$R/m/home/tc-test-key/test-key.txt" "$R/w/home/tc-test-key/"; chmod 644 "$R/w/home/tc-test-key/test-key.txt"
out="$(win open worker "$R/new.jar" "$JP" "$R/new.job" "$OP" "$KEYID")"; chk "worker open with a key file of mode 644 -> stops" $([ $? != 0 ] && grep -q "must be mode 600" <<<"$out"; echo $?)
chmod 600 "$R/w/home/tc-test-key/test-key.txt"
out="$(win open worker "$R/new.jar" "$JP" "$R/new.job" "$OP" "TEST-0000000000000000")"; chk "worker open with a different key id -> stops" $([ $? != 0 ] && grep -q "not the expected one" <<<"$out"; echo $?)
out="$(win open worker "$R/new.jar" "$JP" none none "$KEYID")"; rc=$?; chk "worker open with the right key and id, without the job (none none) -> OK, and the jar is the new one" $([ $rc = 0 ] && grep -q "M512W-OPEN-OK worker" <<<"$out" && grep -q "wrapped --restart" "$R/w/mode-calls.txt" && [ "$(sha256sum "$R/w/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sha256sum "$R/new.jar" | cut -c1-64)" ]; echo $?)
out="$(win close worker)"; chk "worker close -> OK and the measured files are back" $(grep -q "M512W-CLOSE-OK worker" <<<"$out" && [ "$(sha256sum "$R/w/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/w/measured-fps.txt")" ]; echo $?)

mknode w2; nodeenv w2 worker; rm -f "$M512W_BUSY"; mkdir -p "$R/w2/home/tc-test-key"; cp "$R/m/home/tc-test-key/test-key.txt" "$R/w2/home/tc-test-key/" 2>/dev/null; chmod 600 "$R/w2/home/tc-test-key/test-key.txt" 2>/dev/null; out="$(win open worker "$R/new.jar" "$JP" "$R/new.job" "$OP" "$KEYID")"; chk "the worker does not need a marker file (the reservation is on the master)" $(grep -q "M512W-OPEN-OK worker" <<<"$out"; echo $?)
echo "=== 3. the faults of open and close: they must stop, say why, and leave nothing half-done"
f() { mknode m; nodeenv m master; eval "$2"; out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; rc=$?; chk "open fault: $1 -> stops ($3)" $([ $rc != 0 ] && grep -q "$3" <<<"$out"; echo $?); }
f "the cluster is not reserved" 'rm -f "$M512W_BUSY"' "not reserved"; chk "   and no window was left behind" $([ ! -d "$R/m/home/m512w/window" ]; echo $?)
f "the cluster is held by somebody else" 'printf "subhiksharamanathan\t2026\tcrawl\n" > "$M512W_BUSY"' "is held by subhiksharamanathan"
mknode m; nodeenv m master; out="$(win open master "$R/new.jar" "0000000000000000" "$R/new.job" "$OP")"; chk_unused=1
mknode m; nodeenv m master; out="$(win open master "$R/new.jar" "$JP" none none)"; chk "open fault: the master may not skip the job -> stops" $([ $? != 0 ] && grep -q "the master must give the job" <<<"$out"; echo $?)
mknode m; nodeenv m master; out="$(win open master "$R/new.jar" "0000000000000000" "$R/new.job" "$OP")"; chk "open fault: another jar fingerprint -> stops" $([ $? != 0 ] && grep -q "new jar is missing or has another fingerprint" <<<"$out"; echo $?)
f "a YARN application is running" 'export FAKE_APPS=1' "YARN applications are running"
f "the stack is not the measured one (the jar was changed)" 'echo x >> "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar"' "do not open a window on top of a changed stack"; chk "   and no window was left behind (a retry is possible)" $([ ! -d "$R/m/home/m512w/window" ]; echo $?)
f "the mode switch fails" 'export FAKE_MODE_FAIL=1' "the mode switch failed"; chk "   and the window stays, with the saved files, so that close can restore" $([ -f "$R/m/home/m512w/window/saved/attested-hdfs.jar" ]; echo $?)
unset FAKE_MODE_FAIL FAKE_APPS; out="$(win close master)"; chk "   close after a failed open restores the measured jar and settings" $(grep -q "M512W-CLOSE-OK" <<<"$out" && [ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
mknode m; nodeenv m master; win open master "$R/new.jar" "$JP" "$R/new.job" "$OP" >/dev/null; out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; chk "open fault: a window is open already -> stops" $([ $? != 0 ] && grep -q "window is open already" <<<"$out"; echo $?)
export FAKE_APPS=1; out="$(win close master)"; chk "close fault: a YARN application is running -> stops" $([ $? != 0 ] && grep -q "YARN applications are running" <<<"$out"; echo $?); unset FAKE_APPS
rm -f "$M512W_BUSY"; out="$(win close master)"; chk "close fault: the cluster is not reserved -> stops" $([ $? != 0 ] && grep -q "not reserved" <<<"$out"; echo $?); printf 'rishabsdp17\t2026\tsigned wrapper test\n' > "$M512W_BUSY"
echo x >> "$R/m/home/m512w/window/modes/core-site.xml.plain"; out="$(win close master)"; chk "close fault: the restore point differs from the saved settings -> stops before changing anything" $([ $? != 0 ] && grep -q "restore point differs" <<<"$out"; echo $?)
mknode m2; nodeenv m2 master; out="$(win close master)"; chk "close fault: no window is open -> stops" $([ $? != 0 ] && grep -q "no open window" <<<"$out"; echo $?)

echo "=== 4. the demonstration notices a weak wrapper"
mknode m; nodeenv m master; win open master "$R/new.jar" "$JP" "$R/new.job" "$OP" >/dev/null
out="$(demo "$R/new.jar" "$R/m/home/m512w/demo-early")"; chk "demo: runs only while the window is open and the cluster is reserved (it ran, so both held)" $(grep -q "M512-DEMO-OK" <<<"$out"; echo $?)
# a wrapper whose signature check accepts everything: the demonstration must FAIL
rm -rf "$R/weak-src" "$R/weak-out" && mkdir -p "$R/weak-src" "$R/weak-out" && cp "$WORKSRC"/*.java "$R/weak-src/"
python3 - "$R/weak-src/AttestedHdfsFileSystem.java" <<'PY'
import sys
s = open(sys.argv[1]).read()
for old in ("if (!Arrays.equals(id, d.folderId)) {", "if (!f.getName().equals(d.fileName)) {"):
    assert old in s; s = s.replace(old, "if (false) {", 1)
open(sys.argv[1], "w").write(s)
PY
java -m jdk.compiler/com.sun.tools.javac.Main -source 11 -target 11 -Xlint:-options -nowarn -cp "$CP" -d "$R/weak-out" "$R/weak-src/"*.java 2>&1 | head -3
rm -rf "$R/m/home/m512w/demo2"; out="$(FAKE_CP="$CP$R/weak-out:$WORKOUT:$STUBS:$TOOLSOUT" demo "$R/new.jar" "$R/m/home/m512w/demo2")"; rc=$?
chk "a weak wrapper (the folder and name of a record are never compared): the demonstration FAILS and names the attacks that were not refused" $([ $rc != 0 ] && grep -q "M512-DEMO-FAILED" <<<"$out" && grep -q "FAIL: attack [123]" <<<"$out"; echo $?)
mknode m3; nodeenv m3 master; out="$(demo "$R/new.jar" "$R/m3/home/m512w/demo")"; chk "demo fault: the window is not open (signing is not on) -> stops" $([ $? != 0 ] && grep -q "the window is not open on this node" <<<"$out"; echo $?)
mknode m4; nodeenv m4 master; win open master "$R/new.jar" "$JP" "$R/new.job" "$OP" >/dev/null; rm -f "$M512W_BUSY"; out="$(demo "$R/new.jar" "$R/m4/home/m512w/demo")"; chk "demo fault: the cluster is not reserved -> stops" $([ $? != 0 ] && grep -q "reserve the cluster first" <<<"$out"; echo $?)
nodeenv w worker; out="$(demo "$R/new.jar" "$R/w/home/m512w/demo")"; chk "demo fault: it is run on the worker -> stops" $([ $? != 0 ] && grep -q "runs on the master" <<<"$out"; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the real window and demonstration scripts, with the real wrapper, key tool and demonstration tools, pass; the faults and a weak wrapper are all reported; $PASS checks"; else echo "REHEARSAL-FAIL"; exit 1; fi
