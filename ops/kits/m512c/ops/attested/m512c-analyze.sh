#!/usr/bin/env bash
# Milestone 5, the combined crawl: the standard checks of a run with signing and folder binding on, plus a first look at the teammate's receipt files.
# Run in CLOUD SHELL. It only reads: it fetches the run's files from both nodes, unpacks them, and runs, with the tools of the
# commit that ran (audit comparison, expected records, verification summary, NameNode comparison with its strict and negative-
# control variants), with two of them REPLACED by the updated versions in this kit's folder (nn_audit_compare.py and records_expected.py treat the
# folder identity files like record files). It also checks what the run itself found: the offline verification of the whole output, and that every
# read in the audit logs was verified with a signature and a folder binding. Nothing on the cluster is changed.
#   bash ops/attested/m512c-analyze.sh RUN [WORKDIR]       default WORKDIR=~/analysis-RUN (must not exist)
# Test hooks (rehearsal only): M512C_FETCH_DIR (already fetched files instead of gcloud), M512C_TOOLS (a folder with ops/attested), M512C_OVERLAY (the folder with the updated tools).
set -uo pipefail
RUN="${1:?usage: $0 RUN [WORKDIR]}"; W="${2:-$HOME/analysis-$RUN}"; case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
ZONE="${M512C_ZONE:-us-central1-a}"; MASTER=tdx-lab; WORKER=tdx-lab-worker; ME=rishabsdp17
REPO="https://github.com/Antisource/nutch.git"; BRANCH=feat/tee-hadoop-cluster; COMMIT=5bedce243a01e781e2e4527f3b30a9d487dafa1a
KIT="$(cd "$(dirname "$0")" && pwd)"
[ -e "$W" ] && { echo "M512C-STOP: $W exists already; remove it or give another folder" >&2; exit 1; }
mkdir -p "$W/fetch" "$W/work" "$W/out" "$W/logs" "$W/records" || exit 1
bad=0; say() { echo "$*" | tee -a "$W/out/analysis-summary.txt"; }; ok() { say "   ok:   $*"; }; no() { say "   FAIL: $*"; bad=$((bad+1)); }
stop() { say "M512C-STOP: $*"; exit 1; }
say "m512c-analyze: $(date -u +%FT%TZ)   run=$RUN   tools=commit ${COMMIT:0:9}"

say "== fetch the run's files"
if [ -n "${M512C_FETCH_DIR:-}" ]; then cp -r "$M512C_FETCH_DIR/." "$W/fetch/" || stop "cannot copy the test files"; else
  gcloud compute scp --recurse "$MASTER:~/$RUN" "$MASTER:~/$RUN-console.txt" "$W/fetch/" --zone="$ZONE" >"$W/out/fetch-master.log" 2>&1 || stop "fetching the master's files failed (see $W/out/fetch-master.log)"
  gcloud compute scp "$WORKER:~/$RUN-worker.tar.gz" "$W/fetch/" --zone="$ZONE" >"$W/out/fetch-worker.log" 2>&1 || stop "fetching the worker's pack failed (see $W/out/fetch-worker.log)"; fi
F="$W/fetch/$RUN"; [ -d "$F" ] || stop "no $RUN folder was fetched"; [ -f "$W/fetch/$RUN-worker.tar.gz" ] || stop "the worker's pack is missing"
( cd "$F" && sha256sum -c fingerprints.txt >"$W/out/fingerprints-check.txt" 2>&1 ) && ok "all $(grep -c ': OK' "$W/out/fingerprints-check.txt") fetched master files equal the fingerprints the master wrote" || { cat "$W/out/fingerprints-check.txt"; stop "a fetched file differs from the master's fingerprint list"; }
say "   worker pack sha256: $(sha256sum "$W/fetch/$RUN-worker.tar.gz" | cut -c1-64)"
grep -q "M512C-RUN-DONE ($RUN, mode" "$F/summary.txt" && ok "the master's summary says: $(grep 'M512C-RUN-DONE' "$F/summary.txt")" || no "the master's summary does not say M512C-RUN-DONE"

