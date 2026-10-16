#!/usr/bin/env bash
# Rehearsal of m521-window.sh away from the cluster. The REAL script runs with the REAL wrapper code, the REAL signing service (KeyService, started for real from the
# installed jar), the REAL key bundle tool, the REAL m513_bundle_extract.py, the REAL verify-binding.sh and the REAL wrapper-jar.sh, over a node folder that plays a node.
# Stand-ins: the quote command (a script that writes a 632-byte quote with the right REPORTDATA), the TDX guest folder, sudo, hdfs/yarn/hadoop (FakeHdfsCli), cluster-mode.sh
# (it swaps core-site.xml from the mode folder), the measured-set check, and the compiler command.
# Usage: bash m521-window-rehearse.sh KITDIR REPO JARS STUBS WORKOUT BASEOUT TOOLSOUT
set -uo pipefail
KIT="$1"; REPO="$2"; JARS="$3"; STUBS="$4"; WORKOUT="$5"; BASEOUT="$6"; TOOLSOUT="$7"
PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; CP="$(ls "$JARS"/*.jar | tr '\n' ':')"
printf '#!/bin/bash\nexec java -m jdk.compiler/com.sun.tools.javac.Main "$@"\n' > "$R/javac-standin"; chmod +x "$R/javac-standin"
cp "$KIT/ops/attested/wrapper-jar.sh" "$KIT/ops/attested/m513_bundle_extract.py" "$KIT/ops/attested/verify-binding.sh" "$R/"; chmod +x "$R/wrapper-jar.sh"
mkdir -p "$R/fake-tsm" "$R/xbin"
if ! command -v xxd >/dev/null; then cat > "$R/xbin/xxd" <<'EOX'
#!/usr/bin/env python3
import sys
a = sys.argv[1:]; skip = int(a[a.index("-s") + 1]); length = int(a[a.index("-l") + 1]); data = open(a[-1], "rb").read()[skip:skip + length].hex()
for i in range(0, len(data), 60): print(data[i:i + 60])
EOX
chmod +x "$R/xbin/xxd"; export PATH="$R/xbin:$PATH"; fi
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
printf '#!/usr/bin/env bash\necho "no TDX here" >&2; exit 3\n' > "$R/broken-quote.sh"; chmod +x "$R/broken-quote.sh"
# jobs: the measured job (old classes) and the new job (new classes): top-level classes plus a dummy entry, as in a real job file
mkjob() { python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED)
for root, _, files in os.walk(os.path.join(src, "org/apache/nutch/attested")):
    for f in sorted(files):
        if f.startswith(("AttestedFsSmoke", "SigCoreTest", "KeyCoreTest", "M513", "FakeHdfsCli")): continue
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
  N="$R/$1"; export M521W_HOME="$N/home" HOME="$N/home" HADOOP_HOME="$N/home/hadoop" HADOOP_CONF_DIR="$N/home/hadoop/etc/hadoop" M521W_TOOLS="$R" M521W_MODE="$R/cluster-mode.sh" M521W_CHECK="$N/check.sh" \
    M521W_BUSY="$N/BUSY" M521W_USER=rishabsdp17 M521W_NUTCH_DIR="$N/home/m481/patched" FAKE_ROOT="$N/fake-root" FAKE_STATE="$N/state" FAKE_CALLS="$N/mode-calls.txt" FAKE_CP="$FAKE_CP" \
    M521W_QUOTE="$R/fake-quote.sh" M521W_TSM="$R/fake-tsm" M521W_SUDO=true M521W_START_WAIT=8 M521W_SKIP_ADMIT=1
  [ "$2" = master ] && export M521W_HOST=tdx-lab M521W_PORT=17471 || export M521W_HOST=tdx-lab-worker M521W_PORT=17472
  unset FAKE_APPS FAKE_MODE_FAIL M521W_REFERENCE; cd "$N/home"
}
win() { ( cd "$KIT" && bash ops/attested/m521-window.sh "$@" ) 2>&1; }


