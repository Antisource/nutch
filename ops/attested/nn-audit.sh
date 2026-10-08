#!/usr/bin/env bash
# Milestone 4, baby step 4.5.2: the NameNode's own audit log.
#
# Every request to HDFS passes through the NameNode, so its audit log is a record of
# who did what to which path, independent of our wrapper: a read that bypasses the
# wrapper still shows up there. By default Hadoop discards that log (the logger is
# INFO,NullAppender). Switching it on is one setting in hadoop-env.sh
# (HDFS_AUDIT_LOGGER=INFO,RFAAUDIT; the file appender RFAAUDIT is already defined in
# log4j.properties and writes hdfs-audit.log in the logs folder) and a NameNode restart.
#
# Usage, on the master, as the user that runs the NameNode:
#   nn-audit.sh status   what is set now, and the audit log's size (read-only)
#   nn-audit.sh check    the checks that 'on' makes first, shown with what they read (read-only)
#   nn-audit.sh on       back up, set it, restart the NameNode, verify; roll back by itself if it fails
#   nn-audit.sh off      restore the hadoop-env.sh that "on" backed up, and restart the NameNode
#
# Settings (environment): HADOOP_HOME (default ~/hadoop), HADOOP_LOG_DIR (default
# $HADOOP_HOME/logs), NN_AUDIT_BACKUP (default ~/nn-audit-backup), NN_AUDIT_WAIT (seconds to
# wait for the NameNode to stop or start, default 60; NN_AUDIT_DN_WAIT, the same for the DataNodes
# to come back, default 60).
set -uo pipefail

H="${HADOOP_HOME:-$HOME/hadoop}"
ENVF="$H/etc/hadoop/hadoop-env.sh"
LOGDIR="${HADOOP_LOG_DIR:-$H/logs}"
BK="${NN_AUDIT_BACKUP:-$HOME/nn-audit-backup}"
HDFS="$H/bin/hdfs"
YARN="$H/bin/yarn"
WAIT="${NN_AUDIT_WAIT:-60}"
BEGIN="# >>> attested step 4.5.2: NameNode audit log (remove this block to undo)"
END="# <<< attested step 4.5.2"
NNCLASS="org.apache.hadoop.hdfs.server.namenode.NameNode"

die() { echo "NN-AUDIT-STOP: $*" >&2; exit 1; }
say() { echo "== $*"; }

nn_pid() { ps -eo pid,args | awk -v c="$NNCLASS" 'index($0, c) && !/awk/ {print $1; exit}'; }
nn_logger() { ps -eo args | grep -F "$NNCLASS" | tr ' ' '\n' | grep -E '^-Dhdfs\.audit\.logger=' | head -1 | cut -d= -f2; }
live_datanodes() { "$HDFS" dfsadmin -report 2>/dev/null | grep -E '^Live datanodes' | grep -oE '[0-9]+' | head -1; }

