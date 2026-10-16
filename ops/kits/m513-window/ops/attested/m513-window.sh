#!/usr/bin/env bash
# Milestone 5, baby step 5.1.3, part 3: open and close the reserved window in which the wrapper runs on a node with the REAL signing key.
#
#   bash ops/attested/m513-window.sh open  ROLE NEWJAR JARPREFIX NEWJOB|none JOBPREFIX|none
#   bash ops/attested/m513-window.sh close ROLE
#     ROLE          master | worker (the node this script runs on)
#     NEWJAR/NEWJOB the wrapper jar and the job built by part 2 (m513-build.sh), with the first 16 or more hex characters of their SHA-256.
#                   The worker may give  none none  for the job (it is 134 MB and stays on the master): it installs the same jar, pinned by its fingerprint,
#                   which the master's open has already checked class by class against the job.
#
# OPEN, on this node, in this order, stopping at the first problem:
#   checks (right machine, no window open yet, the cluster is reserved by you with tc-busy.sh, the new files are the built ones, no YARN application runs on
#   the master, the stack is the measured one right now, a TDX guest with the quote script, sudo without a password, a free port); saves the installed jar and
#   core-site.xml; makes the signed version of core-site.xml (the measured one plus ten settings: signing on and required, test keys NOT allowed, folder binding
#   on and required, the key provider "service" with its address, token file and key list, no unquoted keys); installs the jar (atomically, refusing unless its
#   classes equal the job's); STARTS THE SIGNING SERVICE (the key is made now, in memory only; the hardware makes the quote for it; the key bundle is written)
#   and checks the bundle, the quote's binding (our check and attest/verify-binding.sh) and that the service answers; applies the settings with cluster-mode.sh
#   and restarts this node's daemons; checks the result.
# CLOSE restores the saved jar and core-site.xml, restarts this node's daemons, STOPS THE SIGNING SERVICE (its key disappears with it), checks that the jar and
# core-site.xml are byte for byte what they were, and that the measured set is unchanged. The key list (public bundles) stays; the service folder is kept in the window folder.
# A window is a state: ~/m513w/window on the node. While it exists, this node is NOT the measured stack and runs are not covered (ADR-029).
# Test hooks (rehearsal only): M513W_HOME, M513W_HOST, M513W_USER, M513W_TOOLS, M513W_MODE, M513W_CHECK, M513W_BUSY, M513W_NUTCH_DIR, M513W_QUOTE, M513W_PORT, M513W_TSM.
set -uo pipefail