trap 'for n in m w m2 m3 m4; do [ -f "$R/$n/home/m521w/window/keyservice.pid" ] && kill $(cat "$R/$n/home/m521w/window/keyservice.pid") 2>/dev/null; done' EXIT
listening() { python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except Exception: sys.exit(1)
PY
}
echo "=== 1. the master: open the window, the signing service starts, close the window"
mknode m; nodeenv m master
out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; rc=$?; echo "$out" | tail -22 | cut -c1-200
chk "open exits 0 and says M521W-OPEN-OK" $([ $rc = 0 ] && grep -q "M521W-OPEN-OK master" <<<"$out"; echo $?)
chk "the installed jar is the new one, and the measured jar was saved" $([ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sha256sum "$R/new.jar" | cut -c1-64)" ] && [ "$(sha256sum "$R/m/home/m521w/window/saved/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
chk "the signed core-site.xml has the thirteen new settings, all final, with the right values, and keeps the measured ones" $(python3 - "$R/m/home/hadoop/etc/hadoop/core-site.xml" "$R/m/home" "$(sha256sum "$KIT/ops/attested/reference-measurements-m521.txt" | cut -d" " -f1)" <<'PY'; echo $?
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot(); d = {p.findtext("name"): (p.findtext("value"), p.findtext("final")) for p in r.findall("property")}; h = sys.argv[2]
want = {"attested.signature.enabled": "true", "attested.signature.required": "true", "attested.signature.allow.test.keys": "false", "attested.folder.binding.enabled": "true", "attested.folder.binding.required": "true",
        "attested.keys.provider": "service", "attested.keys.service.address": "127.0.0.1:17471", "attested.keys.service.token.file": h + "/tc-keyservice/token", "attested.keys.list.dir": h + "/tc-keys/list", "attested.keys.list.allow.unquoted": "false",
        "attested.keys.admission.enabled": "true", "attested.keys.admission.reference.file": h + "/tc-keys/reference-measurements.txt", "attested.keys.admission.reference.sha256": sys.argv[3]}
ok = all(d.get(k) == (v, "true") for k, v in want.items()) and "fs.hdfs.impl" in d and "fs.defaultFS" in d
sys.exit(0 if ok else 1)
PY
)
chk "the reference file of the kit is in place in the key folder, and the pin in core-site.xml is its SHA-256" $(cmp -s "$KIT/ops/attested/reference-measurements-m521.txt" "$R/m/home/tc-keys/reference-measurements.txt"; echo $?)
chk "the mode script was called with the mode folder of the window and --restart" $(grep -q "wrapped --restart dir=window/modes" "$R/m/mode-calls.txt"; echo $?)
KB="$(ls "$R/m/home/tc-keyservice"/TDX-*.attestkey 2>/dev/null | head -1)"; SKID="$(basename "${KB:-none}" .attestkey)"
chk "the signing service runs: a TDX- key bundle exists, the pid is alive and the port answers" $([ -n "$KB" ] && kill -0 "$(cat "$R/m/home/m521w/window/keyservice.pid")" 2>/dev/null && listening 17471; echo $?)
chk "the bundle was also written into the key list of this node" $([ -f "$R/m/home/tc-keys/list/$SKID.attestkey" ]; echo $?)
chk "the quote was taken out of the bundle and checked twice (our check and verify-binding.sh)" $(grep -q "EXTRACT-MATCH" "$R/m/home/m521w/window/extract.txt" && grep -q "says MATCH" <<<"$out" && grep -q "bundle verifies" <<<"$out"; echo $?)
chk "the token file is private (mode 600) and the private key is in no file of the service folder" $([ "$(stat -c %a "$R/m/home/tc-keyservice/token")" = 600 ] && ! grep -rIl "PRIVATE" "$R/m/home/tc-keyservice" 2>/dev/null | grep -q .; echo $?)
chk "the configuration says: provider service, test keys not allowed" $([ "$("$R/m/home/hadoop/bin/hdfs" getconf -confKey attested.keys.provider)" = service ] && [ "$("$R/m/home/hadoop/bin/hdfs" getconf -confKey attested.signature.allow.test.keys)" = false ]; echo $?)
SVPID="$(cat "$R/m/home/m521w/window/keyservice.pid")"
out="$(win close master)"; rc=$?; echo "$out" | tail -12 | cut -c1-200
chk "close exits 0 and says M521W-CLOSE-OK" $([ $rc = 0 ] && grep -q "M521W-CLOSE-OK master" <<<"$out"; echo $?)
chk "the jar and core-site.xml are byte for byte the measured ones again" $([ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ] && [ "$(sha256sum "$R/m/home/hadoop/etc/hadoop/core-site.xml" | cut -c1-64)" = "$(sed -n 2p "$R/m/measured-fps.txt")" ]; echo $?)
chk "the signing service is stopped and its port is closed" $(! kill -0 "$SVPID" 2>/dev/null && ! listening 17471; echo $?)
CW="$(ls -d "$R/m/home/m521w/window-closed-master-"* 2>/dev/null | head -1)"
chk "the service folder was kept in the window folder (bundle, audit log with START and the close's stop line), the token deleted, ~/tc-keyservice is gone" $([ -f "$CW/keyservice-dir/audit.log" ] && grep -q " START key=TDX-" "$CW/keyservice-dir/audit.log" && grep -q " STOPPED-BY-WINDOW-CLOSE " "$CW/keyservice-dir/audit.log" && [ ! -e "$CW/keyservice-dir/token" ] && [ ! -d "$R/m/home/tc-keyservice" ]; echo $?)
chk "the public bundle stays in the key list" $([ -f "$R/m/home/tc-keys/list/$SKID.attestkey" ]; echo $?)

echo "=== 2. the worker: same jar, no job; its own service and its own key"
mknode w; nodeenv w worker
out="$(win open worker "$R/new.jar" "$JP" none none)"; rc=$?; echo "$out" | tail -6 | cut -c1-190
chk "worker open without the job (none none) -> OK, with its own service on its own port" $([ $rc = 0 ] && grep -q "M521W-OPEN-OK worker" <<<"$out" && listening 17472 && [ -n "$(ls "$R/w/home/tc-keyservice"/TDX-*.attestkey 2>/dev/null)" ]; echo $?)
WKID="$(basename "$(ls "$R/w/home/tc-keyservice"/TDX-*.attestkey | head -1)" .attestkey)"
chk "the worker's key is another key than the master's (each machine makes its own)" $([ "$WKID" != "$SKID" ]; echo $?)
out="$(win close worker)"; chk "worker close -> OK, measured files back, service stopped" $(grep -q "M521W-CLOSE-OK worker" <<<"$out" && [ "$(sha256sum "$R/w/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/w/measured-fps.txt")" ] && ! listening 17472; echo $?)

echo "=== 3. the faults of open: they must stop, say why, and leave nothing half-done"
f() { mknode m; nodeenv m master; eval "$2"; out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; rc=$?; chk "open fault: $1 -> stops ($3)" $([ $rc != 0 ] && grep -q "$3" <<<"$out"; echo $?); if ! { [ $rc != 0 ] && grep -q "$3" <<<"$out"; }; then echo "      (rc=$rc; the script said:)"; echo "$out" | tail -4 | cut -c1-210 | sed "s/^/      | /"; fi; }
f "the cluster is not reserved" 'rm -f "$M521W_BUSY"' "not reserved"; chk "   and no window was left behind" $([ ! -d "$R/m/home/m521w/window" ]; echo $?)
f "the cluster is held by somebody else" 'printf "subhiksharamanathan\t2026\tcrawl\n" > "$M521W_BUSY"' "is held by subhiksharamanathan"
f "a YARN application is running" 'export FAKE_APPS=1' "YARN applications are running"
f "the stack is not the measured one (the jar was changed)" 'echo x >> "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar"' "do not open a window on top of a changed stack"
f "this is not a TDX guest (no configfs-tsm folder)" 'export M521W_TSM="$R/no-such-tsm"' "not a TDX guest"; chk "   and no window or service folder was left behind" $([ ! -d "$R/m/home/m521w/window" ] && [ ! -d "$R/m/home/tc-keyservice" ]; echo $?)
f "sudo asks for a password (the quote script cannot run)" 'export M521W_SUDO=false' "sudo asks for a password"
f "the quote script is missing" 'export M521W_QUOTE="$R/no-such-quote.sh"' "the quote script is missing"
f "something listens on the service port already" 'python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"127.0.0.1\",17471)); s.listen(1); time.sleep(40)" & sleep 1' "listens on 127.0.0.1:17471 already"; kill %1 2>/dev/null; wait 2>/dev/null
f "the node's own bundle is not admitted by its quote (the stand-in quote has no Intel chain; the skip hook is off)" 'unset M521W_SKIP_ADMIT' "the node's own bundle is not admitted"
out="$(win close master)"; chk "   close after that refused open restores the measured jar and settings" $(grep -q "M521W-CLOSE-OK" <<<"$out" && [ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
f "a different reference file is in the key folder already (an earlier window's)" 'mkdir -p "$R/m/home/tc-keys"; echo "MRTD ${RANDOM}" > "$R/m/home/tc-keys/reference-measurements.txt"' "exists and differs from the kit"
f "the reference file is missing from the kit" 'export M521W_REFERENCE="$R/no-such-reference.txt"' "the reference file is not in the kit"
f "a service folder from an earlier window exists" 'mkdir -p "$R/m/home/tc-keyservice"' "an earlier window did not close"
f "the quote command fails (no TDX): the service does not start" 'export M521W_QUOTE="$R/broken-quote.sh"' "the signing service did not start within 8 seconds"; chk "   and the window stays, with the saved files, so that close can restore" $([ -f "$R/m/home/m521w/window/saved/attested-hdfs.jar" ]; echo $?)
out="$(win close master)"; chk "   close after that failed open restores the measured jar and settings" $(grep -q "M521W-CLOSE-OK" <<<"$out" && [ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
f "the mode switch fails after the service started" 'export FAKE_MODE_FAIL=1' "the mode switch failed"
SVPID="$(cat "$R/m/home/m521w/window/keyservice.pid")"; chk "   the service is running, and the window stays" $(kill -0 "$SVPID" 2>/dev/null && [ -f "$R/m/home/m521w/window/saved/attested-hdfs.jar" ]; echo $?)
unset FAKE_MODE_FAIL FAKE_APPS; out="$(win close master)"; chk "   close stops that service and restores everything" $(grep -q "M521W-CLOSE-OK" <<<"$out" && ! kill -0 "$SVPID" 2>/dev/null && [ "$(sha256sum "$R/m/home/hadoop/share/hadoop/common/lib/attested-hdfs.jar" | cut -c1-64)" = "$(sed -n 1p "$R/m/measured-fps.txt")" ]; echo $?)
mknode m; nodeenv m master; out="$(win open master "$R/new.jar" "$JP" none none)"; chk "open fault: the master may not skip the job -> stops" $([ $? != 0 ] && grep -q "the master must give the job" <<<"$out"; echo $?)
mknode m; nodeenv m master; out="$(win open master "$R/new.jar" "0000000000000000" "$R/new.job" "$OP")"; chk "open fault: another jar fingerprint -> stops" $([ $? != 0 ] && grep -q "new jar is missing or has another fingerprint" <<<"$out"; echo $?)
mknode m; nodeenv m master; win open master "$R/new.jar" "$JP" "$R/new.job" "$OP" >/dev/null; out="$(win open master "$R/new.jar" "$JP" "$R/new.job" "$OP")"; chk "open fault: a window is open already -> stops" $([ $? != 0 ] && grep -q "window is open already" <<<"$out"; echo $?)
echo "=== 4. the faults of close"
export FAKE_APPS=1; out="$(win close master)"; chk "close fault: a YARN application is running -> stops" $([ $? != 0 ] && grep -q "YARN applications are running" <<<"$out"; echo $?); unset FAKE_APPS
rm -f "$M521W_BUSY"; out="$(win close master)"; chk "close fault: the cluster is not reserved -> stops" $([ $? != 0 ] && grep -q "not reserved" <<<"$out"; echo $?); printf 'rishabsdp17\t2026\treal key test\n' > "$M521W_BUSY"
echo x >> "$R/m/home/m521w/window/modes/core-site.xml.plain"; out="$(win close master)"; chk "close fault: the restore point differs from the saved settings -> stops before changing anything" $([ $? != 0 ] && grep -q "restore point differs" <<<"$out"; echo $?)
SVPID="$(cat "$R/m/home/m521w/window/keyservice.pid")"; chk "   and the service is still running (nothing was changed)" $(kill -0 "$SVPID" 2>/dev/null; echo $?); kill "$SVPID" 2>/dev/null
mknode m2; nodeenv m2 master; out="$(win close master)"; chk "close fault: no window is open -> stops" $([ $? != 0 ] && grep -q "no open window" <<<"$out"; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"
if [ "$FAILN" = 0 ]; then echo "REHEARSAL-PASS: the real window script, with the real signing service, key tool and bundle checks, passes; the faults of open and close are all reported; $PASS checks"; else echo "REHEARSAL-FAIL"; exit 1; fi