restart_nn() {
  "$HDFS" --daemon stop namenode >/dev/null 2>&1
  local i=0
  while [ -n "$(nn_pid)" ] && [ $i -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
  [ -z "$(nn_pid)" ] || { echo "the NameNode did not stop within ${WAIT}s"; return 1; }
  "$HDFS" --daemon start namenode >/dev/null 2>&1
  i=0
  while [ -z "$(nn_pid)" ] && [ $i -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
  [ -n "$(nn_pid)" ] || { echo "the NameNode did not start within ${WAIT}s"; return 1; }
  timeout 180 "$HDFS" dfsadmin -safemode wait >/dev/null 2>&1 || { echo "safe mode did not end"; return 1; }
  return 0
}

# the NameNode must run with the given logger, HDFS must answer, and every DataNode must be back
verify_state() {  # verify_state LOGGER EXPECTED_DATANODES WANT_AUDIT_LINE(yes|no)
  local want="$1" dns="$2" audit="$3" i=0 n
  [ "$(nn_logger)" = "$want" ] || { echo "the NameNode runs with logger '$(nn_logger)', not '$want'"; return 1; }
  "$HDFS" dfs -ls / >/dev/null 2>&1 || { echo "HDFS does not answer 'ls /'"; return 1; }
  while [ $i -lt "${NN_AUDIT_DN_WAIT:-60}" ]; do
    n="$(live_datanodes)"
    [ "${n:-0}" = "$dns" ] && break
    sleep 1; i=$((i + 1))
  done
  [ "${n:-0}" = "$dns" ] || { echo "live DataNodes: ${n:-none}, expected $dns"; return 1; }
  if [ "$audit" = yes ]; then
    sleep 3
    grep -q 'cmd=listStatus' "$LOGDIR/hdfs-audit.log" 2>/dev/null || { echo "no listStatus line in $LOGDIR/hdfs-audit.log after 'ls /'"; return 1; }
  fi
  "$HDFS" fsck / 2>/dev/null | grep -q 'is HEALTHY' || { echo "fsck does not report HEALTHY"; return 1; }
  return 0
}

# the conditions under which the NameNode may be restarted; sets $dns
preconditions() {
  say "preconditions"
  [ -n "$(nn_pid)" ] || die "no NameNode is running here (run this on the master)"
  "$HDFS" dfsadmin -safemode get 2>/dev/null | grep -q 'OFF' || die "HDFS is in safe mode"
  apps="$("$YARN" application -list -appStates RUNNING 2>/dev/null)" || die "cannot ask YARN for running applications (is the ResourceManager up?)"
  napps="$(printf '%s\n' "$apps" | grep -c '^application_')"
  [ "$napps" = 0 ] || die "$napps YARN application(s) are running; wait until none is"
  dns="$(live_datanodes)"; [ "${dns:-0}" -ge 1 ] || die "no live DataNode is reported"
  echo "NameNode pid $(nn_pid); live DataNodes $dns; no running application; safe mode off"
}

# the NameNode's metadata folders, one per line
name_dirs() {
  local d
  for d in $(echo "$("$HDFS" getconf -confKey dfs.namenode.name.dir 2>/dev/null)" | tr ',' ' '); do
    echo "${d#file://}"
  done
}

restore_env() {  # restore_env FILE
  cp -p "$1" "$ENVF" || return 1
}

case "${1:-}" in
status)
  say "the NameNode"; echo "pid: $(nn_pid)"; echo "audit logger of the running NameNode: $(nn_logger)"
  say "hadoop-env.sh"; if grep -qF "$BEGIN" "$ENVF" 2>/dev/null; then echo "the step 4.5.2 block is present"; else echo "the step 4.5.2 block is not present"; fi
  say "the audit log"; ls -l "$LOGDIR/hdfs-audit.log" 2>/dev/null || echo "no hdfs-audit.log yet"
  ;;
check)
  [ -f "$ENVF" ] || die "no $ENVF"
  preconditions
  say "what would be backed up"
  echo "$ENVF ($(wc -c < "$ENVF") bytes)"
  n=0
  for d in $(name_dirs); do
    [ -d "$d" ] || die "the NameNode's metadata folder '$d' does not exist"
    echo "$d ($(du -sk "$d" | cut -f1) KB)"; n=$((n + 1))
  done
  [ $n -ge 1 ] || die "could not read dfs.namenode.name.dir"
  say "the setting"
  if grep -qF "$BEGIN" "$ENVF"; then echo "the step 4.5.2 block is already in $ENVF"; else echo "the step 4.5.2 block is not in $ENVF yet"; fi
  echo "audit logger of the running NameNode: $(nn_logger)"
  echo "free space where the audit log will be written: $(df -h "$LOGDIR" | tail -1 | awk '{print $4}')"
  echo "NN-AUDIT-CHECK-OK: 'on' would proceed; nothing was changed"
  ;;
