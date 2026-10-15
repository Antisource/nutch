# Source this file:  source /opt/tc-shared/bin/tc-env.sh
# It points your shell at the shared, read-only copy of the measured Hadoop client, so that hdfs, yarn and hadoop go through
# the same wrapper and the same configuration as the cluster itself. Nothing in /opt/tc-shared can be changed by you.
export TC_SHARED="${TC_SHARED:-/opt/tc-shared}"
export HADOOP_HOME="$TC_SHARED/hadoop"
export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
export HADOOP_LOG_DIR="${TMPDIR:-/tmp}/tc-hadoop-logs-$(id -un)"
mkdir -p "$HADOOP_LOG_DIR" 2>/dev/null
export TC_NUTCH="$TC_SHARED/nutch"
case ":$PATH:" in *":$HADOOP_HOME/bin:"*) ;; *) export PATH="$HADOOP_HOME/bin:$TC_SHARED/bin:$PATH" ;; esac
echo "shared measured client: HADOOP_HOME=$HADOOP_HOME   user=$(id -un)   (read /opt/tc-shared/README.txt for the rules)"
