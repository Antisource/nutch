#!/usr/bin/env bash
# Re-hash every file named in expected.tsv through the plain HDFS client, with the
# independent merkle_root.py, and compare with the root the wrapper recorded.
# Run on the master. Reads files; changes nothing.
#
# Usage: records_verify.sh EXPECTED.tsv
# Test hooks: ATTESTED_HDFS replaces the "hdfs" command; ATTESTED_MERKLE the path of merkle_root.py.
set -uo pipefail
EXPECTED="${1:?usage: records_verify.sh EXPECTED.tsv}"
HDFS="${ATTESTED_HDFS:-hdfs}"
# Since step 4.6 the wrapper is the cluster's default file system, so a plain "hdfs dfs" goes through it.
# The re-hash must read the bytes as they are stored, not as the wrapper verifies them, so it asks for the plain client.
PLAIN="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"
PY="${ATTESTED_MERKLE:-$(dirname "$0")/merkle_root.py}"
ok=0; bad=0
while IFS=$'\t' read -r path length chunk chunks root; do
  [ -n "$path" ] || continue
  out="$($HDFS dfs $PLAIN -cat "$path" | python3 "$PY" "$chunk")"
  set -- $out
  if [ "${1:-}" = "$root" ] && [ "${2:-}" = "$length" ]; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1)); echo "MISMATCH $path: recorded ${root:0:16}.../$length, re-hashed ${1:-?}/${2:-?}"
  fi
done < "$EXPECTED"
echo "verified: $ok   mismatched: $bad"
if [ "$bad" -eq 0 ]; then echo "RECORDS-VERIFIED"; else echo "RECORDS-MISMATCH"; exit 1; fi
