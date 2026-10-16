#!/usr/bin/env bash
# Rehearsal of m513-keylist-sync.sh (Cloud Shell) away from the cluster: a stand-in for gcloud that maps node:path to folders, two node folders with the bundles that two REAL
# signing services made (with a stand-in quote command), the REAL bundle tool of a real jar, the REAL m513_bundle_extract.py and the REAL verify-binding.sh.
# Usage: bash m513-keylist-sync-rehearse.sh KITDIR JARS WORKOUT
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
KIT="$1"; JARS="$2"; WORKOUT="$3"; R=$(mktemp -d); fail=0; CPJ="$(ls "$JARS"/*.jar | tr '\n' ':')"
res() { if grep -q -- "$2" "$R/out.txt"; then echo "CAUGHT/OK  $1  ->  $2"; else echo "NOT AS EXPECTED  $1 (wanted: $2)"; sed 's/^/      | /' "$R/out.txt" | tail -6; fail=1; fi; }
ok_() { echo "CAUGHT/OK  $1"; }; bad_() { echo "NOT AS EXPECTED  $1"; fail=1; }
mkdir -p "$R/xbin"; if ! command -v xxd >/dev/null; then cat > "$R/xbin/xxd" <<'EOX'
#!/usr/bin/env python3
import sys
a = sys.argv[1:]; skip = int(a[a.index("-s") + 1]); length = int(a[a.index("-l") + 1]); data = open(a[-1], "rb").read()[skip:skip + length].hex()
for i in range(0, len(data), 60): print(data[i:i + 60])
EOX
chmod +x "$R/xbin/xxd"; export PATH="$R/xbin:$PATH"; fi
cat > "$R/fake-quote.sh" <<'EOQ'
#!/usr/bin/env bash
python3 - "$1" "$2" <<'PY'
import hashlib, sys
st = open(sys.argv[1], 'rb').read()
q = bytearray(b'\x04\x00' + b'\x00' * 630)
q[568:632] = hashlib.sha512(st).digest()
open(sys.argv[2], 'wb').write(bytes(q))
PY
EOQ
chmod +x "$R/fake-quote.sh"
cat > "$R/gcloud" <<'EOG'
#!/usr/bin/env bash
N="$FAKE_NODES"
map() { case "$1" in *:*) n="${1%%:*}"; p="${1#*:}"; p="${p/#\~/$N/$n/home}"; echo "$p" ;; *) echo "$1" ;; esac; }
shift   # compute
case "$1" in
  scp) shift; args=(); for a in "$@"; do case "$a" in --zone=*) ;; *) args+=("$a") ;; esac; done
       last=$(( ${#args[@]} - 1 )); dst="${args[$last]}"; unset "args[$last]"; dstp=$(map "$dst")
       for s in "${args[@]}"; do
         case "$s" in *:*) [ -n "${FAKE_FAIL_NODE:-}" ] && [ "${s%%:*}" = "$FAKE_FAIL_NODE" ] && { echo "ssh: connection refused" >&2; exit 1; } ;; esac
         case "$dst" in *:*) [ -n "${FAKE_FAIL_NODE:-}" ] && [ "${dst%%:*}" = "$FAKE_FAIL_NODE" ] && { echo "ssh: connection refused" >&2; exit 1; } ;; esac
         sp=$(map "$s"); cp $sp "$dstp" || exit 1
       done ;;
  ssh) shift; node="$1"; shift; cmd=""; for a in "$@"; do case "$a" in --command=*) cmd="${a#--command=}" ;; esac; done
       [ "$node" = "${FAKE_FAIL_NODE:-}" ] && { echo "ssh: connection refused" >&2; exit 1; }
       HOME="$N/$node/home" bash -c "$cmd" ;;
esac
EOG
chmod +x "$R/gcloud"
python3 - "$R" "$WORKOUT" <<'PYJ'
import os, sys, zipfile
r, src = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(r + "/attested-hdfs.jar", "w", zipfile.ZIP_DEFLATED)
for root, _, files in os.walk(os.path.join(src, "org/apache/nutch/attested")):
    for f in sorted(files):
        if f.startswith(("AttestedFsSmoke", "SigCoreTest", "KeyCoreTest", "M512", "M513", "FakeHdfsCli")): continue
        p = os.path.join(root, f); z.write(p, os.path.relpath(p, src))
