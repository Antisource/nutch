#!/usr/bin/env bash
# Run on a node by mesh-outside.sh. Usage: mesh-outside-node.sh <role> <peer-ordinary-ip> <peer-mesh-ip>
# Tries the peer's Hadoop ports over the ordinary network (should get no answer) and over the mesh (should open).
set -uo pipefail
ROLE="$1"; VPC="$2"; MESH="$3"
export HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
probe() {  # probe <ip> <port>
  if timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then echo "OPEN"; else echo "no answer (dropped or refused)"; fi
}
if [ "$ROLE" = worker ]; then
  PORTS="8032 9000 9870"      # the master's ResourceManager, NameNode and NameNode web page
else
  PORTS="9866 9864 8042 13562" # the worker's DataNode, DataNode web, NodeManager web and shuffle
fi
echo "-- $ROLE tries the peer's Hadoop ports over the ORDINARY network ($VPC)"
for p in $PORTS; do printf '   port %-6s %s\n' "$p" "$(probe "$VPC" "$p")"; done
echo "-- $ROLE tries the same ports over the MESH ($MESH)"
for p in $PORTS; do printf '   port %-6s %s\n' "$p" "$(probe "$MESH" "$p")"; done
if [ "$ROLE" = worker ]; then
  echo "-- the worker tries to submit a job to the master's ordinary address ($VPC), as a stranger on the network would"
  JAR="$(ls "$HADOOP_HOME"/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -1)"
  OUT="$(timeout 120 hadoop jar "$JAR" pi -D fs.defaultFS=hdfs://$VPC:9000 -D yarn.resourcemanager.hostname=$VPC -D ipc.client.connect.timeout=3000 -D ipc.client.connect.max.retries.on.timeouts=1 2 10 2>&1)"
  RC=$?
  echo "$OUT" | grep -E 'Job Finished|Estimated value|Call From|SocketTimeout|ConnectException|failed' | head -3 | cut -c1-220
  echo "   job attempt exit code: $RC (non-zero and no 'Job Finished' means the job was refused)"
fi
