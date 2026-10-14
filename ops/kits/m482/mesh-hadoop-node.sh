#!/usr/bin/env bash
# Run on a node by mesh-hadoop.sh. Usage: mesh-hadoop-node.sh <step> <role>   (role: master | worker)
# steps: pre | stop | hosts | fw | keep | start | report
set -euo pipefail
STEP="$1"; ROLE="$2"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
BACKUP_FW="${FW_BACKUP:-/root/iptables-before-mesh}"
KEEP="${FW_KEEP_FILE:-/tmp/fw-keep}"
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
  if [ "$ROLE" = master ]; then
    if yarn application -list -appStates RUNNING 2>/dev/null | grep -q '^application_'; then fail "a Hadoop application is running"; fi
  fi
  [ -e "$HOSTS.before-mesh" ] || sudo cp "$HOSTS" "$HOSTS.before-mesh"
  echo "$ROLE ok: mesh reachable, hosts backed up to $HOSTS.before-mesh"
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
hosts)
  if grep -q '^10\.10\.0\.1 hadoop-master$' "$HOSTS" && grep -q '^10\.10\.0\.2 hadoop-worker$' "$HOSTS"; then
    echo "hosts already point at the mesh"
  else
    grep -q '^10\.128\.0\.2 hadoop-master$' "$HOSTS" || fail "expected line '10.128.0.2 hadoop-master' not found"
    grep -q '^10\.128\.0\.5 hadoop-worker$' "$HOSTS" || fail "expected line '10.128.0.5 hadoop-worker' not found"
    sudo sed -i -e 's/^10\.128\.0\.2 hadoop-master$/10.10.0.1 hadoop-master/' -e 's/^10\.128\.0\.5 hadoop-worker$/10.10.0.2 hadoop-worker/' "$HOSTS"
  fi
  grep hadoop "$HOSTS"
  ;;
fw)
  rm -f "$KEEP"
  sudo sh -c "iptables-save > '$BACKUP_FW'"
  # safety net: undo the firewall by itself unless a keep file appears within 150 seconds
  sudo systemd-run --on-active=150 --unit=mesh-fw-revert /bin/sh -c "[ -f '$KEEP' ] || iptables-restore < '$BACKUP_FW'" >/dev/null
  sudo iptables -F INPUT
  sudo iptables -A INPUT -i lo -j ACCEPT
  sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  sudo iptables -A INPUT -i wg0 -j ACCEPT
  sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
  sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  sudo iptables -A INPUT -p icmp -j ACCEPT
  sudo iptables -A INPUT -s 169.254.169.254 -j ACCEPT
  sudo iptables -A INPUT -p tcp -m multiport --dports 8030:8033,8088,9000,9870,8040,8042,9864,9866,9867,13562 -j DROP
  sudo iptables -P INPUT DROP
  echo "$ROLE firewall applied; it will undo itself in 150 seconds unless you confirm"
  ;;
keep)
  touch "$KEEP"
  sudo systemctl stop mesh-fw-revert.timer >/dev/null 2>&1 || true
  echo "$ROLE firewall kept"
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
  echo "-- listening Java sockets"; sudo ss -ltnp | grep java | awk '{print $4, $6}' | sort
  echo "-- firewall counters (packets, bytes)"; sudo iptables -L INPUT -v -n | head -14
  echo "-- mesh transfer"; sudo wg show wg0 transfer
  if [ "$ROLE" = master ]; then
    echo "-- HDFS and YARN"
    for i in $(seq 1 24); do
      s="$(hdfs dfsadmin -safemode get 2>/dev/null || true)"
      case "$s" in *OFF*) break ;; esac
      sleep 5
    done
    echo "$s"
    hdfs dfsadmin -report 2>/dev/null | grep -E 'Live datanodes|Missing blocks' || true
    yarn node -list 2>/dev/null | tail -3
    hdfs dfs -ls 2>/dev/null | head -4
  fi
  ;;
*) fail "unknown step $STEP" ;;
esac