HOME_="${M513W_HOME:-$HOME}"; HH="${HADOOP_HOME:-$HOME_/hadoop}"; ME="${M513W_USER:-$(id -un)}"
KITDIR="$(cd "$(dirname "$0")" && pwd)"; TOOLS="${M513W_TOOLS:-$KITDIR}"; MODE="${M513W_MODE:-$TOOLS/cluster-mode.sh}"
CHECK="${M513W_CHECK:-$HOME_/m482kit/m482/check-unchanged-m482.sh}"; BUSY="${M513W_BUSY:-/opt/tc-shared/state/BUSY}"
NUTCH_DIR="${M513W_NUTCH_DIR:-$HOME_/m481/patched}"
CONF="$HH/etc/hadoop/core-site.xml"; LIBJAR="$HH/share/hadoop/common/lib/attested-hdfs.jar"
WIN="$HOME_/m513w/window"; KSDIR="$HOME_/tc-keyservice"; KLDIR="$HOME_/tc-keys/list"; PORT="${M513W_PORT:-7461}"; QUOTE="${M513W_QUOTE:-$KITDIR/quote.sh}"; TSM="${M513W_TSM:-/sys/kernel/config/tsm/report}"; SUDO="${M513W_SUDO:-sudo}"; START_WAIT="${M513W_START_WAIT:-90}"
ACTION="${1:?usage: $0 open|close ROLE ...}"; ROLE="${2:?usage: $0 open|close ROLE ...}"
HOST="${M513W_HOST:-$(hostname)}"
case "$ROLE" in master) WANT=tdx-lab ;; worker) WANT=tdx-lab-worker ;; *) echo "M513W-STOP: the role must be master or worker" >&2; exit 1 ;; esac
[ "$HOST" = "$WANT" ] || { echo "M513W-STOP: this machine is $HOST, but the role $ROLE belongs to $WANT" >&2; exit 1; }
cd "$HOME_" || exit 1
LOGF=""; CHANGED=0   # CHANGED becomes 1 when the first thing on this node is changed (the jar install)
say()  { echo "$*" | tee -a "$LOGF"; }
ok()   { say "   ok:   $*"; }
stop() {
  say "M513W-STOP: $*"
  # an open that stopped before it changed anything on this node leaves no window behind, so that it can simply be started again
  if [ "$ACTION" = open ] && [ -d "$WIN" ] && [ "$CHANGED" = 0 ]; then
    cp "$LOGF" "$HOME_/m513w/window-open-$ROLE.failed.log" 2>/dev/null; rm -rf "$WIN" "$WIN".check-* 2>/dev/null
  fi
  exit 1
}
fp()   { sha256sum "$1" | cut -c1-64; }
need_busy() {
  if [ "$ROLE" = worker ]; then ok "the reservation is held on the master (this node has no marker file); only open this after the master's open succeeded"; return; fi
  [ -f "$BUSY" ] || stop "the cluster is not reserved: run  tc-busy.sh start \"real key test\"  first"
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
  NEWJAR="${3:?usage: $0 open ROLE NEWJAR JARPREFIX NEWJOB JOBPREFIX}"; JP="${4:?}"; NEWJOB="${5:?}"; OP="${6:?}"
  mkdir -p "$HOME_/m513w"; [ ! -e "$WIN" ] || { echo "M513W-STOP: a window is open already (or an earlier one was not closed): $WIN" >&2; exit 1; }
  LOGF="$HOME_/m513w/window-open-$ROLE.log"; : > "$LOGF"
  say "m513-window open: $(date -u +%FT%TZ) on $HOST   role=$ROLE"
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
  say "== what the signing service needs on this node"
  command -v java >/dev/null && ok "java: $(java -version 2>&1 | head -1)" || stop "java is missing"
  [ -f "$QUOTE" ] && ok "the quote script is here: $QUOTE" || stop "the quote script is missing: $QUOTE"
  for t in xxd sha512sum python3; do command -v "$t" >/dev/null || stop "$t is missing (the quote script and attest/verify-binding.sh need it)"; done; ok "xxd, sha512sum and python3 are there"
  "$SUDO" -n true 2>/dev/null && ok "sudo works without a password (attest/quote.sh needs it)" || stop "sudo asks for a password: attest/quote.sh cannot run"
  [ -d "$TSM" ] && ok "configfs-tsm is there: this is a TDX guest ($TSM)" || stop "configfs-tsm not found at $TSM: this is not a TDX guest"
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then stop "something listens on 127.0.0.1:$PORT already (an earlier signing service?)"; fi
  ok "port $PORT is free"
  [ ! -e "$KSDIR" ] && ok "no service folder from an earlier window ($KSDIR)" || stop "the folder $KSDIR exists (an earlier window did not close?): move it away first"
  say "== the signed version of core-site.xml (the measured one plus ten settings)"
  cp -p "$CONF" "$WIN/modes/core-site.xml.plain"
  python3 - "$CONF" "$WIN/modes/core-site.xml.wrapped" "$HOME_" "$PORT" <<'PY' || stop "could not make the signed core-site.xml"
import sys, xml.etree.ElementTree as ET
src, out, home, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src, encoding="utf-8").read()
names = [p.findtext("name") for p in ET.fromstring(text).findall("property")]
new = [("attested.signature.enabled", "true"), ("attested.signature.required", "true"), ("attested.signature.allow.test.keys", "false"),
       ("attested.folder.binding.enabled", "true"), ("attested.folder.binding.required", "true"),
       ("attested.keys.provider", "service"), ("attested.keys.service.address", "127.0.0.1:" + port),
       ("attested.keys.service.token.file", home + "/tc-keyservice/token"), ("attested.keys.list.dir", home + "/tc-keys/list"),
       ("attested.keys.list.allow.unquoted", "false")]
