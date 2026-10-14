#!/usr/bin/env bash
# Milestone 4, baby step 4.6.2: the wrapper as the cluster's own file system, and the switch back to plain.
#
# Two settings in core-site.xml decide which class serves hdfs:// for every Hadoop process that reads the
# file: fs.hdfs.impl (the FileSystem API) and fs.AbstractFileSystem.hdfs.impl (the FileContext API).
# In the WRAPPED version they name the wrapper and are marked final, so a job's own settings file cannot
# change them (a command-line -D option or code that calls conf.set still can: a final flag protects
# against a later settings FILE only). The PLAIN version is the file as it was. The wrapper's classes
# come from the jar of baby step 4.6.1 (wrapper-jar.sh), which must be installed on this node.
#
# Run it on each node, as the user that runs the Hadoop daemons:
#   cluster-mode.sh status                   which version is in place, which daemons run here
#   cluster-mode.sh prepare                  save the current core-site.xml as PLAIN and make the WRAPPED version
#   cluster-mode.sh wrapped [RESTART]        put the WRAPPED version in place
#   cluster-mode.sh plain   [RESTART]        put the PLAIN version back (the undo, and the control runs)
# RESTART is --restart (restart this node's daemons in Hadoop's order: NameNode and ResourceManager on the
# master, DataNode and NodeManager on the worker) or --restart-yarn (only the YARN daemon of this node).
# Without it only the file changes; running daemons keep the version they started with, and commands and
# containers started afterwards read the new file. With a restart the script refuses while a YARN
# application runs, verifies the daemons afterwards, and puts the previous file back by itself if the
# verification fails.
# Settings (environment): HADOOP_HOME (default ~/hadoop), CLUSTER_MODE_DIR (default ~/cluster-mode),
# CLUSTER_MODE_WAIT (seconds to wait for a daemon, default 90).
set -uo pipefail
H="${HADOOP_HOME:-$HOME/hadoop}"
CONF="$H/etc/hadoop/core-site.xml"
ST="${CLUSTER_MODE_DIR:-$HOME/cluster-mode}"
PLAINF="$ST/core-site.xml.plain"; WRAPF="$ST/core-site.xml.wrapped"
WAIT="${CLUSTER_MODE_WAIT:-90}"
HDFS="$H/bin/hdfs"; YARN="$H/bin/yarn"
NN=org.apache.hadoop.hdfs.server.namenode.NameNode; RM=org.apache.hadoop.yarn.server.resourcemanager.ResourceManager
DN=org.apache.hadoop.hdfs.server.datanode.DataNode; NM=org.apache.hadoop.yarn.server.nodemanager.NodeManager
LIBJAR="$H/share/hadoop/common/lib/attested-hdfs.jar"
# Hadoop's admin tool (hdfs dfsadmin) insists on a real DistributedFileSystem and throws "is not an HDFS file
# system" for anything else, the wrapper included (found on the cluster on 8 October 2026). Admin commands are
# not data operations, so they use the plain client, whatever core-site.xml says.
ADMIN_D="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
die() { echo "CLUSTER-MODE-STOP: $*" >&2; exit 1; }
say() { echo "== $*"; }
fp() { sha256sum "$1" | cut -c1-64; }
pid_of() { ps -eo pid,args | awk -v c="$1" 'index($0, c) && !/awk/ {print $1; exit}'; }
have() { [ -n "$(pid_of "$1")" ]; }

mode_now() {
  [ -f "$PLAINF" ] && [ -f "$WRAPF" ] || { echo "not prepared"; return; }
  local f; f="$(fp "$CONF")"
  if [ "$f" = "$(fp "$WRAPF")" ]; then echo wrapped; elif [ "$f" = "$(fp "$PLAINF")" ]; then echo plain; else echo "unknown (core-site.xml was changed by hand)"; fi
}