z.close()
PYJ
mknodes() {   # two nodes, each with the bundle of a real service
  rm -rf "$R/nodes"; for n in tdx-lab tdx-lab-worker; do mkdir -p "$R/nodes/$n/home/hadoop/share/hadoop/common/lib" "$R/nodes/$n/home/tc-keys"; cp "$R/attested-hdfs.jar" "$R/nodes/$n/home/hadoop/share/hadoop/common/lib/"
    ( timeout 30 java -cp "$CPJ$WORKOUT" org.apache.nutch.attested.KeyService --dir "$R/nodes/$n/home/tc-keyservice" --port 0 --list-dir "$R/nodes/$n/home/tc-keys/list" --quote-cmd "$R/fake-quote.sh" --host "$n" >/dev/null 2>&1 & echo $! > "$R/pid-$n" )
    for i in $(seq 1 60); do ls "$R/nodes/$n/home/tc-keyservice"/TDX-*.attestkey >/dev/null 2>&1 && break; sleep 0.5; done
    kill $(cat "$R/pid-$n") 2>/dev/null; done
}
run() { ( M513_GCLOUD="$R/gcloud" FAKE_NODES="$R/nodes" bash "$KIT/ops/attested/m513-keylist-sync.sh" "$R/w$1" ) >"$R/out.txt" 2>&1; echo $?; }
echo "=== 1. the happy path"
mknodes; rc=$(run 1); cat "$R/out.txt" | tail -14 | cut -c1-190
res "T1 the exchange passes" "M513-SYNC-OK"
[ "$rc" = 0 ] && ok_ "T1b exit 0" || bad_ "T1b"
M="$(basename "$(ls "$R/nodes/tdx-lab/home/tc-keyservice"/TDX-*.attestkey)")"; W="$(basename "$(ls "$R/nodes/tdx-lab-worker/home/tc-keyservice"/TDX-*.attestkey)")"
[ -f "$R/nodes/tdx-lab/home/tc-keys/list/$M" ] && [ -f "$R/nodes/tdx-lab/home/tc-keys/list/$W" ] && [ -f "$R/nodes/tdx-lab-worker/home/tc-keys/list/$M" ] && [ -f "$R/nodes/tdx-lab-worker/home/tc-keys/list/$W" ] && ok_ "T1c both bundles are in both key lists" || bad_ "T1c"
[ -f "$R/w1/quotes/quote-tdx-lab.bin" ] && [ -f "$R/w1/quotes/quote-tdx-lab-worker.bin" ] && [ "$(stat -c %s "$R/w1/quotes/quote-tdx-lab.bin")" = 632 ] && ok_ "T1d the two quotes are kept for the laptop" || bad_ "T1d"
[ -f "$R/keylist-sync-quotes.tar.gz" ] && ok_ "T1e the quotes and bundles are packed" || bad_ "T1e"
res "T1f the laptop command is printed" "check.exe"
echo "=== 2. faults: it must stop, say why, and put nothing into any key list"
mknodes; rm -f "$R/nodes/tdx-lab-worker/home/tc-keyservice"/*.attestkey; rc=$(run 2); res "T2 a node has no bundle (its window is not open): the fetch fails and the message says what to check" "M513-SYNC-STOP: cannot fetch the bundle of tdx-lab-worker (is its window open and its service running?)"
mknodes; cp "$R/nodes/tdx-lab/home/tc-keyservice"/TDX-*.attestkey "$R/nodes/tdx-lab-worker/home/tc-keyservice/"; rc=$(run 3); res "T3 a node has two bundles (an earlier window left one)" "tdx-lab-worker has 2 TDX bundles"
mknodes; rm -f "$R/nodes/tdx-lab-worker/home/tc-keyservice"/*.attestkey; cp "$R/nodes/tdx-lab/home/tc-keyservice"/TDX-*.attestkey "$R/nodes/tdx-lab-worker/home/tc-keyservice/"; rc=$(run 4); res "T4 both machines report the same key" "both machines report the same key"
mknodes; python3 - "$R/nodes/tdx-lab-worker/home/tc-keyservice" <<'PY'
import base64, glob, sys
f = glob.glob(sys.argv[1] + "/TDX-*.attestkey")[0]; l = open(f).read().split("\n"); q = bytearray(base64.b64decode(l[2][6:])); q[600] ^= 1
open(f, "w").write(l[0] + "\n" + l[1] + "\nquote=" + base64.b64encode(bytes(q)).decode() + "\n")
PY
rc=$(run 5); res "T5 a quote whose REPORTDATA was changed is found" "FAIL: tdx-lab-worker: the quote does not match its statement"; res "T5b ... and nothing was put into any key list" "M513-SYNC-STOP: a bundle does not match its quote: nothing was put into any key list"
[ -z "$(ls "$R/nodes/tdx-lab/home/tc-keys/list" 2>/dev/null | grep -v "^TDX-" )" ] && [ "$(ls "$R/nodes/tdx-lab-worker/home/tc-keys/list" 2>/dev/null | wc -l)" -le 1 ] && ok_ "T5c the key lists hold only each node's own bundle" || bad_ "T5c"
mknodes; FAKE_FAIL_NODE=tdx-lab-worker rc=$(FAKE_FAIL_NODE=tdx-lab-worker run 6); res "T6 a node cannot be reached" "M513-SYNC-STOP: cannot fetch the bundle of tdx-lab-worker"
mknodes; mkdir -p "$R/w7"; rc=$(run 7); res "T7 the work folder exists already" "M513-SYNC-STOP: .*w7 exists already"
mknodes; python3 - "$R/nodes/tdx-lab/home/tc-keyservice" <<'PY'
import glob, sys
f = glob.glob(sys.argv[1] + "/TDX-*.attestkey")[0]; l = open(f).read().split("\n"); open(f, "w").write(l[0] + "\n" + l[1] + "\nquote=none\n")
PY
rc=$(run 8); res "T8 a bundle without a quote (a service key renamed as a TDX key)" "FAIL: tdx-lab: the quote does not match its statement"
mknodes; rc=$(run 9); res "T9 after all the faults, a clean run still passes" "M513-SYNC-OK"
echo; [ $fail -eq 0 ] && echo "REHEARSAL-PASS: the exchange passes with two real services, and its 8 faults are caught" || echo "REHEARSAL-FAIL"
