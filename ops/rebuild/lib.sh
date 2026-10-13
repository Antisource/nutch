# Shared helpers of the rebuild kit. Source it: . "$(dirname "$0")/lib.sh"
say() { printf '== %s\n' "$*"; }
ok() { printf '   ok: %s\n' "$*"; }
note() { printf '   note: %s\n' "$*"; }
die() { printf 'REBUILD-STOP: %s\n' "$*" >&2; exit 1; }
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${REBUILD_HOME:-$HOME}"
STATE="${REBUILD_STATE:-$HOME_DIR/.rebuild}"
mkdir -p "$STATE" 2>/dev/null || true
mark_done() { date -u +%FT%TZ > "$STATE/$1.done"; }
is_done() { [ -e "$STATE/$1.done" ]; }
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"
hadoop_env() {
  export HADOOP_HOME="${HADOOP_HOME:-$HOME_DIR/hadoop}"
  export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
  export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
}