stop_daemon() {  # stop_daemon CLASS CMD NAME
  "$2" --daemon stop "$3" >/dev/null 2>&1
  local i=0; while have "$1" && [ $i -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
  have "$1" && { echo "$3 did not stop within ${WAIT}s"; return 1; }; return 0
}
start_daemon() {
  "$2" --daemon start "$3" >/dev/null 2>&1
  local i=0; while ! have "$1" && [ $i -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
  have "$1" || { echo "$3 did not start within ${WAIT}s"; return 1; }; return 0
}
restart_daemon() { stop_daemon "$1" "$2" "$3" && start_daemon "$1" "$2" "$3"; }

# the daemons this node runs, noted once before anything changes; the restart, the verification and the
# rollback all use this list, so a daemon that failed to start is started again and counted as missing
snapshot_roles() { WANT_NN=0; WANT_RM=0; WANT_DN=0; WANT_NM=0; have "$NN" && WANT_NN=1; have "$RM" && WANT_RM=1; have "$DN" && WANT_DN=1; have "$NM" && WANT_NM=1; return 0; }

restart_local() {  # restart_local all|yarn
  local scope="$1"
  if [ "$WANT_NN" = 1 ] && [ "$scope" = all ]; then restart_daemon "$NN" "$HDFS" namenode || return 1; timeout 180 "$HDFS" dfsadmin $ADMIN_D -safemode wait >/dev/null 2>&1 || { echo "safe mode did not end"; return 1; }; fi
  if [ "$WANT_RM" = 1 ]; then restart_daemon "$RM" "$YARN" resourcemanager || return 1; fi
  if [ "$WANT_DN" = 1 ] && [ "$scope" = all ]; then restart_daemon "$DN" "$HDFS" datanode || return 1; fi
  if [ "$WANT_NM" = 1 ]; then restart_daemon "$NM" "$YARN" nodemanager || return 1; fi
  return 0
}

verify_local() {  # every daemon this node ran before is running and has joined the cluster; HDFS and YARN answer
  local i n
  [ "$WANT_NN" = 0 ] || have "$NN" || { echo "the NameNode is not running"; return 1; }
  [ "$WANT_RM" = 0 ] || have "$RM" || { echo "the ResourceManager is not running"; return 1; }
  [ "$WANT_DN" = 0 ] || have "$DN" || { echo "the DataNode is not running"; return 1; }
  [ "$WANT_NM" = 0 ] || have "$NM" || { echo "the NodeManager is not running"; return 1; }
  if [ "$WANT_NN" = 1 ]; then
    "$HDFS" dfs -ls / >/dev/null 2>&1 || { echo "'hdfs dfs -ls /' fails"; return 1; }
  fi
  if [ "$WANT_RM" = 1 ] || [ "$WANT_NM" = 1 ]; then
    i=0; while [ $i -lt "$WAIT" ]; do n="$("$YARN" node -list 2>/dev/null | grep -c RUNNING)"; [ "${n:-0}" -ge 1 ] && break; sleep 1; i=$((i + 1)); done
    [ "${n:-0}" -ge 1 ] || { echo "no NodeManager is RUNNING in 'yarn node -list'"; return 1; }
  fi
  if [ "$WANT_DN" = 1 ]; then
    i=0; while [ $i -lt "$WAIT" ]; do n="$("$HDFS" dfsadmin $ADMIN_D -report 2>/dev/null | grep -E '^Live datanodes' | grep -oE '[0-9]+' | head -1)"; [ "${n:-0}" -ge 1 ] && break; sleep 1; i=$((i + 1)); done
    [ "${n:-0}" -ge 1 ] || { echo "the NameNode reports no live DataNode"; return 1; }
  fi
  return 0
}

set_mode() {  # set_mode MODE RESTARTFLAG
  local mode="$1" flag="${2:-}" tf scope="" napps stamp prev
  [ -f "$PLAINF" ] && [ -f "$WRAPF" ] || die "not prepared: run '$0 prepare' first"
  case "$flag" in ""|--restart|--restart-yarn) ;; *) die "unknown option '$flag' (use --restart or --restart-yarn)" ;; esac
  [ "$flag" = --restart ] && scope=all; [ "$flag" = --restart-yarn ] && scope=yarn
  if [ "$mode" = wrapped ]; then tf="$WRAPF"; [ -f "$LIBJAR" ] || die "the wrapper jar is not installed here ($LIBJAR): run wrapper-jar.sh install first"; else tf="$PLAINF"; fi
  if [ -n "$scope" ]; then
    napps="$("$YARN" application -list -appStates RUNNING 2>/dev/null)" || die "cannot ask YARN for running applications (is the ResourceManager up?)"
    napps="$(printf '%s\n' "$napps" | grep -c '^application_')"
    [ "$napps" = 0 ] || die "$napps YARN application(s) are running; wait until none is"
    if have "$NN"; then "$HDFS" dfsadmin $ADMIN_D -safemode get 2>/dev/null | grep -q OFF || die "HDFS is in safe mode"; fi
  fi
  snapshot_roles
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; prev="$ST/before-$stamp.core-site.xml"
  cp -p "$CONF" "$prev" || die "cannot back up $CONF"
  if [ "$(fp "$CONF")" = "$(fp "$tf")" ]; then echo "core-site.xml is already the $mode version"; else
    cp "$tf" "$CONF.new" && mv -f "$CONF.new" "$CONF" || die "cannot write $CONF"
    [ "$(fp "$CONF")" = "$(fp "$tf")" ] || die "$CONF does not match the $mode version after writing"
    echo "core-site.xml is now the $mode version (sha256 $(fp "$CONF" | cut -c1-16)); the previous file is saved as $prev"
  fi
  if [ -z "$scope" ]; then echo "CLUSTER-MODE-SET: $mode (no restart: running daemons keep the version they started with)"; return 0; fi
  say "restarting the daemons of this node ($scope)"
  local why=""
  if restart_local "$scope"; then why="$(verify_local)" && { echo "CLUSTER-MODE-OK: $mode; the daemons of this node are back and have joined the cluster"; return 0; }; else why="a daemon did not restart"; fi
  echo "CLUSTER-MODE-FAILED: $why" >&2
  say "rolling back"
  cp -p "$prev" "$CONF" && echo "core-site.xml restored from $prev"
  if restart_local "$scope" && verify_local >/dev/null; then echo "CLUSTER-MODE-ROLLED-BACK: the previous file is in place and the daemons are back" >&2
  else echo "CLUSTER-MODE-ROLLBACK-INCOMPLETE: look at the daemons by hand; the previous file is $prev" >&2; fi
  exit 1
}

