#!/usr/bin/env bash
# MANDATORY before any commit of code or documents: look at the ACTUAL repository, not at memory.
#   bash ops/attested/preflight.sh [REPO_DIR] [BRANCH]       defaults: the current folder, feat/tee-hadoop-cluster
# It refuses (PREFLIGHT-FAILED) unless all of these hold, each read from the repository itself:
#   1. the working copy is at the latest commit of the branch on GitHub (a fresh fetch, not a remembered head), and has no local changes;
#   2. every place that states a status says what ops/attested/docs-status-expected.tsv requires (docs_status_check.py);
#   3. no earlier facts list has changed its result since the baseline in ops/attested/docs-facts-baseline.tsv (a list that is not in the baseline is refused: add it with its result);
# A package of code or documents is built only after this passes, and the verification after the commit runs it again.
set -uo pipefail
REPO="${1:-.}"; BRANCH="${2:-feat/tee-hadoop-cluster}"
cd "$REPO" 2>/dev/null || { echo "PREFLIGHT-STOP: no folder $REPO" >&2; exit 2; }
bad=0; say() { echo "$*"; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }
say "== 1. the repository as it is on GitHub now"
git fetch -q origin "$BRANCH" 2>/dev/null || { no "cannot fetch origin $BRANCH (no network, or the branch name is wrong)"; say "PREFLIGHT-FAILED ($bad)"; exit 1; }
HEAD="$(git rev-parse HEAD)"; REMOTE="$(git rev-parse FETCH_HEAD)"
[ "$HEAD" = "$REMOTE" ] && ok "this working copy is at the latest commit of $BRANCH: ${HEAD:0:9} $(git log -1 --format=%s | cut -c1-80)" || no "this working copy is at ${HEAD:0:9} but GitHub has ${REMOTE:0:9}: update it first (git pull), and read what changed"
[ -z "$(git status --porcelain -uall)" ] && ok "no local changes" || no "there are local changes: $(git status --porcelain -uall | head -3 | tr '\n' ' ')"
say "== 2. every place that states a status says what it must (the sweep)"
if [ -f ops/attested/docs_status_check.py ] && [ -f ops/attested/docs-status-expected.tsv ]; then
  python3 ops/attested/docs_status_check.py ops/attested/docs-status-expected.tsv . > /tmp/preflight-status.$$ 2>&1; rc=$?
  [ $rc = 0 ] && ok "$(tail -2 /tmp/preflight-status.$$ | tr '\n' ' ')" || { no "$(tail -1 /tmp/preflight-status.$$)"; grep '^FAIL' /tmp/preflight-status.$$ | head -6 | sed 's/^/      /'; }
  rm -f /tmp/preflight-status.$$
else no "ops/attested/docs_status_check.py or docs-status-expected.tsv is missing"; fi
say "== 3. no earlier facts list has changed its result (against the baseline)"
BASE=ops/attested/docs-facts-baseline.tsv; n=0
if [ -f "$BASE" ] && [ -f ops/attested/docs_facts_check.py ]; then
  for L in $(ls ops/attested/docs-facts-*.tsv 2>/dev/null | grep -v baseline); do
    name="$(basename "$L")"; n=$((n+1))
    got="$(python3 ops/attested/docs_facts_check.py . /nonexistent . "$L" --docs-only 2>&1 | grep '^facts:' | grep -o 'text missing in the document: [0-9]*' | grep -o '[0-9]*$')"
    want="$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$BASE")"
    if [ -z "$want" ]; then no "$name is not in the baseline (add it, with its result of $got)"
    elif [ "${got:-x}" != "$want" ]; then no "$name: $got fact(s) have no text in the documents, the baseline says $want: a document that this list quotes has changed"
    fi
  done
  [ $bad -eq 0 ] && ok "all $n facts lists give the result of the baseline"
else no "$BASE or docs_facts_check.py is missing"; fi
if [ $bad -eq 0 ]; then say "PREFLIGHT-OK (head ${HEAD:0:9})"; else say "PREFLIGHT-FAILED ($bad)"; fi
[ $bad -eq 0 ]
