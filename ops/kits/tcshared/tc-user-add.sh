#!/usr/bin/env bash
# ADMIN tool (run by the HDFS superuser, the user who started the NameNode): give one or more Linux users their own HDFS folder.
#   tc-user-add.sh USER [USER ...]
# For each user: /user/USER owned by USER (mode 755), and the YARN staging folder made writable for everybody (mode 1777), which
# every job submission needs. It uses the plain client, because it only creates folders. The users must already exist on this
# machine (a person's Linux account is created the first time they log in).
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: tc-user-add.sh USER [USER ...]" >&2; exit 2; }
HH="${TCS_HAD:-$HOME/hadoop}"; HDFS="$HH/bin/hdfs"; PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"; rc=0
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
for u in "$@"; do
  case "$u" in *[!a-zA-Z0-9_.-]*|"") echo "TC-USER-ADD-STOP: '$u' is not a plausible user name" >&2; rc=1; continue ;; esac
  id -u "$u" >/dev/null 2>&1 || { echo "TC-USER-ADD-STOP: there is no Linux user '$u' on this machine; they must log in to tdx-lab once first" >&2; rc=1; continue; }
  g="$(id -gn "$u")"
  "$HDFS" dfs $PLAIN -mkdir -p "/user/$u" && "$HDFS" dfs $PLAIN -chown "$u:$g" "/user/$u" && "$HDFS" dfs $PLAIN -chmod 755 "/user/$u" || { echo "TC-USER-ADD-STOP: HDFS refused for $u (are you the HDFS superuser?)" >&2; rc=1; continue; }
  "$HDFS" dfs $PLAIN -mkdir -p /tmp/hadoop-yarn/staging && "$HDFS" dfs $PLAIN -chmod 1777 /tmp/hadoop-yarn/staging || { echo "TC-USER-ADD-STOP: could not prepare the YARN staging folder" >&2; rc=1; continue; }
  echo "TC-USER-ADD-OK: $("$HDFS" dfs $PLAIN -ls -d "/user/$u" | awk '{print $1, $3, $4, $8}')"
done
exit $rc