if any(n in names for n, _ in new): sys.exit("one of the signature, binding or key settings is in core-site.xml already")
block = "".join("  <property>\n    <name>%s</name>\n    <value>%s</value>\n    <final>true</final>\n  </property>\n" % (n, v) for n, v in new)
i = text.rindex("</configuration>")
res = text[:i] + block + text[i:]
after = [p.findtext("name") for p in ET.fromstring(res).findall("property")]
if after != names + [n for n, _ in new]: sys.exit("the new file does not hold exactly the old settings plus ten")
open(out, "w", encoding="utf-8").write(res)
print("ok")
PY
  ok "the signed core-site.xml holds the measured settings plus signing on and required, test keys not allowed, folder binding on and required, provider service (127.0.0.1:$PORT), the token file, the key list, no unquoted keys (all final)"
  say "== install the jar (atomically; refused unless its classes equal the job's)"
  CHANGED=1
  ATTESTED_FORCE=1 bash "$TOOLS/wrapper-jar.sh" install "$NEWJAR" ${NEWJOB:+"$NEWJOB"} > "$WIN/install.log" 2>&1 && grep -q WRAPPER-JAR-INSTALLED "$WIN/install.log" && ok "installed: $(grep -o 'sha256 [0-9a-f]*' "$WIN/install.log" | cut -c1-24)..." || { tail -3 "$WIN/install.log"; stop "the jar could not be installed (the saved jar is in $WIN/saved; run close to be sure)"; }
  say "== start the signing service (the key is made now, in memory only, and the hardware makes the quote for it)"
  mkdir -p "$KSDIR" "$KLDIR" && chmod 700 "$KSDIR"
  ( nohup java -cp "$LIBJAR" org.apache.nutch.attested.KeyService --dir "$KSDIR" --port "$PORT" --list-dir "$KLDIR" --quote-cmd "bash $QUOTE" --host "$HOST" >"$KSDIR/service.out" 2>&1 & echo $! >"$WIN/keyservice.pid" )
  for i in $(seq 1 "$START_WAIT"); do [ -f "$KSDIR/port" ] && break; sleep 1; done
  [ -f "$KSDIR/port" ] || { tail -3 "$KSDIR/service.out" 2>/dev/null | sed 's/^/   | /'; tail -3 "$KSDIR/quote.log" 2>/dev/null | sed 's/^/   | /'; stop "the signing service did not start within $START_WAIT seconds (see $KSDIR/service.out and $KSDIR/quote.log); run close to restore"; }
  KB="$(ls "$KSDIR"/*.attestkey 2>/dev/null | head -1)"; SKID="$(basename "$KB" .attestkey)"
  case "$SKID" in TDX-*) ok "the signing service runs with the key $SKID (pid $(cat "$WIN/keyservice.pid")), started at $(date -u +%FT%TZ)" ;; *) stop "the key of the service is not a TDX- key: ${SKID:-none}" ;; esac
  java -cp "$LIBJAR" org.apache.nutch.attested.AttestedKeyTool bundle-verify "$KB" >"$WIN/bundle-verify.txt" 2>&1 && grep -q '^BUNDLE-OK' "$WIN/bundle-verify.txt" && ok "the key bundle verifies: the key id is the hash of the public key and the quote's REPORTDATA is the SHA-512 of the statement" || stop "the key bundle does not verify (see $WIN/bundle-verify.txt)"
  python3 "$TOOLS/m513_bundle_extract.py" "$KB" "$WIN/quote-$ROLE" >"$WIN/extract.txt" 2>&1 && grep -q '^EXTRACT-MATCH' "$WIN/extract.txt" && ok "the quote ($(stat -c %s "$WIN/quote-$ROLE/quote.bin") bytes) was taken out of the bundle: its REPORTDATA equals the SHA-512 of the statement" || stop "the quote could not be taken apart or does not match (see $WIN/extract.txt)"
  bash "$TOOLS/verify-binding.sh" "$WIN/quote-$ROLE/statement.txt" "$WIN/quote-$ROLE/quote.bin" 2>&1 | grep -q '^MATCH' && ok "attest/verify-binding.sh, the check of the earlier milestones, says MATCH" || stop "attest/verify-binding.sh does not say MATCH"
  ans="$( { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; printf 'AUTH %s\nID\n' "$(cat "$KSDIR/token")" >&3; read -r -t 5 l1 <&3; read -r -t 5 l2 <&3; echo "$l1 $l2"; exec 3>&-; } 2>/dev/null )"
  [ "$ans" = "OK OK $SKID" ] && ok "the service answers with its key id on 127.0.0.1:$PORT, and the token works" || stop "the service does not answer as expected on port $PORT (got: ${ans:-nothing})"
  CHANGED=1
  say "== apply the settings and restart this node's daemons (cluster-mode.sh, as in every earlier switch)"
  CLUSTER_MODE_DIR="$WIN/modes" bash "$MODE" wrapped --restart > "$WIN/mode.log" 2>&1; rc=$?
  tail -3 "$WIN/mode.log" | sed 's/^/   | /'
  [ $rc = 0 ] && grep -q "CLUSTER-MODE-OK" "$WIN/mode.log" && ok "daemons restarted with the signed settings" || stop "the mode switch failed (see $WIN/mode.log); run close to restore the measured jar and settings"
  say "== check the result"
  [ "$(fp "$LIBJAR" | cut -c1-${#JP})" = "$JP" ] && ok "the installed jar is the new one" || stop "the installed jar is not the new one"
  gc() { "$HH/bin/hdfs" getconf -confKey "$1" 2>/dev/null; }
  [ "$(gc attested.signature.enabled)" = true ] && [ "$(gc attested.signature.required)" = true ] && [ "$(gc attested.folder.binding.enabled)" = true ] && [ "$(gc attested.folder.binding.required)" = true ] && [ "$(gc attested.keys.provider)" = service ] && [ "$(gc attested.signature.allow.test.keys)" = false ] && [ "$(gc attested.keys.list.allow.unquoted)" = false ] && ok "this node's configuration says: signing on and required, folder binding on and required, the keys come from the signing service, test keys and unquoted keys not accepted" || stop "the signature, binding and key settings are not in effect"
  if [ -n "$NEWJOB" ]; then bash "$TOOLS/wrapper-jar.sh" verify "$NEWJOB" 2>&1 | grep -q CLASSES-SAME && ok "CLASSES-SAME: the installed wrapper classes equal the new job's" || stop "the installed classes do not equal the new job's"
  else bash "$TOOLS/wrapper-jar.sh" verify 2>&1 | grep -q "entries on Hadoop's classpath: 1" && ok "the installed jar is on Hadoop's classpath (once)" || stop "the installed jar is not on Hadoop's classpath"; fi
  say "M513W-OPEN-OK $ROLE: the wrapper with the real key is installed and switched on here, and the signing service runs. This node is NOT the measured stack until you run close."
  cp "$LOGF" "$HOME_/m513w/window-open-$ROLE.log"
