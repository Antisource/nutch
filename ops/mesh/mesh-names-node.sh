#!/usr/bin/env bash
# Run on a node by mesh-names.sh. Usage: mesh-names-node.sh <step> <role>   (role: master | worker)
# steps: pre | stop | names | start | report | pitest | counters
set -euo pipefail
STEP="$1"; ROLE="$2"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
FM="tdx-lab.us-central1-a.c.training-custody.internal"
FW="tdx-lab-worker.us-central1-a.c.training-custody.internal"
# a non-interactive ssh command does not read ~/.bashrc, so set what Hadoop needs here
export HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
fail() { echo "ABORT: $*" >&2; exit 1; }

case "$ROLE" in
  master) PEER_MESH=10.10.0.2 ;;
  worker) PEER_MESH=10.10.0.1 ;;
  *) fail "role must be master or worker" ;;
esac

case "$STEP" in
pre)
  ip link show wg0 >/dev/null 2>&1 || fail "wg0 is not up"
  ping -c 2 -W 2 "$PEER_MESH" >/dev/null 2>&1 || fail "cannot reach $PEER_MESH over the mesh"
  grep -q '^10\.10\.0\.1 hadoop-master$' "$HOSTS" || fail "hadoop-master does not point at the mesh yet (run mesh-hadoop.sh first)"
  if [ "$ROLE" = master ]; then
    if yarn application -list -appStates RUNNING 2>/dev/null | grep -q '^application_'; then fail "a Hadoop application is running"; fi
  fi
  echo "$ROLE ok"
  ;;
stop)
  if [ "$ROLE" = master ]; then
    yarn --daemon stop resourcemanager || true
    hdfs --daemon stop namenode || true
  else
    yarn --daemon stop nodemanager || true
    hdfs --daemon stop datanode || true
  fi
  sleep 5
  echo "$ROLE daemons after stop:"; jps | grep -v Jps || echo "(none)"
  ;;
names)
  [ -e "$HOSTS.before-names" ] || sudo cp "$HOSTS" "$HOSTS.before-names"
  grep -q "^10\.10\.0\.1 $FM tdx-lab\$" "$HOSTS" || echo "10.10.0.1 $FM tdx-lab" | sudo tee -a "$HOSTS" >/dev/null
  grep -q "^10\.10\.0\.2 $FW tdx-lab-worker\$" "$HOSTS" || echo "10.10.0.2 $FW tdx-lab-worker" | sudo tee -a "$HOSTS" >/dev/null
  [ "$(getent hosts "$FM" | awk '{print $1}')" = "10.10.0.1" ] || fail "$FM does not resolve to 10.10.0.1"
  [ "$(getent hosts "$FW" | awk '{print $1}')" = "10.10.0.2" ] || fail "$FW does not resolve to 10.10.0.2"
  echo "$ROLE names now resolve to the mesh:"; getent hosts "$FM" "$FW"
  ;;
start)
  if [ "$ROLE" = master ]; then
    hdfs --daemon start namenode
    yarn --daemon start resourcemanager
  else
    hdfs --daemon start datanode
    yarn --daemon start nodemanager
  fi
  sleep 10
  echo "$ROLE daemons after start:"; jps | grep -v Jps || true
  ;;
report)
  for i in $(seq 1 24); do
    s="$(hdfs dfsadmin -safemode get 2>/dev/null || true)"
    case "$s" in *OFF*) break ;; esac
    sleep 5
  done
  echo "$s"
  hdfs dfsadmin -report 2>/dev/null | grep -E 'Live datanodes|Missing blocks' || true
  yarn node -list 2>/dev/null | tail -3
  hdfs dfs -ls 2>/dev/null | head -4
  ;;
pitest)
  JAR="$(ls "$HADOOP_HOME"/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -1)"
  echo "running the Pi example: $(basename "$JAR")"
  hadoop jar "$JAR" pi 2 10 2>&1 | grep -E 'Job Finished|Estimated value|FAILED|Exception|Container launch' || true
  ;;
counters)
  echo "-- Hadoop-port drop rule (packets, bytes); 0 means nothing reached those ports from the ordinary network"
  sudo iptables -L INPUT -v -n | grep -E 'pkts|multiport'
  echo "-- mesh transfer"; sudo wg show wg0 transfer
  ;;
*) fail "unknown step $STEP" ;;
esac
