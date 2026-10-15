#!/usr/bin/env bash
# A one-command test that your setup works: who you are, that the wrapper is the cluster's file system, that your HDFS folder
# exists, that a node is registered, and that a file you write through the wrapper gets a record and can be read and removed.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/tc-env.sh" >/dev/null
U="${TCS_USER:-$(id -un)}"; PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"; bad=0
ok() { echo "   ok:   $*"; }; no() { echo "   FAIL: $*"; bad=$((bad+1)); }
echo "tc-check for $U on $(hostname)"
eff="$(hdfs getconf -confKey fs.hdfs.impl 2>&1 | tail -1)"; case "$eff" in *Attested*) ok "the wrapper is the cluster's file system ($eff)" ;; *) no "fs.hdfs.impl is '$eff', not the wrapper" ;; esac
if hdfs dfs -test -d "/user/$U"; then ok "/user/$U exists"; else no "/user/$U does not exist: ask the admin to run tc-user-add.sh $U"; fi
n="$(yarn node -list 2>/dev/null | awk -F'\t' '$2 ~ /RUNNING/ {c++} END {print c+0}')"; [ "$n" -ge 1 ] && ok "$n YARN node(s) RUNNING" || no "no YARN node is RUNNING"
f="/user/$U/tc-check-$(date +%s)-$$.txt"
if printf 'hello\n' | hdfs dfs -put - "$f" 2>/dev/null; then
  [ "$(hdfs dfs -cat "$f" 2>/dev/null)" = hello ] && ok "wrote and read back a file through the wrapper" || no "the file could not be read back"
  hdfs dfs $PLAIN -ls "/user/$U" 2>/dev/null | grep -q "/\.$(basename "$f")\.attested\$" && ok "the wrapper made its record next to it" || no "no record was made next to the file"
  hdfs dfs -rm -skipTrash "$f" >/dev/null 2>&1; hdfs dfs $PLAIN -test -e "$f" && no "the test file is still there" || ok "the test file is removed"
  hdfs dfs $PLAIN -ls "/user/$U" 2>/dev/null | grep -q "/\.$(basename "$f")\.attested\$" && echo "   note: the wrapper's delete left the record of the test file (harmless; remove it with the plain client if you like)"
else no "could not write a file to /user/$U"; fi
"$H/tc-busy.sh" status
[ "$bad" = 0 ] && echo "TC-CHECK-OK" || { echo "TC-CHECK-FAILED ($bad)"; exit 1; }