case "${1:-}" in
status)
  say "core-site.xml"; echo "version in place: $(mode_now)"; echo "sha256: $(fp "$CONF" | cut -c1-16)"
  grep -qF "fs.hdfs.impl" "$CONF" && echo "the lookup fs.hdfs.impl is set in the file" || echo "the lookup fs.hdfs.impl is not set in the file"
  say "the wrapper jar"; [ -f "$LIBJAR" ] && echo "installed ($(fp "$LIBJAR" | cut -c1-16))" || echo "not installed"
  say "the daemons of this node"
  for c in "$NN" "$RM" "$DN" "$NM"; do have "$c" && echo "running: ${c##*.} (pid $(pid_of "$c"))"; done
  [ -d "$ST" ] && { echo "saved files in $ST:"; ls "$ST" | sed 's/^/  /'; }
  ;;
prepare)
  [ -f "$CONF" ] || die "no $CONF"
  [ ! -f "$PLAINF" ] || die "already prepared ($ST holds the PLAIN version); nothing was changed"
  grep -qF "fs.hdfs.impl" "$CONF" && die "$CONF already contains fs.hdfs.impl; refusing to treat it as the PLAIN version"
  mkdir -p "$ST" || die "cannot create $ST"
  cp -p "$CONF" "$PLAINF" || die "cannot save $PLAINF"
  python3 - "$PLAINF" "$WRAPF" <<'PY' || { rm -f "$PLAINF" "$WRAPF"; die "could not make the WRAPPED version (nothing was kept)"; }
import sys, xml.etree.ElementTree as ET
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
if text.count("</configuration>") != 1:
    sys.exit("core-site.xml does not have exactly one </configuration>")
add = ("  <property><name>fs.hdfs.impl</name><value>org.apache.nutch.attested.AttestedHdfsFileSystem</value><final>true</final></property>\n"
       "  <property><name>fs.AbstractFileSystem.hdfs.impl</name><value>org.apache.nutch.attested.AttestedHdfs</value><final>true</final></property>\n")
out = text.replace("</configuration>", add + "</configuration>")
root = ET.fromstring(out)
names = [p.findtext("name") for p in root.findall("property")]
if names.count("fs.hdfs.impl") != 1 or names.count("fs.AbstractFileSystem.hdfs.impl") != 1:
    sys.exit("the WRAPPED version does not have each lookup exactly once")
open(dst, "w", encoding="utf-8").write(out)
PY
  say "saved in $ST"; echo "PLAIN   $(fp "$PLAINF" | cut -c1-16)  (the file as it is now)"; echo "WRAPPED $(fp "$WRAPF" | cut -c1-16)  (the same, plus the two lookups, final)"
  diff "$PLAINF" "$WRAPF" | sed 's/^/  /'
  echo "CLUSTER-MODE-PREPARED: nothing in $CONF was changed"
  ;;
wrapped) set_mode wrapped "${2:-}" ;;
plain)   set_mode plain "${2:-}" ;;
*) echo "usage: $0 status | prepare | wrapped [--restart|--restart-yarn] | plain [--restart|--restart-yarn]" >&2; exit 2 ;;
esac