say "== unpack"
mkdir -p "$W/work/master" "$W/work/worker"; tar xzf "$F/master-logs.tar.gz" -C "$W/work/master" && tar xzf "$W/fetch/$RUN-worker.tar.gz" -C "$W/work/worker" || stop "unpacking failed"
for n in master worker; do cp "$W/work/$n"/attested-audit/*.tsv "$W/logs/" 2>/dev/null; cp "$W/work/$n"/attested-records/*.tsv "$W/records/" 2>/dev/null; done
nm=$(ls "$W/logs" | grep -c -E '^tdx-lab-[0-9]'); nw=$(ls "$W/logs" | grep -c '^tdx-lab-worker-'); nr=$(ls "$W/records" | wc -l)
[ "$nm" -ge 1 ] && [ "$nw" -ge 1 ] && ok "audit logs: $nm from the master, $nw from the worker; record logs: $nr" || no "audit logs missing: master $nm, worker $nw"
[ -d "$W/work/worker/userlogs" ] && ok "the worker's task logs: $(find "$W/work/worker/userlogs" -type f | wc -l) files" || no "no task logs from the worker"

say "== the tools of commit ${COMMIT:0:9}, with the two updated ones"
if [ -n "${M512C_TOOLS:-}" ]; then T="$M512C_TOOLS"; ok "test tools: $T"; else
  git clone -q --branch "$BRANCH" "$REPO" "$W/tools" >"$W/out/clone.log" 2>&1 && git -C "$W/tools" checkout -q "$COMMIT" >>"$W/out/clone.log" 2>&1 || stop "cannot get the tools (see $W/out/clone.log)"
  [ "$(git -C "$W/tools" rev-parse HEAD)" = "$COMMIT" ] && ok "tools at $COMMIT" || stop "the tools are not at $COMMIT"; T="$W/tools"; fi
A="$T/ops/attested"; B="$F/before.tsv"; AF="$F/after.tsv"
OV="${M512C_OVERLAY:-$KIT}"
for f in nn_audit_compare.py records_expected.py; do
  [ -f "$OV/$f" ] || stop "the updated tool $f is not in $OV"
  cp "$OV/$f" "$A/$f" || stop "cannot put the updated $f in place"
done
ok "nn_audit_compare.py ($(sha256sum "$A/nn_audit_compare.py" | cut -c1-12)...) and records_expected.py ($(sha256sum "$A/records_expected.py" | cut -c1-12)...) are the updated ones of this kit"
verdict() { grep -m1 -E "$2" "$W/out/$1.txt" || echo "(no verdict line)"; }

say "== the standard checks"
python3 "$A/audit_compare.py" "$B" "$AF" "$W/logs" --require-hosts tdx-lab,tdx-lab-worker >"$W/out/audit.txt" 2>&1; v=$(verdict audit '^AUDIT-(CLEAN|GAPS)')
[ "$v" = AUDIT-CLEAN ] && ok "audit_compare: AUDIT-CLEAN ($(grep -m1 'explained by the log' "$W/out/audit.txt"))" || no "audit_compare: $v (see $W/out/audit.txt)"
python3 "$A/records_expected.py" "$AF" "$W/records" "$W/logs" --cover "^/user/$ME/(crawl|seeds)-$RUN(/|\$)" --require-sidecars --out "$W/out/expected.tsv" >"$W/out/records.txt" 2>&1; v=$(verdict records '^RECORDS-(COMPLETE|GAPS)')
[ "$v" = RECORDS-COMPLETE ] && ok "records_expected: RECORDS-COMPLETE ($(grep -m1 -i -E 'judged|files' "$W/out/records.txt" | cut -c1-100))" || no "records_expected: $v (see $W/out/records.txt)"
python3 "$A/verify_summary.py" "$W/logs" >"$W/out/verify.txt" 2>&1; v=$(verdict verify '^VERIFY-(CLEAN|FAIL|NOT)')
[ "$v" = VERIFY-CLEAN ] && ok "verify_summary: VERIFY-CLEAN ($(grep -m1 -i -E 'opens' "$W/out/verify.txt" | cut -c1-100))" || no "verify_summary: $v (see $W/out/verify.txt)"
python3 "$A/nn_audit_compare.py" --nn "$F/nn-window.log" --wrapper "$W/logs" >"$W/out/nn.txt" 2>&1; v=$(verdict nn '^NN-AUDIT-COMPARE-(CLEAN|FINDINGS)')
[ "$v" = NN-AUDIT-COMPARE-CLEAN ] && ok "nn_audit_compare: NN-AUDIT-COMPARE-CLEAN ($(grep -m1 -o 'folders made with their identity file[^:]*: [0-9]*' "$W/out/nn.txt" || echo "no folder made with an identity file"))" || no "nn_audit_compare: $v (see $W/out/nn.txt)"
python3 "$A/nn_audit_compare.py" --nn "$F/nn-window.log" --wrapper "$W/logs" --strict >"$W/out/nn-strict.txt" 2>&1; say "   info: with --strict: $(verdict nn-strict '^NN-AUDIT-COMPARE-(CLEAN|FINDINGS)')"
mkdir -p "$W/logs-minus"; cp "$W/logs"/*.tsv "$W/logs-minus/"; big=$(ls -S "$W/logs-minus" | head -1); rm "$W/logs-minus/$big"
python3 "$A/nn_audit_compare.py" --nn "$F/nn-window.log" --wrapper "$W/logs-minus" >"$W/out/nn-control.txt" 2>&1; v=$(verdict nn-control '^NN-AUDIT-COMPARE-(CLEAN|FINDINGS)')
case "$v" in NN-AUDIT-COMPARE-FINDINGS*) ok "negative control: with the biggest wrapper log removed ($big) the comparison reports $v" ;; *) no "negative control NOT caught: without $big it says '$v' (the comparison would not notice a missing log)" ;; esac

say "== what the run itself found, and the signature and the folder binding of every read"
mkdir -p "$W/work/verify" && tar xzf "$F/verify-results.tar.gz" -C "$W/work/verify" 2>/dev/null && nt=$(ls "$W/work/verify/verify"/tree-*.txt 2>/dev/null | wc -l) || nt=0
if [ "$nt" -ge 2 ]; then
  badtree=0; for t in "$W/work/verify/verify"/tree-*.txt; do grep -q "^VERIFY-TREE-CLEAN" "$t" || badtree=$((badtree+1)); done
  [ "$badtree" = 0 ] && ok "the run's offline verification: $nt trees, all VERIFY-TREE-CLEAN ($(cat "$W/work/verify/verify"/tree-*.txt | grep -o 'folders=[0-9]* files=[0-9]*' | tr '\n' ' '))" || no "the run's offline verification found problems in $badtree of $nt trees (see $W/work/verify/verify)"
else no "the run's offline verification results are missing or incomplete ($nt trees found in verify-results.tar.gz)"; fi
nok=$(cat "$W/logs"/*.tsv | grep -c 'bind=ok' || true); nnone=$(cat "$W/logs"/*.tsv | grep -c 'bind=none' || true); nsok=$(cat "$W/logs"/*.tsv | grep -c 'sig=ok-test' || true); nsnone=$(cat "$W/logs"/*.tsv | grep -c 'sig=none' || true); nfail=$(cat "$W/logs"/*.tsv | grep -c 'VERIFY-FAIL' || true)
[ "$nok" -gt 0 ] && [ "$nnone" = 0 ] && ok "every verified read was bound to its folder: $nok reads with bind=ok, none with bind=none" || no "reads and their folder binding: $nok with bind=ok, $nnone with bind=none (folder binding was required, so there must be reads and none unbound)"
[ "$nsok" -gt 0 ] && [ "$nsnone" = 0 ] && ok "every verified read had a signature: $nsok reads with sig=ok-test, none with sig=none" || no "reads and their signature: $nsok with sig=ok-test, $nsnone with sig=none"
[ "$nfail" = 0 ] && ok "no VERIFY-FAIL line in any audit log" || no "$nfail VERIFY-FAIL lines in the audit logs"
ni=$(grep -c '/_attested-folder$' "$AF" || true); say "   info: identity files in the after listing: $ni; record files: $(grep -c '\.attested$' "$AF" || true)"
[ "$ni" -gt 0 ] && ok "the folders of the run have identity files" || no "no identity file in the after listing"

say "== a first look at the teammate's receipt files (information, not a pass or fail)"
python3 - "$AF" "$RUN" "$ME" <<'PY' | tee -a "$W/out/analysis-summary.txt"
import sys, re, collections
after, run, me = sys.argv[1:4]
rows = [l.rstrip("\n").split("\t") for l in open(after, encoding="utf-8", errors="replace") if l.strip()]
under = [r for r in rows if len(r) >= 4 and r[0] == "-" and ("/crawl-%s/" % run) in r[3]]
kinds = collections.Counter(); size = collections.Counter()
for r in under:
    if "/tc_receipts/" in r[3]:
        k = re.match(r"(receipts|outcomes|handshakes)-", r[3].split("/")[-1]); k = k.group(1) if k else "other"
        kinds[k] += 1; size[k] += int(r[1])
warcs = [r for r in under if r[3].endswith(".warc.gz")]
print("   tc_receipts files in the crawl folder: %d  %s" % (sum(kinds.values()), dict(kinds)))
print("   their sizes in bytes: %s" % dict(size))
print("   WARC files: %d  (%d bytes)" % (len(warcs), sum(int(r[1]) for r in warcs)))
folders = sorted({"/".join(r[3].split("/")[:-1]) for r in under if "/tc_receipts/" in r[3]})
for f in folders[:6]: print("   folder: " + f)
PY

say "== evidence"
cp -r "$F" "$W/out/$RUN-from-master"; cp "$W/fetch/$RUN-console.txt" "$W/out/" 2>/dev/null; echo "$(sha256sum "$W/fetch/$RUN-worker.tar.gz" | cut -c1-64)  $RUN-worker.tar.gz" > "$W/out/worker-pack.sha256"
if [ $bad -eq 0 ]; then say "M512C-ANALYSIS-CLEAN ($RUN)"; else say "M512C-ANALYSIS-FINDINGS ($bad): $RUN"; fi
( cd "$W/out" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS ); echo "   the files of the analysis are in $W/out ($(grep -c . "$W/out/SHA256SUMS") files listed)"
[ $bad -eq 0 ]
