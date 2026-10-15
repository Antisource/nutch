#!/usr/bin/env bash
# Milestone 5, baby step 5.1.2, part 3: open and close the reserved window in which the signed wrapper runs on a node.
#
#   bash ops/attested/m512-window.sh open  ROLE NEWJAR JARPREFIX NEWJOB|none JOBPREFIX|none [KEYID]
#   bash ops/attested/m512-window.sh close ROLE
#     ROLE          master | worker (the node this script runs on)
#     NEWJAR/NEWJOB the wrapper jar and the job built by part 2 (m512-build.sh), with the first 16 or more hex characters of their SHA-256.
#                   The worker may give  none none  for the job (it is 134 MB and stays on the master): it installs the same jar, pinned by its fingerprint,
#                   which the master's open has already checked class by class against the job.
#     KEYID         worker only: the id of the test key that the master generated (the worker must hold the same key file)
#
# OPEN, on this node, in this order, stopping at the first problem:
#   checks (right machine, no window open yet, the cluster is reserved by you with tc-busy.sh, the new files are the built ones, no YARN
#   application runs on the master, the stack is the measured one right now); saves the installed jar and core-site.xml; makes (master) or
#   checks (worker) the test key; makes the signed version of core-site.xml (the measured one plus five settings: signing on, required, test keys
#   allowed, folder binding on, folder binding required); installs the jar (atomically, refusing unless its classes equal the job's); applies the settings with
#   cluster-mode.sh and restarts this node's daemons; checks the result.
# CLOSE restores the saved jar and core-site.xml, restarts this node's daemons, checks that they are byte for byte what they were, and that the
# measured set is unchanged. The test key file stays (it is a TEST key, never evidence; delete it when the test is over).
# A window is a state: ~/m512w/window on the node. While it exists, this node is NOT the measured stack and runs are not covered (ADR-029).
# Test hooks (rehearsal only): M512W_HOME, M512W_HOST, M512W_USER, M512W_TOOLS, M512W_MODE, M512W_CHECK, M512W_BUSY, M512W_NUTCH_DIR.
set -uo pipefail

HOME_="${M512W_HOME:-$HOME}"; HH="${HADOOP_HOME:-$HOME_/hadoop}"; ME="${M512W_USER:-$(id -un)}"
KITDIR="$(cd "$(dirname "$0")" && pwd)"; TOOLS="${M512W_TOOLS:-$KITDIR}"; MODE="${M512W_MODE:-$TOOLS/cluster-mode.sh}"
CHECK="${M512W_CHECK:-$HOME_/m482kit/m482/check-unchanged-m482.sh}"; BUSY="${M512W_BUSY:-/opt/tc-shared/state/BUSY}"
NUTCH_DIR="${M512W_NUTCH_DIR:-$HOME_/m481/patched}"
CONF="$HH/etc/hadoop/core-site.xml"; LIBJAR="$HH/share/hadoop/common/lib/attested-hdfs.jar"
WIN="$HOME_/m512w/window"; KEYDIR="$HOME_/tc-test-key"; KEYFILE="$KEYDIR/test-key.txt"
ACTION="${1:?usage: $0 open|close ROLE ...}"; ROLE="${2:?usage: $0 open|close ROLE ...}"
HOST="${M512W_HOST:-$(hostname)}"
case "$ROLE" in master) WANT=tdx-lab ;; worker) WANT=tdx-lab-worker ;; *) echo "M512W-STOP: the role must be master or worker" >&2; exit 1 ;; esac
[ "$HOST" = "$WANT" ] || { echo "M512W-STOP: this machine is $HOST, but the role $ROLE belongs to $WANT" >&2; exit 1; }
cd "$HOME_" || exit 1
LOGF=""; CHANGED=0   # CHANGED becomes 1 when the first thing on this node is changed (the jar install)
say()  { echo "$*" | tee -a "$LOGF"; }
ok()   { say "   ok:   $*"; }
stop() {
  say "M512W-STOP: $*"
  # an open that stopped before it changed anything on this node leaves no window behind, so that it can simply be started again
  if [ "$ACTION" = open ] && [ -d "$WIN" ] && [ "$CHANGED" = 0 ]; then
    cp "$LOGF" "$HOME_/m512w/window-open-$ROLE.failed.log" 2>/dev/null; rm -rf "$WIN" "$WIN".check-* 2>/dev/null
  fi
  exit 1
}
fp()   { sha256sum "$1" | cut -c1-64; }
need_busy() {
  if [ "$ROLE" = worker ]; then ok "the reservation is held on the master (this node has no marker file); only open this after the master's open succeeded"; return; fi
  [ -f "$BUSY" ] || stop "the cluster is not reserved: run  tc-busy.sh start \"signed wrapper test\"  first"
  [ "$(cut -f1 "$BUSY")" = "$ME" ] || stop "the cluster is held by $(cut -f1 "$BUSY"), not by you: $(cut -f3 "$BUSY")"
  ok "the cluster is reserved by you ($(cut -f3 "$BUSY"))"
}
no_app() {
  if [ "$ROLE" = master ]; then
    n="$("$HH/bin/yarn" application -list -appStates RUNNING 2>/dev/null | grep -c 'application_[0-9]' || true)"
    [ "$n" = 0 ] && ok "no YARN application is running" || stop "$n YARN applications are running"
  fi
}
measured_intact() { # measured_intact <label>
  local nd=""; [ "$ROLE" = master ] && nd="$NUTCH_DIR"
  if NUTCH_DIR="$nd" bash "$CHECK" > "$WIN.check-$1.txt" 2>&1 && grep -q 'ALL-UNCHANGED' "$WIN.check-$1.txt"; then ok "$2 ($(grep ALL-UNCHANGED "$WIN.check-$1.txt"))"
  else tail -4 "$WIN.check-$1.txt"; stop "$3"; fi
}

