#!/usr/bin/env bash
# Read-only. Compare what the kit would build with what THIS (working) node has: versions, packages, host names, the four
# Hadoop settings files, data folders. A difference means the kit's specification is wrong or incomplete.
#   check-existing.sh master|worker
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROLE="${1:-}"; case "$ROLE" in master|worker) ;; *) die "usage: check-existing.sh master|worker" ;; esac
H="$HOME_DIR/hadoop"; diffs=0
chk() { if eval "$2"; then ok "$1"; else echo "   DIFFERENT: $1"; diffs=$((diffs + 1)); fi; }
say "versions"
chk "Ubuntu 22.04" 'grep -q "^VERSION_ID=\"22.04\"" /etc/os-release'
chk "Hadoop 3.4.3" '"$H/bin/hadoop" version 2>/dev/null | head -1 | grep -q "Hadoop 3.4.3"'
chk "Java 11" 'java -version 2>&1 | head -1 | grep -q "\"11\."'
say "packages the kit installs"
PK="openjdk-11-jdk-headless ant git python3 zstd curl ca-certificates libcld2-0 wireguard-tools"; [ "$ROLE" = master ] && PK="$PK maven"
for p in $PK; do chk "package $p" "dpkg-query -W -f='\${Status}' $p 2>/dev/null | grep -q 'install ok installed'"; done
say "host names"
chk "hadoop-master in /etc/hosts" "grep -qE '[[:space:]]hadoop-master\$' /etc/hosts"
chk "hadoop-worker in /etc/hosts" "grep -qE '[[:space:]]hadoop-worker\$' /etc/hosts"
say "Hadoop settings (against the PLAIN core-site.xml when the wrapped configuration is in place)"
T="$(mktemp -d)"; for f in core-site hdfs-site yarn-site mapred-site; do cp "$H/etc/hadoop/$f.xml" "$T/" 2>/dev/null; done
[ -f "$HOME_DIR/cluster-mode/core-site.xml.plain" ] && cp "$HOME_DIR/cluster-mode/core-site.xml.plain" "$T/core-site.xml" && note "core-site.xml taken from the saved PLAIN version"
python3 "$KIT_DIR/hadoop_conf.py" check "$KIT_DIR/conf" "$T" "$HOME_DIR" | sed 's/^/     /'; python3 "$KIT_DIR/hadoop_conf.py" check "$KIT_DIR/conf" "$T" "$HOME_DIR" > /dev/null || diffs=$((diffs + 1)); rm -rf "$T"
chk "JAVA_HOME in hadoop-env.sh" "grep -q '^export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64' '$H/etc/hadoop/hadoop-env.sh'"
say "data folders"
for d in tmp namenode datanode; do [ "$ROLE" = worker ] && [ "$d" = namenode ] && continue; [ "$ROLE" = master ] && [ "$d" = datanode ] && continue; chk "$HOME_DIR/hadoop-data/$d" "[ -d '$HOME_DIR/hadoop-data/$d' ]"; done
echo; [ "$diffs" = 0 ] && echo "EXISTING-MATCHES-KIT ($ROLE)" || echo "EXISTING-DIFFERS-FROM-KIT ($ROLE): $diffs difference(s); the kit's specification needs fixing"
[ "$diffs" = 0 ]
