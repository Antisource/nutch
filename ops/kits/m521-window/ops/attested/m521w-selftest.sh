#!/usr/bin/env bash
# The self-test of the window kit of step 5.2.1, run on the master BEFORE the window: it changes nothing on the cluster. It unpacks nothing itself: run it from the unpacked kit.
#   bash ops/attested/m521w-selftest.sh          prints the six results; every one must say PASS
# It needs ~/m521b (the built jar of part 2), ~/m521/tree (the scratch clone with the 5.2.1 sources) and the installed (measured) jar of Hadoop.
set -uo pipefail
HOME_="${M521S_HOME:-$HOME}"; A="$(cd "$(dirname "$0")" && pwd)"; K="$(dirname "$(dirname "$A")")"; W="${M521S_WORK:-$HOME_/m521wkit-selftest}"
HCP_CMD="${M521S_HADOOP:-hadoop}"; NEWJAR_SRC="$HOME_/m521b/attested-hdfs.jar"; BASEJAR_SRC="$HOME_/hadoop/share/hadoop/common/lib/attested-hdfs.jar"; TREE="$HOME_/m521/tree"
echo "$(date -u +%FT%TZ)"; hostname
[ -f "$NEWJAR_SRC" ] && [ -f "$BASEJAR_SRC" ] && [ -d "$TREE" ] || { echo "M521WS-STOP: ~/m521b/attested-hdfs.jar, the installed jar or ~/m521/tree is missing"; exit 1; }
rm -rf "$W" && mkdir -p "$W/classes" "$W/tools" "$W/jars" "$W/base" "$W/stubs"
cp "$NEWJAR_SRC" "$W/newjar.jar" && (cd "$W/classes" && python3 -m zipfile -e "$W/newjar.jar" .) && (cd "$W/base" && python3 -m zipfile -e "$BASEJAR_SRC" .)
HCP="$($HCP_CMD classpath)"; for p in $(echo "$HCP" | tr ':' ' '); do for j in $p; do case "$j" in *attested-hdfs*) ;; *.jar) ln -sf "$j" "$W/jars/" ;; esac; done; done
javac -source 11 -target 11 -Xlint:-options -nowarn -cp "$W/newjar.jar:$HCP" -d "$W/tools" "$TREE/ops/attested/AttestedFsSmoke.java" "$K/rehearsal/FakeHdfsCli.java" && echo "compiled: the smoke test (the stand-in for HDFS needs it) and the fake HDFS command line"
echo "##### 1. the window script rehearsal (47 checks)"; bash "$A/m521-window-rehearse.sh" "$K" "$TREE" "$W/jars" "$W/stubs" "$W/classes" "$W/base" "$W/tools" 2>&1 | tail -1
echo "##### 2. the live script rehearsal (22 checks)"; M521R_VECTORS="$K/testdata" bash "$A/m521-live-rehearse.sh" "$A" "$W/newjar.jar" "$W/jars" "$W/tools" 2>&1 | tail -1
echo "##### 3. the key list exchange rehearsal (16 checks)"; bash "$A/m513-keylist-sync-rehearse.sh" "$K" "$W/jars" "$W/classes" 2>&1 | tail -1
echo "##### 4. the real bundles of run 15 are admitted by the built jar (the same check that the window makes on the live bundles)"
for b in "$K"/testdata/TDX-*.attestkey; do java -cp "$W/newjar.jar" org.apache.nutch.attested.AttestedKeyTool bundle-admit "$b" "$A/reference-measurements-m521.txt" 2>&1 | grep -o '^ADMIT.*' | cut -c1-120; done
echo "##### 5. the files of the kit equal the list"; (cd "$K/.." && sha256sum -c m521wkit-expected.sha 2>&1 | grep -c ': OK$' | sed 's/^/files identical to the list: /')
echo "$(date -u +%FT%TZ)"
