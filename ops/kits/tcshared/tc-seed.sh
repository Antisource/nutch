#!/usr/bin/env bash
# Put a seed file into HDFS through the wrapper, so that it gets its record (the A2 rule: no file without a record).
#   tc-seed.sh LOCAL_SEED_FILE NAME      creates /user/<you>/seeds-NAME/ and puts the file in it
# Use the printed folder as the seed folder of your crawl. It refuses to reuse a name.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/tc-env.sh" >/dev/null
U="${TCS_USER:-$(id -un)}"; F="${1:?usage: tc-seed.sh LOCAL_SEED_FILE NAME}"; N="${2:?usage: tc-seed.sh LOCAL_SEED_FILE NAME}"
case "$N" in *[!a-zA-Z0-9_-]*|"") echo "TC-SEED-STOP: NAME must be letters, digits, - and _" >&2; exit 1 ;; esac
[ -f "$F" ] || { echo "TC-SEED-STOP: no such file: $F" >&2; exit 1; }
T="/user/$U/seeds-$N"; PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
hdfs dfs -test -d "/user/$U" || { echo "TC-SEED-STOP: /user/$U does not exist; ask the admin to run tc-user-add.sh $U" >&2; exit 1; }
hdfs dfs -test -e "$T" && { echo "TC-SEED-STOP: $T exists already; use a new NAME" >&2; exit 1; }
hdfs dfs -mkdir -p "$T" && hdfs dfs -put "$F" "$T/" || { echo "TC-SEED-STOP: the upload failed" >&2; exit 1; }
B="$(basename "$F")"
if hdfs dfs $PLAIN -ls "$T" 2>/dev/null | grep -q "/\.$B\.attested\$"; then echo "TC-SEED-OK: $T/$B has its record (.$B.attested); use $T as the seed folder"; else echo "TC-SEED-WARNING: $T/$B is stored but its record was not found: is the cluster in wrapped mode?" >&2; exit 1; fi