else
  [ -d "$WIN/saved" ] || { echo "M513W-STOP: no open window found at $WIN (nothing to close)" >&2; exit 1; }
  LOGF="$WIN/close.log"; : > "$LOGF"
  say "m513-window close: $(date -u +%FT%TZ) on $HOST   role=$ROLE"
  say "== checks"
  need_busy; no_app
  [ -f "$WIN/saved/attested-hdfs.jar" ] && [ -f "$WIN/saved/core-site.xml" ] && [ -f "$WIN/modes/core-site.xml.plain" ] || stop "the saved files are incomplete in $WIN"
  [ "$(fp "$WIN/modes/core-site.xml.plain")" = "$(awk '/^core /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "the restore point equals the saved core-site.xml" || stop "the restore point differs from the saved core-site.xml"
  say "== restore the measured jar (atomically) and the measured settings, and restart this node's daemons"
  ATTESTED_FORCE=1 bash "$TOOLS/wrapper-jar.sh" install "$WIN/saved/attested-hdfs.jar" > "$WIN/restore-jar.log" 2>&1 && grep -q WRAPPER-JAR-INSTALLED "$WIN/restore-jar.log" && ok "the saved jar is installed again" || { tail -3 "$WIN/restore-jar.log"; stop "could not restore the jar (it is saved in $WIN/saved/attested-hdfs.jar)"; }
  CLUSTER_MODE_DIR="$WIN/modes" bash "$MODE" plain --restart > "$WIN/restore-mode.log" 2>&1; rc=$?
  tail -3 "$WIN/restore-mode.log" | sed 's/^/   | /'
  [ $rc = 0 ] && grep -q "CLUSTER-MODE-OK" "$WIN/restore-mode.log" && ok "the measured settings are back and the daemons restarted" || stop "the mode switch back failed (see $WIN/restore-mode.log)"
  say "== stop the signing service"
  if [ -f "$WIN/keyservice.pid" ] && kill -0 "$(cat "$WIN/keyservice.pid")" 2>/dev/null; then
    kill "$(cat "$WIN/keyservice.pid")" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(cat "$WIN/keyservice.pid")" 2>/dev/null || break; sleep 1; done
  fi
  if [ -f "$WIN/keyservice.pid" ] && kill -0 "$(cat "$WIN/keyservice.pid")" 2>/dev/null; then stop "the signing service is still running (pid $(cat "$WIN/keyservice.pid"))"; fi
  [ -f "$KSDIR/audit.log" ] && echo "$(date -u +%FT%TZ) STOPPED-BY-WINDOW-CLOSE pid=$(cat "$WIN/keyservice.pid" 2>/dev/null)" >>"$KSDIR/audit.log"
  ok "the signing service is stopped (its private key disappeared with it: it was never written anywhere)"
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then stop "something still listens on 127.0.0.1:$PORT"; fi
  ok "port $PORT is closed"
  if [ -d "$KSDIR" ]; then rm -f "$KSDIR/token"; mv "$KSDIR" "$WIN/keyservice-dir" && ok "the service folder (bundle, audit log, quote log) is kept in the window folder; its token is deleted"; fi
  say "== check that it is the measured stack again"
  [ "$(fp "$LIBJAR")" = "$(awk '/^jar /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "the installed jar is byte for byte the saved one" || stop "the installed jar differs from the saved one"
  [ "$(fp "$CONF")" = "$(awk '/^core /{print $2}' "$WIN/saved/fingerprints.txt")" ] && ok "core-site.xml is byte for byte the saved one" || stop "core-site.xml differs from the saved one"
  "$HH/bin/hdfs" getconf -confKey attested.signature.enabled >/dev/null 2>&1 && stop "the signature setting is still in effect" || "$HH/bin/hdfs" getconf -confKey attested.folder.binding.enabled >/dev/null 2>&1 && stop "the binding setting is still in effect" || ok "the signature, binding and key settings are no longer in effect"
  measured_intact after "the measured set is unchanged" "the measured set differs after the restore"
  say "M513W-CLOSE-OK $ROLE: this node is the measured stack again. The signing service is stopped. The key list in $KLDIR keeps the public bundles."
  mv "$WIN" "$HOME_/m513w/window-closed-$ROLE-$(date -u +%Y%m%dT%H%M%SZ)"
fi