on)
  [ -f "$ENVF" ] || die "no $ENVF"
  if grep -qF "$BEGIN" "$ENVF"; then die "the step 4.5.2 block is already in $ENVF (use 'status')"; fi
  [ "$(nn_logger)" != "INFO,RFAAUDIT" ] || die "the NameNode already runs with INFO,RFAAUDIT"
  preconditions
  say "backups in $BK"
  mkdir -p "$BK" || die "cannot create $BK"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$ENVF" "$BK/hadoop-env.sh.$stamp" || die "cannot back up $ENVF"
  echo "$BK/hadoop-env.sh.$stamp" > "$BK/latest-env"
  echo "saved $BK/hadoop-env.sh.$stamp"
  i=0
  for d in $(name_dirs); do
    [ -d "$d" ] || die "the NameNode's metadata folder '$d' does not exist"
    kb="$(du -sk "$d" | cut -f1)"
    [ "$kb" -lt 2097152 ] || die "the NameNode's metadata folder '$d' is larger than 2 GB ($kb KB)"
    cp -a "$d" "$BK/name-$stamp-$i" || die "cannot copy the NameNode's metadata folder '$d'"
    echo "saved $BK/name-$stamp-$i (from $d, $kb KB)"
    i=$((i + 1))
  done
  [ $i -ge 1 ] || die "could not read dfs.namenode.name.dir"
  say "setting HDFS_AUDIT_LOGGER=INFO,RFAAUDIT in $ENVF"
  { echo ""; echo "$BEGIN"; echo "export HDFS_AUDIT_LOGGER=INFO,RFAAUDIT"; echo "$END"; } >> "$ENVF"
  say "restarting the NameNode"
  why=""
  if restart_nn; then
    why="$(verify_state INFO,RFAAUDIT "$dns" yes)" && ok=1 || ok=0
  else
    ok=0; why="the NameNode could not be restarted"
  fi
  if [ "$ok" = 1 ]; then
    echo "NN-AUDIT-ON-OK: the NameNode runs with INFO,RFAAUDIT; $dns DataNode(s) are back; fsck is HEALTHY; $LOGDIR/hdfs-audit.log is being written"
    echo "undo with: $0 off"
  else
    echo "NN-AUDIT-FAILED: $why" >&2
    say "rolling back"
    restore_env "$BK/hadoop-env.sh.$stamp" && echo "hadoop-env.sh restored from $BK/hadoop-env.sh.$stamp"
    if restart_nn && verify_state INFO,NullAppender "$dns" no >/dev/null; then
      echo "NN-AUDIT-ROLLED-BACK: the NameNode runs with INFO,NullAppender again and HDFS is healthy" >&2
    else
      echo "NN-AUDIT-ROLLBACK-INCOMPLETE: look at the NameNode by hand; the metadata is saved in $BK/name-$stamp-*" >&2
    fi
    exit 1
  fi
  ;;
off)
  [ -f "$BK/latest-env" ] || die "no backup note at $BK/latest-env: nothing to restore"
  saved="$(cat "$BK/latest-env")"; [ -f "$saved" ] || die "the backup $saved is missing"
  [ -n "$(nn_pid)" ] || die "no NameNode is running here"
  dns="$(live_datanodes)"; [ "${dns:-0}" -ge 1 ] || die "no live DataNode is reported"
  restore_env "$saved" || die "cannot restore $saved"
  echo "hadoop-env.sh restored from $saved"
  if restart_nn && verify_state INFO,NullAppender "$dns" no; then
    echo "NN-AUDIT-OFF-OK: the NameNode runs with INFO,NullAppender; HDFS is healthy"
  else
    echo "NN-AUDIT-OFF-FAILED: look at the NameNode by hand" >&2; exit 1
  fi
  ;;
*)
  echo "usage: $0 status | check | on | off" >&2; exit 2
  ;;
esac