if [ "$ACTION" = open ]; then
  NEWJAR="${3:?usage: $0 open ROLE NEWJAR JARPREFIX NEWJOB JOBPREFIX [KEYID]}"; JP="${4:?}"; NEWJOB="${5:?}"; OP="${6:?}"; KEYID="${7:-}"
  mkdir -p "$HOME_/m512w"; [ ! -e "$WIN" ] || { echo "M512W-STOP: a window is open already (or an earlier one was not closed): $WIN" >&2; exit 1; }
  LOGF="$HOME_/m512w/window-open-$ROLE.log"; : > "$LOGF"
  say "m512-window open: $(date -u +%FT%TZ) on $HOST   role=$ROLE"
  say "== checks"
  [ ${#JP} -ge 16 ] && { [ "$NEWJOB" = none ] || [ ${#OP} -ge 16 ]; } || stop "give at least 16 hex characters of each fingerprint"
  [ -f "$NEWJAR" ] && [ "$(fp "$NEWJAR" | cut -c1-${#JP})" = "$JP" ] && ok "the new jar is the built one ($JP...)" || stop "the new jar is missing or has another fingerprint"
  if [ "$NEWJOB" = none ]; then
    [ "$ROLE" = worker ] || stop "the master must give the job: it is where the jar is checked class by class against the job"
    NEWJOB=""; ok "no job on the worker: the jar is pinned by its fingerprint (the master checked it against the job)"
  else
    [ -f "$NEWJOB" ] && [ "$(fp "$NEWJOB" | cut -c1-${#OP})" = "$OP" ] && ok "the new job is the built one ($OP...)" || stop "the new job is missing or has another fingerprint"
  fi
  need_busy; no_app
  [ -f "$LIBJAR" ] && [ -f "$CONF" ] || stop "no installed wrapper jar or core-site.xml under $HH"
  mkdir -p "$WIN"; mv "$LOGF" "$WIN/open.log"; LOGF="$WIN/open.log"
  measured_intact before "the stack is the measured one right now" "the stack is not the measured one; do not open a window on top of a changed stack"
  say "== save what is installed now"
  mkdir -p "$WIN/saved" "$WIN/modes"
  cp -p "$LIBJAR" "$WIN/saved/attested-hdfs.jar" && cp -p "$CONF" "$WIN/saved/core-site.xml" || stop "cannot save the installed files"
  { echo "jar  $(fp "$WIN/saved/attested-hdfs.jar")"; echo "core $(fp "$WIN/saved/core-site.xml")"; } > "$WIN/saved/fingerprints.txt"
  ok "saved the jar ($(fp "$WIN/saved/attested-hdfs.jar" | cut -c1-16)...) and core-site.xml ($(fp "$WIN/saved/core-site.xml" | cut -c1-16)...)"
  say "== the test key"
  if [ "$ROLE" = master ]; then
    if [ -f "$KEYFILE" ]; then ok "reusing the test key file that exists: $(java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool info "$KEYFILE" 2>&1 | head -1)"
    else mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR" && java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool generate "$KEYFILE" > "$WIN/keytool.txt" 2>&1 && ok "$(cat "$WIN/keytool.txt")" || stop "cannot make the test key ($(cat "$WIN/keytool.txt"))"; fi
    info="$(java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool info "$KEYFILE" 2>&1)"; echo "$info" | grep -q "can sign: true" || stop "the key file cannot sign: $info"
    say "   >>> the test key id is: $(echo "$info" | grep -o 'TEST-[0-9a-f]*' | head -1)   (give it to the worker's open command, and copy $KEYFILE there)"
  else
    [ -n "$KEYID" ] || stop "the worker needs the key id that the master printed"
    [ -f "$KEYFILE" ] || stop "the test key file is not here: $KEYFILE (copy it from the master first)"
    info="$(java -cp "$NEWJAR" org.apache.nutch.attested.AttestedKeyTool info "$KEYFILE" 2>&1)"
    echo "$info" | grep -q "key id $KEYID " && echo "$info" | grep -q "can sign: true" && ok "the key file here is the master's key ($KEYID) and can sign" || stop "the key file here is not the expected one: $info"
    [ "$(stat -c %a "$KEYFILE")" = 600 ] || stop "the key file must be mode 600 (it is $(stat -c %a "$KEYFILE")): chmod 600 $KEYFILE"
  fi
  say "== the signed version of core-site.xml (the measured one plus five settings)"
  cp -p "$CONF" "$WIN/modes/core-site.xml.plain"
  python3 - "$CONF" "$WIN/modes/core-site.xml.wrapped" <<'PY' || stop "could not make the signed core-site.xml"
import sys, xml.etree.ElementTree as ET
src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
names = [p.findtext("name") for p in ET.fromstring(text).findall("property")]
new = ["attested.signature.enabled", "attested.signature.required", "attested.signature.allow.test.keys", "attested.folder.binding.enabled", "attested.folder.binding.required"]
if any(n in names for n in new): sys.exit("one of the signature or binding settings is in core-site.xml already")
block = "".join("  <property>\n    <name>%s</name>\n    <value>true</value>\n    <final>true</final>\n  </property>\n" % n for n in new)
i = text.rindex("</configuration>")
res = text[:i] + block + text[i:]
after = [p.findtext("name") for p in ET.fromstring(res).findall("property")]
if after != names + new: sys.exit("the new file does not hold exactly the old settings plus five")
open(out, "w", encoding="utf-8").write(res)
print("ok")
PY
  ok "the signed core-site.xml holds the measured settings plus signature.enabled, signature.required, allow.test.keys, folder.binding.enabled and folder.binding.required (all final)"
  say "== install the jar (atomically; refused unless its classes equal the job's)"
  CHANGED=1
  ATTESTED_FORCE=1 bash "$TOOLS/wrapper-jar.sh" install "$NEWJAR" ${NEWJOB:+"$NEWJOB"} > "$WIN/install.log" 2>&1 && grep -q WRAPPER-JAR-INSTALLED "$WIN/install.log" && ok "installed: $(grep -o 'sha256 [0-9a-f]*' "$WIN/install.log" | cut -c1-24)..." || { tail -3 "$WIN/install.log"; stop "the jar could not be installed (the saved jar is in $WIN/saved; run close to be sure)"; }
  say "== apply the settings and restart this node's daemons (cluster-mode.sh, as in every earlier switch)"
  CLUSTER_MODE_DIR="$WIN/modes" bash "$MODE" wrapped --restart > "$WIN/mode.log" 2>&1; rc=$?
  tail -3 "$WIN/mode.log" | sed 's/^/   | /'
  [ $rc = 0 ] && grep -q "CLUSTER-MODE-OK" "$WIN/mode.log" && ok "daemons restarted with the signed settings" || stop "the mode switch failed (see $WIN/mode.log); run close to restore the measured jar and settings"
  say "== check the result"
  [ "$(fp "$LIBJAR" | cut -c1-${#JP})" = "$JP" ] && ok "the installed jar is the new one" || stop "the installed jar is not the new one"
  [ "$("$HH/bin/hdfs" getconf -confKey attested.signature.enabled 2>/dev/null)" = true ] && [ "$("$HH/bin/hdfs" getconf -confKey attested.signature.required 2>/dev/null)" = true ] && [ "$("$HH/bin/hdfs" getconf -confKey attested.folder.binding.enabled 2>/dev/null)" = true ] && [ "$("$HH/bin/hdfs" getconf -confKey attested.folder.binding.required 2>/dev/null)" = true ] && ok "this node's configuration says: signing on, signatures required, folder binding on and required" || stop "the signature and binding settings are not in effect"
  if [ -n "$NEWJOB" ]; then bash "$TOOLS/wrapper-jar.sh" verify "$NEWJOB" 2>&1 | grep -q CLASSES-SAME && ok "CLASSES-SAME: the installed wrapper classes equal the new job's" || stop "the installed classes do not equal the new job's"
  else bash "$TOOLS/wrapper-jar.sh" verify 2>&1 | grep -q "entries on Hadoop's classpath: 1" && ok "the installed jar is on Hadoop's classpath (once)" || stop "the installed jar is not on Hadoop's classpath"; fi
  say "M512W-OPEN-OK $ROLE: the signed wrapper is installed and switched on here. This node is NOT the measured stack until you run close."
  cp "$LOGF" "$HOME_/m512w/window-open-$ROLE.log"
else
  [ -d "$WIN/saved" ] || { echo "M512W-STOP: no open window found at $WIN (nothing to close)" >&2; exit 1; }
  LOGF="$WIN/close.log"; : > "$LOGF"
  say "m512-window close: $(date -u +%FT%TZ) on $HOST   role=$ROLE"
  say "== checks"
  need_busy; no_app
  [ -f "$WIN/saved/attested-hdfs.jar" ] && [ -f "$WIN/saved/core-site.xml" ] && [ -f "$WIN/modes/core-site.xml.plain" ] || stop "the saved files are incomplete in $WIN"
  [ "$(fp "$WIN/modes/core-site.xml.plain")" = "$(awk '/^core /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "the restore point equals the saved core-site.xml" || stop "the restore point differs from the saved core-site.xml"
  say "== restore the measured jar (atomically) and the measured settings, and restart this node's daemons"
  ATTESTED_FORCE=1 bash "$TOOLS/wrapper-jar.sh" install "$WIN/saved/attested-hdfs.jar" > "$WIN/restore-jar.log" 2>&1 && grep -q WRAPPER-JAR-INSTALLED "$WIN/restore-jar.log" && ok "the saved jar is installed again" || { tail -3 "$WIN/restore-jar.log"; stop "could not restore the jar (it is saved in $WIN/saved/attested-hdfs.jar)"; }
  CLUSTER_MODE_DIR="$WIN/modes" bash "$MODE" plain --restart > "$WIN/restore-mode.log" 2>&1; rc=$?
  tail -3 "$WIN/restore-mode.log" | sed 's/^/   | /'
  [ $rc = 0 ] && grep -q "CLUSTER-MODE-OK" "$WIN/restore-mode.log" && ok "the measured settings are back and the daemons restarted" || stop "the mode switch back failed (see $WIN/restore-mode.log)"
  say "== check that it is the measured stack again"
  [ "$(fp "$LIBJAR")" = "$(awk '/^jar /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "the installed jar is byte for byte the saved one" || stop "the installed jar differs from the saved one"
  [ "$(fp "$CONF")" = "$(awk '/^core /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "core-site.xml is byte for byte the saved one" || stop "core-site.xml differs from the saved one"
  "$HH/bin/hdfs" getconf -confKey attested.signature.enabled >/dev/null 2>&1 && stop "the signature setting is still in effect" || "$HH/bin/hdfs" getconf -confKey attested.folder.binding.enabled >/dev/null 2>&1 && stop "the binding setting is still in effect" || ok "the signature and binding settings are no longer in effect"
  measured_intact after "the measured set is unchanged" "the measured set differs after the restore"
  say "M512W-CLOSE-OK $ROLE: this node is the measured stack again. The test key file is still in $KEYDIR (delete it when the test is over)."
  mv "$WIN" "$HOME_/m512w/window-closed-$ROLE-$(date -u +%Y%m%dT%H%M%SZ)"
fi
