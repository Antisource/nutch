#!/usr/bin/env bash
# The self-test of the window kit of step 5.2.2, run in Cloud Shell BEFORE the test mesh is touched: it changes nothing on the cluster and does not contact the nodes.
#   bash ops/attested/m522w-selftest.sh JAR        JAR = the doorman's jar (the jar built in part 2b, copied to Cloud Shell)
set -uo pipefail
JAR="${1:?usage: $0 JAR}"; A="$(cd "$(dirname "$0")" && pwd)"; K="$(dirname "$(dirname "$A")")"
echo "$(date -u +%FT%TZ)"; hostname
[ -f "$JAR" ] || { echo "M522WS-STOP: no jar at $JAR"; exit 1; }
for t in java python3 base64; do command -v $t >/dev/null && echo "have $t" || { echo "M522WS-STOP: $t is missing"; exit 1; }; done
echo "jar: $(sha256sum "$JAR" | cut -c1-16)  $(python3 -m zipfile -l "$JAR" | grep -c '\.class') classes"
echo "##### 1. the rehearsal of the doorman's scripts (29 checks: the real scripts and the real doorman, fake nodes that can misbehave, a rogue node)"; bash "$A/mesh-admit-rehearse.sh" "$A" "$JAR" "$K/testdata" "$A/reference-measurements-m521.txt" 2>&1 | tail -1
echo "##### 2. the jar's doorman admits the two REAL node bundles of 17 October (the clock is set to 08:20 because the bundles are old)"
java -cp "$JAR" org.apache.nutch.attested.AttestedKeyTool node-admit-all "$A/reference-measurements-m521.txt" "$A/mesh-peers-m522.txt" "${TMPDIR:-/tmp}/m522ws-admitted.tsv" --now 2026-10-17T08:20:00Z "$K/testdata/node-bundle-tdx-lab.attestnode" "$K/testdata/node-bundle-tdx-lab-worker.attestnode" 2>&1 | grep '^NODES\|^REJECT' | cut -c1-150; rm -f "${TMPDIR:-/tmp}/m522ws-admitted.tsv"
echo "##### 3. the policy table that the window uses"; grep -v '^#' "$A/mesh-peers-m522.txt"
echo "##### 4. the files of the kit equal the list"; (cd "$K/.." && sha256sum -c m522wkit-expected.sha 2>&1 | grep -c ': OK$' | sed 's/^/files identical to the list: /')
echo "$(date -u +%FT%TZ)"
