#!/usr/bin/env bash
# The Hadoop daemons of one node, in the order the lab cluster uses.   node-hadoop.sh master|worker ACTION
#   format      master only, once ever: format the NameNode (refuses if a file system is already there)
#   start       master: NameNode, then ResourceManager.  worker: DataNode, then NodeManager (a daemon that already runs is skipped)
#   stop        the reverse
#   status      which daemons run here
#   init-hdfs   master: create /user/<you> in HDFS
#   wait        master: wait until HDFS has its DataNode and YARN has its NodeManager (TIMEOUT seconds, default 180)
#   pitest      master: run Hadoop's Pi example (proves that jobs run)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROLE="${1:-}"; ACT="${2:-}"; case "$ROLE" in master|worker) ;; *) die "usage: node-hadoop.sh master|worker ACTION" ;; esac
hadoop_env
[ -x "$HADOOP_HOME/bin/hdfs" ] || die "no Hadoop in $HADOOP_HOME (run node-base.sh first)"
case "$ACT" in
format)
  [ "$ROLE" = master ] || die "format is for the master only"
  NN="$HOME_DIR/hadoop-data/namenode"
  [ ! -d "$NN/current" ] || die "the NameNode folder already holds a file system ($NN/current); formatting would erase HDFS. Remove it yourself if that is what you want."
  hdfs namenode -format -nonInteractive > "$STATE/format.log" 2>&1 || { tail -5 "$STATE/format.log"; die "formatting failed (log: $STATE/format.log)"; }
  ok "NameNode formatted" ;;
start)
  running() { jps 2>/dev/null | grep -qw "$1"; }
  if [ "$ROLE" = master ]; then
    running NameNode && note "NameNode already runs" || hdfs --daemon start namenode
    running ResourceManager && note "ResourceManager already runs" || yarn --daemon start resourcemanager
  else
    running DataNode && note "DataNode already runs" || hdfs --daemon start datanode
    running NodeManager && note "NodeManager already runs" || yarn --daemon start nodemanager
  fi
  sleep 10; echo "$ROLE daemons:"; jps | grep -v Jps || echo "(none)" ;;
stop)
  if [ "$ROLE" = master ]; then yarn --daemon stop resourcemanager || true; hdfs --daemon stop namenode || true
  else yarn --daemon stop nodemanager || true; hdfs --daemon stop datanode || true; fi
  sleep 5; jps | grep -v Jps || echo "(none)" ;;
status) jps | grep -v Jps || echo "(none)" ;;
init-hdfs)
  [ "$ROLE" = master ] || die "init-hdfs is for the master only"
  hdfs dfs -mkdir -p "/user/$(id -un)" && ok "/user/$(id -un) exists in HDFS" || die "could not create /user/$(id -un)" ;;
wait)
  [ "$ROLE" = master ] || die "wait is for the master only"
  T="${TIMEOUT:-180}"; end=$(( $(date +%s) + T ))
  while [ "$(date +%s)" -lt "$end" ]; do
    dn=$(hdfs dfsadmin -report 2>/dev/null | grep -E '^Live datanodes' | grep -o -E '[0-9]+' | head -1)
    nm=$(yarn node -list 2>/dev/null | grep -c RUNNING)
    if [ "${dn:-0}" -ge 1 ] && [ "${nm:-0}" -ge 1 ]; then echo "CLUSTER-UP: $dn DataNode(s), $nm NodeManager(s)"; exit 0; fi
    sleep 5
  done
  die "after ${T} s: ${dn:-0} DataNode(s) and ${nm:-0} NodeManager(s) are up; check the logs in $HADOOP_HOME/logs and that hadoop-worker resolves on both nodes" ;;
pitest)
  [ "$ROLE" = master ] || die "pitest is for the master only"
  JAR="$(ls "$HADOOP_HOME"/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar 2>/dev/null | head -1)"; [ -n "$JAR" ] || die "no examples jar"
  hadoop jar "$JAR" pi 2 10 > "$STATE/pi.log" 2>&1; grep -E 'Estimated value|Job Finished' "$STATE/pi.log" || { tail -5 "$STATE/pi.log"; die "the Pi job did not finish (log: $STATE/pi.log)"; } ;;
*) die "unknown action '$ACT'" ;;
esac
