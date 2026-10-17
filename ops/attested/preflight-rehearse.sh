#!/usr/bin/env bash
# Rehearsal of preflight.sh: a local bare repository stands in for GitHub, so that each failure can be made on purpose.
#   bash ops/attested/preflight-rehearse.sh REPO_DIR       REPO_DIR = a clean clone that contains preflight.sh and its baseline
set -uo pipefail
SRC="$(cd "${1:?usage: $0 REPO_DIR}" && pwd)"; BR="${2:-feat/tee-hadoop-cluster}"; PASS=0; FAILN=0
chk() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  pass: $1"; else FAILN=$((FAILN+1)); echo "  FAIL: $1"; fi; }
R="$(mktemp -d)"; git clone -q --bare "$SRC" "$R/origin.git" && git -C "$R/origin.git" branch -q -f "$BR" HEAD 2>/dev/null
pf() { ( cd "$1" && bash ops/attested/preflight.sh . "$BR" 2>&1 ); }
fresh() { rm -rf "$R/$1"; git clone -q --branch "$BR" "$R/origin.git" "$R/$1"; }
push_change() { # $1 = shell snippet run in a work clone, $2 = message
  rm -rf "$R/work"; git clone -q --branch "$BR" "$R/origin.git" "$R/work"; ( cd "$R/work" && eval "$1" && git add -A && { git -c user.email=t@t -c user.name=t commit -q -m "$2" >/dev/null 2>&1 || true; } && git push -q origin "$BR" ); }
echo "=== 1. the happy path: a fresh clone of the latest commit"
fresh a; out="$(pf "$R/a")"; echo "$out" | tail -3 | cut -c1-170
chk "PREFLIGHT-OK on the latest commit, with the sweep and every facts list at its baseline" $(grep -q '^PREFLIGHT-OK' <<<"$out"; echo $?)
echo "=== 2. faults: it must refuse, and say why"
push_change 'echo "x" >> docs/README.md' "docs: a later commit"
out="$(pf "$R/a")"; chk "a working copy that is behind GitHub is refused (the head was remembered, not looked at)" $(grep -q '^PREFLIGHT-FAILED' <<<"$out" && grep -q 'but GitHub has' <<<"$out"; echo $?)
fresh b; echo "local" >> "$R/b/docs/README.md"; out="$(pf "$R/b")"; chk "local changes are refused" $(grep -q 'there are local changes' <<<"$out" && grep -q '^PREFLIGHT-FAILED' <<<"$out"; echo $?)
push_change 'python3 - <<"PY"
p = "docs/milestone-plan.md"; s = open(p).read(); s = s.replace("step 5.3 and the rest of step 5.2 open", "5.2 and 5.3 open"); open(p, "w").write(s)
PY' "docs: a stale summary"
fresh c; out="$(pf "$R/c")"; chk "a stale status summary is refused by the sweep" $(grep -q '^PREFLIGHT-FAILED' <<<"$out" && grep -q 'still says\|does not contain' <<<"$out"; echo $?)
push_change 'python3 - <<"PY"
p = "docs/milestone-plan.md"; s = open(p).read(); s = s.replace("5.2 and 5.3 open", "step 5.3 and the rest of step 5.2 open"); open(p, "w").write(s)
PY' "docs: the summary is right again"
fresh d; out="$(pf "$R/d")"; chk "once the summary is right again the preflight passes (the sweep, not luck)" $(grep -q '^PREFLIGHT-OK' <<<"$out"; echo $?)
push_change 'python3 - <<"PY"
import glob
t = open("ops/attested/docs-facts-m513.tsv").read().split("\n"); d = [l for l in t if l and not l.startswith("#")][0].split("\t")
p = d[2].replace("@docs:", "") if d[2].startswith("@docs:") else d[0]
s = open(p).read(); i = s.index(d[1]) if d[1] in s else -1
print("quoted text found:", i >= 0)
open(p, "w").write(s.replace(d[1], d[1][:-3] + "XXX", 1))
PY' "docs: a quoted phrase changes"
fresh e; out="$(pf "$R/e")"; chk "a document that an earlier facts list quotes was changed: the baseline comparison refuses it" $(grep -q '^PREFLIGHT-FAILED' <<<"$out" && grep -q 'baseline says' <<<"$out"; echo $?)
push_change 'git -c user.email=t@t -c user.name=t revert --no-edit HEAD >/dev/null' "docs: the quoted phrase is restored"
fresh e2; out="$(pf "$R/e2")"; chk "with the quoted phrase restored the preflight passes again (the failure was that change and nothing else)" $(grep -q '^PREFLIGHT-OK' <<<"$out"; echo $?)
push_change 'cp ops/attested/docs-facts-m513.tsv ops/attested/docs-facts-zz.tsv' "chore: a new facts list"
fresh f; out="$(pf "$R/f")"; chk "a facts list that is not in the baseline is refused until it is added" $(grep -q 'docs-facts-zz.tsv is not in the baseline' <<<"$out"; echo $?)
push_change 'rm -f ops/attested/docs-status-expected.tsv' "chore: the expected-status file is gone"
fresh g; out="$(pf "$R/g")"; chk "a missing expected-status file is refused (the sweep cannot be skipped by deleting its rules)" $(grep -q 'is missing' <<<"$out" && grep -q '^PREFLIGHT-FAILED' <<<"$out"; echo $?)
fresh h2; out="$(cd "$R/h2" && bash ops/attested/preflight.sh . no-such-branch 2>&1)"; chk "a wrong branch name or no network is refused, not skipped" $(grep -q 'cannot fetch' <<<"$out"; echo $?)
echo; echo "pass: $PASS   fail: $FAILN"; [ "$FAILN" = 0 ] && echo "REHEARSAL-PASS: preflight.sh passes on the real state and refuses all 7 faults; $PASS checks" || echo "REHEARSAL-FAIL"
